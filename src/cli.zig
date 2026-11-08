//! Command-line parsing, in the style of Go's flag package that the Go
//! version used: -p N, -p=N, -debug and -v, with one or two dashes.

const std = @import("std");

pub const usage =
    \\Usage: postgres17-standalone [-p port] [-debug] [-v] <dataDir>
    \\  -p port   host port Postgres listens on, on all interfaces (default 5432)
    \\  -debug    boot to a shell in the Linux root instead of Postgres
    \\  -v        print version and exit
    \\
;

pub const Config = struct {
    port: u16 = 5432,
    debug: bool = false,
    version: bool = false,
    data_dir: []const u8 = "",
};

pub const Error = error{Usage};

pub fn parse(args: []const []const u8) Error!Config {
    var cfg: Config = .{};
    var positional: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') {
            if (positional != null) return error.Usage;
            positional = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            if (i + 1 < args.len and positional == null and i + 2 == args.len) {
                positional = args[i + 1];
                break;
            }
            return error.Usage;
        }
        var name = std.mem.trimStart(u8, a, "-");
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            name = name[0..eq];
        }
        if (std.mem.eql(u8, name, "p")) {
            const v = value orelse blk: {
                i += 1;
                if (i >= args.len) return error.Usage;
                break :blk args[i];
            };
            cfg.port = std.fmt.parseInt(u16, v, 10) catch return error.Usage;
            if (cfg.port == 0) return error.Usage;
        } else if (std.mem.eql(u8, name, "debug")) {
            cfg.debug = try boolValue(value);
        } else if (std.mem.eql(u8, name, "v")) {
            cfg.version = try boolValue(value);
        } else return error.Usage;
    }
    if (cfg.version) return cfg;
    cfg.data_dir = positional orelse return error.Usage;
    return cfg;
}

fn boolValue(v: ?[]const u8) Error!bool {
    const s = v orelse return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
    return error.Usage;
}

test parse {
    const t = std.testing;
    var c = try parse(&.{"data"});
    try t.expectEqual(@as(u16, 5432), c.port);
    try t.expectEqualStrings("data", c.data_dir);

    c = try parse(&.{ "-p", "5433", "-debug", "d" });
    try t.expectEqual(@as(u16, 5433), c.port);
    try t.expect(c.debug);

    c = try parse(&.{ "--p=6000", "d" });
    try t.expectEqual(@as(u16, 6000), c.port);

    c = try parse(&.{"-v"});
    try t.expect(c.version);

    try t.expectError(error.Usage, parse(&.{}));
    try t.expectError(error.Usage, parse(&.{ "a", "b" }));
    try t.expectError(error.Usage, parse(&.{ "-p", "x", "d" }));
    try t.expectError(error.Usage, parse(&.{ "-x", "d" }));
    try t.expectError(error.Usage, parse(&.{"-p"}));
}
