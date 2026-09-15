const std = @import("std");

// Temporary workaround
const c = @import("c.zig");
// Remove src/c.zig file and revert to this,
// once ZLS catches up with Zig build system:
// const c = @import("c");

pub fn main() !void {
    const sql = "SELECT 1; SELECT 1 FROM; SELECT GROUP BY";
    var sql_errors: [*c]c.gsql_syntax_error = null;
    const error_count = c.gsql_check_syntax(sql.ptr, sql.len, &sql_errors);
    defer c.gsql_syntax_errors_free(sql_errors, error_count);

    std.debug.print("Found {d} syntax errors in sql.\n", .{error_count});

    for (sql_errors[0..@intCast(error_count)]) |sql_error| {
        std.debug.print(
            "byte {d}, line {d}, column {d}, messaga: {s}\n",
            .{ sql_error.start_byte, sql_error.line, sql_error.column, sql_error.message },
        );
    }
}
