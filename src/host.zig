//! The host side of the machine's console and signals: stdin as a
//! cancellable reader, the terminal's raw mode for interactive tools such
//! as psql, and SIGINT/SIGTERM (on Windows, Ctrl-C and the console's
//! close, logoff and shutdown events) turned into a clean Postgres
//! shutdown.
//!
//! Adapted from hyper9's src/stdin.zig and src/hostsig.zig (MIT), which
//! the h9 library leaves to its embedders.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");

const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;

/// An open file, pipe or console: a file descriptor on POSIX, a HANDLE on
/// Windows.
pub const Handle = if (is_windows) std.os.windows.HANDLE else posix.fd_t;

/// The process's standard input.
pub fn stdinHandle() Handle {
    return if (is_windows) std.os.windows.peb().ProcessParameters.hStdInput else posix.STDIN_FILENO;
}

/// A pipe: `r` to read, `w` to write.
pub const Pipe = struct {
    r: Handle,
    w: Handle,

    pub fn init() !Pipe {
        if (is_windows) {
            var r: Handle = undefined;
            var w: Handle = undefined;
            if (!win.CreatePipe(&r, &w, null, 0).toBool()) return error.SystemResources;
            return .{ .r = r, .w = w };
        }
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.SystemResources;
        return .{ .r = fds[0], .w = fds[1] };
    }

    pub fn close(p: Pipe) void {
        for ([_]Handle{ p.r, p.w }) |h| {
            if (is_windows) _ = win.CloseHandle(h) else _ = c.close(h);
        }
    }

    /// Writes `bytes` to the pipe; safe from any thread.
    pub fn write(p: Pipe, bytes: []const u8) void {
        if (is_windows) {
            var n: win.DWORD = 0;
            _ = win.WriteFile(p.w, bytes.ptr, @intCast(bytes.len), &n, null);
        } else _ = c.write(p.w, bytes.ptr, bytes.len);
    }
};

/// The Win32 console calls std doesn't wrap.
const win = struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;
    const DWORD = w.DWORD;
    const BOOL = w.BOOL;

    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelSynchronousIo(thread: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;

    const COORD = extern struct { x: i16, y: i16 };
    const SMALL_RECT = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        size: COORD,
        cursor: COORD,
        attributes: u16,
        window: SMALL_RECT,
        max_window: COORD,
    };

    const ERROR_BROKEN_PIPE: DWORD = 109;
    const ERROR_HANDLE_EOF: DWORD = 38;
    const ERROR_OPERATION_ABORTED: DWORD = 995;

    const CTRL_C_EVENT = 0;
    const CTRL_BREAK_EVENT = 1;
    const CTRL_CLOSE_EVENT = 2;
    const CTRL_LOGOFF_EVENT = 5;
    const CTRL_SHUTDOWN_EVENT = 6;

    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

    fn stdout() HANDLE {
        return w.peb().ProcessParameters.hStdOutput;
    }
};

pub const Stdin = if (is_windows) WindowsStdin else PosixStdin;

