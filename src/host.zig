//! The host side of the machine's console and signals, on POSIX hosts:
//! stdin as a cancellable reader, the terminal's raw mode for the debug
//! shell, and SIGINT/SIGTERM turned into a clean Postgres shutdown.
//!
//! Adapted from hyper9's src/stdin.zig and src/hostsig.zig (MIT), which
//! the h9 library leaves to its embedders.

const std = @import("std");
const h9 = @import("h9");

const posix = std.posix;
const c = std.c;

/// stdin as a `std.Io.Reader` whose blocked read `cancel` can end, so a
/// run can finish while the console's reader thread waits for input. It
/// polls stdin together with a wake pipe; `cancel` writes to the pipe.
pub const Stdin = struct {
    wake: [2]posix.fd_t = .{ -1, -1 },
    interface: std.Io.Reader,

    pub fn init(s: *Stdin, buf: []u8) void {
        s.* = .{ .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        } };
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe(&fds) != 0) return;
        for (fds) |fd| _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        const fl = c.fcntl(fds[0], posix.F.GETFL);
        _ = c.fcntl(fds[0], posix.F.SETFL, fl | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
        s.wake = fds;
    }

    pub fn cancelHook(s: *Stdin) h9.consin.Cancel {
        return .{ .ctx = s, .func = cancel, .reset = reset };
    }

    fn cancel(ctx: *anyopaque, _: std.Thread) void {
        const s: *Stdin = @ptrCast(@alignCast(ctx));
        if (s.wake[1] >= 0) _ = c.write(s.wake[1], "x", 1);
    }

    fn reset(ctx: *anyopaque) void {
        const s: *Stdin = @ptrCast(@alignCast(ctx));
        if (s.wake[0] >= 0) s.drainWake();
    }

    fn drainWake(s: *Stdin) void {
        var b: [64]u8 = undefined;
        while (c.read(s.wake[0], &b, b.len) > 0) {}
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *Stdin = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        if (s.wake[0] >= 0) while (true) {
            var fds = [2]posix.pollfd{
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = s.wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch break;
            if (fds[1].revents != 0) {
                s.drainWake();
                return error.ReadFailed;
            }
            if (fds[0].revents != 0) break;
        };
        while (true) {
            const n = posix.read(posix.STDIN_FILENO, dest) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            wr.advance(n);
            return n;
        }
    }
};

/// The host terminal's mode, set as the guest asks through TCSETS or
/// /dev/consctl. The original mode comes back when the guest turns raw
/// off, when the run ends, and on exit.
pub const Terminal = struct {
    saved: ?c.termios = null,
    raw: bool = false,
    no_echo: bool = false,
    no_crnl: bool = false,
    lock: std.atomic.Mutex = .unlocked,

    /// For `Machine.Stdio.raw`.
    pub fn hook(t: *Terminal) h9.Machine.Raw {
        return .{ .ctx = t, .set = setRaw, .echo = setEcho, .crnl = setCrnl, .size = size };
    }

    pub fn restore(t: *Terminal) void {
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = false;
        t.no_echo = false;
        t.apply(.NOW);
    }

    fn lockSpin(t: *Terminal) void {
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn setRaw(ctx: *anyopaque, on: bool) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = on;
        t.apply(.FLUSH);
    }

    fn setEcho(ctx: *anyopaque, on: bool) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.no_echo = !on;
        t.apply(.NOW);
    }

    fn setCrnl(ctx: *anyopaque, on: bool) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.no_crnl = !on;
        if (t.raw) t.apply(.NOW);
    }

    fn size(_: *anyopaque) ?[2]u16 {
        for ([_]posix.fd_t{ posix.STDOUT_FILENO, posix.STDIN_FILENO }) |fd| {
            var ws: posix.winsize = undefined;
            if (c.ioctl(fd, c.T.IOCGWINSZ, &ws) == 0 and ws.row != 0 and ws.col != 0) return .{ ws.row, ws.col };
        }
        return null;
    }

    fn apply(t: *Terminal, when: c.TCSA) void {
        const fd = posix.STDIN_FILENO;
        if (!t.raw and !t.no_echo) {
            if (t.saved) |s| {
                var tt = s;
                _ = c.tcsetattr(fd, when, &tt);
                t.saved = null;
            }
            return;
        }
        if (t.saved == null) {
            var s: c.termios = undefined;
            if (c.tcgetattr(fd, &s) != 0) return;
            t.saved = s;
        }
        var tt = t.saved.?;
        tt.lflag.ECHO = !t.no_echo;
        if (t.raw) {
            tt.lflag.ICANON = false;
            tt.lflag.ISIG = false;
            if (t.no_crnl) tt.iflag.ICRNL = false;
            tt.cc[@intFromEnum(c.V.MIN)] = 1;
            tt.cc[@intFromEnum(c.V.TIME)] = 0;
        }
        _ = c.tcsetattr(fd, when, &tt);
    }
};

