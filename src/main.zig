//! minipg: PostgreSQL as a file.
//!
//! A .pgdb directory is the database; `minipg app.pgdb` opens a psql shell
//! on it. minipg embeds Docker Hub's postgres:<major>-alpine image as a
//! Linux root and runs it with hyper9 (h9) as a library: h9's Linux
//! personality runs Alpine's own Postgres binaries on the host's hypervisor
//! (HVF on macOS, KVM on Linux) or on h9's native backend (x86_64 Linux
//! without KVM). Postgres listens on a host loopback port directly; psql
//! and the other tools run in their own short-lived machines and connect
//! over loopback.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const paths = @import("paths.zig");
const Ctx = @import("ctx.zig").Ctx;

comptime {
    if (builtin.os.tag == .windows) @compileError("minipg needs a POSIX host for now");
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    const args = cli.parse(arena, argv[1..]) catch {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };
    switch (args.command) {
        .help => {
            var buf: [256]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            try w.interface.writeAll(cli.usage);
            try w.interface.flush();
            return 0;
        },
        .version => {
            var buf: [64]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            try w.interface.print("minipg {s}\n", .{build_options.version});
            try w.interface.flush();
            return 0;
        },
        else => {},
    }
    const ctx: Ctx = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .env = init.environ_map,
        .dirs = paths.dirs(arena, init.environ_map) catch return fail("HOME isn't set"),
        .version = build_options.version,
    };
    return run(ctx, args) catch |err| {
        std.debug.print("minipg: {t}\n", .{err});
        return 1;
    };
}

fn fail(msg: []const u8) u8 {
    std.debug.print("minipg: {s}\n", .{msg});
    return 1;
}

fn run(ctx: Ctx, args: cli.Args) !u8 {
    return switch (args.command) {
        .init => commands.init(ctx, args),
        .shell => commands.shell(ctx, args),
        .serve => commands.serve(ctx, args),
        .stop => commands.stop(ctx, args),
        .status => commands.status(ctx, args),
        .url => commands.url(ctx, args),
        .logs => commands.logs(ctx, args),
        .exec => commands.exec(ctx, args),
        .help, .version => unreachable,
        else => commands.usageError(ctx, "{t} isn't implemented yet", .{args.command}),
    };
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("control.zig");
    _ = @import("logwin.zig");
    _ = @import("net.zig");
    _ = @import("paths.zig");
    _ = @import("pgdb.zig");
    _ = @import("pgwire.zig");
}
