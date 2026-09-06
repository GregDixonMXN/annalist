// `annalist doctor`: health checks + repair for the local installation.
// - stale "running" sessions (supervisor died without finalizing)
// - SQLite integrity_check
// - events referencing missing blobs (data loss warning)
// - orphan blobs (with --gc to collect them)
// Exit 0 when healthy (or fully repaired with --fix/--gc), 1 when problems remain.

const std = @import("std");
const db = @import("db.zig");

pub const Report = struct {
    stale_sessions: i64 = 0,
    integrity_ok: bool = false,
    missing_blobs: i64 = 0,
    orphan_blobs: i64 = 0,
    orphan_bytes: i64 = 0,
    collected: i64 = 0,
};

pub fn runDoctor(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    fix: bool,
    gc: bool,
) !Report {
    var rep = Report{};
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    // 1. Integrity.
    {
        var stmt = try database.prepare("PRAGMA integrity_check;");
        defer stmt.finalize();
        if (try stmt.step()) {
            rep.integrity_ok = std.mem.eql(u8, stmt.columnText(0), "ok");
        }
        try out.print("database integrity: {s}\n", .{if (rep.integrity_ok) "ok" else "CORRUPT"});
    }

    // 2. Stale running sessions (this project only).
    {
        var stmt = try database.prepare(
            "SELECT id, command, started_at FROM sessions WHERE project_id = ?1 AND (status = 'running' OR ended_at IS NULL) ORDER BY id ASC;",
        );
        defer stmt.finalize();
        try stmt.bindText(1, project_id);
        while (try stmt.step()) {
            rep.stale_sessions += 1;
            const id = stmt.columnInt64(0);
            const cmd = stmt.columnText(1);
            const started = stmt.columnInt64(2);
            try out.print("stale session {d} ({s}, started {d})\n", .{ id, cmd, started });
            if (fix) {
                var upd = try database.prepare(
                    "UPDATE sessions SET ended_at = ?1, status = 'interrupted' WHERE id = ?2;",
                );
                defer upd.finalize();
                try upd.bindInt64(1, std.time.milliTimestamp());
                try upd.bindInt64(2, id);
                _ = try upd.step();
                try out.print("  -> marked interrupted\n", .{});
            }
        }
        if (rep.stale_sessions == 0) try out.writeAll("no stale sessions\n");
        if (rep.stale_sessions > 0 and !fix)
            try out.writeAll("re-run with --fix to mark them interrupted\n");
    }

    // 3 + 4. Blob references vs store.
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
            if (!q.columnIsNull(0)) {
                const existing = try referenced.getOrPut(q.columnText(0));
                if (!existing.found_existing) {
                    existing.key_ptr.* = try allocator.dupe(u8, q.columnText(0));
                }
            }
            if (!q.columnIsNull(1)) {
                const existing = try referenced.getOrPut(q.columnText(1));
                if (!existing.found_existing) {
                    existing.key_ptr.* = try allocator.dupe(u8, q.columnText(1));
                }
            }
        }

        // Missing blobs: referenced but absent.
        {
            var it = referenced.iterator();
            while (it.next()) |kv| {
                if (!blobExists(project_root, kv.key_ptr.*)) rep.missing_blobs += 1;
            }
            try out.print("referenced blobs missing from store: {d}\n", .{rep.missing_blobs});
        }

        // Orphan blobs: present but unreferenced.
        const objects = try std.fs.path.join(allocator, &.{ project_root, ".annalist", "objects" });
        defer allocator.free(objects);
        var total_orphans: i64 = 0;
        var total_bytes: i64 = 0;
        var collected: i64 = 0;
        if (std.fs.openDirAbsolute(objects, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close();
            const walker = d.walk(allocator) catch null;
            if (walker) |w| {
                var ww = w;
                defer ww.deinit();
                while (ww.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    // entry.path looks like "ab/cdef..."; rebuild hex.
                    if (entry.path.len < 4) continue;
                    const hex = std.fmt.allocPrint(allocator, "{s}{s}", .{
                        entry.path[0..2],
                        entry.path[3..],
                    }) catch continue;
                    defer allocator.free(hex);
                    if (referenced.get(hex) != null) continue;
                    const abs = std.fs.path.join(allocator, &.{ objects, entry.path }) catch continue;
                    defer allocator.free(abs);
                    const st = std.fs.cwd().statFile(abs) catch continue;
                    total_orphans += 1;
                    total_bytes += @as(i64, @intCast(@min(st.size, std.math.maxInt(i64))));
                    if (gc) {
                        std.fs.deleteFileAbsolute(abs) catch continue;
                        collected += 1;
                    }
                }
            }
        } else |_| {
            try out.writeAll("no object store yet\n");
        }
        rep.orphan_blobs = total_orphans;
        rep.orphan_bytes = total_bytes;
        rep.collected = collected;
        try out.print("orphan blobs: {d} ({d} bytes){s}\n", .{
            total_orphans,
            total_bytes,
            if (gc) " — collected" else "",
        });
        if (total_orphans > 0 and !gc)
            try out.writeAll("re-run with --gc to collect them\n");
    }

    try out.flush();
    return rep;
}

fn blobExists(project_root: []const u8, hex: []const u8) bool {
    if (hex.len != 64) return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/.annalist/objects/{s}/{s}",
        .{ project_root, hex[0..2], hex[2..] },
    ) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
