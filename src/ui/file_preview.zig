const std = @import("std");
const qt = @import("libqt6zig");
const utils = @import("utils");
const fsutils = utils.fsutils;
const a = std.heap.page_allocator;
const syntax = @import("code_highlighter.zig");

pub const Preview = struct {
    widget: qt.QWidget,
    title: qt.QLabel,
    image: qt.QLabel,
    text: qt.QPlainTextEdit,
    timer: qt.QTimer,
    highlighter: qt.QSyntaxHighlighter,
    path: ?[]u8 = null,
    var active: ?*Preview = null;

    pub fn init(parent: qt.QWidget) Preview {
        const widget = qt.QWidget.new(parent);
        widget.setObjectName("filePreview");
        widget.setFixedWidth(270);
        const layout = qt.QVBoxLayout.new(widget);
        layout.setContentsMargins(12, 12, 12, 12);
        const title = qt.QLabel.new(widget);
        title.setTextFormat(qt.qnamespace_enums.TextFormat.PlainText);
        title.setWordWrap(true);
        const picture = qt.QLabel.new(widget);
        picture.setAlignment(qt.qnamespace_enums.AlignmentFlag.AlignCenter);
        const text = qt.QPlainTextEdit.new(widget);
        text.setReadOnly(true);
        const highlighter = qt.QSyntaxHighlighter.new2(text.document());
        highlighter.onHighlightBlock(syntax.highlight);
        text.setFocusPolicy(qt.qnamespace_enums.FocusPolicy.NoFocus);
        layout.addWidget(title);
        layout.addWidget(picture);
        layout.addWidget(text);
        const timer = qt.QTimer.new();
        timer.setSingleShot(true);
        timer.onTimeout(onTimeout);
        widget.hide();
        return .{ .widget = widget, .title = title, .image = picture, .text = text, .timer = timer, .highlighter = highlighter };
    }

    pub fn select(self: *Preview, path: ?[]const u8) void {
        self.timer.stop();
        syntax.configure("", self.text);
        if (self.path) |old| a.free(old);
        self.path = null;
        self.image.clear();
        self.image.hide();
        self.text.clear();
        self.widget.hide();
        if (path) |value| {
            self.path = a.dupe(u8, value) catch return;
            self.title.setText(std.fs.path.basename(value));
            self.text.setPlainText("Loading preview…");
            self.widget.show();
            active = self;
            self.timer.start(120);
        }
    }

    fn onTimeout(_: qt.QTimer) callconv(.c) void {
        const self = active orelse return;
        self.load() catch {
            self.text.setPlainText("Preview unavailable. The path may have moved or access was denied.");
        };
    }

    fn load(self: *Preview) !void {
        const path = self.path orelse return;
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (stat.kind == .directory) {
            try self.loadDirectory(path);
            return;
        }
        if (stat.kind != .file) {
            self.text.setPlainText("Preview unavailable for this file type.");
            return;
        }
        var metadata: [128]u8 = undefined;
        const details = try std.fmt.bufPrint(&metadata, "{d} bytes", .{stat.size});
        self.text.setPlainText(details);
        if (self.loadImage(path, stat.size)) return;
        try self.loadText(path, stat.size);
    }

    fn loadDirectory(self: *Preview, path: []const u8) !void {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(a);
        try content.appendSlice(a, "Folder contents\n\n");
        var count: usize = 0;
        while (try iterator.next(io)) |entry| {
            if (count == 64) {
                try content.appendSlice(a, "\nMore entries…");
                break;
            }
            try content.appendSlice(a, entry.name);
            try content.appendSlice(a, if (entry.kind == .directory) "/\n" else "\n");
            count += 1;
        }
        if (count == 0) try content.appendSlice(a, "Empty folder");
        self.text.setPlainText(content.items);
    }

    fn loadImage(self: *Preview, path: []const u8, file_size: u64) bool {
        const extension = std.fs.path.extension(path);
        for (utils.image_extensions.all) |ext| {
            if (!std.ascii.eqlIgnoreCase(extension, ext)) continue;
            if (file_size > 16 * 1024 * 1024) return true;
            const reader = qt.QImageReader.new3(path);
            defer reader.delete();
            const size = reader.size();
            defer size.delete();
            if (size.width() <= 0 or size.height() <= 0 or @as(i64, size.width()) * size.height() > 16 * 1024 * 1024) return true;
            reader.setAutoTransform(true);
            const decoded = reader.read();
            defer decoded.delete();
            if (decoded.isNull()) return true;
            const pixmap = qt.QPixmap.fromImage(decoded);
            defer pixmap.delete();
            const scaled = pixmap.scaled4(240, 220, qt.qnamespace_enums.AspectRatioMode.KeepAspectRatio, qt.qnamespace_enums.TransformationMode.SmoothTransformation);
            defer scaled.delete();
            self.image.setPixmap(scaled);
            self.image.show();
            return true;
        }
        return false;
    }

    fn loadText(self: *Preview, path: []const u8, file_size: u64) !void {
        if (file_size > 128 * 1024) {
            self.text.setPlainText("Text preview limited to files up to 128 KiB.");
            return;
        }
        const bytes = try fsutils.readFile(a, path, 128 * 1024);
        defer a.free(bytes);
        if (!isText(bytes)) {
            self.text.setPlainText("Binary or unsupported text encoding. Open with the default app to view.");
            return;
        }
        syntax.configure(path, self.text);
        self.text.setPlainText(if (bytes.len == 0) "Empty file" else bytes);
        self.highlighter.rehighlight();
    }

    pub fn deinit(self: *Preview) void {
        self.timer.stop();
        self.timer.delete();
        if (self.path) |path| a.free(path);
        if (active == self) active = null;
    }
};

