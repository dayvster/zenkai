const std = @import("std");
const qt = @import("libqt6zig");

const Language = enum { plain, code, hash, lua, json };
var language: Language = .plain;
var dark = true;

pub fn configure(path: []const u8, editor: qt.QPlainTextEdit) void {
    language = detect(path);
    dark = editor.palette().color2(qt.qpalette_enums.ColorRole.Base).lightness() < 128;
}

fn detect(path: []const u8) Language {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".lua")) return .lua;
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return .json;
    for ([_][]const u8{ ".py", ".sh", ".bash", ".yaml", ".yml", ".toml", ".conf", ".rb", ".ps1" }) |value| {
        if (std.ascii.eqlIgnoreCase(ext, value)) return .hash;
    }
    for ([_][]const u8{ ".zig", ".c", ".h", ".cpp", ".hpp", ".rs", ".go", ".js", ".jsx", ".ts", ".tsx", ".java", ".cs", ".swift", ".kt", ".css" }) |value| {
        if (std.ascii.eqlIgnoreCase(ext, value)) return .code;
    }
    return .plain;
}

const Kind = enum { comment, string, number, keyword };
const Painter = struct {
    highlighter: qt.QSyntaxHighlighter,
    text: []const u8,
    byte_offset: usize = 0,
    column: i32 = 0,
    fn paint(self: *Painter, start: usize, end: usize, kind: Kind) void {
        const colors = if (dark) [_][]const u8{ "#8b9b8b", "#a8d28d", "#e4b47c", "#9fb8ff" } else [_][]const u8{ "#536653", "#32691e", "#8a4b09", "#3949ab" };
        const color = qt.QColor.new8(colors[@backingInt(kind)]);
        defer color.delete();
        self.column += utf16Length(self.text[self.byte_offset..start]);
        const length = utf16Length(self.text[start..end]);
        self.highlighter.setFormat2(self.column, length, color);
        self.column += length;
        self.byte_offset = end;
    }
};

// Qt format offsets are UTF-16 code units, whereas the callback supplies UTF-8.
fn utf16Length(text: []const u8) i32 {
    var count: i32 = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) count += if (byte >= 0xf0) @as(i32, 2) else 1;
    }
    return count;
}

fn keyword(word: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, "const var let fn function pub return if else switch case default for while do break continue defer errdefer try catch throw throws async await class struct enum union interface impl trait import from export package use using namespace include static void int bool float double char null nil true false undefined local end then elseif repeat until and or not in is def lambda pass with as except finally raise yield match type comptime inline extern test self this new delete public private protected extends", ' ');
    while (words.next()) |value| if (std.mem.eql(u8, word, value)) return true;
    return false;
}

pub fn highlight(highlighter: qt.QSyntaxHighlighter, raw: [*:0]const u8) callconv(.c) void {
    highlighter.setCurrentBlockState(0);
    if (language == .plain) return;
    const text = std.mem.span(raw);
    var painter = Painter{ .highlighter = highlighter, .text = text };
    var i: usize = 0;
    const block_end: []const u8 = if (language == .lua) "]]" else "*/";
    if (highlighter.previousBlockState() == 1) {
        if (std.mem.indexOf(u8, text, block_end)) |end| {
            i = end + 2;
            painter.paint(0, i, .comment);
        } else {
            painter.paint(0, text.len, .comment);
            highlighter.setCurrentBlockState(1);
            return;
        }
    }
    while (i < text.len) {
        const start = i;
        const rest = text[i..];
        const block_start = (language == .code and std.mem.startsWith(u8, rest, "/*")) or
            (language == .lua and std.mem.startsWith(u8, rest, "--[["));
        if (block_start) {
            const skip: usize = if (language == .lua) 4 else 2;
            if (std.mem.indexOf(u8, text[i + skip ..], block_end)) |end| {
                i += skip + end + 2;
            } else {
                i = text.len;
                highlighter.setCurrentBlockState(1);
            }
            painter.paint(start, i, .comment);
        } else if ((language == .code and std.mem.startsWith(u8, rest, "//")) or
            (language == .lua and std.mem.startsWith(u8, rest, "--")) or
            (language == .hash and text[i] == '#'))
        {
            painter.paint(i, text.len, .comment);
            break;
        } else if (text[i] == '"' or text[i] == '\'' or (language == .code and text[i] == '`')) {
            const quote = text[i];
            i += 1;
            while (i < text.len) {
                if (text[i] == '\\') {
                    i = @min(i + 2, text.len);
                } else if (text[i] == quote) {
                    i += 1;
                    break;
                } else i += 1;
            }
            painter.paint(start, i, .string);
        } else if (std.ascii.isDigit(text[i])) {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '.' or text[i] == '_')) : (i += 1) {}
            painter.paint(start, i, .number);
        } else if (std.ascii.isAlphabetic(text[i]) or text[i] == '_') {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
            if (keyword(text[start..i])) painter.paint(start, i, .keyword);
        } else i += 1;
    }
}

test "language selection and UTF-16 offsets" {
    try std.testing.expectEqual(Language.code, detect("main.ZIG"));
    try std.testing.expectEqual(Language.lua, detect("main.lua"));
    try std.testing.expectEqual(Language.plain, detect("notes.txt"));
    try std.testing.expectEqual(@as(i32, 5), utf16Length("a😀éz"));
    try std.testing.expect(keyword("const") and !keyword("constant"));
}
