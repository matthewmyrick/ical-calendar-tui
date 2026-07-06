const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ical-calendar-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    // Info.plist is embedded into a __TEXT,__info_plist section from Zig
    // (see main.zig) so TCC can find the usage description in a bare binary.
    exe.root_module.addAnonymousImport("Info.plist", .{
        .root_source_file = b.path("native/Info.plist"),
    });
    addNativeBits(b, exe.root_module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the TUI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests (leak-checked)");
    test_step.dependOn(&run_exe_tests.step);

    // Integration smoke tests: hit the real EventKit store + ical CLI.
    // Requires calendar access; deliberately NOT part of `zig build test`.
    const itests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/itest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addNativeBits(b, itests.root_module);
    const run_itests = b.addRunArtifact(itests);
    const itest_step = b.step("itest", "Integration smoke tests (needs calendar access)");
    itest_step.dependOn(&run_itests.step);
}

/// The EventKit shim (the only ObjC in the project, SPEC §2) plus the test
/// fixtures that live outside src/ — shared by the exe and itest modules.
fn addNativeBits(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("ical-list-sample.json", .{
        .root_source_file = b.path("testdata/ical-list-sample.json"),
    });
    module.addAnonymousImport("ical-calendars-sample.json", .{
        .root_source_file = b.path("testdata/ical-calendars-sample.json"),
    });
    module.addCSourceFile(.{
        .file = b.path("native/eventkit_shim.m"),
        .flags = &.{"-fobjc-arc"},
    });
    module.addIncludePath(b.path("native"));
    module.link_libc = true;
    module.linkSystemLibrary("objc", .{});
    module.linkFramework("EventKit", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("AppKit", .{}); // NSColor for calendar colors
}
