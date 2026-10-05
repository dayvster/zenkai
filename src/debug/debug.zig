const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const log = @import("utils").log;

/// Timing gate, set by `-Dbench=true`. Off by default. Entry points are inline
/// and comptime-guarded so a release build drops the call sites entirely.
pub const instrumentation = build_options.bench;

const CLOCK_MONOTONIC: i32 = 1;
const timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, ts: *timespec) callconv(.c) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn monotonicNs() u64 {
    if (comptime builtin.os.tag == .windows) {
        return GetTickCount64() * std.time.ns_per_ms;
    } else {
        var ts: timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
    }
}

// Benchmarking is only ever triggered by the --benchmark-all flag, so the
// marks cost nothing when unused. Gating on build mode meant benchmarks were
// impossible in a release build, which is the only build worth benchmarking.
const bench_enabled = instrumentation;

pub var process_start_ns: u64 = 0;

pub fn elapsedMs() f64 {
    if (process_start_ns == 0) return 0;
    return @as(f64, @floatFromInt(monotonicNs() - process_start_ns)) / std.time.ns_per_ms;
}

const Bench = struct { label: []const u8, ns: u64 };
var bench_entries: [32]Bench = undefined;
var bench_count: usize = 0;

pub inline fn mark(label: []const u8) void {
    if (comptime !bench_enabled) return;
    if (bench_count < bench_entries.len) {
        bench_entries[bench_count] = .{ .label = label, .ns = monotonicNs() };
        bench_count += 1;
    }
}

/// Start a fresh phase, so startup and the deferred rescan can be reported
/// as two separate tables instead of one interleaved mess.
pub inline fn resetBenchmarks() void {
    if (comptime !bench_enabled) return;
    bench_count = 0;
}

pub inline fn printBenchmarks() void {
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

pub const Phase = enum(u8) {
    qt, // Qt: widget build, paint, style, icon engine
    app, // zenkai's own code: parsing, filtering, strings
    os, // syscalls: open/read/stat/getdents/exec, dynamic linking
};

const PhaseEntry = struct { label: []const u8, phase: Phase, ns: u64 };

var phase_entries: [64]PhaseEntry = undefined;
var phase_count: usize = 0;

/// Start a span. Pass the result to `done`, `report`, `accSpan` or `accCount`.
pub inline fn tick() u64 {
    if (comptime !instrumentation) return 0;
    return monotonicNs();
}

pub inline fn done(label: []const u8, p: Phase, t: u64) void {
    if (comptime !instrumentation) return;
    const now = monotonicNs();
    if (now < t) return;
    if (phase_count >= phase_entries.len) return;
    phase_entries[phase_count] = .{ .label = label, .phase = p, .ns = now - t };
    phase_count += 1;
}

/// For spans summed by hand, to avoid two clock reads per iteration.
pub inline fn report(label: []const u8, p: Phase, ns: u64) void {
    if (comptime !instrumentation) return;
    if (phase_count >= phase_entries.len) return;
    phase_entries[phase_count] = .{ .label = label, .phase = p, .ns = ns };
    phase_count += 1;
}

// Same-label calls are summed into one row with a count, so a per-item path
// does not overflow the table.
const Acc = struct { label: []const u8, phase: Phase, ns: u64, n: usize };

var accs: [16]Acc = undefined;
var acc_count: usize = 0;

pub inline fn accSpan(label: []const u8, p: Phase, t: u64) void {
    if (comptime !instrumentation) return;
    const now = monotonicNs();
    if (now < t) return;
    accAddN(label, p, now - t, 1);
}

pub inline fn accCount(label: []const u8, p: Phase, ns: u64, n: usize) void {
    if (comptime !instrumentation) return;
    accAddN(label, p, ns, n);
}

fn accAddN(label: []const u8, p: Phase, ns: u64, n: usize) void {
    if (comptime !instrumentation) return;
    for (accs[0..acc_count]) |*a| {
        if (a.label.ptr == label.ptr) {
            a.ns += ns;
            a.n += n;
            return;
        }
    }
    if (acc_count >= accs.len) return;
    accs[acc_count] = .{ .label = label, .phase = p, .ns = ns, .n = n };
    acc_count += 1;
}

pub inline fn resetAccumulators() void {
    if (comptime !instrumentation) return;
    acc_count = 0;
}

pub fn phaseTotal(p: Phase) u64 {
    if (comptime !instrumentation) return 0;
    var total: u64 = 0;
    for (phase_entries[0..phase_count]) |e| {
        if (e.phase == p) total += e.ns;
    }
    for (accs[0..acc_count]) |a| {
        if (a.phase == p) total += a.ns;
    }
    return total;
}

pub inline fn resetPhases() void {
    if (comptime !instrumentation) return;
    phase_count = 0;
    resetAccumulators();
}

pub inline fn printPhases() void {
    if (comptime !instrumentation) return;
    if (phase_count == 0 and acc_count == 0) return;

    log.info("phases:", .{});
    var last: ?Phase = null;
    for (phase_entries[0..phase_count]) |e| {
        if (last != e.phase) {
            last = e.phase;
            log.info("  [{s}]", .{@tagName(e.phase)});
        }
        log.info("    {s}  {d:.3}ms", .{ e.label, @as(f64, @floatFromInt(e.ns)) / std.time.ns_per_ms });
    }
    for (accs[0..acc_count]) |a| {
        if (last != a.phase) {
            last = a.phase;
            log.info("  [{s}]", .{@tagName(a.phase)});
        }
        log.info("    {s}  {d:.3}ms  (x{d})", .{
            a.label,
            @as(f64, @floatFromInt(a.ns)) / std.time.ns_per_ms,
            a.n,
        });
    }

    inline for (.{ Phase.qt, Phase.app, Phase.os }) |p| {
        log.info("  total {s}  {d:.2}ms", .{
            @tagName(p),
            @as(f64, @floatFromInt(phaseTotal(p))) / std.time.ns_per_ms,
        });
    }
}
