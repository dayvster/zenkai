const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .strip = true,
    });

    const exe = b.addExecutable(.{
        .name = "zlauncher",
        .root_module = module,
    });

    const qt6zig = b.dependency("libqt6zig", .{
        .target = target,
        .optimize = .ReleaseFast,
    });

    exe.root_module.addImport("libqt6zig", qt6zig.module("libqt6zig"));

    const libs = [_][]const u8{
        "qobject",
        "qcoreapplication",
        "qguiapplication",
        "qapplication",
        "qwidget",
        "qlabel",
        "qlineedit",
        "qlayout",
        "qboxlayout",
        "qlistwidget",
        "qshortcut",
        "qkeysequence",
        "qscreen",
        "qpalette",
        "qcolor",
        "qstylehints",
        "qnamespace",
        "qabstractitemview",
        "qimage",
        "qpixmap",
        "qicon",
        "qrect",
        "qsize",
        "qpoint",
        "qwindow",
    };

    for (libs) |lib| {
        exe.root_module.linkLibrary(qt6zig.artifact(lib));
    }

    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.linkSystemLibrary("Qt6Core", .{});
    exe.root_module.linkSystemLibrary("Qt6Gui", .{});
    exe.root_module.linkSystemLibrary("Qt6Widgets", .{});
    exe.root_module.linkSystemLibrary("stdc++", .{});

    exe.root_module.addImport("fsutils", b.createModule(.{
        .root_source_file = b.path("src/utils/fsutils.zig"),
    }));

    exe.root_module.addImport("desktopapp", b.createModule(.{
        .root_source_file = b.path("src/core/desktopapp.zig"),
    }));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
