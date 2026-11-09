//! h9 machines: the server machine that runs Postgres over a .pgdb, and the
//! short-lived tool machines that run psql, pg_dump and the rest against
//! it over loopback. Both use the same root; writes outside the machine's
//! cwd go to an overlay in memory and vanish when it exits.

const std = @import("std");
const h9 = @import("h9");
const host = @import("host.zig");
const root_mod = @import("roots.zig");

/// Postgres's data directory in the guest: `pgdata` in the .pgdb, which is
/// the server machine's cwd.
pub const guest_pgdata = "/mnt/term/cwd/pgdata";
/// The .pgdb directory itself, in the server machine.
pub const guest_pgdb = "/mnt/term/cwd";

/// Guest memory for the server machine (the POC's figure).
pub const server_memory: u64 = 2 << 30;
/// Guest memory for a tool machine.
pub const tool_memory: u64 = 1 << 30;

/// The image's environment as h9 env vars, with `extra` overriding it.
pub fn environment(arena: std.mem.Allocator, meta: root_mod.Meta, extra: []const h9.EnvVar) ![]const h9.EnvVar {
    var vars: std.ArrayList(h9.EnvVar) = .empty;
    outer: for (meta.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        const name = e[0..eq];
        for (extra) |x| if (std.mem.eql(u8, x.name, name)) continue :outer;
        try vars.append(arena, .{ .name = name, .value = e[eq + 1 ..] });
    }
    // An image without ENV (a local tree) still needs a PATH.
    var has_path = false;
    for (vars.items) |v| has_path = has_path or std.mem.eql(u8, v.name, "PATH");
    for (extra) |x| has_path = has_path or std.mem.eql(u8, x.name, "PATH");
    if (!has_path) try vars.append(arena, .{ .name = "PATH", .value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" });
    try vars.appendSlice(arena, extra);
    return vars.items;
}

/// A Linux exit status from a machine's run, as a process exit code.
pub fn exitCode(status: h9.Status) u8 {
    return switch (status) {
        .exited => |msg| if (msg.len == 0) 0 else std.fmt.parseInt(u8, msg, 10) catch 1,
        .killed => 1,
    };
}

fn unavailable(err: anyerror) []const u8 {
    return h9.vmm.whyUnavailable(.auto) orelse @errorName(err);
}

pub const ServerRun = struct {
    root: root_mod.Root,
    /// The .pgdb directory, absolute and resolved.
    pgdb: []const u8,
    env: []const h9.EnvVar,
    /// The program: the image's entrypoint unless said otherwise.
    prog: []const u8 = "/usr/local/bin/docker-entrypoint.sh",
    argv: []const []const u8,
    /// Receives Postgres's stdout and stderr.
    log: *std.Io.Writer,
    signals: *h9.Machine.Signals,
    /// The machine's console input, if any.
    in: ?*std.Io.Reader = null,
    in_cancel: ?h9.consin.Cancel = null,
};

pub const RunResult = struct {
    status: ?h9.Status,
    /// Why the run couldn't start or failed, when `status` is null.
    err_msg: []const u8 = "",
    stuck: bool = false,
};

/// Runs Postgres in a server machine until it exits.
pub fn runServer(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, r: ServerRun) RunResult {
    const opts: h9.Machine.Options = .{
        .linux_root = r.root.dir,
        .cwd = r.pgdb,
        .env = r.env,
        .guest_tools = false,
        .builtin = .off,
        .console_tty = false,
        .policy = .{
            // Postgres listens on the host's own ports.
            .net = .enable,
            .cwd_writable = true,
            .memory = server_memory,
        },
        .signals = r.signals,
        .stdio = .{ .out = r.log, .err = r.log, .in = r.in, .in_cancel = r.in_cancel },
    };
    var machine = h9.Machine.init(gpa, io, opts) catch |err|
        return .{ .status = null, .err_msg = std.fmt.allocPrint(arena, "cannot create a machine: {s} ({t})", .{ unavailable(err), err }) catch "cannot create a machine" };
    defer machine.deinit();
    const prog: h9.Program = .{ .guest = r.prog };
    const status = machine.run(prog, r.argv) catch |err| {
        const msg = if (machine.err_msg.len > 0) machine.err_msg else @errorName(err);
        return .{ .status = null, .stuck = machine.stuck, .err_msg = std.fmt.allocPrint(arena, "{s}: {s}", .{ prog.guest, msg }) catch "run failed" };
    };
    return .{ .status = status, .stuck = machine.stuck };
}

pub const ToolRun = struct {
    root: root_mod.Root,
    /// The host directory the tool sees as its cwd: the caller's.
    cwd: []const u8,
    env: []const h9.EnvVar,
    argv: []const []const u8,
};

/// Runs a tool such as psql in a fresh machine with the caller's stdio,
/// and returns its exit code.
pub fn runTool(gpa: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, r: ToolRun) !u8 {
    var terminal: host.Terminal = .{};
    defer terminal.restore();
    const tty = (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

    var sig: host.Signals = undefined;
    try sig.init(io, .tool, null);
    defer sig.deinit();

    var in_buf: [4096]u8 = undefined;
    var stdin: host.Stdin = undefined;
    stdin.init(&in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});

    var env: std.ArrayList(h9.EnvVar) = .empty;
    defer env.deinit(gpa);
    try env.appendSlice(gpa, r.env);
    if (tty) try env.append(gpa, .{ .name = "TERM", .value = env_map.get("TERM") orelse "xterm" });

    const opts: h9.Machine.Options = .{
        .linux_root = r.root.dir,
        .cwd = r.cwd,
        .env = env.items,
        .guest_tools = false,
        .builtin = .off,
        .console_tty = tty,
        .policy = .{
            .net = .enable,
            .cwd_writable = true,
            .memory = tool_memory,
        },
        .signals = &sig.machine,
        .stdio = .{
            .in = &stdin.interface,
            .in_cancel = stdin.cancelHook(),
            .out = &out.interface,
            .err = &err_w.interface,
            .raw = if (tty) terminal.hook() else null,
        },
    };
    var machine = h9.Machine.init(gpa, io, opts) catch |err| {
        std.debug.print("minipg: cannot create a machine: {s} ({t})\n", .{ unavailable(err), err });
        return 1;
    };
    defer machine.deinit();
    const status = machine.run(.{ .guest = r.argv[0] }, r.argv) catch |err| {
        if (machine.stuck) {
            terminal.restore();
            std.process.exit(1);
        }
        switch (err) {
            error.NotFound => {
                std.debug.print("minipg: {s}: not found in the Postgres root\n", .{r.argv[0]});
                return 127;
            },
            else => {
                std.debug.print("minipg: {s}: {s}\n", .{ r.argv[0], if (machine.err_msg.len > 0) machine.err_msg else @errorName(err) });
                return 1;
            },
        }
    };
    const code = exitCode(status);
    if (machine.stuck) {
        terminal.restore();
        std.process.exit(code);
    }
    return code;
}
