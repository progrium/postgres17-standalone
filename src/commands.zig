//! The commands.

const std = @import("std");
const h9 = @import("h9");
const Ctx = @import("ctx.zig").Ctx;
const cli = @import("cli.zig");
const pgdb_mod = @import("pgdb.zig");
const client = @import("client.zig");
const control = @import("control.zig");
const server = @import("server.zig");
const roots = @import("roots.zig");
const vm = @import("vm.zig");
const net = @import("net.zig");
const paths = @import("paths.zig");

const Pgdb = pgdb_mod.Pgdb;

pub fn usageError(ctx: Ctx, comptime fmt: []const u8, args: anytype) u8 {
    ctx.warn(fmt, args);
    std.debug.print("Run minipg --help for usage.\n", .{});
    return 2;
}

/// Opens the .pgdb named on the command line, explaining a failure.
fn openPgdb(ctx: Ctx, path: []const u8) ?Pgdb {
    return pgdb_mod.open(ctx.arena, ctx.io, path) catch |err| {
        switch (err) {
            error.NotFound => ctx.warn("{s} doesn't exist (minipg init {s} creates it)", .{ path, path }),
            error.NotPgdb => ctx.warn("{s} isn't a .pgdb: it has no minipg.toml", .{path}),
            error.BadConfig => ctx.warn("{s}/minipg.toml is unreadable or malformed", .{path}),
            error.NewerFormat => ctx.warn("{s} was made by a newer minipg (its format is newer than {d}); upgrade minipg to open it", .{ path, @import("config.zig").format_version }),
            error.OutOfMemory => ctx.warn("out of memory", .{}),
        }
        return null;
    };
}

/// The settings for a new .pgdb at `path`.
fn newConfig(ctx: Ctx, args: cli.Args, path: []const u8) !pgdb_mod.Config {
    const meta = try roots.embeddedMeta(ctx.arena);
    const port = if (args.flag(&.{"port"})) |v|
        std.fmt.parseInt(u16, v, 10) catch return error.BadPort
    else
        try net.freePort();
    return .{
        .pg_major = meta.major,
        .pg_arch = roots.host_arch,
        .pg_digest = meta.digest,
        .user = args.flag(&.{"user"}) orelse ctx.getenv("POSTGRES_USER") orelse "postgres",
        .password = ctx.getenv("POSTGRES_PASSWORD") orelse try pgdb_mod.generatePassword(ctx.arena, ctx.io),
        .database = ctx.getenv("POSTGRES_DB") orelse pgdb_mod.defaultDatabase(path),
        .port = port,
    };
}

/// Opens the .pgdb, creating it if it's missing (shell, url, run and the
/// bare form). A new one's cluster is initialized by its first server.
fn openOrCreate(ctx: Ctx, args: cli.Args, path: []const u8) ?Pgdb {
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| {
        return openPgdb(ctx, path);
    } else |_| {}
    const c = newConfig(ctx, args, path) catch |err| {
        ctx.warn("creating {s}: {t}", .{ path, err });
        return null;
    };
    const p = pgdb_mod.create(ctx.arena, ctx.io, path, c) catch |err| {
        ctx.warn("creating {s}: {t}", .{ path, err });
        return null;
    };
    ctx.warn("creating {s}", .{path});
    return p;
}

pub fn init(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "init needs a .pgdb path", .{});
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return ctx.fail("{s} already exists", .{path}) else |_| {}
    if (args.flag(&.{"pg"})) |m| {
        const meta = try roots.embeddedMeta(ctx.arena);
        if (!std.mem.eql(u8, m, try std.fmt.allocPrint(ctx.arena, "{d}", .{meta.major})))
            return ctx.fail("this minipg has only Postgres {d}", .{meta.major});
    }
    const c = newConfig(ctx, args, path) catch |err| switch (err) {
        error.BadPort => return usageError(ctx, "--port takes a port number", .{}),
        else => return err,
    };
    const p = try pgdb_mod.create(ctx.arena, ctx.io, path, c);
    const code = server.initialize(ctx, p) catch |err| blk: {
        ctx.warn("{t}", .{err});
        break :blk 1;
    };
    if (code != 0 or !p.initialized(ctx.arena, ctx.io)) {
        ctx.warn("initializing {s} failed; its log ends:", .{path});
        client.printLogTail(ctx, p, 20);
        std.Io.Dir.cwd().deleteTree(ctx.io, p.path) catch {};
        return 1;
    }
    const meta = try roots.embeddedMeta(ctx.arena);
    var buf: [256]u8 = undefined;
    var out = ctx.stdout(&buf);
    try out.interface.print("created {s} (Postgres {s}, database {s})\n", .{ path, meta.version, c.database });
    try out.interface.flush();
    return 0;
}

