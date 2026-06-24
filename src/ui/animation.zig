const std = @import("std");
const qt = @import("libqt6zig");

const QWidget = qt.QWidget;
const QPropertyAnimation = qt.QPropertyAnimation;
const QEasingCurve = qt.QEasingCurve;
const QVariant = qt.QVariant;
const QApp = qt.QApplication;

pub const AnimationConfig = struct {
    enabled: bool = true,
    interval_ms: i32 = 200,
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
        window.SetWindowOpacity(1.0);
        return;
    }
    window.SetWindowOpacity(0.0);
    var prop_name: [13]u8 = "windowOpacity".*;
    var anim = QPropertyAnimation.New2(window, prop_name[0..]);
    anim.SetDuration(g_cfg.interval_ms);
    anim.SetStartValue(QVariant.New9(0.0));
    anim.SetEndValue(QVariant.New9(1.0));
    var easing = QEasingCurve.New3(@intFromEnum(g_cfg.easing));
    defer easing.Delete();
    anim.SetEasingCurve(easing);
    anim.Start1(1);
}

fn onLaunchCloseFinished(_: QPropertyAnimation) callconv(.c) void {
    QApp.Quit();
}

pub fn animateFadeOutAndQuit() void {
    const widget = g_window_widget orelse {
        QApp.Quit();
        return;
    };
    if (!g_cfg.enabled) {
        QApp.Quit();
        return;
    }
    const current = widget.WindowOpacity();
    var prop_name: [13]u8 = "windowOpacity".*;
    var anim = QPropertyAnimation.New2(widget, prop_name[0..]);
    anim.SetDuration(g_cfg.interval_ms);
    anim.SetStartValue(QVariant.New9(current));
    anim.SetEndValue(QVariant.New9(0.0));
    var easing = QEasingCurve.New3(@intFromEnum(EasingType.InCubic));
    defer easing.Delete();
    anim.SetEasingCurve(easing);
    anim.OnFinished(onLaunchCloseFinished);
    anim.Start1(1);
}
