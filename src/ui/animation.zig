const std = @import("std");
const qt = @import("libqt6zig");

const QWidget = qt.QWidget;
const QPropertyAnimation = qt.QPropertyAnimation;
const QEasingCurve = qt.QEasingCurve;
const QVariant = qt.QVariant;
const QApp = qt.QApplication;
const debug = @import("../debug/debug.zig");
const utils = @import("utils");

pub const AnimationConfig = struct {
    enabled: bool = true,
    interval_ms: i32 = 200,
    quit_when_shown: bool = false,
    easing: EasingType = .OutCubic,
};

pub const EasingType = enum(i32) {
    Linear = 0,
    InQuad = 1,
    OutQuad = 2,
    InOutQuad = 3,
    InCubic = 5,
    OutCubic = 6,
    InOutCubic = 7,
    OutBack = 34,
    InOutBack = 35,

    pub fn fromName(name: []const u8) EasingType {
        if (std.mem.eql(u8, name, "linear")) return .Linear;
        if (std.mem.eql(u8, name, "in-quad")) return .InQuad;
        if (std.mem.eql(u8, name, "out-quad")) return .OutQuad;
        if (std.mem.eql(u8, name, "in-out-quad")) return .InOutQuad;
        if (std.mem.eql(u8, name, "in-cubic")) return .InCubic;
        if (std.mem.eql(u8, name, "out-cubic")) return .OutCubic;
        if (std.mem.eql(u8, name, "in-out-cubic")) return .InOutCubic;
        if (std.mem.eql(u8, name, "out-back")) return .OutBack;
        if (std.mem.eql(u8, name, "in-out-back")) return .InOutBack;
        return .OutCubic;
    }
};

var g_cfg: AnimationConfig = .{};
var g_window_widget: ?QWidget = null;

// onValueChanged fires once per tick, so this counts real presented frames.
// A clock read per frame, so bench builds only.
var g_anim_t0: u64 = 0;
var g_anim_frames: usize = 0;
var g_anim_work_ns: u64 = 0;
var g_anim_last_ns: u64 = 0;

fn onFadeTick(_: QPropertyAnimation, _: QVariant) callconv(.c) void {
    if (comptime !debug.instrumentation) return;
    const now = debug.tick();
    if (g_anim_frames > 0 and now > g_anim_last_ns) g_anim_work_ns += now - g_anim_last_ns;
    g_anim_last_ns = now;
    g_anim_frames += 1;
}

pub fn setConfig(cfg: AnimationConfig) void {
    g_cfg = cfg;
}

pub fn config() AnimationConfig {
    return g_cfg;
}

pub fn setWindowWidget(widget: QWidget) void {
    g_window_widget = widget;
}

pub fn animateFadeIn(window: QWidget) void {
    if (!g_cfg.enabled) {
        window.setWindowOpacity(1.0);
        // No fade means no finished signal, so close here instead.
        if (g_cfg.quit_when_shown) QApp.quit();
        return;
    }
    window.setWindowOpacity(0.0);
    var prop_name: [13]u8 = "windowOpacity".*;
    const t_anim = debug.tick();
    g_anim_t0 = t_anim;
    g_anim_frames = 0;
    g_anim_work_ns = 0;
    g_anim_last_ns = 0;
    var anim = QPropertyAnimation.new2(window, prop_name[0..]);
    anim.setDuration(g_cfg.interval_ms);
    anim.setStartValue(QVariant.new9(0.0));
    anim.setEndValue(QVariant.new9(1.0));
    var easing = QEasingCurve.new3(@intFromEnum(g_cfg.easing));
    defer easing.delete();
    anim.setEasingCurve(easing);
    if (comptime debug.instrumentation) anim.onValueChanged(onFadeTick);
    anim.onFinished(onFadeInFinished);
    anim.start1(1);
    debug.done("animateFadeIn setup (Qt)", .qt, t_anim);
}

fn onFadeInFinished(_: QPropertyAnimation) callconv(.c) void {
    if (comptime debug.instrumentation) {
        const wall = debug.tick() - g_anim_t0;
        const work = if (g_anim_frames > 0) debug.tick() - g_anim_last_ns else 0;
        utils.log.info("animation: {d} frames over {d:.2}ms wall, {d:.2}ms in-frame, {d:.2}ms/frame", .{
            g_anim_frames,
            @as(f64, @floatFromInt(wall)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(g_anim_work_ns + work)) / std.time.ns_per_ms,
            if (g_anim_frames == 0) 0.0 else @as(f64, @floatFromInt((g_anim_work_ns + work) / g_anim_frames)) / std.time.ns_per_ms,
        });
    }
    if (comptime debug.instrumentation) {
        utils.log.info("window fully visible in {d:.2}ms", .{debug.elapsedMs()});
    }
    // The window is painted and the visible rows are populated, which is the
    // point a person would press ESC. Used by bench.sh so a benchmark run
    // terminates on exactly the frame it was measuring.
    if (g_cfg.quit_when_shown) QApp.quit();
}

fn onLaunchCloseFinished(_: QPropertyAnimation) callconv(.c) void {
    QApp.quit();
}

pub fn animateFadeOutAndQuit() void {
    const widget = g_window_widget orelse {
        QApp.quit();
        return;
    };
    if (!g_cfg.enabled) {
        QApp.quit();
        return;
    }
    const current = widget.windowOpacity();
    var prop_name: [13]u8 = "windowOpacity".*;
    var anim = QPropertyAnimation.new2(widget, prop_name[0..]);
    anim.setDuration(g_cfg.interval_ms);
    anim.setStartValue(QVariant.new9(current));
    anim.setEndValue(QVariant.new9(0.0));
    var easing = QEasingCurve.new3(@intFromEnum(EasingType.InCubic));
    defer easing.delete();
    anim.setEasingCurve(easing);
    anim.onFinished(onLaunchCloseFinished);
    anim.start1(1);
}