pub fn serve(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "serve needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    var opts: server.Options = .{
        .listen = args.flag(&.{"listen"}) orelse "127.0.0.1",
        .log_file = args.flag(&.{"log"}),
        .trust = args.has(&.{"trust"}),
        .foreground = !args.has(&.{"background"}),
        .postgres_args = args.rest,
    };
    if (args.flag(&.{ "p", "port" })) |v| opts.port = std.fmt.parseInt(u16, v, 10) catch return usageError(ctx, "-p takes a port number", .{});
    if (args.flag(&.{"idle"})) |v| opts.idle_timeout = std.fmt.parseInt(i64, v, 10) catch return usageError(ctx, "--idle takes seconds", .{});
    if (opts.trust and !net.isLoopback(opts.listen))
        return ctx.fail("--trust lets anyone who can reach the port in without a password, so it only works with a loopback --listen", .{});
    if (opts.log_file) |l| opts.log_file = try pgdb_mod.absolute(ctx.arena, ctx.io, l);
    return server.serve(ctx, p, opts);
}

pub fn stop(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "stop needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    const r = try client.find(ctx, p) orelse {
        ctx.warn("no server is running for {s}", .{path});
        return 0;
    };
    client.stop(ctx, p, r) catch |err| return ctx.fail("stopping {s}: {t}", .{ path, err });
    return 0;
}

/// Exit code for `status` when no server is running.
pub const exit_stopped = 3;

pub fn status(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "status needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    var buf: [1024]u8 = undefined;
    var out = ctx.stdout(&buf);
    const w = &out.interface;
    defer w.flush() catch {};
    const r = try client.find(ctx, p) orelse {
        try w.print("{s}: stopped\n", .{path});
        try w.print("  postgres  {d} ({s})\n", .{ p.config.pg_major, if (p.config.pg_last_opened.len > 0) p.config.pg_last_opened else "never started" });
        try w.print("  port      {d} (preferred)\n", .{p.config.port});
        return exit_stopped;
    };
    const st = client.status(ctx, r) catch |err| return ctx.fail("asking the server: {t}", .{err});
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    try w.print("{s}: {s}\n", .{ path, if (std.mem.eql(u8, st.state, "ready")) "running" else st.state });
    try w.print("  postgres  {s}\n", .{st.pg_version});
    try w.print("  listen    {s}:{d}\n", .{ st.listen, st.port });
    try w.print("  pid       {d}\n", .{st.pid});
    if (st.clients >= 0) try w.print("  clients   {d}\n", .{st.clients});
    try w.print("  uptime    {d}s\n", .{now - st.started});
    if (st.idle_timeout > 0) try w.print("  idle stop after {d}s without clients\n", .{st.idle_timeout}) else try w.print("  idle stop never (foreground)\n", .{});
    try w.print("  minipg    {s}\n", .{st.version});
    return 0;
}

/// Percent-encodes a URL component.
fn escape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) {
            try out.append(arena, ch);
        } else try out.print(arena, "%{X:0>2}", .{ch});
    }
    return out.items;
}

const Conn = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    fn url(c: Conn, arena: std.mem.Allocator) ![]const u8 {
        const h = if (std.mem.indexOfScalar(u8, c.host, ':') != null) try std.fmt.allocPrint(arena, "[{s}]", .{c.host}) else c.host;
        return std.fmt.allocPrint(arena, "postgres://{s}:{s}@{s}:{d}/{s}", .{
            try escape(arena, c.user), try escape(arena, c.password), h, c.port, try escape(arena, c.database),
        });
    }

    fn pgEnv(c: Conn, arena: std.mem.Allocator) ![]const h9.EnvVar {
        return arena.dupe(h9.EnvVar, &.{
            .{ .name = "PGHOST", .value = c.host },
            .{ .name = "PGPORT", .value = try std.fmt.allocPrint(arena, "{d}", .{c.port}) },
            .{ .name = "PGUSER", .value = c.user },
            .{ .name = "PGPASSWORD", .value = c.password },
            .{ .name = "PGDATABASE", .value = c.database },
        });
    }
};

