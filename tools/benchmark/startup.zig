const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const cwd = Io.Dir.cwd;

const Scenario = struct { name: []const u8, cache: []const u8, args: []const []const u8 };
const scenarios = [_]Scenario{
    .{ .name = "minimal", .cache = "skipped", .args = &.{ "--no-dapps", "--no-plugins", "--no-icons" } },
    .{ .name = "uncached", .cache = "miss", .args = &.{"--no-plugins"} },
    .{ .name = "cached", .cache = "fresh", .args = &.{"--no-plugins"} },
    .{ .name = "cached-no-icons", .cache = "fresh", .args = &.{ "--no-plugins", "--no-icons" } },
    .{ .name = "stale", .cache = "stale", .args = &.{"--no-plugins"} },
    .{ .name = "cached-plugins", .cache = "fresh", .args = &.{} },
    .{ .name = "run", .cache = "skipped", .args = &.{"--run"} },
};
const metrics = [_][]const u8{ "show_return_ms", "first_paint_ms", "data_ready_ms", "ready_paint_ms", "refresh_ms", "parent_observed_ready_ms" };
const work_metrics = [_][]const u8{ "through_first_paint_ms", "through_ready_paint_ms", "through_report_ms" };

fn object(a: Allocator) Value {
    _ = a;
    return .{ .object = .{} };
}
fn array(a: Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}
fn string(text: []const u8) Value {
    return .{ .string = text };
}
fn integer(n: usize) Value {
    return .{ .integer = @intCast(n) };
}
fn put(a: Allocator, value: *Value, key: []const u8, item: Value) !void {
    try value.object.put(a, key, item);
}
fn field(value: Value, key: []const u8) !Value {
    if (value != .object) return error.InvalidReport;
    return value.object.get(key) orelse error.InvalidReport;
}
fn number(value: Value) !f64 {
    const n: f64 = switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => return error.InvalidReport,
    };
    if (!std.math.isFinite(n)) return error.InvalidReport;
    return n;
}
fn equals(value: Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}
fn parse(a: Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, text, .{ .allocate = .alloc_always })).value;
}
fn read(a: Allocator, io: Io, path: []const u8) ![]u8 {
    return cwd().readFileAlloc(io, path, a, .limited(256 * 1024 * 1024));
}
fn save(a: Allocator, io: Io, path: []const u8, value: Value) !void {
    const data = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    defer a.free(data);
    try cwd().writeFile(io, .{ .sub_path = path, .data = data });
}
fn reserve(io: Io, path: []const u8) !void {
    const file = try cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
}
fn hash(a: Allocator, bytes: []const u8) !Value {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return string(try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)));
}

fn distribution(a: Allocator, values: []f64) !Value {
    if (values.len == 0) return error.NoSamples;
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    const median = if (values.len % 2 == 1) values[middle] else (values[middle - 1] + values[middle]) / 2;
    var result = object(a);
    try put(a, &result, "median", .{ .float = median });
    try put(a, &result, "p95", .{ .float = values[(values.len * 95 + 99) / 100 - 1] });
    try put(a, &result, "min", .{ .float = values[0] });
    try put(a, &result, "max", .{ .float = values[values.len - 1] });
    return result;
}

fn summarize(a: Allocator, samples: Value) !Value {
    var result = object(a);
    for (scenarios) |scenario| {
        var rows: std.ArrayList(Value) = .empty;
        defer rows.deinit(a);
        var apps = array(a);
        var plugins = array(a);
        var focused: usize = 0;
        for (samples.array.items) |row| {
            if (!equals(try field(row, "scenario"), scenario.name) or (try field(row, "warmup")).bool) continue;
            try rows.append(a, row);
            for ([_]*Value{ &apps, &plugins }, [_][]const u8{ "apps", "plugins" }) |list, key| {
                const value = try field(row, key);
                var found = false;
                for (list.array.items) |old| {
                    if (old.integer == value.integer) {
                        found = true;
                        break;
                    }
                }
                if (!found) try list.array.append(value);
            }
            if ((try field(row, "input_focused")).bool) focused += 1;
        }
        if (rows.items.len == 0) continue;
        var summary = object(a);
        var measures = object(a);
        for (metrics) |key| {
            const values = try a.alloc(f64, rows.items.len);
            defer a.free(values);
            for (rows.items, values) |row, *value| value.* = try number(try field(row, key));
            try put(a, &measures, key, try distribution(a, values));
        }
        try put(a, &summary, "n", integer(rows.items.len));
        try put(a, &summary, "apps", apps);
        try put(a, &summary, "plugins", plugins);
        try put(a, &summary, "focused_samples", integer(focused));
        try put(a, &summary, "metrics", measures);
        try put(a, &result, scenario.name, summary);
    }
    return result;
}