/// How long a clean shutdown may take before the machine is stopped.
pub const shutdown_timeout_ms = 30 * std.time.ms_per_s;

/// SIGINT and SIGTERM, handled as the Go version did: the first asks the
/// guest to shut down cleanly (an `interrupt` note, which Postgres takes
/// as SIGINT, a fast shutdown; a `hangup` for the debug shell), and the
/// second, or the timeout, tears the machine down at once.
///
/// The handlers write a byte to a self-pipe; a watcher thread reads it and
/// calls `Machine.Signals`, which `Machine.run` acts on.
pub const Signals = struct {
    io: std.Io,
    debug: bool,
    machine: h9.Machine.Signals = .{},
    /// Set by the first signal.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set by a second signal or the timeout.
    forced: std.atomic.Value(bool) = .init(false),
    pipe: [2]posix.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,
    old: [2]posix.Sigaction = undefined,

    const sigs = [_]posix.SIG{ .INT, .TERM };
    const ev_signal = 's';
    const ev_quit = 'q';

    var wake_fd: posix.fd_t = -1;

    pub fn init(s: *Signals, io: std.Io, debug: bool) !void {
        s.* = .{ .io = io, .debug = debug };
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.SystemResources;
        for (fds) |fd| _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        const fl = c.fcntl(fds[1], posix.F.GETFL);
        _ = c.fcntl(fds[1], posix.F.SETFL, fl | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
        s.pipe = fds;
        wake_fd = fds[1];
        s.thread = try std.Thread.spawn(.{}, watch, .{s});
        const act: posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        for (sigs, &s.old) |sig, *o| posix.sigaction(sig, &act, o);
        var set = posix.sigemptyset();
        for (sigs) |sig| posix.sigaddset(&set, sig);
        posix.sigprocmask(posix.SIG.UNBLOCK, &set, null);
    }

    pub fn deinit(s: *Signals) void {
        const t = s.thread orelse return;
        for (sigs, &s.old) |sig, *o| posix.sigaction(sig, o, null);
        _ = c.write(s.pipe[1], &[_]u8{ev_quit}, 1);
        t.join();
        wake_fd = -1;
        _ = c.close(s.pipe[0]);
        _ = c.close(s.pipe[1]);
        s.thread = null;
    }

    fn handler(_: posix.SIG) callconv(.c) void {
        const fd = wake_fd;
        if (fd >= 0) {
            const e = c._errno().*;
            _ = c.write(fd, &[_]u8{ev_signal}, 1);
            c._errno().* = e;
        }
    }

    fn watch(s: *Signals) void {
        var buf: [64]u8 = undefined;
        while (true) {
            var fds = [1]posix.pollfd{.{ .fd = s.pipe[0], .events = posix.POLL.IN, .revents = 0 }};
            const timeout: i32 = if (s.stopping.load(.acquire) and !s.forced.load(.acquire)) shutdown_timeout_ms else -1;
            const ready = posix.poll(&fds, timeout) catch 1;
            if (ready == 0) {
                say("Timed out waiting for Postgres to shut down\n");
                s.force();
                continue;
            }
            const n = c.read(s.pipe[0], &buf, buf.len);
            if (n < 0) {
                if (c._errno().* == @intFromEnum(posix.E.INTR)) continue;
                return;
            }
            if (n == 0) return;
            for (buf[0..@intCast(n)]) |ev| switch (ev) {
                ev_signal => s.signal(),
                ev_quit => return,
                else => {},
            };
        }
    }

    fn signal(s: *Signals) void {
        if (!s.stopping.swap(true, .acq_rel)) {
            say("\nShutting down... (Ctrl+C again to force)\n");
            if (s.debug) s.machine.hangup(s.io) else s.machine.interrupt(s.io);
        } else if (!s.forced.load(.acquire)) {
            say("Forced exit; the data directory may need recovery on next start\n");
            s.force();
        }
    }

    fn force(s: *Signals) void {
        s.forced.store(true, .release);
        s.machine.stop(s.io);
    }

    fn say(msg: []const u8) void {
        _ = c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
    }
};
