// Line-oriented unified diffs for text files. Simple LCS over lines with a
// cell cap; oversized inputs fall back to a summary line. No AST awareness.

const std = @import("std");

pub const DIFF_CELL_CAP: usize = 4_000_000; // ~2000x2000 lines

pub const Hunk = struct {
    prefix: u8, // ' ', '-', '+'
    line: []const u8, // borrowed from inputs
};

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            try out.append(allocator, text[start..i]);
            start = i + 1;
        }
    }
    if (start < text.len) try out.append(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

/// Compute a unified-style hunk list. Caller frees the slice (lines borrowed).
pub fn diffLines(
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
) ![]Hunk {
    const a = try splitLines(allocator, before);
    defer allocator.free(a);
    const b = try splitLines(allocator, after);
    defer allocator.free(b);

    if (a.len == 0 and b.len == 0) return &.{};
    if (a.len * b.len > DIFF_CELL_CAP) {
        // Too big: emit a pure deletion + insertion summary.
        var out: std.ArrayList(Hunk) = .empty;
        errdefer out.deinit(allocator);
        try out.append(allocator, .{ .prefix = '-', .line = "(large file: before omitted)" });
        try out.append(allocator, .{ .prefix = '+', .line = "(large file: after omitted)" });
        return out.toOwnedSlice(allocator);
    }

    // LCS table of u32 lengths, (a.len+1) x (b.len+1).
    const w = b.len + 1;
    const table = try allocator.alloc(u32, (a.len + 1) * w);
    defer allocator.free(table);
    @memset(table, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (std.mem.eql(u8, a[i], b[j]))
                table[(i + 1) * w + (j + 1)] + 1
            else
                @max(table[(i + 1) * w + j], table[i * w + (j + 1)]);
        }
    }

    var out: std.ArrayList(Hunk) = .empty;
    errdefer out.deinit(allocator);
    var x: usize = 0;
    var y: usize = 0;
    while (x < a.len or y < b.len) {
        if (x < a.len and y < b.len and std.mem.eql(u8, a[x], b[y])) {
            try out.append(allocator, .{ .prefix = ' ', .line = a[x] });
            x += 1;
            y += 1;
        } else if (y < b.len and (x >= a.len or table[(x + 1) * w + y] < table[x * w + (y + 1)])) {
            try out.append(allocator, .{ .prefix = '+', .line = b[y] });
            y += 1;
        } else {
            try out.append(allocator, .{ .prefix = '-', .line = a[x] });
            x += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "basic diff" {
    const hunks = try diffLines(testing.allocator, "a\nb\nc\n", "a\nB\nc\nd\n");
    defer testing.allocator.free(hunks);
    try testing.expectEqual(@as(usize, 5), hunks.len);
    try testing.expect(hunks[0].prefix == ' ');
    try testing.expect(hunks[1].prefix == '-');
    try testing.expect(hunks[2].prefix == '+');
    try testing.expect(hunks[4].prefix == '+');
}

test "empty inputs" {
    const hunks = try diffLines(testing.allocator, "", "");
    defer testing.allocator.free(hunks);
    try testing.expectEqual(@as(usize, 0), hunks.len);
}
