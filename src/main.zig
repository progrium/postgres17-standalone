//! postgres17-standalone: PostgreSQL 17 in one binary.
//!
//! It embeds Docker Hub's postgres:17-alpine image as a Linux root and runs
//! it with hyper9 (h9) as a library: h9's Linux personality runs Alpine's
//! own postgres binaries on the host's hypervisor (HVF on macOS, KVM on
//! Linux) or on h9's native backend (x86_64 Linux without KVM). The
//! image's docker-entrypoint.sh initializes the cluster on first run,
//! exactly as the Docker image does, and then serves it.
//!
//! The data directory is a plain host directory: Postgres's PGDATA is its
//! `pgdata` subdirectory, reached in the guest through h9's binding of the
//! machine's cwd at /mnt/term/cwd. Postgres listens on the host's own
//! network stack, so `-p` is the port it listens on.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const host = @import("host.zig");

/// The Linux root: Alpine with PostgreSQL 17, an xz-compressed tarball
/// (scripts/root.sh).
const root_tar = @embedFile("root_tar");

const cache_env = "POSTGRES17_STANDALONE_CACHE_DIR";
/// PGDATA in the guest: the data directory is the machine's cwd.
const guest_pgdata = "/mnt/term/cwd/pgdata";
/// The image's ENV, which h9 doesn't read from an image config.
const image_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
/// Environment passed through from the host, as `docker run -e` would.
const passthrough = [_][]const u8{
    "POSTGRES_PASSWORD",
    "POSTGRES_USER",
    "POSTGRES_DB",
    "POSTGRES_INITDB_ARGS",
    "POSTGRES_INITDB_WALDIR",
    "POSTGRES_HOST_AUTH_METHOD",
    "TZ",
};

var terminal: host.Terminal = .{};

/// Restores the host terminal before the default panic output.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ret_addr: ?usize) noreturn {
        terminal.restore();
        std.debug.defaultPanic(msg, ret_addr);
    }
}.f);

comptime {
    if (builtin.os.tag == .windows) @compileError("postgres17-standalone needs a POSIX host for now (h9 has no Windows hypervisor backend yet)");
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const cfg = cli.parse(args[1..]) catch {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };
    if (cfg.version) {
        var buf: [64]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try w.interface.print("{s}\n", .{build_options.version});
        try w.interface.flush();
        return 0;
    }
    return run(init, cfg) catch |err| {
        std.debug.print("postgres17-standalone: {t}\n", .{err});
        return 1;
    };
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(fmt ++ "\n", args);
    return 1;
}

fn run(init: std.process.Init, cfg: cli.Config) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const cwd = std.Io.Dir.cwd();

    // The data directory, absolute with symlinks resolved, as h9 takes
    // host paths.
    cwd.createDirPath(io, cfg.data_dir) catch |err|
        return fail("data dir {s}: {t}", .{ cfg.data_dir, err });
    const data_dir = try cwd.realPathFileAlloc(io, cfg.data_dir, arena);
    var data = try cwd.openDir(io, data_dir, .{});
    defer data.close(io);

    // One instance per data directory. The OS drops the lock if the
    // process dies.
    const lock = data.createFile(io, ".lock", .{ .truncate = false }) catch |err|
        return fail("{s}/.lock: {t}", .{ data_dir, err });
    defer lock.close(io);
    if (!(lock.tryLock(io, .exclusive) catch false))
        return fail("{s} is in use by another instance", .{data_dir});

    const password = env.get("POSTGRES_PASSWORD") orelse "";
    if (password.len == 0 and !cfg.debug)
        return fail("POSTGRES_PASSWORD environment variable is required", .{});

    const root = unpackRoot(init) catch |err|
        return fail("unpacking the root image: {t}", .{err});

    var vars: std.ArrayList(h9.EnvVar) = .empty;
    try vars.appendSlice(arena, &.{
        .{ .name = "PATH", .value = image_path },
        .{ .name = "LANG", .value = "en_US.utf8" },
        .{ .name = "PG_MAJOR", .value = "17" },
        .{ .name = "PGDATA", .value = guest_pgdata },
        .{ .name = "PGPORT", .value = try std.fmt.allocPrint(arena, "{d}", .{cfg.port}) },
    });
    for (passthrough) |name| if (env.get(name)) |v| try vars.append(arena, .{ .name = name, .value = v });
    if (cfg.debug) try vars.append(arena, .{ .name = "TERM", .value = env.get("TERM") orelse "xterm" });

    var sig: host.Signals = undefined;
    try sig.init(io, cfg.debug);
    defer sig.deinit();
    defer terminal.restore();

    var in_buf: [4096]u8 = undefined;
    var stdin: host.Stdin = undefined;
    stdin.init(&in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});
    const tty = (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

    const opts: h9.Machine.Options = .{
        .linux_root = root,
        .cwd = data_dir,
        .env = vars.items,
        .guest_tools = false,
        .builtin = .off,
        .console_tty = cfg.debug and tty,
        .policy = .{
            // Postgres listens on the host's own ports.
            .net = .enable,
            .cwd_writable = true,
            // The default write mode: the data directory persists, and the
            // root's writes (/var/run/postgresql) go to an overlay in memory.
            .memory = 2 << 30,
        },
        .signals = &sig.machine,
        .stdio = .{
            // Only the debug shell reads the console.
            .in = if (cfg.debug) &stdin.interface else null,
            .in_cancel = if (cfg.debug) stdin.cancelHook() else null,
            .out = &out.interface,
            .err = &err_w.interface,
            .raw = if (cfg.debug and tty) terminal.hook() else null,
        },
    };
    var machine = h9.Machine.init(init.gpa, io, opts) catch |err| {
        const why = h9.vmm.whyUnavailable(.auto) orelse @errorName(err);
        return fail("cannot create a machine: {s} ({t})", .{ why, err });
    };
    defer machine.deinit();

    const argv: []const []const u8 = if (cfg.debug)
        &.{ "sh", "-l" }
    else
        &.{ "docker-entrypoint.sh", "postgres" };
    const prog: h9.Program = .{ .guest = if (cfg.debug) "/bin/sh" else "/usr/local/bin/docker-entrypoint.sh" };

    if (!cfg.debug) std.debug.print("Postgres will listen on 0.0.0.0:{d} ({t} backend)\n", .{ cfg.port, machine.backend.kind() });
    const status = machine.run(prog, argv) catch |err| {
        if (machine.stuck) {
            terminal.restore();
            std.process.exit(1);
        }
        return fail("{s}: {s}", .{ prog.guest, if (machine.err_msg.len > 0) machine.err_msg else @errorName(err) });
    };
    const code: u8 = switch (status) {
        // A Linux program's exit status comes back as its number.
        .exited => |msg| if (msg.len == 0) 0 else std.fmt.parseInt(u8, msg, 10) catch blk: {
            std.debug.print("postgres17-standalone: exited: {s}\n", .{msg});
            break :blk 1;
        },
        .killed => |msg| blk: {
            // The guest went away under a forced stop, or died.
            if (!sig.forced.load(.acquire)) std.debug.print("postgres17-standalone: killed: {s}\n", .{msg});
            break :blk 1;
        },
    };
    if (machine.stuck) {
        terminal.restore();
        std.process.exit(code);
    }
    return code;
}

