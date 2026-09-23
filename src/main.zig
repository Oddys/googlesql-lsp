const std = @import("std");

const lsp = @import("lsp");

const c = @import("c.zig");

// Temporary workaround for ZLS to work
// Remove src/c.zig file and revert to this,
// once ZLS catches up with Zig build system:
// const c = @import("c");

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
            std.log.info("The client is '{s}' ({s})", .{ client_info.name, client_info.version orelse "unknown version" });
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
        std.log.debug("Received 'textDocument/didOpen' notification", .{});

        const uri = params.textDocument.uri;
        try self.putFile(uri, params.textDocument.text);
        try self.publishDiagnostics(arena, uri, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        self: *Self,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        std.log.debug("Received 'textDocument/didChange' notification", .{});

        const uri = params.textDocument.uri;

        for (params.contentChanges) |content_change| {
            switch (content_change) {
                .text_document_content_change_whole_document => |change| {
                    try self.putFile(uri, change.text);
                    try self.publishDiagnostics(arena, uri, change.text);
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
    fn publishDiagnostics(self: *Self, arena: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        const diagnostics = diagnose(text);
        std.log.debug("Publishing {d} diagnostic(s) for '{s}'", .{ diagnostics.len, uri });

        try self.transport.writeNotification(
            self.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.publish_diagnostics.Params,
            .{ .uri = uri, .diagnostics = diagnostics },
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

fn diagnose(text: []const u8) []const lsp.types.Diagnostic {
    _ = text;
    return &.{
        .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 1 },
            },
            .severity = .Hint,
            .source = "googlesql-lsp",
            .message = .{ .string = "Diagnostics are wired up" },
        },
    };
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
