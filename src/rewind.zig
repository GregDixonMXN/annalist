// `annalist rewind <session> [seq] [--force]`: restore the working tree
// to a recorded point.
//
// Full rewind (no seq) undoes the whole session: every path the session
// touched returns to its pre-session state (created->deleted, modified or
// deleted->previous content, renamed->moved back). With seq N, paths with
// events at seq <= N go to their state at N; paths only touched later go
// to pre-session state. Paths the session never touched are never touched.
// The rewind itself is NOT recorded as a session.
//
// Safety: without --force, every touched path must still match the
// session-end state (i.e. nobody changed it since). Otherwise rewind
// refuses and lists the divergent paths. Blob bytes missing from the
// object store are a hard error (data loss) even with --force.

const std = @import("std");
const db = @import("db.zig");
const views = @import("views.zig");
const store = @import("store.zig");
const hash = @import("hash.zig");
const scan = @import("scan.zig");
const safe = @import("safe_fs.zig");

pub const MAX_BLOB_READ: usize = 64 * 1024 * 1024;

const PS = struct {
    present: bool,
    hash: ?[]u8 = null, // owned; null = present but unhashable (unrestorable)
};

fn freePs(allocator: std.mem.Allocator, ps: PS) void {
    if (ps.hash) |h| allocator.free(h);
}

fn freeMap(allocator: std.mem.Allocator, m: *std.StringHashMap(PS)) void {
    var it = m.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        freePs(allocator, kv.value_ptr.*);
    }
    m.deinit();
}

fn setState(allocator: std.mem.Allocator, m: *std.StringHashMap(PS), path: []const u8, ps: PS) !void {
    const gop = try m.getOrPut(path);
    if (gop.found_existing) {
        freePs(allocator, gop.value_ptr.*);
        gop.value_ptr.* = ps;
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, path);
        gop.value_ptr.* = ps;
    }
}

fn setOwned(allocator: std.mem.Allocator, m: *std.StringHashMap(PS), path: []const u8, present: bool, h: ?[]const u8) !void {
    try setState(allocator, m, path, .{
        .present = present,
        .hash = if (h) |hh| try allocator.dupe(u8, hh) else null,
    });
}

/// Reject absolute paths and `..` components: rewind must stay in the project.
fn safeRel(path: []const u8) bool {
    return safe.validPath(path);
}
fn hashFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) !?[]u8 {
    const bytes = (safe.read(allocator, root, rel, scan.MAX_FILE_BYTES) catch |err| {
        if (err == error.FileTooBig or err == error.StreamTooLong) return error.TooBig;
        return err;
    }) orelse return null;
    defer allocator.free(bytes);
    var hex: [hash.HASH_HEX_LEN]u8 = undefined;
    hash.sha256Hex(bytes, &hex);
    return try allocator.dupe(u8, &hex);
}

fn statesEqual(a: PS, b_hash: ?[]const u8, b_present: bool) bool {
    if (a.present != b_present) return false;
    if (!a.present) return true;
    if (a.hash == null or b_hash == null) return false;
    return std.mem.eql(u8, a.hash.?, b_hash.?);
}

