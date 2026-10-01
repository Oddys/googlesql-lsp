const std = @import("std");
const testing = std.testing;

const lsp = @import("lsp");
const Encoding = lsp.offsets.Encoding;
const Diagnostic = lsp.types.Diagnostic;
const Range = lsp.types.Range;

/// Temporary workaround for ZLS to work
/// Remove src/c.zig file and revert to this,
/// once ZLS catches up with Zig build system:
/// const c = @import("c");
const c = @import("c.zig");

pub fn main(init: std.process.Init) !void {
    var read_buffer: [256]u8 = undefined; // lsp-kit requires this buffer to be at least 128 bytes
    var stdio_transport: lsp.Transport.Stdio = .init(
        &read_buffer,
        .stdin(),
        .stdout(),
    );
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler: Handler = .init(init.gpa, init.io, transport);
    defer handler.deinit();

    // Wraps the allocator passed to `run` into ArenaAllocator and passes:
    // `arena` to Handler's method calls
    // `allocator` to Transport's method calls
    lsp.basic_server.run(
        init.io,
        init.gpa,
        transport,
        &handler,
        std.log.err,
    ) catch |e| switch (e) {
        error.EndOfStream => {
            std.log.debug("Client has stopped sending input", .{});
        },
        else => @panic("Panic!"),
    };
}

