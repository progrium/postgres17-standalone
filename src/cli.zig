//! Command-line parsing: `minipg <command> <pgdb> [flags] [args]`, or the
//! bare form `minipg <pgdb> [sql]` for `shell`. Flags may come before or
//! after the .pgdb, as `-x`, `--name`, `--name=value` or `--name value`;
//! `--` ends them.

const std = @import("std");

pub const usage =
    \\minipg: PostgreSQL as a single executable
    \\
    \\Usage:
    \\  minipg <pgdb> [sql]                    psql on the .pgdb (created if missing), or run one statement
    \\  minipg <command> <pgdb> [flags]
    \\
    \\Commands:
    \\  init <pgdb> [--port N]                 create a .pgdb
    \\  shell <pgdb|url> [-d DB] [sql]         psql (the bare form)
    \\  serve <pgdb> [-p PORT] [--listen ADDR] [--log FILE] [--trust]
    \\                                         run the server in the foreground
    \\  stop <pgdb>                            stop its server
    \\  status <pgdb>                          whether a server is running, and its details
    \\  url <pgdb> [-d DB]                     a postgres:// URL for apps
    \\  env <pgdb> [-d DB]                     PG* and DATABASE_URL as shell exports
    \\  run <pgdb> [-d DB] -- CMD [args]       run a host command with DATABASE_URL and PG* set
    \\  logs <pgdb> [-f]                       the server's recent log
    \\  exec <pgdb> [-d DB] -- TOOL [args]     run a Postgres tool (pg_dump, psql, ...) against it
    \\  dump <pgdb> [-d DB] [pg_dump args]     pg_dump to stdout
    \\  restore <pgdb> [-d DB] [FILE]          restore a dump (SQL or custom format) from FILE or stdin
    \\  dbs <pgdb>                             list databases
    \\  create <pgdb> NAME                     create a database
    \\  drop <pgdb> NAME                       drop a database
    \\  default <pgdb> [NAME]                  show or set the default database
    \\  passwd <pgdb>                          rotate the superuser's password
    \\  versions                               Postgres versions embedded, cached and available
    \\  fetch MAJOR                            download a Postgres major's root
    \\  prune                                  remove downloaded roots
    \\
    \\Flags:
    \\  -v, --version                          print minipg's version
    \\  -h, --help                             this help
    \\
    \\Environment: MINIPG_IDLE (seconds a background server waits without
    \\clients, default 60), MINIPG_OFFLINE, MINIPG_REGISTRY, and POSTGRES_USER,
    \\POSTGRES_PASSWORD, POSTGRES_DB as defaults for init.
    \\
;

pub const Command = enum {
    init,
    shell,
    serve,
    stop,
    status,
    url,
    env,
    run,
    logs,
    exec,
    dump,
    restore,
    dbs,
    create,
    drop,
    default,
    passwd,
    versions,
    fetch,
    prune,
    help,
    version,
};

/// Flags that take a value, by command. Every other flag is a switch.
fn takesValue(cmd: Command, name: []const u8) bool {
    const common = [_][]const u8{ "d", "db" };
    for (common) |n| if (std.mem.eql(u8, n, name)) return true;
    const per: []const []const u8 = switch (cmd) {
        .init => &.{ "port", "pg", "user" },
        .serve => &.{ "p", "port", "listen", "log", "idle" },
        else => &.{},
    };
    for (per) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub const Flag = struct { name: []const u8, value: ?[]const u8 };

pub const Args = struct {
    command: Command,
    /// Positional arguments: the .pgdb first, for commands that take one.
    positional: []const []const u8 = &.{},
    flags: []const Flag = &.{},
    /// Everything after `--`.
    rest: []const []const u8 = &.{},
    /// Whether `--` was given.
    dashdash: bool = false,

    pub fn flag(a: Args, names: []const []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (a.flags) |f| for (names) |n| {
            if (std.mem.eql(u8, f.name, n)) found = f.value orelse "";
        };
        return found;
    }

    pub fn has(a: Args, names: []const []const u8) bool {
        return a.flag(names) != null;
    }

    pub fn pgdb(a: Args) ?[]const u8 {
        return if (a.positional.len > 0) a.positional[0] else null;
    }
};

pub const Error = error{ Usage, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, argv: []const []const u8) Error!Args {
    if (argv.len == 0) return .{ .command = .help };
    var cmd: Command = .shell;
    var start: usize = 0;
    const first = argv[0];
    if (std.mem.eql(u8, first, "-v") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version"))
        return .{ .command = .version };
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help"))
        return .{ .command = .help };
    if (std.meta.stringToEnum(Command, first)) |c| {
        cmd = c;
        start = 1;
    }
    var positional: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList(Flag) = .empty;
    var i = start;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            return .{ .command = cmd, .positional = positional.items, .flags = flags.items, .rest = argv[i + 1 ..], .dashdash = true };
        }
        if (a.len < 2 or a[0] != '-') {
            try positional.append(arena, a);
            continue;
        }
        var name = std.mem.trimStart(u8, a, "-");
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            name = name[0..eq];
        } else if (takesValue(cmd, name)) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            value = argv[i];
        }
        if (std.mem.eql(u8, name, "h") or std.mem.eql(u8, name, "help")) return .{ .command = .help };
        try flags.append(arena, .{ .name = name, .value = value });
    }
    return .{ .command = cmd, .positional = positional.items, .flags = flags.items };
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = try parse(a, &.{"app.pgdb"});
    try std.testing.expectEqual(Command.shell, r.command);
    try std.testing.expectEqualStrings("app.pgdb", r.pgdb().?);

    r = try parse(a, &.{ "app.pgdb", "select 1" });
    try std.testing.expectEqualStrings("select 1", r.positional[1]);

    r = try parse(a, &.{ "serve", "-p", "6000", "app.pgdb", "--trust", "--listen=0.0.0.0" });
    try std.testing.expectEqual(Command.serve, r.command);
    try std.testing.expectEqualStrings("6000", r.flag(&.{ "p", "port" }).?);
    try std.testing.expectEqualStrings("0.0.0.0", r.flag(&.{"listen"}).?);
    try std.testing.expect(r.has(&.{"trust"}));
    try std.testing.expectEqualStrings("app.pgdb", r.pgdb().?);

    r = try parse(a, &.{ "exec", "app.pgdb", "-d", "other", "--", "pg_dump", "-s" });
    try std.testing.expectEqualStrings("other", r.flag(&.{ "d", "db" }).?);
    try std.testing.expectEqual(@as(usize, 2), r.rest.len);
    try std.testing.expectEqualStrings("-s", r.rest[1]);

    r = try parse(a, &.{ "logs", "app.pgdb", "-f" });
    try std.testing.expect(r.has(&.{ "f", "follow" }));

    try std.testing.expectEqual(Command.version, (try parse(a, &.{"-v"})).command);
    try std.testing.expectEqual(Command.help, (try parse(a, &.{})).command);
    try std.testing.expectError(error.Usage, parse(a, &.{ "serve", "x", "-p" }));
}
