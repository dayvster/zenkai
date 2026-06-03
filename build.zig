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
        .name = "zenkai",
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
        "qpainter",
        "qfont",
        "qvariant",
        "qabstractitemmodel",
        "qaction",
        "qmessagebox",
        "qtoolbutton",
        "qlistview",
    };

    for (libs) |lib| {
        const artifact = qt6zig.artifact(lib);
        exe.root_module.linkLibrary(artifact);
    }

    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.linkSystemLibrary("Qt6Core", .{});
    exe.root_module.linkSystemLibrary("Qt6Gui", .{});
    exe.root_module.linkSystemLibrary("Qt6Widgets", .{});
    exe.root_module.link_libcpp = false;
    exe.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/libstdc++.so" });
    exe.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/gcc/x86_64-pc-linux-gnu/16.1.1/libgcc_eh.a" });

    const utils_module = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/utils.zig"),
    });

    const desktopapp_module = b.addModule("desktopapp", .{
        .root_source_file = b.path("src/core/desktopapp.zig"),
    });

    const dapp_parser_module = b.addModule("dapp_parser", .{
        .root_source_file = b.path("src/core/dapp_parser.zig"),
        .imports = &.{
            .{ .name = "desktopapp", .module = desktopapp_module },
            .{ .name = "utils", .module = utils_module },
        },
    });

    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/config/config.zig"),
        .imports = &.{.{ .name = "utils", .module = utils_module }},
    });

    exe.root_module.addImport("utils", utils_module);
    exe.root_module.addImport("desktopapp", desktopapp_module);
    exe.root_module.addImport("dapp_parser", dapp_parser_module);
    exe.root_module.addImport("config", config_module);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const check_step = b.step("check", "Check code compiles");
    check_step.dependOn(&exe.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