/// All LSP methods expect ArenaAllocator as a parameter
const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    files: std.StringHashMapUnmanaged([]u8),
    offset_encoding: lsp.offsets.Encoding,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .files = .empty,
            .offset_encoding = .@"utf-16",
        };
    }

    pub fn deinit(self: *Self) void {
        var files_it = self.files.iterator();
        while (files_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(self.allocator);

        self.* = undefined;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialize
    pub fn initialize(
        self: Self,
        _: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        std.log.debug("Received 'initialize' message: {}", .{request});

        if (request.clientInfo) |client_info| {
            std.log.info(
                "The client is '{s}' ({s})",
                .{ client_info.name, client_info.version orelse "unknown version" },
            );
        }

        const server_capabilities: lsp.types.ServerCapabilities = .{
            .positionEncoding = switch (self.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{ .text_document_sync_kind = .Full },
        };
        return .{
            .capabilities = server_capabilities,
            .serverInfo = .{
                .name = "GoogleSQL Language Server",
                .version = "0.1.0",
            },
        };
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialized
    pub fn initialized(
        _: *Handler,
        _: std.mem.Allocator,
        _: lsp.types.InitializedParams,
    ) void {
        std.log.debug("Received 'initialized' notification", .{});
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
    pub fn @"textDocument/didOpen"(
        self: *Self,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        const uri = params.textDocument.uri;
        const version = params.textDocument.version;

        std.log.debug(
            "Received 'textDocument/didOpen' notification for {s}, v{d}",
            .{ uri, version },
        );

        try self.putFile(uri, params.textDocument.text);
        try self.publishDiagnostics(arena, uri, version, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        self: *Self,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        const uri = params.textDocument.uri;
        const version = params.textDocument.version;

        std.log.debug(
            "Received 'textDocument/didChange' notification for {s}, v{d}",
            .{ uri, version },
        );

        for (params.contentChanges) |content_change| {
            switch (content_change) {
                .text_document_content_change_whole_document => |change| {
                    try self.putFile(uri, change.text);
                    try self.publishDiagnostics(arena, uri, version, change.text);
                },
                .text_document_content_change_partial => {
                    @panic("Partial changes are not supported");
                },
            }
        }
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
    pub fn @"textDocument/didClose"(
        self: *Handler,
        arena: std.mem.Allocator,
        notification: lsp.types.TextDocument.DidCloseParams,
    ) !void {
        std.log.debug("Received 'textDocument/didClose' notification", .{});

        const entry = self.files.fetchRemove(notification.textDocument.uri) orelse {
            std.log.warn("Closing non existent Document: '{s}'", .{notification.textDocument.uri});
            return;
        };
        defer self.allocator.free(entry.key);
        self.allocator.free(entry.value);
        try self.clearDiagnostics(arena, entry.key);
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#shutdown
    pub fn shutdown(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) ?void {
        std.log.debug("Received 'shutdown' request", .{});
        return null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#exit
    /// The `lsp.basic_server.run` function will automatically return after this function completes.
    pub fn exit(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) void {
        std.log.debug("Received 'exit' notification", .{});
    }

    /// Stores a copy of `text` under `uri`, freeing the previous text if any
    fn putFile(self: *Self, uri: []const u8, text: []const u8) !void {
        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(value);

        const entry = try self.files.getOrPut(self.allocator, key);
        if (entry.found_existing) {
            self.allocator.free(key);
            self.allocator.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = value;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_publishDiagnostics
    fn publishDiagnostics(
        self: *Self,
        arena: std.mem.Allocator,
        uri: []const u8,
        version: i32,
        text: []const u8,
    ) !void {
        const diagnostics = try diagnose(arena, .gsql, text, self.offset_encoding);
        // No `free(diagnostics)` since ArenaAllocator is used;
        std.log.debug("Publishing {d} diagnostic(s) for '{s}', v{d}", .{ diagnostics.len, uri, version });

        try self.transport.writeNotification(
            self.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .version = version, .diagnostics = diagnostics },
            .{ .emit_null_optional_fields = false },
        );
    }

    /// Publishes empty diagnostics in response to textDocument/didClose
    fn clearDiagnostics(self: *Self, arena: std.mem.Allocator, uri: []const u8) !void {
        std.log.debug("Clearing diagnostics for '{s}'", .{uri});

        try self.transport.writeNotification(
            self.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        );
    }

    // basic_server.run does not work if this is not defined
    pub fn onResponse(_: *Self, _: std.mem.Allocator, _: lsp.JsonRPCMessage.Response) void {}
};

fn errToDiagnostic(
    arena: std.mem.Allocator,
    text: []const u8,
    encoding: lsp.offsets.Encoding,
    err: c.gsql_syntax_error,
) !lsp.types.Diagnostic {
    const start: usize = if (err.start_byte < 0) 0 else @intCast(@min(err.start_byte, text.len));
    const end: usize = if (err.end_byte < 0 or err.end_byte < err.start_byte)
        start
    else
        (@intCast(@min(err.end_byte, text.len)));
    const range = lsp.offsets.locToRange(text, .{ .start = start, .end = end }, encoding);
    const message = try std.fmt.allocPrint(
        arena,
        "{s}",
        .{if (err.message == null) "<No error message>" else std.mem.span(err.message)},
    );
    return .{ .range = range, .severity = .Error, .message = .{ .string = message }, .source = "googlesql-lsp" };
}

/// A wrapper for C API so that the real implementation could be mocked in tests
const GSqlSyntax = struct {
    gsql_check_syntax: *const fn (
        sql: [*c]const u8,
        sql_len: usize,
        errors: [*c][*c]c.gsql_syntax_error,
    ) callconv(.c) c_int = c.gsql_check_syntax,
    gsql_syntax_errors_free: *const fn (
        errors: [*c]c.gsql_syntax_error,
        count: c_int,
    ) callconv(.c) void = c.gsql_syntax_errors_free,

    const gsql: GSqlSyntax = .{};
};

fn diagnose(
    arena: std.mem.Allocator,
    gsql: GSqlSyntax,
    text: []const u8,
    encoding: Encoding,
) ![]const Diagnostic {
    var errors: [*c]c.gsql_syntax_error = null;
    const num_errors = gsql.gsql_check_syntax(text.ptr, text.len, &errors);
    defer gsql.gsql_syntax_errors_free(errors, num_errors);

    if (num_errors == -1) {
        std.log.debug("Syntax check failed (internal error)", .{});
        return &.{
            .{
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 0, .character = 0 },
                },
                .severity = .Warning,
                .source = "googlesql-lsp",
                .message = .{ .string = "Syntax check failed (internal error)" },
            },
        };
    }

    if (num_errors == 0) {
        return &.{};
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    // No `errdefer diagnostics.deinit` call since ArenaAllocator is used;

    var i: usize = 0;
    while (i < num_errors) {
        const err = errors[i];
        const diagnostic = try errToDiagnostic(arena, text, encoding, err);
        try diagnostics.append(arena, diagnostic);
        i += 1;
    }
    return diagnostics.toOwnedSlice(arena);
}

// KCOV_EXCL_START
test {
    testing.refAllDecls(@This());
}

test "putFile adds text" {
    var handler: Handler = .init(std.testing.allocator, undefined, undefined);
    defer handler.deinit();

    const uri = "a.sql";
    try handler.putFile(uri, "SELECT 1;");

    const stored_text = handler.files.get(uri);
    try std.testing.expect(stored_text != null);
    try std.testing.expectEqualStrings("SELECT 1;", stored_text.?);
    try std.testing.expectEqual(1, handler.files.count());
}

test "putFile replaces text" {
    var handler: Handler = .init(std.testing.allocator, undefined, undefined);
    defer handler.deinit();

    const uri = "a.sql";
    try handler.putFile(uri, "SELECT 1;");
    try handler.putFile(uri, "SELECT 2;");

    const stored_text = handler.files.get(uri);
    try std.testing.expect(stored_text != null);
    try std.testing.expectEqualStrings("SELECT 2;", stored_text.?);
    try std.testing.expectEqual(1, handler.files.count());
}

/// Captures messages written by the handler instead of sending them to stdout
const TestTransport = struct {
    transport: lsp.Transport = .{
        .vtable = &.{
            .readJsonMessage = readJsonMessage,
            .writeJsonMessage = writeJsonMessage,
        },
    },
    buffer: [4096]u8 = undefined,
    len: usize = 0,

    fn readJsonMessage(
        _: *lsp.Transport,
        _: std.Io,
        _: std.mem.Allocator,
    ) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn writeJsonMessage(
        transport: *lsp.Transport,
        _: std.Io,
        msg: []const u8,
    ) lsp.Transport.WriteError!void {
        const self: *TestTransport = @fieldParentPtr("transport", transport);
        @memcpy(self.buffer[0..msg.len], msg);
        self.len = msg.len;
    }

    fn written(self: *TestTransport) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "didOpen stores file text" {
    var test_transport: TestTransport = .{};
    var handler: Handler = .init(std.testing.allocator, std.testing.io, &test_transport.transport);
    defer handler.deinit();

    try handler.@"textDocument/didOpen"(std.testing.allocator, .{ .textDocument = .{
        .uri = "file:///query.sql",
        .languageId = .{ .custom_value = "sql" },
        .version = 1,
        .text = "SELECT 1;",
    } });

    try std.testing.expectEqualStrings("SELECT 1;", handler.files.get("file:///query.sql").?);
    try std.testing.expectEqual(1, handler.files.count());
}

test "didOpen publishes empty diagnostics for uri and version" {
    var test_transport: TestTransport = .{};
    var handler: Handler = .init(std.testing.allocator, std.testing.io, &test_transport.transport);
    defer handler.deinit();

    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    try handler.@"textDocument/didOpen"(
        arena,
        .{
            .textDocument = .{
                .uri = "file:///query.sql",
                .languageId = .{ .custom_value = "sql" },
                .version = 100,
                .text = "SELECT 1;",
            },
        },
    );

    const parsed = try std.json.parseFromSlice(
        struct { method: []const u8, params: lsp.types.publish_diagnostics.Params },
        std.testing.allocator,
        test_transport.written(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const method = parsed.value.method;
    const params = parsed.value.params;
    try std.testing.expectEqualStrings("textDocument/publishDiagnostics", method);
    try std.testing.expectEqualStrings("file:///query.sql", params.uri);
    try std.testing.expectEqual(100, params.version);
    try std.testing.expectEqual(0, params.diagnostics.len);
}

test "didChange stores file text and publishes diagnostics" {
    var transport: TestTransport = .{};
    var handler: Handler = .init(testing.allocator, testing.io, &transport.transport);
    defer handler.deinit();

    const uri = "file://query.sql";
    const version = 2;
    const contents = "SELECT";
    const in_params: lsp.types.TextDocument.DidChangeParams = .{
        .textDocument = .{
            .uri = uri,
            .version = version,
        },
        .contentChanges = &.{
            .{ .text_document_content_change_whole_document = .{ .text = contents } },
        },
    };

    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    try handler.@"textDocument/didChange"(arena, in_params);

    const stored = handler.files.get(uri);
    try testing.expect(stored != null);
    try testing.expectEqualStrings(contents, stored.?);
    try testing.expectEqual(1, handler.files.size);

    const parsed = try std.json.parseFromSlice(
        struct { method: []const u8, params: lsp.types.publish_diagnostics.Params },
        testing.allocator,
        transport.written(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const method = parsed.value.method;
    const out_params = parsed.value.params;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", method);
    try testing.expectEqualStrings(uri, out_params.uri);
    try testing.expectEqual(version, out_params.version);
    try testing.expectEqual(1, out_params.diagnostics.len);
}

test "didClose clears the file and diagnostics" {
    var transport: TestTransport = .{};
    var handler: Handler = .init(testing.allocator, testing.io, &transport.transport);
    defer handler.deinit();

    const uri = "file://query.sql";
    try handler.putFile(uri, "SELECT 1");

    const in_params: lsp.types.TextDocument.DidCloseParams = .{ .textDocument = .{ .uri = uri } };
    try handler.@"textDocument/didClose"(testing.allocator, in_params);

    try testing.expectEqual(null, handler.files.get(uri));
    try testing.expectEqual(0, handler.files.size);

    const written = transport.written();
    const written_type = struct {
        method: []const u8,
        params: lsp.types.publish_diagnostics.Params,
    };
    const parsed = try std.json.parseFromSlice(
        written_type,
        testing.allocator,
        written,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const method = parsed.value.method;
    const params = parsed.value.params;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", method);
    try testing.expectEqualStrings(uri, params.uri);
    try testing.expectEqual(0, params.diagnostics.len);
}

test "errToDiagnostic maps byte offsets to range and copies message" {
    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const text = "SELECT 1;\nSELECT FROM";
    const err_message = "Syntax error: SELECT list must not be empty";
    const diagnostic = try errToDiagnostic(arena, text, .@"utf-16", .{
        .start_byte = 17,
        .end_byte = 21,
        .message = err_message,
    });

    try testing.expectEqual(
        Range{
            .start = .{ .line = 1, .character = 7 },
            .end = .{ .line = 1, .character = 11 },
        },
        diagnostic.range,
    );
    try testing.expectEqual(.Error, diagnostic.severity.?);
    try testing.expectEqualStrings("googlesql-lsp", diagnostic.source.?);
    try testing.expectEqualStrings(err_message, diagnostic.message.string);
}

test "errToDiagnostic handles out-of-range offsets and missing message" {
    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const text = "SEL";
    const cases = [_]c.gsql_syntax_error{
        .{ .start_byte = -1, .end_byte = -1 }, // unknown offsets
        .{ .start_byte = 2, .end_byte = 1 }, // end before start
        .{ .start_byte = 2, .end_byte = 4 }, // end past text
        .{ .start_byte = 4, .end_byte = 4 }, // both past text
    };
    const expected = [cases.len]Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 2 } },
        .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 3 } },
        .{ .start = .{ .line = 0, .character = 3 }, .end = .{ .line = 0, .character = 3 } },
    };
    for (cases, expected) |case, exp| {
        const diagnostic = try errToDiagnostic(arena, text, .@"utf-16", case);
        try testing.expectEqual(.Error, diagnostic.severity.?);
        try testing.expectEqual(exp, diagnostic.range);
        try testing.expectEqualStrings("<No error message>", diagnostic.message.string);
    }
}

/// Builds a GSqlSyntax whose check always returns `num_errs` and yields `errs`
fn mockGSqlSyntax(comptime num_errs: c_int, comptime errs: []const c.gsql_syntax_error) GSqlSyntax {
    const mock = struct {
        // errs : []const T
        // errs.* : [N]T (slice dereferencing gives an array by value; works only because
        // errs is comptime and its length N is known)
        // i.e.:
        // takes an array errs points to and creates its mutable copy
        // (None of []const T, []T or *const [N]T can be implicitly coerced to [*c]T)
        var captured_errs: [errs.len]c.gsql_syntax_error = errs.*;

        fn check(_: [*c]const u8, _: usize, errors: [*c][*c]c.gsql_syntax_error) callconv(.c) c_int {
            // &captured_errs : *[N]T -> [*c]T (coercion)
            // i.e.:
            // const tmp1: *[errs.len]c.gsql_syntax_error = &captured_errs;
            // const tmp2: [*c]c.gsql_syntax_error = tmp1;
            // errors.* = tmp2;
            errors.* = &captured_errs;

            return num_errs;
        }

        // no-op
        fn free(_: [*c]c.gsql_syntax_error, _: c_int) callconv(.c) void {}
    };
    return .{ .gsql_check_syntax = mock.check, .gsql_syntax_errors_free = mock.free };
}

test "diagnose runs syntax check and produce diagnostics" {
    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const text = "SELECT FROM WHERE";

    const failed = try diagnose(arena, mockGSqlSyntax(-1, &.{}), text, .@"utf-16");
    try testing.expectEqual(1, failed.len);
    try testing.expectEqual(.Warning, failed[0].severity.?);
    try testing.expectEqualStrings("Syntax check failed (internal error)", failed[0].message.string);

    const error_cases = [_][]const c.gsql_syntax_error{
        &.{},
        &.{.{ .start_byte = 7, .end_byte = 11, .message = "first" }},
        &.{
            .{ .start_byte = 7, .end_byte = 11, .message = "first" },
            .{ .start_byte = 12, .end_byte = 17, .message = "second" },
        },
    };

    // `comptime` because types are created
    comptime var mocks: [error_cases.len]GSqlSyntax = undefined;
    comptime for (error_cases, 0..) |e, case_num| {
        mocks[case_num] = mockGSqlSyntax(e.len, e);
    };

    for (error_cases, mocks) |errs, gsql| {
        const diagnostics = try diagnose(arena, gsql, text, .@"utf-16");
        try testing.expectEqual(errs.len, diagnostics.len);
        // No need to check each diagnostic's content - covered by test of errToDiagnostic
    }
}

// KCOV_EXCL_END
