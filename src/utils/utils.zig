const std = @import("std");

/// Calculates the **Damerau-Levenshtein distance** between two strings.
///
/// This is the minimum number of single-character edits (insertions, deletions,
/// substitutions, or **adjacent transpositions**) required to change `s1` into `s2`.
///
/// Features:
/// - Supports adjacent transpositions (e.g. "ab" → "ba" costs 1)
/// - Early exit when distance exceeds `max_distance`
/// - Optimized space usage (only 3 rows)
/// - Uses a small inline buffer (256 usize) to avoid allocations for short strings
///
/// **Time Complexity**: O(m * n)
/// **Space Complexity**: O(min(m, n)) + small constant
///
/// Returns `max_distance` if the real distance is greater than or equal to it.
pub fn demerauLevenshteinDistance(
    allocator: std.mem.Allocator,
    s1: []const u8,
    s2: []const u8,
    max_distance: usize,
) !usize {
    const s1_len = s1.len;
    const s2_len = s2.len;

    // Early returns for trivial cases and impossible distances
    if (s1_len == 0) return @min(s2_len, max_distance);
    if (s2_len == 0) return @min(s1_len, max_distance);

    // Length difference already exceeds max_distance
    const len_diff = if (s1_len > s2_len) s1_len - s2_len else s2_len - s1_len;
    if (len_diff > max_distance) {
        return max_distance;
    }

    const row_len = s2_len + 1;
    const total_needed = row_len * 3;

    var inline_buffer: [256]usize = undefined;
    const buffer = if (total_needed <= inline_buffer.len)
        inline_buffer[0..total_needed]
    else
        try allocator.alloc(usize, total_needed);

    defer if (total_needed > inline_buffer.len) allocator.free(buffer);

    var prev_prev = buffer[0..row_len];
    var prev = buffer[row_len .. row_len * 2];
    var curr = buffer[row_len * 2 .. total_needed];

    @memset(prev_prev, 0);
    for (0..row_len) |j| {
        prev[j] = j;
    }

    for (1..s1_len + 1) |i| {
        curr[0] = i;
        var row_min_distance = curr[0];

        for (1..row_len) |j| {
            const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;

            // Levenshtein standard operations
            var min_val = @min(
                prev[j] + 1, // deletion
                curr[j - 1] + 1, // insertion
                prev[j - 1] + cost, // substitution
            );

            // Damerau transposition check
            if (i > 1 and j > 1 and
                s1[i - 2] == s2[j - 1] and
                s1[i - 1] == s2[j - 2])
            {
                min_val = @min(min_val, prev_prev[j - 2] + 1);
            }

            curr[j] = min_val;

            if (min_val < row_min_distance) {
                row_min_distance = min_val;
            }
        }

        if (row_min_distance > max_distance) {
            return max_distance;
        }

        const temp = prev_prev;
        prev_prev = prev;
        prev = curr;
        curr = temp;
    }

    const distance = prev[s2_len];
    return @min(distance, max_distance);
}

/// Calculates the **Levenshtein distance** (classic edit distance) between two strings.
///
/// This is the minimum number of single-character edits (**insertions, deletions,
/// or substitutions**) required to change `s1` into `s2`. Does **not** count
/// transpositions as a single operation.
///
/// Features:
/// - Early exit when distance exceeds `max_distance`
/// - Optimized space usage (only 2 rows)
/// - Uses a small inline buffer (256 usize) to avoid allocations for short strings
///
/// **Time Complexity**: O(m * n)
/// **Space Complexity**: O(min(m, n)) + small constant
///
/// Returns `max_distance` if the real distance is greater than or equal to it.
pub fn levenshteinDistance(
    allocator: std.mem.Allocator,
    s1: []const u8,
    s2: []const u8,
    max_distance: usize,
) !usize {
    const s1_len = s1.len;
    const s2_len = s2.len;

    if (s1_len == 0) return @min(s2_len, max_distance);
    if (s2_len == 0) return @min(s1_len, max_distance);

    const len_diff = if (s1_len > s2_len) s1_len - s2_len else s2_len - s1_len;
    if (len_diff > max_distance) {
        return max_distance;
    }

    const row_len = s2_len + 1;
    const total_needed = row_len * 2;

    var inline_buffer: [256]usize = undefined;
    const buffer = if (total_needed <= inline_buffer.len)
        inline_buffer[0..total_needed]
    else
        try allocator.alloc(usize, total_needed);

    defer if (total_needed > inline_buffer.len) allocator.free(buffer);

    var prev = buffer[0..row_len];
    var curr = buffer[row_len..total_needed];

    for (0..row_len) |j| {
        prev[j] = j;
    }

    for (1..s1_len + 1) |i| {
        curr[0] = i;
        var row_min_distance = curr[0];

        for (1..row_len) |j| {
            const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;

            const min_val = @min(
                prev[j] + 1, // deletion
                curr[j - 1] + 1, // insertion
                prev[j - 1] + cost, // substitution
            );

            curr[j] = min_val;

            if (min_val < row_min_distance) {
                row_min_distance = min_val;
            }
        }

        // Fast early exit
        if (row_min_distance > max_distance) {
            return max_distance;
        }

        const temp = prev;
        prev = curr;
        curr = temp;
    }

    const distance = prev[s2_len];
    return @min(distance, max_distance);
}

pub fn execute(cmd: []const u8) !void {
    var buf: [1024:0]u8 = undefined;

    if (cmd.len >= buf.len) {
        return error.CommandTooLong;
    }

    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;

    const argv = [_:null]?[*:0]const u8{
        "sh",
        "-c",
        @as([*:0]const u8, @ptrCast(&buf)),
        null,
    };

    const pid = std.os.linux.fork();

    if (pid == 0) {
        _ = std.os.linux.execve("/bin/sh", &argv, environ);
        std.os.linux.exit(1);
    }
}

extern "c" var environ: [*:null]?[*:0]u8;
