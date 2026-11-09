//! h9 machines: the server machine that runs Postgres over a .pgdb, and the
//! short-lived tool machines that run psql, pg_dump and the rest against
//! it over loopback. Both use the same root; writes outside the machine's
//! cwd go to an overlay in memory and vanish when it exits.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const host = @import("host.zig");
const root_mod = @import("roots.zig");
const sys = @import("sys.zig");

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

/// The backend MINIPG_BACKEND names: auto (the default) uses the host's
/// hypervisor. h9's native backend (x86_64 Linux without KVM) runs the
/// guest in minipg's own process, where a guest that escapes Postgres can
/// reach the host, so it's never picked by itself.
pub fn backendFrom(env: *const std.process.Environ.Map) !h9.vmm.BackendKind {
    const v = env.get("MINIPG_BACKEND") orelse return .auto;
    if (v.len == 0) return .auto;
    return std.meta.stringToEnum(h9.vmm.BackendKind, v) orelse error.BadBackend;
}

fn unavailable(arena: std.mem.Allocator, kind: h9.vmm.BackendKind, err: anyerror) []const u8 {
    const why = h9.vmm.whyUnavailable(kind) orelse @errorName(err);
    if (kind == .auto and builtin.os.tag == .linux and builtin.cpu.arch == .x86_64)
        return std.fmt.allocPrint(arena, "{s}; MINIPG_BACKEND=native runs Postgres on h9's native backend instead, which isn't a sandbox", .{why}) catch why;
    return why;
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
    backend: h9.vmm.BackendKind = .auto,
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
        .linux_root = sys.kernPath(arena, r.root.dir) catch r.root.dir,
        .cwd = sys.kernPath(arena, r.pgdb) catch r.pgdb,
        .env = r.env,
        .guest_tools = false,
        .builtin = .off,
        .backend = r.backend,
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
        return .{ .status = null, .err_msg = std.fmt.allocPrint(arena, "cannot create a machine: {s} ({t})", .{ unavailable(arena, r.backend, err), err }) catch "cannot create a machine" };
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
    /// Stdin instead of the caller's (restore's dump file); never a terminal.
    in: ?*host.Stdin = null,
};

/// Runs a tool such as psql in a fresh machine with the caller's stdio,
/// and returns its exit code.
pub fn runTool(gpa: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, r: ToolRun) !u8 {
    const backend = backendFrom(env_map) catch {
        std.debug.print("minipg: MINIPG_BACKEND must be auto, native, kvm, hvf, or whp\n", .{});
        return 2;
    };
    var terminal: host.Terminal = .{};
    defer terminal.restore();
    const tty = r.in == null and (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

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
    if (tty) terminal.enableVt();

    var path_arena: std.heap.ArenaAllocator = .init(gpa);
    defer path_arena.deinit();
    const opts: h9.Machine.Options = .{
        .linux_root = try sys.kernPath(path_arena.allocator(), r.root.dir),
        .cwd = try sys.kernPath(path_arena.allocator(), r.cwd),
        .env = env.items,
        .guest_tools = false,
        .builtin = .off,
        .backend = backend,
        .console_tty = tty,
        .policy = .{
            .net = .enable,
            .cwd_writable = true,
            .memory = tool_memory,
        },
        .signals = &sig.machine,
        .stdio = .{
            .in = if (r.in) |i| &i.interface else &stdin.interface,
            .in_cancel = if (r.in) |i| i.cancelHook() else stdin.cancelHook(),
            .out = &out.interface,
            .err = &err_w.interface,
            .raw = if (tty) terminal.hook() else null,
        },
    };
    var machine = h9.Machine.init(gpa, io, opts) catch |err| {
        std.debug.print("minipg: cannot create a machine: {s} ({t})\n", .{ unavailable(path_arena.allocator(), backend, err), err });
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