/// stdin as a `std.Io.Reader` whose blocked read `cancel` can end, so a
/// run can finish while the console's reader thread waits for input. It
/// polls stdin together with a wake pipe; `cancel` writes to the pipe.
const PosixStdin = struct {
    fd: posix.fd_t = posix.STDIN_FILENO,
    wake: [2]posix.fd_t = .{ -1, -1 },
    interface: std.Io.Reader,

    pub fn init(s: *PosixStdin, buf: []u8) void {
        s.initFd(posix.STDIN_FILENO, buf);
    }

    /// The same over another file descriptor, such as a pipe.
    pub fn initFd(s: *PosixStdin, in_fd: posix.fd_t, buf: []u8) void {
        s.* = .{ .fd = in_fd, .interface = .{
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

    pub fn cancelHook(s: *PosixStdin) h9.consin.Cancel {
        return .{ .ctx = s, .func = cancel, .reset = reset };
    }

    fn cancel(ctx: *anyopaque, _: std.Thread) void {
        const s: *PosixStdin = @ptrCast(@alignCast(ctx));
        if (s.wake[1] >= 0) _ = c.write(s.wake[1], "x", 1);
    }

    fn reset(ctx: *anyopaque) void {
        const s: *PosixStdin = @ptrCast(@alignCast(ctx));
        if (s.wake[0] >= 0) s.drainWake();
    }

    fn drainWake(s: *PosixStdin) void {
        var b: [64]u8 = undefined;
        while (c.read(s.wake[0], &b, b.len) > 0) {}
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *PosixStdin = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        if (s.wake[0] >= 0) while (true) {
            var fds = [2]posix.pollfd{
                .{ .fd = s.fd, .events = posix.POLL.IN, .revents = 0 },
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
            const n = posix.read(s.fd, dest) catch |err| switch (err) {
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

/// The same on Windows. std reads with NtReadFile and treats
/// STATUS_PENDING as unreachable, which a console handle under a
/// pseudoconsole (Windows Terminal, OpenSSH, ConPTY) can return, so this
/// calls ReadFile, which waits for the read, and `cancel` ends it with
/// CancelSynchronousIo. A console in line mode ends each line with \r\n;
/// the reader turns that into \n, as a POSIX terminal does.
const WindowsStdin = struct {
    handle: ?win.HANDLE,
    console: bool,
    cancelled: std.atomic.Value(bool) = .init(false),
    interface: std.Io.Reader,

    pub fn init(s: *WindowsStdin, buf: []u8) void {
        s.initFd(stdinHandle(), buf);
    }

    /// The same over another handle, such as a pipe or a file.
    pub fn initFd(s: *WindowsStdin, h: ?win.HANDLE, buf: []u8) void {
        var mode: win.DWORD = 0;
        s.* = .{
            .handle = h,
            .console = if (h) |hh| win.GetConsoleMode(hh, &mode).toBool() else false,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn cancelHook(s: *WindowsStdin) h9.consin.Cancel {
        return .{ .ctx = s, .func = cancel, .reset = reset };
    }

    fn cancel(ctx: *anyopaque, thread: std.Thread) void {
        const s: *WindowsStdin = @ptrCast(@alignCast(ctx));
        s.cancelled.store(true, .release);
        _ = win.CancelSynchronousIo(thread.getHandle());
    }

    fn reset(ctx: *anyopaque) void {
        const s: *WindowsStdin = @ptrCast(@alignCast(ctx));
        s.cancelled.store(false, .release);
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *WindowsStdin = @alignCast(@fieldParentPtr("interface", r));
        const h = s.handle orelse return error.EndOfStream;
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        var n: win.DWORD = 0;
        while (true) {
            if (s.cancelled.swap(false, .acq_rel)) return error.ReadFailed;
            if (!win.ReadFile(h, dest.ptr, std.math.lossyCast(win.DWORD, dest.len), &n, null).toBool()) {
                if (s.cancelled.swap(false, .acq_rel)) return error.ReadFailed;
                return switch (@intFromEnum(std.os.windows.GetLastError())) {
                    win.ERROR_BROKEN_PIPE, win.ERROR_HANDLE_EOF => error.EndOfStream,
                    else => error.ReadFailed,
                };
            }
            // Ctrl-C in a console with processed input ends a pending read
            // with no bytes and ERROR_OPERATION_ABORTED; that isn't EOF.
            if (n == 0 and s.console and @intFromEnum(std.os.windows.GetLastError()) == win.ERROR_OPERATION_ABORTED) continue;
            break;
        }
        if (n == 0) return error.EndOfStream;
        var got: usize = n;
        if (s.console) got = crlfToLf(dest[0..n]);
        wr.advance(got);
        return got;
    }

    /// Replaces each \r\n in `b` with \n, in place; returns the new length.
    fn crlfToLf(b: []u8) usize {
        var o: usize = 0;
        for (b, 0..) |ch, i| {
            if (ch == '\r' and i + 1 < b.len and b[i + 1] == '\n') continue;
            b[o] = ch;
            o += 1;
        }
        return o;
    }
};

pub const Terminal = if (is_windows) WindowsTerminal else PosixTerminal;

/// The host terminal's mode, set as the guest asks through TCSETS or
/// /dev/consctl. The original mode comes back when the guest turns raw
/// off, when the run ends, and on exit.
const PosixTerminal = struct {
    saved: ?c.termios = null,
    raw: bool = false,
    no_echo: bool = false,
    no_crnl: bool = false,
    lock: std.atomic.Mutex = .unlocked,

    /// For `Machine.Stdio.raw`.
    pub fn hook(t: *PosixTerminal) h9.Machine.Raw {
        return .{ .ctx = t, .set = setRaw, .echo = setEcho, .crnl = setCrnl, .size = size };
    }

    /// Nothing to do on POSIX: terminals take escape sequences already.
    pub fn enableVt(_: *PosixTerminal) void {}

    pub fn restore(t: *PosixTerminal) void {
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = false;
        t.no_echo = false;
        t.apply(.NOW);
    }

    fn lockSpin(t: *PosixTerminal) void {
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn setRaw(ctx: *anyopaque, on: bool) void {
        const t: *PosixTerminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = on;
        t.apply(.DRAIN);
    }

    fn setEcho(ctx: *anyopaque, on: bool) void {
        const t: *PosixTerminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.no_echo = !on;
        t.apply(.NOW);
    }

    fn setCrnl(ctx: *anyopaque, on: bool) void {
        const t: *PosixTerminal = @ptrCast(@alignCast(ctx));
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

    fn apply(t: *PosixTerminal, when: c.TCSA) void {
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

/// The same for a Windows console: raw mode is a console without line
/// input, echo and processed input. `enableVt` turns on escape sequences
/// in the console's output for the run, as psql's line editing needs.
const WindowsTerminal = struct {
    saved: ?win.DWORD = null,
    saved_out: ?win.DWORD = null,
    raw: bool = false,
    no_echo: bool = false,
    lock: std.atomic.Mutex = .unlocked,

    pub fn hook(t: *WindowsTerminal) h9.Machine.Raw {
        return .{ .ctx = t, .set = setRaw, .echo = setEcho, .crnl = setCrnl, .size = size };
    }

    pub fn enableVt(t: *WindowsTerminal) void {
        const out = win.stdout();
        var mode: win.DWORD = 0;
        if (!win.GetConsoleMode(out, &mode).toBool()) return;
        if (mode & win.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0) return;
        if (win.SetConsoleMode(out, mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING).toBool()) t.saved_out = mode;
    }

    pub fn restore(t: *WindowsTerminal) void {
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = false;
        t.no_echo = false;
        t.apply();
        if (t.saved_out) |m| {
            _ = win.SetConsoleMode(win.stdout(), m);
            t.saved_out = null;
        }
    }

    fn lockSpin(t: *WindowsTerminal) void {
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn setRaw(ctx: *anyopaque, on: bool) void {
        const t: *WindowsTerminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.raw = on;
        t.apply();
    }

    fn setEcho(ctx: *anyopaque, on: bool) void {
        const t: *WindowsTerminal = @ptrCast(@alignCast(ctx));
        t.lockSpin();
        defer t.lock.unlock();
        t.no_echo = !on;
        t.apply();
    }

    /// Windows passes Enter as CR in raw mode already.
    fn setCrnl(_: *anyopaque, _: bool) void {}

    fn size(_: *anyopaque) ?[2]u16 {
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!win.GetConsoleScreenBufferInfo(win.stdout(), &info).toBool()) return null;
        const rows = info.window.bottom - info.window.top + 1;
        const cols = info.window.right - info.window.left + 1;
        if (rows <= 0 or cols <= 0) return null;
        return .{ @intCast(rows), @intCast(cols) };
    }

    fn apply(t: *WindowsTerminal) void {
        const in = stdinHandle();
        if (!t.raw and !t.no_echo) {
            if (t.saved) |mode| {
                _ = win.SetConsoleMode(in, mode);
                t.saved = null;
            }
            return;
        }
        if (t.saved == null) {
            var mode: win.DWORD = 0;
            if (!win.GetConsoleMode(in, &mode).toBool()) return;
            t.saved = mode;
        }
        const mode = t.saved.?;
        const m = if (t.raw)
            (mode & ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT)) | win.ENABLE_VIRTUAL_TERMINAL_INPUT
        else
            mode & ~win.ENABLE_ECHO_INPUT;
        _ = win.SetConsoleMode(in, m);
    }
};

/// How long a clean shutdown may take before the machine is stopped.
pub const shutdown_timeout_ms = 30 * std.time.ms_per_s;

/// SIGINT and SIGTERM; on Windows, Ctrl-C, Ctrl-Break, and the console's
/// close, logoff and shutdown events.
///
/// For a server machine, the first asks Postgres to shut down cleanly (an
/// `interrupt` note, which the Linux personality delivers as SIGINT, a fast
/// shutdown), and the second, or the timeout, tears the machine down at
/// once. `request` takes the same path for a stop that didn't come from a
/// signal (the control socket, the idle timeout).
///
/// For a tool machine, every signal is passed on as an `interrupt`, as a
/// terminal would to the program in the foreground.
///
/// On POSIX the handlers write a byte to a self-pipe; a watcher thread
/// reads it and calls `Machine.Signals`, which `Machine.run` acts on. On
/// Windows the console control handler runs on a thread of its own and
/// counts the event for the watcher, which checks every 50 ms.
pub const Signals = struct {
    pub const Mode = enum { server, tool };

    io: std.Io,
    mode: Mode,
    /// Where shutdown messages go: the server's log.
    out: ?*std.Io.Writer = null,
    /// How a server machine is asked to stop cleanly, instead of an
    /// `interrupt` note.
    stop_hook: ?StopHook = null,
    machine: h9.Machine.Signals = .{},
    /// Set by the first signal.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set by a second signal or the timeout.
    forced: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    sys: Sys = .{},

    pub const StopHook = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) void,
    };

    const Sys = if (is_windows) WindowsSignals else PosixSignals;

    pub fn init(s: *Signals, io: std.Io, mode: Mode, out: ?*std.Io.Writer) !void {
        s.* = .{ .io = io, .mode = mode, .out = out };
        try Sys.init(s);
    }

    pub fn deinit(s: *Signals) void {
        Sys.deinit(s);
    }

    /// Asks for a clean shutdown, as a first signal would. Safe from any
    /// thread.
    pub fn request(s: *Signals) void {
        Sys.post(s);
    }

    fn signal(s: *Signals) void {
        if (s.mode == .tool) {
            s.machine.interrupt(s.io);
            return;
        }
        if (!s.stopping.swap(true, .acq_rel)) {
            s.say("Shutting down...\n");
            if (s.stop_hook) |h| h.func(h.ctx) else s.machine.interrupt(s.io);
        } else if (!s.forced.load(.acquire)) {
            s.say("Forced exit; Postgres will recover from its WAL on next start\n");
            s.force();
        }
    }

    fn force(s: *Signals) void {
        s.forced.store(true, .release);
        s.machine.stop(s.io);
    }

    fn say(s: *Signals, msg: []const u8) void {
        if (s.out) |w| {
            w.writeAll(msg) catch {};
            w.flush() catch {};
        } else if (is_windows) {
            std.debug.print("{s}", .{msg});
        } else _ = c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
    }
};

const PosixSignals = struct {
    pipe: [2]posix.fd_t = .{ -1, -1 },
    old: [2]posix.Sigaction = undefined,

    const sigs = [_]posix.SIG{ .INT, .TERM };
    const ev_signal = 's';
    const ev_quit = 'q';

    var wake_fd: posix.fd_t = -1;

    fn init(s: *Signals) !void {
        const x = &s.sys;
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.SystemResources;
        for (fds) |fd| _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        const fl = c.fcntl(fds[1], posix.F.GETFL);
        _ = c.fcntl(fds[1], posix.F.SETFL, fl | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
        x.pipe = fds;
        wake_fd = fds[1];
        s.thread = try std.Thread.spawn(.{}, watch, .{s});
        const act: posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        for (sigs, &x.old) |sig, *o| posix.sigaction(sig, &act, o);
        var set = posix.sigemptyset();
        for (sigs) |sig| posix.sigaddset(&set, sig);
        posix.sigprocmask(posix.SIG.UNBLOCK, &set, null);
    }

    fn deinit(s: *Signals) void {
        const x = &s.sys;
        const t = s.thread orelse return;
        for (sigs, &x.old) |sig, *o| posix.sigaction(sig, o, null);
        _ = c.write(x.pipe[1], &[_]u8{ev_quit}, 1);
        t.join();
        wake_fd = -1;
        _ = c.close(x.pipe[0]);
        _ = c.close(x.pipe[1]);
        s.thread = null;
    }

    fn post(s: *Signals) void {
        _ = c.write(s.sys.pipe[1], &[_]u8{ev_signal}, 1);
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
        const x = &s.sys;
        var buf: [64]u8 = undefined;
        while (true) {
            var fds = [1]posix.pollfd{.{ .fd = x.pipe[0], .events = posix.POLL.IN, .revents = 0 }};
            const timeout: i32 = if (s.stopping.load(.acquire) and !s.forced.load(.acquire)) shutdown_timeout_ms else -1;
            const ready = posix.poll(&fds, timeout) catch 1;
            if (ready == 0) {
                s.say("Timed out waiting for Postgres to shut down\n");
                s.force();
                continue;
            }
            const n = c.read(x.pipe[0], &buf, buf.len);
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
};

const WindowsSignals = struct {
    /// Events not yet acted on.
    pending: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    installed: bool = false,

    /// The one instance, for the console control handler.
    var current: ?*Signals = null;

    fn init(s: *Signals) !void {
        current = s;
        s.thread = try std.Thread.spawn(.{}, watch, .{s});
        // A process inherits "ignore Ctrl-C" from its parent (OpenSSH sets
        // it, for one), as POSIX inherits a blocked signal mask.
        _ = win.SetConsoleCtrlHandler(null, .FALSE);
        s.sys.installed = win.SetConsoleCtrlHandler(handler, .TRUE).toBool();
    }

    fn deinit(s: *Signals) void {
        const t = s.thread orelse return;
        if (s.sys.installed) _ = win.SetConsoleCtrlHandler(handler, .FALSE);
        s.sys.quit.store(true, .release);
        t.join();
        current = null;
        s.thread = null;
    }

    fn post(s: *Signals) void {
        _ = s.sys.pending.fetchAdd(1, .acq_rel);
    }

    /// Runs on a thread Windows creates for each event.
    fn handler(ev: win.DWORD) callconv(.winapi) win.BOOL {
        const s = current orelse return .FALSE;
        switch (ev) {
            win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT => post(s),
            win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT => {
                post(s);
                // Returning lets Windows end the process at once, so wait
                // here while Postgres shuts down; Windows allows about 5 s.
                var i: u32 = 0;
                while (i < 45 and current != null) : (i += 1) std.Io.sleep(s.io, .fromMilliseconds(100), .awake) catch {};
            },
            else => return .FALSE,
        }
        return .TRUE;
    }

    fn watch(s: *Signals) void {
        const x = &s.sys;
        var deadline: ?i64 = null;
        while (!x.quit.load(.acquire)) {
            var n = x.pending.swap(0, .acq_rel);
            while (n > 0) : (n -= 1) s.signal();
            if (s.stopping.load(.acquire) and !s.forced.load(.acquire)) {
                const now = std.Io.Clock.awake.now(s.io).toMilliseconds();
                const d = deadline orelse now + shutdown_timeout_ms;
                deadline = d;
                if (now >= d) {
                    s.say("Timed out waiting for Postgres to shut down\n");
                    s.force();
                }
            }
            std.Io.sleep(s.io, .fromMilliseconds(50), .awake) catch {};
        }
    }
};