/// The cache directory: $POSTGRES17_STANDALONE_CACHE_DIR, or the user's
/// cache dir with postgres17-standalone in it.
fn cacheDir(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get(cache_env)) |d| if (d.len > 0) {
        try std.Io.Dir.cwd().createDirPath(io, d);
        return std.Io.Dir.cwd().realPathFileAlloc(io, d, arena);
    };
    const base = if (builtin.os.tag == .macos)
        try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHomeDir, "Library", "Caches" })
    else if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) x else try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHomeDir, ".cache" }) else try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.NoHomeDir, ".cache" });
    const dir = try std.fs.path.join(arena, &.{ base, "postgres17-standalone" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena);
}

/// Unpacks the embedded root into the cache dir, once, and returns its
/// path. The directory is named after a hash of the embedded archive, so a
/// binary with a different root never reuses a stale one; roots from other
/// versions are removed.
fn unpackRoot(init: std.process.Init) ![]const u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const dir_path = try cacheDir(arena, io, init.environ_map);
    var cache = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer cache.close(io);

    const name = try std.fmt.allocPrint(arena, "root-{x:0>16}", .{std.hash.Wyhash.hash(0, root_tar)});
    const path = try std.fs.path.join(arena, &.{ dir_path, name });
    if (cache.access(io, name, .{})) |_| return path else |_| {}

    std.debug.print("Unpacking the root image to {s}...\n", .{path});
    // Unpack beside it and rename, so a failed run never leaves a partial
    // root under the final name.
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(arena, ".tmp-{x}", .{&rnd});
    try cache.createDirPath(io, tmp);
    defer cache.deleteTree(io, tmp) catch {};
    {
        var dest = try cache.openDir(io, tmp, .{});
        defer dest.close(io);
        var src: std.Io.Reader = .fixed(root_tar);
        var xz = try std.compress.xz.Decompress.init(&src, init.gpa, try init.gpa.alloc(u8, 1 << 16));
        defer xz.deinit();
        try std.tar.extract(io, dest, &xz.reader, .{ .mode_mode = .executable_bit_only });
    }
    cache.rename(tmp, cache, name, io) catch |err| {
        // Another instance unpacked the same root first.
        if (cache.access(io, name, .{})) |_| return path else |_| {}
        return err;
    };

    // Best effort: drop roots from other versions.
    var it = cache.iterate();
    var old: std.ArrayList([]const u8) = .empty;
    while (it.next(io) catch null) |e| {
        if (std.mem.startsWith(u8, e.name, "root-") and !std.mem.eql(u8, e.name, name))
            try old.append(arena, try arena.dupe(u8, e.name));
    }
    for (old.items) |o| cache.deleteTree(io, o) catch {};
    return path;
}

test {
    _ = cli;
}