fn isText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') return false;
    return true;
}

test "preview text accepts UTF-8 and rejects binary content" {
    try std.testing.expect(isText("hello\nGrüße\t<html>"));
    try std.testing.expect(!isText("hello\x00world"));
    try std.testing.expect(!isText("\xff\xfe"));
}

test "file preview renders text, folders and images and clears selection" {
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(a, &argc, &argv);
    defer app.delete();
    const parent = qt.QWidget.new2();
    defer parent.delete();
    var preview = Preview.init(parent);
    defer preview.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.txt", .data = "<b>plain text</b>" });
    const path = try tmp.dir.realPathFileAlloc(io, "sample.txt", a);
    defer a.free(path);
    preview.select(path);
    preview.timer.stop();
    try preview.load();
    const text = preview.text.toPlainText(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("<b>plain text</b>", text);
    syntax.configure("example.c", preview.text);
    preview.text.setPlainText("/* comment\ncontinued */ const char *s = \"😀\";\nreturn 42;");
    preview.highlighter.rehighlight();
    const first = preview.text.document().findBlockByNumber(0);
    defer first.delete();
    const second = preview.text.document().findBlockByNumber(1);
    defer second.delete();
    try std.testing.expectEqual(@as(i32, 1), first.userState());
    try std.testing.expectEqual(@as(i32, 0), second.userState());
    const folder = std.fs.path.dirname(path).?;
    preview.select(folder);
    preview.timer.stop();
    try preview.load();
    const listing = preview.text.toPlainText(a);
    defer a.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "sample.txt") != null);
    const image_path = try std.fs.path.join(a, &.{ folder, "sample.png" });
    defer a.free(image_path);
    const picture = qt.QImage.new3(20, 10, qt.qimage_enums.Format.Format_ARGB32);
    defer picture.delete();
    picture.fill(0xff336699);
    try std.testing.expect(picture.save(image_path));
    preview.select(image_path);
    preview.timer.stop();
    try preview.load();
    try std.testing.expect(!preview.image.isHidden());
    if (std.c.getenv("ZENKAI_FILE_PREVIEW")) |output| {
        parent.resize(270, 440);
        preview.widget.resize(270, 440);
        parent.show();
        qt.QApplication.processEvents();
        const shot = parent.grab();
        defer shot.delete();
        try std.testing.expect(shot.save(std.mem.span(output)));
    }
    preview.select(null);
    try std.testing.expect(preview.widget.isHidden() and preview.path == null and !preview.timer.isActive());
}
