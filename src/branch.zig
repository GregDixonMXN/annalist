// `annalist branch`: named workstreams for parallel agent runs.
// `branch` lists branches with session counts (* marks current).
// `branch <name>` switches (names are created on first use).
// Every `run` records the current branch on its session row.
// Names: 1-64 chars of [A-Za-z0-9_.-]; "main" is the default.

const std = @import("std");
const db = @import("db.zig");
const config = @import("config.zig");

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '.' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn runBranch(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    name: ?[]const u8,
) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    if (name) |n| {
        if (!validName(n)) return error.BadBranchName;
        const cur = try config.readCurrentBranch(allocator, project_root);
        defer allocator.free(cur);
        if (std.mem.eql(u8, cur, n)) {
            try out.print("already on '{s}'\n", .{n});
            try out.flush();
            return;
        }
        try config.writeCurrentBranch(allocator, project_root, n);
        try out.print("switched to '{s}'\n", .{n});
        try out.flush();
        return;
    }

    const cur = try config.readCurrentBranch(allocator, project_root);
    defer allocator.free(cur);
    var stmt = try database.prepare(
        "SELECT branch, COUNT(*), MAX(id) FROM sessions WHERE project_id = ?1 GROUP BY branch ORDER BY MAX(id) ASC;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, project_id);
    var saw_current = false;
    while (try stmt.step()) {
        const b = stmt.columnText(0);
        const count = stmt.columnInt64(1);
        if (std.mem.eql(u8, b, cur)) saw_current = true;
        const mark: []const u8 = if (std.mem.eql(u8, b, cur)) "*" else " ";
        try out.print("{s} {s} ({d} session{s})\n", .{ mark, b, count, if (count == 1) @as([]const u8, "") else "s" });
    }
    if (!saw_current) try out.print("* {s} (0 sessions)\n", .{cur});
    try out.flush();
}
