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

/// Remove empty parent dirs of an absolute file path, stopping at root.
// Stops at the first non-empty dir; never touches root itself.
fn pruneEmptyParents(root: []const u8, abs_file: []const u8) void {
    var dir_opt = std.fs.path.dirname(abs_file);
    while (dir_opt) |dir| {
        if (dir.len <= root.len) break;
        if (!std.mem.startsWith(u8, dir, root)) break;
        std.fs.deleteDirAbsolute(dir) catch break;
        dir_opt = std.fs.path.dirname(dir);
    }
}

/// Reject absolute paths and `..` components: rewind must stay in the project.
fn safeRel(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Hash a file relative to root. Returns null when absent; error.TooBig when
/// over the scan cap (treated as unknown by the caller).
fn hashFile(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) !?[]u8 {
    const abs = try std.fs.path.join(allocator, &.{ root, rel });
    defer allocator.free(abs);
    const f = std.fs.openFileAbsolute(abs, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer f.close();
    const st = try f.stat();
    if (st.size > scan.MAX_FILE_BYTES) return error.TooBig;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = try allocator.alloc(u8, hash.HASH_HEX_LEN);
    const digits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = digits[b >> 4];
        hex[i * 2 + 1] = digits[b & 0xf];
    }
    return hex;
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
) !void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch return error.BadSessionId;
    try views.assertSession(database, project_id, id);
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

    // Apply.
    var restored: usize = 0;
    var deleted: usize = 0;
    var skipped: usize = 0;
    var it = desired.iterator();
    while (it.next()) |kv| {
        const rel = kv.key_ptr.*;
        if (!safeRel(rel)) return error.UnsafePath;
        const want = kv.value_ptr.*;
        if (!want.present) {
            const abs = try std.fs.path.join(allocator, &.{ project_root, rel });
            defer allocator.free(abs);
            const existed = blk: {
                std.fs.accessAbsolute(abs, .{}) catch break :blk false;
                break :blk true;
            };
            if (existed) {
                std.fs.deleteFileAbsolute(abs) catch |err| {
                    if (err != error.FileNotFound) return err;
                };
                pruneEmptyParents(project_root, abs);
                deleted += 1;
                try out.print("  - {s}\n", .{rel});
            } else {
                skipped += 1;
                try out.print("  = {s} (already absent)\n", .{rel});
            }
        } else if (want.hash) |h| {
            const cur_hash: ?[]u8 = hashFile(allocator, project_root, rel) catch |err| blk: {
                if (err == error.TooBig) break :blk null;
                return err;
            };
            defer if (cur_hash) |ch| allocator.free(ch);
            if (cur_hash) |ch| {
                if (std.mem.eql(u8, ch, h)) {
                    skipped += 1;
                    try out.print("  = {s} (unchanged)\n", .{rel});
                    continue;
                }
            }
            const bytes = store.get(allocator, project_root, h, MAX_BLOB_READ) catch |err| {
                if (err == error.FileNotFound) {
                    try out.print("  ! {s} (blob {s} missing from store)\n", .{ rel, h });
                    return error.BlobMissing;
                }
                return err;
            };
            defer allocator.free(bytes);
            const abs = try std.fs.path.join(allocator, &.{ project_root, rel });
            defer allocator.free(abs);
            if (std.fs.path.dirname(abs)) |dir| {
                std.fs.cwd().makePath(dir) catch {};
            }
            const f = try std.fs.createFileAbsolute(abs, .{});
            defer f.close();
            try f.writeAll(bytes);
            restored += 1;
            try out.print("  + {s}\n", .{rel});
        } else {
            skipped += 1;
            try out.print("  ? {s} (content never stored, left as-is)\n", .{rel});
        }
    }
    try out.print("rewind session {d}: {d} restored, {d} deleted, {d} skipped\n", .{ id, restored, deleted, skipped });
    try out.flush();
}
