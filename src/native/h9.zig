//! The few hyper9 types minipg uses, for the Linux build (`-Dhost=linux`),
//! where minipg runs inside the Postgres image and starts Postgres and its
//! tools as ordinary processes instead of h9 machines. vm.zig does the
//! running; this only gives host.zig, server.zig and commands.zig the same
//! names, so they build either way.

const std = @import("std");

pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// How a process ended, in h9's terms: `exited` with its exit status as a
/// string (empty for 0), or `killed` by a signal.
pub const Status = union(enum) {
    exited: []const u8,
    killed: []const u8,
};

pub const consin = struct {
    pub const Cancel = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, thread: std.Thread) void,
        reset: *const fn (ctx: *anyopaque) void,
    };
};

pub const Machine = struct {
    pub const Raw = struct {
        ctx: *anyopaque,
        set: *const fn (ctx: *anyopaque, on: bool) void,
        echo: ?*const fn (ctx: *anyopaque, on: bool) void = null,
        crnl: ?*const fn (ctx: *anyopaque, on: bool) void = null,
        size: ?*const fn (ctx: *anyopaque) ?[2]u16 = null,
    };

    /// What host.Signals asks of a run: here, signals to the process vm.zig
    /// started, which leads its own process group.
    pub const Signals = struct {
        pid: std.atomic.Value(i32) = .init(0),

        /// SIGINT to the process.
        pub fn interrupt(s: *Signals, io: std.Io) void {
            _ = io;
            const pid = s.pid.load(.acquire);
            if (pid > 0) _ = std.c.kill(pid, .INT);
        }

        /// SIGKILL to its whole process group.
        pub fn stop(s: *Signals, io: std.Io) void {
            _ = io;
            const pid = s.pid.load(.acquire);
            if (pid > 0) _ = std.c.kill(-pid, .KILL);
        }
    };
};

pub const vmm = struct {
    pub const BackendKind = enum { auto, process };

    pub fn whyUnavailable(kind: BackendKind) ?[]const u8 {
        _ = kind;
        return null;
    }
};
