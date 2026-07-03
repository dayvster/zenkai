const std = @import("std");

const V16 = @Vector(16, u8);

pub fn memchrCrOrLf(data: []const u8) ?usize {
    const cr: V16 = @splat(@as(u8, '\r'));
    const lf: V16 = @splat(@as(u8, '\n'));

    var offset: usize = 0;
    while (offset + 16 <= data.len) : (offset += 16) {
        const block: [16]u8 = data[offset..][0..16].*;
        const bytes: V16 = block;
        const matches = (bytes == cr) | (bytes == lf);
        const any = @reduce(.Or, matches);
        if (any) {
            const arr: [16]bool = matches;
            for (arr, 0..) |m, j| {
                if (m) return offset + j;
            }
        }
    }
    return if (offset < data.len) brk: {
        for (data[offset..], 0..) |b, j| {
            if (b == '\r' or b == '\n') break :brk offset + j;
        }
        break :brk null;
    } else null;
}