const Options = struct {
    binary: []const u8 = "",
    output: []const u8 = "benchmark-results/startup.json",
    note: []const u8 = "",
    runs: usize = 20,
    warmups: usize = 3,
    timeout: f64 = 25,
    seed: u64 = 42,
    selected: std.ArrayList(usize) = .empty,
};

fn waitWithDeadline(child: *std.process.Child, io: Io, deadline: Io.Timeout) !std.process.Child.Term {
    const Result = union(enum) { process: std.process.Child.WaitError!std.process.Child.Term, timer: Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.process, std.process.Child.wait, .{ child, io });
    try select.concurrent(.timer, Io.Timeout.sleep, .{ deadline, io });
    switch (try select.await()) {
        .process => |result| return try result,
        .timer => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn runOnce(a: Allocator, io: Io, env: *const std.process.Environ.Map, options: Options, extra: []const []const u8) !Value {
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(a);
    try command.appendSlice(a, &.{ options.binary, "--benchmark-startup", "--theme=dark", "--width=600", "--height=500" });
    try command.appendSlice(a, extra);
    const started = Io.Clock.Timestamp.now(io, .awake);
    const deadline: Io.Timeout = .{ .deadline = started.addDuration(.{ .clock = .awake, .raw = .fromNanoseconds(@intFromFloat(options.timeout * 1e9)) }) };
    var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = env, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .create_no_window = false });
    defer child.kill(io);
    var storage: Io.File.MultiReader.Buffer(2) = undefined;
    var streams: Io.File.MultiReader = undefined;
    streams.init(a, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer streams.deinit();
    var offsets = [_]usize{ 0, 0 };
    var report: ?Value = null;
    var work: ?Value = null;
    var log = array(a);
    while (true) {
        var ended = false;
        streams.fill(4096, deadline) catch |err| switch (err) {
            error.EndOfStream => ended = true,
            else => return err,
        };
        const elapsed: f64 = @as(f64, @floatFromInt(started.untilNow(io).raw.nanoseconds)) / 1e6;
        for (0..2) |stream| {
            const bytes = streams.reader(stream).buffered();
            if (bytes.len > 4 * 1024 * 1024) return error.LogTooLarge;
            while (offsets[stream] < bytes.len) {
                const start = offsets[stream];
                const end = if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |pos| pos else if (ended) bytes.len else break;
                const line = std.mem.trimEnd(u8, bytes[start..end], "\r");
                offsets[stream] = @min(end + 1, bytes.len);
                try log.array.append(string(try a.dupe(u8, line)));
                if (std.mem.startsWith(u8, line, "ZENKAI_WORK ")) work = try parse(a, line[12..]);
                if (std.mem.startsWith(u8, line, "ZENKAI_BENCH ")) {
                    if (report != null) return error.DuplicateReport;
                    report = try parse(a, line[13..]);
                    try put(a, &report.?, "parent_observed_ready_ms", .{ .float = elapsed });
                }
            }
        }
        if (ended) break;
    }
    try streams.checkAnyError();
    const term = try waitWithDeadline(&child, io, deadline);
    if (term != .exited or term.exited != 0 or report == null) return error.BenchmarkFailed;
    var result = report.?;
    if (!equals(try field(result, "status"), "ok") or !equals(try field(result, "build"), "ReleaseFast")) return error.InvalidBuildOrReport;
    if (equals(try field(result, "os"), "windows") and !(try field(result, "windows_transitions_disabled")).bool) return error.TransitionsNotDisabled;
    var cmd = array(a);
    for (command.items) |arg| try cmd.array.append(string(arg));
    try put(a, &result, "command", cmd);
    try put(a, &result, "log", log);
    if (work) |value| try put(a, &result, "work", value);
    return result;
}

fn git(a: Allocator, io: Io, args: []const []const u8) Value {
    const result = std.process.run(a, io, .{ .argv = args, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } } }) catch return .null;
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        a.free(result.stdout);
        return .null;
    }
    return string(std.mem.trimEnd(u8, result.stdout, "\r\n"));
}

