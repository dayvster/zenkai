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
    // bplist00 are "magic bytes" that binary plists start with
    if (std.mem.startsWith(u8, input, "bplist00"))
        return .BIN;
    // needs to explanation
    if (std.mem.startsWith(u8, input, "<?xml"))
        return .XML;

    return error.InvalidHeader;
}
