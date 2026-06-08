const std = @import("std");

pub const PlistError = error{
    InvalidHeader,
    InvalidTrailer,
    InvalidMarker,
    OutOfBounds,
    UnsupportedType,
    ParseError,
};

pub const PlistValue = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    date: f64,
    data: []const u8,
    array: []const PlistValue,
    dict: std.StringHashMapUnmanaged(PlistValue),
};

pub const PlistType = enum { XML, BIN };

pub fn BinOrXML(input: []const u8) !PlistType {
    if (input.len < 8) return error.InvalidHeader;
    if (std.mem.startsWith(u8, input, "bplist00"))
        return .BIN;
    if (std.mem.startsWith(u8, input, "<?xml"))
        return .XML;
    return error.InvalidHeader;
}

/// macOS .app bundle model extracted from Info.plist.
/// All fields are optional — only keys present in the plist are populated.
pub const InfoPlist = struct {
    allocator: std.mem.Allocator,

    name: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    executable: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    bundle_id: ?[]const u8 = null,
    package_type: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    version: ?[]const u8 = null,
    short_version: ?[]const u8 = null,
    min_system_version: ?[]const u8 = null,
    development_region: ?[]const u8 = null,
    info_string: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    category: ?[]const u8 = null,
    principal_class: ?[]const u8 = null,
    main_nib: ?[]const u8 = null,
    main_storyboard: ?[]const u8 = null,
    spoken_name: ?[]const u8 = null,

    high_res_capable: ?bool = null,
    ui_element: ?bool = null,
    background_only: ?bool = null,

    document_types: []const []const u8 = &.{},
    url_schemes: []const []const u8 = &.{},

    pub fn deinit(self: *InfoPlist) void {
        const a = self.allocator;
        inline for (@typeInfo(@TypeOf(self.*)).Struct.fields) |field| {
            if (field.type == ?[]const u8) {
                if (@field(self, field.name)) |s| a.free(s);
            }
        }
        for (self.document_types) |s| a.free(s);
        a.free(self.document_types);
        for (self.url_schemes) |s| a.free(s);
        a.free(self.url_schemes);
    }

    pub fn fromDict(allocator: std.mem.Allocator, dict: std.StringHashMapUnmanaged(PlistValue)) !InfoPlist {
        var out: InfoPlist = .{ .allocator = allocator };

        if (extractString(dict, "CFBundleName")) |s| out.name = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleDisplayName")) |s| out.display_name = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleExecutable")) |s| out.executable = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleIconFile")) |s| out.icon = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleIdentifier")) |s| out.bundle_id = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundlePackageType")) |s| out.package_type = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleSignature")) |s| out.signature = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleVersion")) |s| out.version = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleShortVersionString")) |s| out.short_version = try allocator.dupe(u8, s);
        if (extractString(dict, "LSMinimumSystemVersion")) |s| out.min_system_version = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleDevelopmentRegion")) |s| out.development_region = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleGetInfoString")) |s| out.info_string = try allocator.dupe(u8, s);
        if (extractString(dict, "NSHumanReadableCopyright")) |s| out.copyright = try allocator.dupe(u8, s);
        if (extractString(dict, "LSApplicationCategoryType")) |s| out.category = try allocator.dupe(u8, s);
        if (extractString(dict, "NSPrincipalClass")) |s| out.principal_class = try allocator.dupe(u8, s);
        if (extractString(dict, "NSMainNibFile")) |s| out.main_nib = try allocator.dupe(u8, s);
        if (extractString(dict, "NSMainStoryboardFile")) |s| out.main_storyboard = try allocator.dupe(u8, s);
        if (extractString(dict, "CFBundleSpokenName")) |s| out.spoken_name = try allocator.dupe(u8, s);

        if (extractBool(dict, "NSHighResolutionCapable")) |v| out.high_res_capable = v;
        if (extractBool(dict, "LSUIElement")) |v| out.ui_element = v;
        if (extractBool(dict, "LSBackgroundOnly")) |v| out.background_only = v;

        out.document_types = try extractStringArray(allocator, dict, "CFBundleDocumentTypes");
        out.url_schemes = try extractStringArray(allocator, dict, "CFBundleURLTypes");

        return out;
    }

    fn extractString(dict: std.StringHashMapUnmanaged(PlistValue), key: []const u8) ?[]const u8 {
        const entry = dict.get(key) orelse return null;
        return switch (entry) {
            .string => |s| s,
            else => null,
        };
    }

    fn extractBool(dict: std.StringHashMapUnmanaged(PlistValue), key: []const u8) ?bool {
        const entry = dict.get(key) orelse return null;
        return switch (entry) {
            .boolean => |b| b,
            .integer => |i| if (i == 0) false else true,
            else => null,
        };
    }

    fn extractStringArray(allocator: std.mem.Allocator, dict: std.StringHashMapUnmanaged(PlistValue), key: []const u8) ![]const []const u8 {
        const entry = dict.get(key) orelse return &.{};
        const items = switch (entry) {
            .array => |a| a,
            else => return &.{},
        };
        const result = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            result[i] = switch (item) {
                .string => |s| try allocator.dupe(u8, s),
                else => "",
            };
        }
        return result;
    }
};
