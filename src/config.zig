//! minipg.toml: the .pgdb's settings, as flat `key = value` lines with
//! dotted keys (valid TOML). Only strings and integers occur, so this
//! reads and writes just those.

const std = @import("std");

/// The layout version this minipg writes and the newest it opens.
pub const format_version: u32 = 1;

pub const Config = struct {
    format: u32 = format_version,
    pg_major: u32 = 0,
    pg_variant: []const u8 = "alpine",
    pg_arch: []const u8 = "",
    pg_digest: []const u8 = "",
    pg_last_opened: []const u8 = "",
    user: []const u8 = "postgres",
    password: []const u8 = "",
    database: []const u8 = "",
    port: u16 = 0,

    const Field = struct { key: []const u8, name: []const u8 };
    const fields = [_]Field{
        .{ .key = "format", .name = "format" },
        .{ .key = "pg.major", .name = "pg_major" },
        .{ .key = "pg.variant", .name = "pg_variant" },
        .{ .key = "pg.arch", .name = "pg_arch" },
        .{ .key = "pg.digest", .name = "pg_digest" },
        .{ .key = "pg.last_opened", .name = "pg_last_opened" },
        .{ .key = "user", .name = "user" },
        .{ .key = "password", .name = "password" },
        .{ .key = "database", .name = "database" },
        .{ .key = "port", .name = "port" },
    };

    pub const ParseError = error{ Syntax, OutOfMemory };

    /// Parses `text`; strings are allocated in `arena`. Unknown keys are
    /// ignored, so an older minipg reads a newer format's file far enough
    /// to see its `format` and refuse it.
    pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Config {
        var c: Config = .{ .format = 0 };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            inline for (fields) |f| {
                if (std.mem.eql(u8, key, f.key)) {
                    const T = @FieldType(Config, f.name);
                    if (T == []const u8) {
                        @field(c, f.name) = try parseString(arena, val);
                    } else {
                        @field(c, f.name) = std.fmt.parseInt(T, val, 10) catch return error.Syntax;
                    }
                }
            }
        }
        return c;
    }

    pub fn write(c: Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("# minipg settings for this .pgdb. The password is the Postgres\n# superuser's; keep this file private.\n");
        inline for (fields) |f| {
            const v = @field(c, f.name);
            if (@TypeOf(v) == []const u8) {
                try w.print("{s} = ", .{f.key});
                try writeString(w, v);
                try w.writeByte('\n');
            } else try w.print("{s} = {d}\n", .{ f.key, v });
        }
    }
};

fn parseString(arena: std.mem.Allocator, v: []const u8) Config.ParseError![]const u8 {
    if (v.len < 2 or v[0] != '"' or v[v.len - 1] != '"') return error.Syntax;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < v.len - 1) : (i += 1) {
        var ch = v[i];
        if (ch == '\\') {
            i += 1;
            if (i >= v.len - 1) return error.Syntax;
            ch = switch (v[i]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                else => return error.Syntax,
            };
        } else if (ch == '"') return error.Syntax;
        try out.append(arena, ch);
    }
    return out.items;
}

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

test "round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c: Config = .{
        .pg_major = 18,
        .pg_arch = "amd64",
        .pg_digest = "sha256:abc",
        .pg_last_opened = "18.1",
        .password = "p\"w\\x",
        .database = "my app",
        .port = 54321,
    };
    var buf: std.Io.Writer.Allocating = .init(arena.allocator());
    try c.write(&buf.writer);
    const back = try Config.parse(arena.allocator(), buf.written());
    try std.testing.expectEqual(@as(u32, 1), back.format);
    try std.testing.expectEqual(@as(u32, 18), back.pg_major);
    try std.testing.expectEqual(@as(u16, 54321), back.port);
    try std.testing.expectEqualStrings("p\"w\\x", back.password);
    try std.testing.expectEqualStrings("my app", back.database);
    try std.testing.expectEqualStrings("alpine", back.pg_variant);
}

test "unknown keys and comments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try Config.parse(arena.allocator(), "# hi\nformat = 7\nfuture.key = \"x\"\n\nport = 5\n");
    try std.testing.expectEqual(@as(u32, 7), c.format);
    try std.testing.expectEqual(@as(u16, 5), c.port);
    try std.testing.expectError(error.Syntax, Config.parse(arena.allocator(), "port = x\n"));
}
