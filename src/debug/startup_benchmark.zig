const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const clock = @import("debug.zig");

// These are application-side milestones, not compositor presentation timestamps.
pub var enabled = false;
pub var entry_ns: u64 = 0;
pub var cache_state: []const u8 = "skipped";
pub var app_count: usize = 0;
pub var plugin_count: usize = 0;
pub var icons_enabled = true;
pub var run_mode = false;
var config_ns: u64 = 0;
var qt_ns: u64 = 0;
var plugins_ns: u64 = 0;
var window_ns: u64 = 0;
var show_ns: u64 = 0;
var data_ns: u64 = 0;
var first_paint_ns: u64 = 0;
var first_paint_start_ns: u64 = 0;
var ready_paint_start_ns: u64 = 0;
var paint_handler_ns: u64 = 0;
var refresh_ns: u64 = 0;
var refresh_ms: f64 = 0;
var icon_requests: usize = 0;
var icon_ns: u64 = 0;
var ready = false;
var ready_paint_ns: u64 = 0;
var completed = false;
var transitions_disabled = false;
var watched_viewport: ?*anyopaque = null;
var turn_timer: ?qt.QTimer = null;
var timeout_timer: ?qt.QTimer = null;
var input: ?qt.QLineEdit = null;

// Disjoint wall-clock scopes around data work. These deliberately exclude Qt
// calls, but include allocation, filesystem I/O, Lua and Windows APIs where used.
pub const WorkPhase = enum { config, cli_setup, cache_read, cache_decode, cache_stat, frequency, list_prepare, discovery, item_conversion, cache_write, plugins };
var work_ns: [@typeInfo(WorkPhase).@"enum".field_names.len]u64 = @splat(0);
var work_first_paint_ns: u64 = 0;
var work_ready_paint_ns: u64 = 0;
pub fn workStart() u64 {
    return if (enabled) clock.monotonicNs() else 0;
}
pub fn workEnd(phase: WorkPhase, start: u64) void {
    if (start != 0) work_ns[@backingInt(phase)] += clock.monotonicNs() - start;
}
fn workTotal() u64 {
    var total: u64 = 0;
    for (work_ns) |ns| total += ns;
    return total;
}

extern "dwmapi" fn DwmSetWindowAttribute(?*anyopaque, u32, *const anyopaque, u32) callconv(.winapi) i32;

pub fn iconStarted() u64 {
    return if (enabled and icons_enabled) clock.monotonicNs() else 0;
}
pub fn iconFinished(start: u64) void {
    if (start == 0) return;
    icon_requests += 1;
    icon_ns += clock.monotonicNs() - start;
}

pub fn configDone() void {
    if (enabled) config_ns = clock.monotonicNs();
}
pub fn qtDone() void {
    if (enabled) qt_ns = clock.monotonicNs();
}
pub fn pluginsDone(count: usize) void {
    if (!enabled) return;
    plugin_count = count;
    plugins_ns = clock.monotonicNs();
}
pub fn showReturned() void {
    if (enabled) show_ns = clock.monotonicNs();
}
pub fn refreshStarted() void {
    if (enabled) refresh_ns = clock.monotonicNs();
}
pub fn dataReady(count: usize) void {
    if (!enabled) return;
    app_count = count;
    data_ns = clock.monotonicNs();
    if (refresh_ns != 0) refresh_ms = millis(data_ns - refresh_ns);
    ready = true;
}

pub fn attach(app: qt.QApplication, window: qt.QWidget, viewport: qt.QWidget, search: qt.QLineEdit) void {
    if (!enabled) return;
    window_ns = clock.monotonicNs();
    input = search;
    qt.QApplication.setEffectEnabled2(0, false);
    if (comptime builtin.os.tag == .windows) {
        const disable: i32 = 1;
        transitions_disabled = DwmSetWindowAttribute(@ptrFromInt(window.winId()), 3, &disable, @sizeOf(i32)) >= 0;
    }
    watched_viewport = @ptrCast(viewport.ptr);
    app.onNotify(onNotify);
    turn_timer = qt.QTimer.new();
    turn_timer.?.setSingleShot(true);
    turn_timer.?.onTimeout(onPaintTurn);
    timeout_timer = qt.QTimer.new();
    timeout_timer.?.setSingleShot(true);
    timeout_timer.?.onTimeout(onTimeout);
    timeout_timer.?.start(15000);
}

