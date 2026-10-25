const std = @import("std");

pub const Object = ?*anyopaque;
const Selector = *anyopaque;
extern "objc" fn objc_getClass(name: [*:0]const u8) Object;
extern "objc" fn sel_registerName(name: [*:0]const u8) Selector;
extern "objc" fn objc_msgSend() void;

pub fn class(name: [*:0]const u8) Object {
    return objc_getClass(name);
}

/// All messages here return scalars or pointers, so no structure-return ABI is needed.
pub fn send(comptime Return: type, receiver: Object, name: [*:0]const u8, args: anytype) Return {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const Function = switch (fields.len) {
        0 => fn (Object, Selector) callconv(.c) Return,
        1 => fn (Object, Selector, fields[0].type) callconv(.c) Return,
        else => @compileError("Unsupported Objective-C message arity"),
    };
    const function: *const Function = @ptrCast(&objc_msgSend);
    return @call(.auto, function, .{ receiver, sel_registerName(name) } ++ args);
}

pub fn pool() Object {
    return send(Object, send(Object, class("NSAutoreleasePool"), "alloc", .{}), "init", .{});
}

pub fn string(object: Object) []const u8 {
    const raw = send(?[*:0]const u8, object, "UTF8String", .{}) orelse return "";
    return std.mem.sliceTo(raw, 0);
}

pub fn browserPath(allocator: std.mem.Allocator, scheme: []const u8) ![]u8 {
    const scope = pool();
    defer send(void, scope, "drain", .{});
    const text = try std.fmt.allocPrintSentinel(allocator, "{s}://example.com", .{scheme}, 0);
    defer allocator.free(text);
    const ns_string = send(Object, class("NSString"), "stringWithUTF8String:", .{text.ptr});
    const url = send(Object, class("NSURL"), "URLWithString:", .{ns_string});
    const workspace = send(Object, class("NSWorkspace"), "sharedWorkspace", .{});
    const application = send(Object, workspace, "URLForApplicationToOpenURL:", .{url});
    const path = string(send(Object, application, "path", .{}));
    if (path.len == 0) return error.NoAssociation;
    return allocator.dupe(u8, path);
}

pub const Ref = *const anyopaque;
pub extern "CoreFoundation" fn CFRelease(value: Ref) void;
pub extern "CoreFoundation" fn CFRetain(value: Ref) Ref;
pub extern "CoreFoundation" fn CFGetTypeID(value: Ref) usize;
pub extern "CoreFoundation" fn CFArrayGetTypeID() usize;
pub extern "CoreFoundation" fn CFArrayGetCount(array: Ref) isize;
pub extern "CoreFoundation" fn CFArrayGetValueAtIndex(array: Ref, index: isize) ?Ref;
pub extern "CoreFoundation" fn CFStringGetTypeID() usize;
extern "CoreFoundation" fn CFStringCreateWithCString(allocator: ?Ref, text: [*:0]const u8, encoding: u32) ?Ref;
extern "CoreFoundation" fn CFStringGetLength(text: Ref) isize;
extern "CoreFoundation" fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) isize;
extern "CoreFoundation" fn CFStringGetCString(text: Ref, buffer: [*]u8, size: isize, encoding: u32) u8;
pub extern "CoreFoundation" const kCFBooleanFalse: Ref;
pub extern "ApplicationServices" fn AXIsProcessTrusted() bool;
pub extern "ApplicationServices" fn AXUIElementCreateApplication(pid: i32) ?Ref;
pub extern "ApplicationServices" fn AXUIElementSetMessagingTimeout(element: Ref, seconds: f32) i32;
extern "ApplicationServices" fn AXUIElementCopyAttributeValue(element: Ref, attribute: Ref, value: *?Ref) i32;
extern "ApplicationServices" fn AXUIElementSetAttributeValue(element: Ref, attribute: Ref, value: Ref) i32;
extern "ApplicationServices" fn AXUIElementPerformAction(element: Ref, action: Ref) i32;
pub extern "ApplicationServices" fn AXUIElementGetPid(element: Ref, pid: *i32) i32;

fn cfString(text: [*:0]const u8) !Ref {
    return CFStringCreateWithCString(null, text, 0x08000100) orelse error.OutOfMemory;
}

pub fn attribute(element: Ref, name: [*:0]const u8) !Ref {
    const key = try cfString(name);
    defer CFRelease(key);
    var result: ?Ref = null;
    if (AXUIElementCopyAttributeValue(element, key, &result) != 0) return error.AttributeUnavailable;
    return result orelse error.AttributeUnavailable;
}

pub fn setAttribute(element: Ref, name: [*:0]const u8, value: Ref) !void {
    const key = try cfString(name);
    defer CFRelease(key);
    if (AXUIElementSetAttributeValue(element, key, value) != 0) return error.FocusFailed;
}

pub fn raise(element: Ref) !void {
    const action = try cfString("AXRaise");
    defer CFRelease(action);
    if (AXUIElementPerformAction(element, action) != 0) return error.FocusFailed;
}

pub fn copyString(allocator: std.mem.Allocator, value: Ref) ![]u8 {
    if (CFGetTypeID(value) != CFStringGetTypeID()) return error.InvalidResponse;
    const maximum = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), 0x08000100);
    if (maximum < 0 or maximum > 1024 * 1024) return error.ResponseTooLarge;
    const buffer = try allocator.alloc(u8, @intCast(maximum + 1));
    defer allocator.free(buffer);
    if (CFStringGetCString(value, buffer.ptr, @intCast(buffer.len), 0x08000100) == 0) return error.InvalidResponse;
    return allocator.dupe(u8, std.mem.sliceTo(buffer, 0));
}