pub fn runRewind(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    id_text: []const u8,
    seq_text: ?[]const u8,
    force: bool,
    dry_run: bool,
) !void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch return error.BadSessionId;
    try views.assertSession(database, project_id, id);
    var running = try database.prepare("SELECT id FROM sessions WHERE project_id = ?1 AND ended_at IS NULL;");
    defer running.finalize();
    try running.bindText(1, project_id);
    if (try running.step()) return error.UnfinishedSession;
    const full = seq_text == null;
    const max_seq: i64 = if (seq_text) |s|
        std.fmt.parseInt(i64, s, 10) catch return error.BadSeq
    else
        std.math.maxInt(i64);
    if (max_seq <= 0) return error.BadSeq;

    var desired = std.StringHashMap(PS).init(allocator);
    defer freeMap(allocator, &desired);
    var endmap = std.StringHashMap(PS).init(allocator);
    defer freeMap(allocator, &endmap);
    // Pre-session state per path, from each path's first event.
    var premap = std.StringHashMap(PS).init(allocator);
    defer freeMap(allocator, &premap);

    // Single ordered pass: endmap tracks session-end state; premap the
    // pre-session state; desired the state at max_seq (or, for a full
    // rewind, the pre-session state = undo the whole session).
    var stmt = try database.prepare(
        "SELECT type, path, prev_path, prev_hash, new_hash, seq FROM events WHERE session_id = ?1 AND type LIKE 'file_%' ORDER BY seq ASC;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    var file_events: usize = 0;
    while (try stmt.step()) {
        file_events += 1;
        const t = stmt.columnText(0);
        const cur = stmt.columnText(1);
        const prev_path: ?[]const u8 = if (stmt.columnIsNull(2)) null else stmt.columnText(2);
        const prev_hash: ?[]const u8 = if (stmt.columnIsNull(3)) null else stmt.columnText(3);
        const new_hash: ?[]const u8 = if (stmt.columnIsNull(4)) null else stmt.columnText(4);
        const seq = stmt.columnInt64(5);
        const is_rename = std.mem.eql(u8, t, "file_renamed");
        const is_delete = std.mem.eql(u8, t, "file_deleted");

        // Session-end state always advances.
        if (is_rename) {
            if (prev_path) |pp| try setOwned(allocator, &endmap, pp, false, null);
            try setOwned(allocator, &endmap, cur, true, new_hash);
        } else if (is_delete) {
            try setOwned(allocator, &endmap, cur, false, null);
        } else {
            try setOwned(allocator, &endmap, cur, true, new_hash);
        }

        // Pre-session state, recorded once per path.
        if (is_rename) {
            if (prev_path) |pp| {
                if (!premap.contains(pp)) try setOwned(allocator, &premap, pp, true, prev_hash);
            }
            if (!premap.contains(cur)) try setOwned(allocator, &premap, cur, false, null);
        } else if (std.mem.eql(u8, t, "file_created")) {
            if (!premap.contains(cur)) try setOwned(allocator, &premap, cur, false, null);
        } else {
            if (!premap.contains(cur)) try setOwned(allocator, &premap, cur, true, prev_hash);
        }

        // State at max_seq: forward-apply events within range.
        if (!full and seq <= max_seq) {
            if (is_rename) {
                if (prev_path) |pp| try setOwned(allocator, &desired, pp, false, null);
                try setOwned(allocator, &desired, cur, true, new_hash);
            } else if (is_delete) {
                try setOwned(allocator, &desired, cur, false, null);
            } else {
                try setOwned(allocator, &desired, cur, true, new_hash);
            }
        }
    }
    if (file_events == 0) return error.NothingToRewind;

    if (full) {
        // Undo the whole session: target = pre-session state.
        var it = premap.iterator();
        while (it.next()) |kv| {
            const h: ?[]const u8 = if (kv.value_ptr.hash) |hh| hh else null;
            try setOwned(allocator, &desired, kv.key_ptr.*, kv.value_ptr.present, h);
        }
    } else {
        // Paths only touched after N: fall back to pre-session state.
        var it = premap.iterator();
        while (it.next()) |kv| {
            if (desired.contains(kv.key_ptr.*)) continue;
            const h: ?[]const u8 = if (kv.value_ptr.hash) |hh| hh else null;
            try setOwned(allocator, &desired, kv.key_ptr.*, kv.value_ptr.present, h);
        }
    }

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    // Guard: every touched path must match session-end state (or already
    // match the target), unless --force.
    var divergent: usize = 0;
    if (!force) {
        var it = desired.iterator();
        while (it.next()) |kv| {
            const rel = kv.key_ptr.*;
            if (!safeRel(rel)) return error.UnsafePath;
            const end = endmap.get(rel);
            const want = kv.value_ptr.*;
            const cur_hash = hashFile(allocator, project_root, rel) catch |err| {
                if (err == error.TooBig) {
                    divergent += 1;
                    try out.print("  ~ {s} (unreadable for guard)\n", .{rel});
                    continue;
                }
                return err;
            };
            defer if (cur_hash) |h| allocator.free(h);
            const cur_present = cur_hash != null;
            const at_end = if (end) |e| statesEqual(e, cur_hash, cur_present) else !cur_present;
            const at_target = statesEqual(want, cur_hash, cur_present);
            if (!at_end and !at_target) {
                divergent += 1;
                try out.print("  ~ {s} (changed since session end)\n", .{rel});
            }
        }
        if (divergent > 0) {
            try out.print("refusing: {d} path(s) changed since session {d}; re-run with --force\n", .{ divergent, id });
            try out.flush();
            return error.Divergent;
        }
    }

    // Preflight every destination and every required blob before the first write.
    var check = desired.iterator();
    while (check.next()) |kv| {
        if (!safeRel(kv.key_ptr.*)) return error.UnsafePath;
        // Current content is unread here (only freed); oversized files degrade
        // to null instead of aborting — the divergence guard already ran above.
        const current = safe.read(allocator, project_root, kv.key_ptr.*, MAX_BLOB_READ) catch |err| blk: {
            if (err == error.FileTooBig or err == error.StreamTooLong) break :blk null;
            return err;
        };
        defer if (current) |bytes| allocator.free(bytes);
        if (kv.value_ptr.present) {
            const h = kv.value_ptr.hash orelse return error.UnrestorableContent;
            const bytes = try store.get(allocator, project_root, h, MAX_BLOB_READ);
            allocator.free(bytes);
        }
        try out.print("  {s} {s}\n", .{ if (kv.value_ptr.present) @as([]const u8, "restore") else "remove", kv.key_ptr.* });
    }
    if (dry_run) {
        try out.print("Preview only: {d} path(s). No files changed.\n", .{desired.count()});
        try out.flush();
        return;
    }
    // Keep an independent copy of ALL current touched files before applying.
    // A manifest also records absent paths. This survives a partial I/O failure.
    const backup = try std.fmt.allocPrint(allocator, "{s}/.annalist/recovery/{d}-{x}", .{ project_root, std.time.milliTimestamp(), std.crypto.random.int(u64) });
    defer allocator.free(backup);
    try std.fs.cwd().makePath(backup);
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    try manifest.appendSlice(allocator, "[\n");
    var copies = desired.iterator();
    var first = true;
    while (copies.next()) |kv| {
        const current = try safe.read(allocator, project_root, kv.key_ptr.*, MAX_BLOB_READ);
        defer if (current) |bytes| allocator.free(bytes);
        if (current) |bytes| try safe.write(backup, kv.key_ptr.*, bytes);
        const escaped = try db.jsonEscape(allocator, kv.key_ptr.*);
        defer allocator.free(escaped);
        if (!first) try manifest.appendSlice(allocator, ",\n");
        first = false;
        try manifest.writer(allocator).print("{{\"path\":{s},\"present\":{s}}}", .{ escaped, if (current != null) @as([]const u8, "true") else "false" });
    }
    try manifest.appendSlice(allocator, "\n]\n");
    // Keep manifest outside the copied paths to avoid name collisions.
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}.json", .{backup});
    defer allocator.free(manifest_path);
    const mf = try std.fs.createFileAbsolute(manifest_path, .{ .exclusive = true, .mode = 0o600 });
    defer mf.close();
    try mf.writeAll(manifest.items);
    try mf.sync();
    try out.print("Pre-recovery copies: {s}\nManifest: {s}\n", .{ backup, manifest_path });
    try out.flush();
    var apply = desired.iterator();
    while (apply.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (kv.value_ptr.present) {
            const bytes = try store.get(allocator, project_root, kv.value_ptr.hash.?, MAX_BLOB_READ);
            defer allocator.free(bytes);
            try safe.write(project_root, rel, bytes);
        } else {
            var dir = safe.parent(project_root, rel, false) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            defer dir.close();
            dir.deleteFile(std.fs.path.basename(rel)) catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }
    try out.print("Recovered session {d}: {d} path(s). Pre-recovery copies retained.\n", .{ id, desired.count() });
    try out.flush();
}