fn onNotify(app: qt.QApplication, receiver: qt.QObject, event: qt.QEvent) callconv(.c) bool {
    const is_viewport_paint = @as(?*anyopaque, @ptrCast(receiver.ptr)) == watched_viewport and
        event.type0() == qt.qcoreevent_enums.Type.Paint;
    const had_data = ready;
    const paint_start = if (is_viewport_paint) clock.monotonicNs() else 0;
    // Delegate the real event exactly once. Timestamp immediately after the
    // actual handler returns, before any refresh timer can run ahead of us.
    const handled = app.superNotify(receiver, event);
    if (is_viewport_paint and !completed) {
        const now = clock.monotonicNs();
        paint_handler_ns += now - paint_start;
        if (first_paint_ns == 0) {
            work_first_paint_ns = workTotal();
            first_paint_ns = now;
            first_paint_start_ns = paint_start;
        }
        if (had_data and ready_paint_ns == 0) {
            work_ready_paint_ns = workTotal();
            ready_paint_ns = now;
            ready_paint_start_ns = paint_start;
            turn_timer.?.start(0); // Only reporting/exit is queued, never timing.
        }
    }
    return handled;
}

fn onPaintTurn(_: qt.QTimer) callconv(.c) void {
    finish("ok", ready_paint_ns);
}
fn onTimeout(_: qt.QTimer) callconv(.c) void {
    finish("timeout", clock.monotonicNs());
}
pub fn failed() void {
    if (enabled) finish("discovery_failed", clock.monotonicNs());
}
fn millis(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
fn sinceEntry(ns: u64) f64 {
    return if (ns >= entry_ns) millis(ns - entry_ns) else 0;
}

fn finish(status: []const u8, now: u64) void {
    if (completed) return;
    completed = true;
    std.debug.print("ZENKAI_WORK {{\"through_first_paint_ms\":{d:.6},\"through_ready_paint_ms\":{d:.6},\"through_report_ms\":{d:.6},\"phases_ms\":{{", .{ millis(work_first_paint_ns), millis(work_ready_paint_ns), millis(workTotal()) });
    inline for (std.meta.tags(WorkPhase), 0..) |phase, i| {
        std.debug.print("{s}\"{s}\":{d:.6}", .{ if (i == 0) "" else ",", @tagName(phase), millis(work_ns[i]) });
    }
    std.debug.print("}}}}\n", .{});
    std.debug.print("ZENKAI_BENCH {{\"schema\":3,\"status\":\"{s}\",\"os\":\"{s}\",\"build\":\"{s}\",\"cache\":\"{s}\",\"apps\":{d},\"plugins\":{d},\"icons\":{s},\"run_mode\":{s},\"animations\":false,\"windows_transitions_disabled\":{s},\"input_focused\":{s},\"config_ms\":{d:.3},\"qt_theme_ms\":{d:.3},\"plugins_ms\":{d:.3},\"window_ms\":{d:.3},\"show_return_ms\":{d:.3},\"first_paint_ms\":{d:.3},\"data_ready_ms\":{d:.3},\"ready_paint_ms\":{d:.3},\"refresh_ms\":{d:.3},\"icon_requests\":{d},\"icon_ms\":{d:.3},\"first_paint_start_ms\":{d:.3},\"ready_paint_start_ms\":{d:.3},\"paint_handler_ms\":{d:.3}}}\n", .{
        status,                                        @tagName(builtin.os.tag),                                                @tagName(builtin.mode),                 cache_state,
        app_count,                                     plugin_count,                                                            if (icons_enabled) "true" else "false", if (run_mode) "true" else "false",
        if (transitions_disabled) "true" else "false", if (if (input) |field| field.hasFocus() else false) "true" else "false", sinceEntry(config_ns),                  sinceEntry(qt_ns),
        sinceEntry(plugins_ns),                        sinceEntry(window_ns),                                                   sinceEntry(show_ns),                    sinceEntry(first_paint_ns),
        sinceEntry(data_ns),                           sinceEntry(now),                                                         refresh_ms,                             icon_requests,
        millis(icon_ns),                               sinceEntry(first_paint_start_ns),                                        sinceEntry(ready_paint_start_ns),       millis(paint_handler_ns),
    });
    qt.QApplication.quit();
}

pub fn deinit() void {
    if (!enabled) return;
    if (turn_timer) |timer| {
        timer.stop();
        timer.delete();
    }
    if (timeout_timer) |timer| {
        timer.stop();
        timer.delete();
    }
    watched_viewport = null;
    turn_timer = null;
    timeout_timer = null;
    input = null;
}
