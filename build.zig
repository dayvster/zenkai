const std = @import("std");
const configureQtExeRootModule = @import("libqt6zig").configureQtExeRootModule;

pub fn build(b: *std.Build) !void {
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
        "qabstractscrollarea",
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
        "qtimer",
        "qcursor",
    };

    for (libs) |lib| {
        const artifact = qt6zig.artifact(lib);
        exe.root_module.linkLibrary(artifact);
    }

    const lua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.root_module.addImport("zlua", lua_dep.module("zlua"));

    try configureQtExeRootModule(b, exe, .{
        .linux_libraries = &.{"libgcc_eh.a"},
    });

    exe.root_module.linkSystemLibrary("m", .{});

    const lua_capi_module = b.addModule("lua_capi", .{
        .root_source_file = b.path("src/plugins/lua_capi.zig"),
    });

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

    const frequency_module = b.addModule("core_freq", .{
        .root_source_file = b.path("src/core/frequency.zig"),
        .imports = &.{
            .{ .name = "utils", .module = utils_module },
        },
    });

    const plugins_module = b.addModule("plugins", .{
        .root_source_file = b.path("src/plugins/plugins.zig"),
        .imports = &.{
            .{ .name = "lua_capi", .module = lua_capi_module },
            .{ .name = "utils", .module = utils_module },
        },
    });

    const osx_module = if (target.result.os.tag == .macos) b.addModule("osx", .{
        .root_source_file = b.path("src/core/osx/osx.zig"),
        .imports = &.{
            .{ .name = "desktopapp", .module = desktopapp_module },
            .{ .name = "utils", .module = utils_module },
            .{ .name = "libqt6zig", .module = qt6zig.module("libqt6zig") },
        },
    }) else null;

    exe.root_module.addImport("utils", utils_module);
    exe.root_module.addImport("desktopapp", desktopapp_module);
    exe.root_module.addImport("dapp_parser", dapp_parser_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("lua_capi", lua_capi_module);
    exe.root_module.addImport("plugins", plugins_module);
    exe.root_module.addImport("core_freq", frequency_module);
    if (osx_module) |mod| exe.root_module.addImport("osx", mod);
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

    const plugin_test_module = b.createModule(.{
        .root_source_file = b.path("src/plugins/plugins.test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    plugin_test_module.addImport("lua_capi", lua_capi_module);
    plugin_test_module.addImport("zlua", lua_dep.module("zlua"));
    plugin_test_module.linkSystemLibrary("m", .{});

    const plugin_tests = b.addTest(.{
        .root_module = plugin_test_module,
    });

    const run_plugin_tests = b.addRunArtifact(plugin_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_plugin_tests.step);
}
