const std = @import("std");
const log = @import("utils").log;

const CLOCK_MONOTONIC: i32 = 1;
const timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, ts: *timespec) callconv(.c) i32;

pub fn monotonicNs() u64 {
    var ts: timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

const bench_enabled = @import("builtin").mode == .Debug;

const Bench = struct { label: []const u8, ns: u64 };
var bench_entries: [32]Bench = undefined;
var bench_count: usize = 0;

pub fn mark(label: []const u8) void {
    if (comptime !bench_enabled) return;
    if (bench_count < bench_entries.len) {
        bench_entries[bench_count] = .{ .label = label, .ns = monotonicNs() };
        bench_count += 1;
    }
}

pub fn printBenchmarks() void {
    if (comptime !bench_enabled) return;
    if (bench_count < 2) return;
    log.info("benchmark:", .{});
    var total: u64 = 0;
    for (1..bench_count) |i| {
        const delta = bench_entries[i].ns - bench_entries[i - 1].ns;
        total += delta;
        const ms = @as(f64, @floatFromInt(delta)) / std.time.ns_per_ms;
        log.info("  {s}  {d:.2}ms", .{ bench_entries[i - 1].label, ms });
    }
    log.info("  total  {d:.2}ms", .{@as(f64, @floatFromInt(total)) / std.time.ns_per_ms});
}