fn suite(a: Allocator, io: Io, env: *std.process.Environ.Map, options: Options, payload: *Value) !void {
    // Exclusively created beside the output; only this one cache file is ever deleted.
    const cache_path = try std.fmt.allocPrint(a, "{s}.apps-cache", .{options.output});
    try reserve(io, cache_path);
    defer cwd().deleteFile(io, cache_path) catch {};
    try env.put("ZENKAI_BENCHMARK_CACHE", cache_path);
    try cwd().deleteFile(io, cache_path);
    const seed = try runOnce(a, io, env, options, &.{"--no-plugins"});
    if (try number(try field(seed, "apps")) == 0) return error.NoApplications;
    const seed_bytes = try read(a, io, cache_path);
    try put(a, payload, "cache_seed_apps", try field(seed, "apps"));
    try put(a, payload, "cache_seed_sha256", try hash(a, seed_bytes));
    var random = std.Random.DefaultPrng.init(options.seed);
    const order = try a.dupe(usize, options.selected.items);
    for (0..options.runs + options.warmups) |iteration| {
        random.random().shuffle(usize, order);
        for (order) |index| {
            const scenario = scenarios[index];
            if (std.mem.eql(u8, scenario.cache, "miss")) {
                cwd().deleteFile(io, cache_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            } else if (std.mem.eql(u8, scenario.cache, "fresh") or std.mem.eql(u8, scenario.cache, "stale")) {
                try cwd().writeFile(io, .{ .sub_path = cache_path, .data = seed_bytes });
                const file = try cwd().openFile(io, cache_path, .{ .mode = .read_write });
                defer file.close(io);
                const stamp = Io.Timestamp.now(io, .real).subDuration(.fromSeconds(if (std.mem.eql(u8, scenario.cache, "stale")) 600 else 0));
                try file.setTimestamps(io, .{ .access_timestamp = .{ .new = stamp }, .modify_timestamp = .{ .new = stamp } });
            }
            var report = try runOnce(a, io, env, options, scenario.args);
            if (!equals(try field(report, "cache"), scenario.cache)) return error.UnexpectedCacheState;
            if (!std.mem.eql(u8, scenario.cache, "skipped") and try number(try field(report, "apps")) == 0) return error.NoApplications;
            try put(a, &report, "scenario", string(scenario.name));
            try put(a, &report, "warmup", .{ .bool = iteration < options.warmups });
            try put(a, &report, "iteration", integer(iteration));
            try payload.object.getPtr("samples").?.array.append(report);
            try put(a, payload, "summary", try summarize(a, try field(payload.*, "samples")));
            try save(a, io, options.output, payload.*);
            std.debug.print("{s} {s} {d}: internal {d:.2} ms; parent {d:.2} ms\n", .{ scenario.name, if (iteration < options.warmups) "warmup" else "sample", iteration + 1, try number(try field(report, "ready_paint_ms")), try number(try field(report, "parent_observed_ready_ms")) });
            try Io.sleep(io, .fromMilliseconds(150), .awake);
        }
    }
}

fn summarizeWork(a: Allocator, io: Io, path: []const u8) !void {
    const data = try parse(a, try read(a, io, path));
    if (data.object.contains("failure")) return error.IncompleteRun;
    const runs = try number(try field(try field(data, "metadata"), "runs"));
    var summary = object(a);
    for (scenarios) |scenario| {
        var rows: std.ArrayList(Value) = .empty;
        for ((try field(data, "samples")).array.items) |row| {
            if ((try field(row, "warmup")).bool or !equals(try field(row, "scenario"), scenario.name)) continue;
            const work = try field(row, "work");
            var sum: f64 = 0;
            for ((try field(work, "phases_ms")).object.values()) |value| sum += try number(value);
            const first = try number(try field(work, work_metrics[0]));
            const ready = try number(try field(work, work_metrics[1]));
            const total = try number(try field(work, work_metrics[2]));
            if (@abs(sum - total) > 0.00002 or first > ready or ready > total) return error.InvalidWorkTotals;
            try rows.append(a, work);
        }
        if (rows.items.len == 0) continue;
        if (@as(f64, @floatFromInt(rows.items.len)) != runs) return error.IncompleteScenario;
        var item = object(a);
        try put(a, &item, "n", integer(rows.items.len));
        const values = try a.alloc(f64, rows.items.len);
        for (work_metrics) |key| {
            for (rows.items, values) |row, *value| value.* = try number(try field(row, key));
            try put(a, &item, key, try distribution(a, values));
        }
        var phases = object(a);
        for ((try field(rows.items[0], "phases_ms")).object.keys()) |key| {
            for (rows.items, values) |row, *value| value.* = try number(try field(try field(row, "phases_ms"), key));
            try put(a, &phases, key, try distribution(a, values));
        }
        try put(a, &item, "phases_ms", phases);
        try put(a, &summary, scenario.name, item);
    }
    var output = object(a);
    try put(a, &output, "source", string(path));
    try put(a, &output, "definition", string("Direct disjoint wall-clock scopes, not CPU time. Includes allocation/filesystem work and discovery APIs. Excludes Qt calls, loader, event-loop waits, UI construction, layout and painting. Phase totals run through report; snapshots contain work completed by each paint. Not an exhaustive attribution or a replacement for launch latency."));
    try put(a, &output, "summary", summary);
    const output_path = try std.fmt.allocPrint(a, "{s}.work-summary.json", .{std.mem.trimEnd(u8, path[0 .. path.len - std.fs.path.extension(path).len], ".")});
    try reserve(io, output_path);
    try save(a, io, output_path, output);
    std.debug.print("Saved {s}\n", .{output_path});
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--summarize-work")) return summarizeWork(a, io, args[2]);
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = args[i];
        if (std.mem.eql(u8, key, "--help")) {
            std.debug.print("zig run tools/benchmark/startup.zig -- --binary PATH [--runs 20] [--warmups 3] [--scenario NAME] [--output FILE] [--timeout 25] [--seed 42] [--note TEXT]\nzig run tools/benchmark/startup.zig -- --summarize-work RESULTS.json\n", .{});
            return;
        }
        if (i + 1 == args.len) return error.MissingOptionValue;
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--binary")) options.binary = value else if (std.mem.eql(u8, key, "--output")) options.output = value else if (std.mem.eql(u8, key, "--note")) options.note = value else if (std.mem.eql(u8, key, "--runs")) options.runs = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--warmups")) options.warmups = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--seed")) options.seed = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, key, "--timeout")) options.timeout = try std.fmt.parseFloat(f64, value) else if (std.mem.eql(u8, key, "--scenario")) {
            const index = for (scenarios, 0..) |scenario, index| {
                if (std.mem.eql(u8, scenario.name, value)) break index;
            } else return error.UnknownScenario;
            if (index == scenarios.len - 1 and builtin.os.tag != .windows) return error.RunModeWindowsOnly;
            if (std.mem.indexOfScalar(usize, options.selected.items, index) == null) try options.selected.append(a, index);
        } else return error.UnknownOption;
    }
    if (options.binary.len == 0 or options.runs == 0 or options.runs > 10000 or options.warmups > 10000 or !std.math.isFinite(options.timeout) or options.timeout <= 0 or options.timeout > 3600) return error.InvalidOptions;
    options.binary = try cwd().realPathFileAlloc(io, options.binary, a);
    if (options.selected.items.len == 0) for (scenarios, 0..) |_, index| {
        if (index != scenarios.len - 1 or builtin.os.tag == .windows) try options.selected.append(a, index);
    };
    if (std.fs.path.dirname(options.output)) |dir| try cwd().createDirPath(io, dir);
    try reserve(io, options.output);
    const patch_path = try std.fmt.allocPrint(a, "{s}.patch", .{options.output[0 .. options.output.len - std.fs.path.extension(options.output).len]});
    try reserve(io, patch_path);
    const patch = git(a, io, &.{ "git", "diff", "HEAD" });
    try cwd().writeFile(io, .{ .sub_path = patch_path, .data = if (patch == .string) patch.string else "" });
    var metadata = object(a);
    try put(a, &metadata, "created_unix_ms", .{ .integer = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, 1000000)) });
    try put(a, &metadata, "platform", string(@tagName(builtin.os.tag)));
    try put(a, &metadata, "machine", string(@tagName(builtin.cpu.arch)));
    try put(a, &metadata, "zig", string(builtin.zig_version_string));
    try put(a, &metadata, "binary", string(options.binary));
    try put(a, &metadata, "binary_sha256", try hash(a, try read(a, io, options.binary)));
    try put(a, &metadata, "git_head", git(a, io, &.{ "git", "rev-parse", "HEAD" }));
    try put(a, &metadata, "git_status", git(a, io, &.{ "git", "status", "--short" }));
    try put(a, &metadata, "runs", integer(options.runs));
    try put(a, &metadata, "warmups", integer(options.warmups));
    try put(a, &metadata, "seed", string(try std.fmt.allocPrint(a, "{d}", .{options.seed})));
    try put(a, &metadata, "note", string(options.note));
    var display = object(a);
    for ([_][]const u8{ "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "QT_QPA_PLATFORM", "WAYLAND_DISPLAY", "DISPLAY" }) |key| try put(a, &display, key, if (init.environ_map.get(key)) |value| string(value) else .null);
    try put(a, &metadata, "display", display);
    try put(a, &metadata, "definition", string("Internal timestamps start at main entry and end after viewport paint dispatch, not compositor presentation. Parent time ends on receipt of the complete ready report line and includes spawn, loader, pipes and reader scheduling. Uncached means no Zenkai app cache, not OS-cold. Dark theme; 600x500 except Run mode; application animations disabled; compositor settings unchanged."));
    var sources = object(a);
    try put(a, &sources, "tools/benchmark/startup.zig", string(@embedFile("startup.zig")));
    try put(a, &sources, "src/debug/startup_benchmark.zig", string(try read(a, io, "src/debug/startup_benchmark.zig")));
    try put(a, &metadata, "benchmark_sources", sources);
    var payload = object(a);
    try put(a, &payload, "metadata", metadata);
    try put(a, &payload, "samples", array(a));
    try put(a, &payload, "summary", object(a));
    try save(a, io, options.output, payload);
    var env = try init.environ_map.clone(a);
    suite(a, io, &env, options, &payload) catch |err| {
        try put(a, &payload, "failure", string(@errorName(err)));
        try save(a, io, options.output, payload);
        return err;
    };
    std.debug.print("Saved {s}\n", .{options.output});
}

test "nearest-rank p95 keeps the tail and median averages the middle pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var values = [_]f64{ 20, 10 };
    const result = try distribution(arena.allocator(), &values);
    try std.testing.expectEqual(@as(f64, 15), try number(try field(result, "median")));
    try std.testing.expectEqual(@as(f64, 20), try number(try field(result, "p95")));
    var twenty: [20]f64 = undefined;
    for (&twenty, 1..) |*v, index| v.* = @floatFromInt(index);
    try std.testing.expectEqual(@as(f64, 19), try number(try field(try distribution(arena.allocator(), &twenty), "p95")));
}

test "warmups are excluded and scenarios remain separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var samples = array(a);
    for ([_]f64{ 1000, 10, 20, 200 }, 0..) |value, i| {
        var row = object(a);
        try put(a, &row, "scenario", string(if (i == 3) "uncached" else "cached"));
        try put(a, &row, "warmup", .{ .bool = i == 0 });
        try put(a, &row, "input_focused", .{ .bool = true });
        try put(a, &row, "apps", integer(121));
        try put(a, &row, "plugins", integer(0));
        for (metrics) |key| try put(a, &row, key, .{ .float = value });
        try samples.array.append(row);
    }
    const result = try summarize(a, samples);
    const cached = try field(result, "cached");
    try std.testing.expectEqual(@as(f64, 2), try number(try field(cached, "n")));
    try std.testing.expectEqual(@as(f64, 2), try number(try field(cached, "focused_samples")));
    try std.testing.expectEqual(@as(f64, 15), try number(try field(try field(try field(cached, "metrics"), "ready_paint_ms"), "median")));
    try std.testing.expectEqual(@as(f64, 1), try number(try field(try field(result, "uncached"), "n")));
}
