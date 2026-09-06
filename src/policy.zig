// `annalist policy` + `annalist prune`: retention management.
// policy shows [retention] max_age_days (0 = keep forever);
// policy --set-max-age <days> updates it.
// prune [--dry-run] [--older-than <days>] deletes finalized sessions older
// than the cutoff (configured max_age_days, or --older-than override),
// their events, and blobs left unreferenced. Running sessions are never
// pruned. --dry-run reports without writing.

const std = @import("std");
const db = @import("db.zig");
const config = @import("config.zig");

pub const DAY_MS: i64 = 86_400_000;

pub fn runPolicy(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    set_max_age: ?[]const u8,
) !void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    if (set_max_age) |s| {
        const days = std.fmt.parseInt(i64, s, 10) catch return error.BadRetention;
        if (days < 0 or days > 36500) return error.BadRetention;
        try config.writeRetentionDays(allocator, project_root, days);
        if (days == 0) {
            try out.writeAll("retention: keep forever\n");
        } else {
            try out.print("retention: prune sessions older than {d} day(s)\n", .{days});
        }
        try out.flush();
        return;
    }

    const days = try config.readRetentionDays(allocator, project_root);
    if (days == 0) {
        try out.writeAll("retention: keep forever (set with `policy --set-max-age <days>`)\n");
    } else {
        try out.print("retention: prune sessions older than {d} day(s) (`prune --dry-run` to preview)\n", .{days});
    }
    try out.flush();
}

pub fn runPrune(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    older_than: ?[]const u8,
    dry_run: bool,
) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    var days: i64 = try config.readRetentionDays(allocator, project_root);
    if (older_than) |s| {
        days = std.fmt.parseInt(i64, s, 10) catch return error.BadRetention;
        if (days <= 0) return error.BadRetention;
    }
    if (days <= 0) return error.NeedRetention;

    const cutoff = std.time.milliTimestamp() - days * DAY_MS;

    var sel = try database.prepare(
        "SELECT id FROM sessions WHERE project_id = ?1 AND ended_at IS NOT NULL AND ended_at < ?2 ORDER BY id ASC;",
    );
    defer sel.finalize();
    try sel.bindText(1, project_id);
    try sel.bindInt64(2, cutoff);
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(allocator);
    while (try sel.step()) try ids.append(allocator, sel.columnInt64(0));

    var sessions: usize = 0;
    var events: i64 = 0;
    for (ids.items) |sid| {
        var cnt = try database.prepare("SELECT COUNT(*) FROM events WHERE session_id = ?1;");
        defer cnt.finalize();
        try cnt.bindInt64(1, sid);
        if (try cnt.step()) events += cnt.columnInt64(0);
        if (!dry_run) {
            var del_e = try database.prepare("DELETE FROM events WHERE session_id = ?1;");
            defer del_e.finalize();
            try del_e.bindInt64(1, sid);
            _ = try del_e.step();
            var del_s = try database.prepare("DELETE FROM sessions WHERE id = ?1;");
            defer del_s.finalize();
            try del_s.bindInt64(1, sid);
            _ = try del_s.step();
        }
        sessions += 1;
    }

    // Sweep blobs left unreferenced by this project's remaining events.
    var freed_blobs: i64 = 0;
    var freed_bytes: i64 = 0;
    {
        var referenced = std.StringHashMap(void).init(allocator);
        defer {
            var it = referenced.iterator();
            while (it.next()) |kv| allocator.free(kv.key_ptr.*);
            referenced.deinit();
        }
        var q = try database.prepare(
            "SELECT e.prev_hash, e.new_hash FROM events e JOIN sessions s ON s.id = e.session_id WHERE s.project_id = ?1 AND (e.prev_hash IS NOT NULL OR e.new_hash IS NOT NULL);",
        );
        defer q.finalize();
        try q.bindText(1, project_id);
        while (try q.step()) {
            for ([2]c_int{ 0, 1 }) |col| {
                if (!q.columnIsNull(col)) {
                    const gop = try referenced.getOrPut(q.columnText(col));
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try allocator.dupe(u8, q.columnText(col));
                    }
                }
            }
        }
        const objects = try std.fs.path.join(allocator, &.{ project_root, ".annalist", "objects" });
        defer allocator.free(objects);
        if (std.fs.openDirAbsolute(objects, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close();
            const walker = d.walk(allocator) catch null;
            if (walker) |w| {
                var ww = w;
                defer ww.deinit();
                while (ww.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (entry.path.len < 4) continue;
                    const hex = try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.path[0..2], entry.path[3..] });
                    defer allocator.free(hex);
                    if (referenced.contains(hex)) continue;
                    const abs = try std.fs.path.join(allocator, &.{ objects, entry.path });
                    defer allocator.free(abs);
                    const st = std.fs.cwd().statFile(abs) catch continue;
                    if (!dry_run) {
                        std.fs.deleteFileAbsolute(abs) catch continue;
                    }
                    freed_blobs += 1;
                    freed_bytes += @as(i64, @intCast(@min(st.size, std.math.maxInt(i64))));
                }
            }
        } else |_| {}
    }

    try out.print("{s}: {d} session(s), {d} event(s), {d} orphan blob(s) ({d} bytes)\n", .{
        if (dry_run) @as([]const u8, "would prune") else "pruned",
        sessions,
        events,
        freed_blobs,
        freed_bytes,
    });
    try out.flush();
}