/// Connection details for a .pgdb: the running server's port, or the
/// stored one.
fn connFor(args: cli.Args, p: Pgdb, r: ?client.Running) Conn {
    return .{
        .host = if (r) |rr| net.dialHost(rr.info.listen) else "127.0.0.1",
        .port = if (r) |rr| rr.info.port else p.config.port,
        .user = p.config.user,
        .password = p.config.password,
        .database = args.flag(&.{ "d", "db" }) orelse p.config.database,
    };
}

pub fn url(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "url needs a .pgdb path", .{});
    const p = openOrCreate(ctx, args, path) orelse return 1;
    const r = try client.find(ctx, p);
    var buf: [512]u8 = undefined;
    var out = ctx.stdout(&buf);
    try out.interface.print("{s}\n", .{try connFor(args, p, r).url(ctx.arena)});
    try out.interface.flush();
    return 0;
}

pub fn logs(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "logs needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    const follow = args.has(&.{ "f", "follow" });
    var buf: [4096]u8 = undefined;
    var out = ctx.stdout(&buf);
    if (try client.find(ctx, p)) |r| {
        if (try control.stream(ctx.arena, ctx.io, r.info.control, if (follow) "logs follow" else "logs", &out.interface)) |msg|
            return ctx.fail("server: {s}", .{msg});
        return 0;
    }
    // No server: the last one's log file.
    const key = try paths.key(ctx.arena, p.path);
    const log_path = try ctx.dirs.logFor(ctx.arena, key);
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, log_path, ctx.arena, .limited(1 << 30)) catch {
        ctx.warn("no server is running for {s}, and it has no log yet", .{path});
        return 0;
    };
    try out.interface.writeAll(text);
    try out.interface.flush();
    return 0;
}

/// The caller's working directory, for a tool machine's cwd.
fn hostCwd(ctx: Ctx) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.arena);
}

/// Runs `argv` in a tool machine connected to the .pgdb's server.
fn runToolOn(ctx: Ctx, args: cli.Args, p: Pgdb, argv: []const []const u8) !u8 {
    const root = roots.forPgdb(ctx, p) catch |err| switch (err) {
        error.NoRoot => return 1,
        else => return err,
    };
    const r = client.ensure(ctx, p, .{ .idle_timeout = idleTimeout(ctx) }) catch |err| switch (err) {
        error.ServerFailed => return 1,
        else => return ctx.fail("starting the server for {s}: {t}", .{ p.path, err }),
    };
    const conn = connFor(args, p, r);
    const env = try vm.environment(ctx.arena, root.meta, try conn.pgEnv(ctx.arena));
    return vm.runTool(ctx.gpa, ctx.io, ctx.env, .{ .root = root, .cwd = try hostCwd(ctx), .env = env, .argv = argv });
}

/// MINIPG_IDLE, in seconds.
pub fn idleTimeout(ctx: Ctx) i64 {
    const v = ctx.getenv("MINIPG_IDLE") orelse return client.default_idle;
    return std.fmt.parseInt(i64, v, 10) catch client.default_idle;
}

pub fn shell(ctx: Ctx, args: cli.Args) !u8 {
    const target = args.pgdb() orelse return usageError(ctx, "shell needs a .pgdb path or a postgres:// URL", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "psql");
    if (std.mem.startsWith(u8, target, "postgres://") or std.mem.startsWith(u8, target, "postgresql://")) {
        // A URL: psql on it, from a tool machine on the embedded root.
        const root = try roots.embedded(ctx.gpa, ctx.arena, ctx.io, ctx.dirs.roots);
        try argv.append(ctx.arena, target);
        for (args.positional[1..]) |sql| try argv.appendSlice(ctx.arena, &.{ "-c", sql });
        try argv.appendSlice(ctx.arena, args.rest);
        const env = try vm.environment(ctx.arena, root.meta, &.{});
        return vm.runTool(ctx.gpa, ctx.io, ctx.env, .{ .root = root, .cwd = try hostCwd(ctx), .env = env, .argv = argv.items });
    }
    const p = openOrCreate(ctx, args, target) orelse return 1;
    for (args.positional[1..]) |sql| try argv.appendSlice(ctx.arena, &.{ "-c", sql });
    try argv.appendSlice(ctx.arena, args.rest);
    return runToolOn(ctx, args, p, argv.items);
}

pub fn exec(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "exec needs a .pgdb path", .{});
    if (args.rest.len == 0) return usageError(ctx, "exec needs a tool: minipg exec {s} -- TOOL [args]", .{path});
    const p = openPgdb(ctx, path) orelse return 1;
    return runToolOn(ctx, args, p, args.rest);
}
