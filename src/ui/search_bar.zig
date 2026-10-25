const std = @import("std");
const qt = @import("libqt6zig");
const lang = @import("lang");

const QLineEdit = qt.QLineEdit;
const QTimer = qt.QTimer;
const QWidget = qt.QWidget;

var g_self: *SearchBar = undefined;
var g_text: ?[]u8 = null;

fn onTextChanged(_: QLineEdit, text_cstr: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(text_cstr);
    const owned = std.heap.page_allocator.dupe(u8, text) catch return;
    if (g_text) |old| std.heap.page_allocator.free(old);
    g_text = owned;
    if (g_self.debounce_timer) |timer| {
        timer.stop();
        timer.start(@intCast(g_self.debounce_ms));
    }
}

fn onDebounceTimeout(_: QTimer) callconv(.c) void {
    if (g_self.on_debounced) |cb| {
        cb(g_text orelse "");
    }
}

pub const SearchBar = struct {
    widget: QLineEdit,
    debounce_timer: ?QTimer,
    debounce_ms: i32,
    on_debounced: ?*const fn (text: []const u8) void,

    pub fn init(parent: QWidget, debounce_ms: i32) SearchBar {
        var sb = QLineEdit.new2();
        sb.setObjectName("searchbarInput");
        {
            var buf: [256]u8 = undefined;
            const text = lang.get().search_placeholder;
            const len = @min(text.len, buf.len - 1);
            @memcpy(buf[0..len], text[0..len]);
            buf[len] = 0;
            sb.setPlaceholderText(buf[0..len]);
        }
        sb.setClearButtonEnabled(false);

        var timer = QTimer.new2(parent);
        timer.setSingleShot(true);

        return .{
            .widget = sb,
            .debounce_timer = timer,
            .debounce_ms = debounce_ms,
            .on_debounced = null,
        };
    }

    pub fn setup(self: *SearchBar) void {
        g_self = self;
        self.widget.onTextChanged(onTextChanged);
        if (self.debounce_timer) |timer| {
            timer.onTimeout(onDebounceTimeout);
        }
    }

    pub fn deinit(self: *SearchBar) void {
        if (g_text) |text| std.heap.page_allocator.free(text);
        g_text = null;
        if (self.debounce_timer) |timer| timer.delete();
        self.widget.delete();
    }

    pub fn getText(_: *SearchBar) []const u8 {
        return g_text orelse "";
    }

    pub fn setText(self: *SearchBar, text: []const u8) void {
        self.widget.setText(text);
    }

    pub fn setPlaceholder(self: *SearchBar, placeholder: []const u8) void {
        var buf: [256]u8 = undefined;
        const len = @min(placeholder.len, buf.len - 1);
        @memcpy(buf[0..len], placeholder[0..len]);
        buf[len] = 0;
        self.widget.setPlaceholderText(buf[0..len]);
    }

    pub fn focus(self: *SearchBar) void {
        self.widget.setFocus();
    }
};

pub fn currentText() []const u8 {
    return g_text orelse "";
}
