//! minipg: Alpine's PostgreSQL image run by hyper9 (h9) as a library, in
//! one binary.
//!
//!   zig build                          build zig-out/bin/minipg
//!   zig build run -- app.pgdb          build and run it
//!   zig build test                     unit tests
//!   zig build -Dtarget=aarch64-linux-musl
//!
//! The binary embeds assets/root-<arch>.tar.xz, the Linux root for the
//! target's architecture, and assets/root-<arch>.json, what it is; `make
//! root` (scripts/root.sh) makes both.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const version = b.option([]const u8, "version", "Version -v prints (default: dev)") orelse "dev";
    const arch: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @panic("minipg runs on x86_64 and aarch64 hosts only"),
    };
    const root_path = b.option([]const u8, "root", "The Linux root tarball to embed (default assets/root-<arch>.tar.xz)") orelse
        b.fmt("assets/root-{s}.tar.xz", .{arch});
    // Its metadata sits beside it.
    const meta_path = b.fmt("{s}.json", .{root_path[0 .. root_path.len - ".tar.xz".len]});

    // No GUI: the machine has no screen. Unicorn (GPLv2) stays out, so the
    // binary runs on the host's hypervisor (HVF, KVM) or h9's native
    // backend on x86_64 Linux.
    const h9 = b.dependency("h9", .{
        .target = target,
        .optimize = optimize,
        .gfx = .none,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "minipg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "h9", .module = h9.module("h9") },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.addAnonymousImport("root_tar", .{ .root_source_file = b.path(root_path) });
    exe.root_module.addAnonymousImport("root_meta", .{ .root_source_file = b.path(meta_path) });
    if (os == .macos) {
        addSdkPaths(b, exe.root_module);
        exe.root_module.linkFramework("Hypervisor", .{});
    }

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    // HVF refuses to create a VM without the hypervisor entitlement.
    var ready = &install.step;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addArg(b.getInstallPath(.bin, exe.out_filename));
        sign.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&sign.step);
        ready = &sign.step;
    }

    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    run.step.dependOn(ready);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run minipg").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "h9", .module = h9.module("h9") },
        },
    }) });
    tests.root_module.addOptions("build_options", options);
    tests.root_module.addAnonymousImport("root_tar", .{ .root_source_file = b.path(root_path) });
    tests.root_module.addAnonymousImport("root_meta", .{ .root_source_file = b.path(meta_path) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// The macOS SDK's paths, as hyper9's build adds them: from $SDKROOT, or
/// on a Mac from `xcrun --show-sdk-path` (what hyper9's scripts/env.sh sets
/// SDKROOT to), since Zig doesn't find the Hypervisor framework itself.
fn addSdkPaths(b: *std.Build, m: *std.Build.Module) void {
    const sdk = b.graph.environ_map.get("SDKROOT") orelse blk: {
        if (b.graph.host.result.os.tag != .macos) return;
        const out = b.run(&.{ "xcrun", "--show-sdk-path" });
        break :blk std.mem.trim(u8, out, " \t\r\n");
    };
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}
