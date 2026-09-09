// `annalist import <dir> [--force]`: restore sessions from export bundles.
// Reads manifest.json + blobs/, inserts a new session row (fresh id) with
// the bundle's events remapped onto it, and copies blobs into the project
// store after verifying each blob's content hash matches its filename.
// Hashes are validated as 64 hex chars before touching the filesystem.
// Dedup: a session with the same command + started_at in this project is
// refused unless --force. Imported sessions land on the current branch.

const std = @import("std");
const db = @import("db.zig");
const session = @import("session.zig");
const config = @import("config.zig");
const store = @import("store.zig");
const hash = @import("hash.zig");

/// Cap for a single blob read from a bundle (matches recorder limits x margin).
pub const MAX_BUNDLE_BLOB: usize = 64 * 1024 * 1024;

const ManifestSession = struct {
    id: i64,
    command: []const u8,
    argv_json: std.json.Value,
    cwd: []const u8,
    started_at: i64,
    ended_at: ?i64 = null,
    exit_code: ?i64 = null,
    status: []const u8,
};

const ManifestEvent = struct {
    seq: i64,
    ts: i64,
    type: []const u8,
    path: []const u8,
    prev_path: ?[]const u8 = null,
    prev_hash: ?[]const u8 = null,
    new_hash: ?[]const u8 = null,
    size: i64 = 0,
};

const Manifest = struct {
    format: i64,
    project_id: []const u8,
    session: ManifestSession,
    events: []ManifestEvent,
};

fn validHex(h: []const u8) bool {
    if (h.len != hash.HASH_HEX_LEN) return false;
    for (h) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn runImport(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    dir: []const u8,
    force: bool,
) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    const abs_dir = if (std.fs.path.isAbsolute(dir))
        try allocator.dupe(u8, dir)
    else blk: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, dir });
    };
    defer allocator.free(abs_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ abs_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    const raw = std.fs.cwd().readFileAlloc(allocator, manifest_path, 256 * 1024 * 1024) catch
        return error.BadBundle;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(Manifest, allocator, raw, .{ .allocate = .alloc_always }) catch
        return error.BadBundle;
    defer parsed.deinit();
    const m = parsed.value;
    if (m.format != 1) return error.BadBundle;

    if (!session.validTimestamp(m.session.started_at) or !session.validTimestamp(m.session.ended_at orelse return error.BadBundle) or m.session.ended_at.? < m.session.started_at) return error.BadBundle;
    const status_ok = std.mem.eql(u8, m.session.status, "success") or std.mem.eql(u8, m.session.status, "failed") or std.mem.eql(u8, m.session.status, "interrupted") or std.mem.eql(u8, m.session.status, "signaled");
    if (!status_ok) return error.BadBundle;
    if (m.session.exit_code) |code| {
        if (code < 0 or code > 255) return error.BadBundle;
    }
    var previous_seq: i64 = -1;
    for (m.events) |ev| {
        if (ev.seq <= previous_seq or ev.size < 0 or !session.validTimestamp(ev.ts)) return error.BadBundle;
        previous_seq = ev.seq;
        if (std.mem.startsWith(u8, ev.type, "file_")) {
            if (!@import("safe_fs.zig").validPath(ev.path)) return error.BadBundle;
            if (std.mem.eql(u8, ev.type, "file_renamed")) {
                if (!@import("safe_fs.zig").validPath(ev.prev_path orelse return error.BadBundle)) return error.BadBundle;
            } else {
                if (!std.mem.eql(u8, ev.type, "file_created") and !std.mem.eql(u8, ev.type, "file_modified") and !std.mem.eql(u8, ev.type, "file_deleted")) return error.BadBundle;
                if ((ev.prev_path orelse "").len != 0) return error.BadBundle;
            }
            if (std.mem.eql(u8, ev.type, "file_created") and ev.prev_hash != null) return error.BadBundle;
            if (std.mem.eql(u8, ev.type, "file_deleted") and ev.new_hash != null) return error.BadBundle;
        } else {
            const known = std.mem.eql(u8, ev.type, "session_started") or std.mem.eql(u8, ev.type, "session_ended") or std.mem.eql(u8, ev.type, "process_started") or std.mem.eql(u8, ev.type, "process_exited") or std.mem.eql(u8, ev.type, "error") or std.mem.eql(u8, ev.type, "git_state");
            if (!known or ev.prev_hash != null or ev.new_hash != null) return error.BadBundle;
            if (!std.mem.eql(u8, ev.type, "git_state") and (ev.path.len != 0 or (ev.prev_path orelse "").len != 0)) return error.BadBundle;
        }
    }
    if (m.session.ended_at == null or std.mem.eql(u8, m.session.status, "running")) return error.BadBundle;
    if (m.session.argv_json != .array) return error.BadBundle;
    for (m.session.argv_json.array.items) |arg| if (arg != .string) return error.BadBundle;
    try database.exec("BEGIN IMMEDIATE;");
    errdefer database.exec("ROLLBACK;") catch {};
    try session.ensureProject(database, project_id, project_root);
    // Dedup guard.
    {
        var q = try database.prepare(
            "SELECT id FROM sessions WHERE project_id = ?1 AND command = ?2 AND started_at = ?3;",
        );
        defer q.finalize();
        try q.bindText(1, project_id);
        try q.bindText(2, m.session.command);
        try q.bindInt64(3, m.session.started_at);
        if (try q.step()) {
            if (!force) return error.AlreadyImported;
        }
    }

    // Copy + verify blobs first: refuse before writing any rows on corrupt bundles.
    var referenced = std.StringHashMap(void).init(allocator);
    defer {
        var it = referenced.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        referenced.deinit();
    }
    for (m.events) |ev| {
        if (ev.prev_hash) |h| {
            if (!validHex(h)) return error.BadBundle;
            const gop = try referenced.getOrPut(h);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, h);
        }
        if (ev.new_hash) |h| {
            if (!validHex(h)) return error.BadBundle;
            const gop = try referenced.getOrPut(h);
            if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, h);
        }
    }
    var it = referenced.iterator();
    while (it.next()) |kv| {
        const hex = kv.key_ptr.*;
        const src = try std.fs.path.join(allocator, &.{ abs_dir, "blobs", hex[0..2], hex[2..] });
        defer allocator.free(src);
        const bytes = std.fs.cwd().readFileAlloc(allocator, src, MAX_BUNDLE_BLOB) catch
            return error.BlobMissing;
        defer allocator.free(bytes);
        var digest: [hash.HASH_HEX_LEN]u8 = undefined;
        hash.sha256Hex(bytes, &digest);
        if (!std.ascii.eqlIgnoreCase(&digest, hex)) return error.CorruptBundle;
        const stored = try store.put(allocator, project_root, bytes);
        defer allocator.free(stored);
    }

    // Insert session row on the current branch.
    const branch = try config.readCurrentBranch(allocator, project_root);
    defer allocator.free(branch);
    var argv_aw: std.Io.Writer.Allocating = .init(allocator);
    defer argv_aw.deinit();
    try std.json.Stringify.value(m.session.argv_json, .{}, &argv_aw.writer);
    const argv_text = argv_aw.written();
    var ins = try database.prepare(
        "INSERT INTO sessions(project_id, command, argv_json, cwd, started_at, ended_at, exit_code, status, branch) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);",
    );
    defer ins.finalize();
    try ins.bindText(1, project_id);
    try ins.bindText(2, m.session.command);
    try ins.bindText(3, argv_text);
    try ins.bindText(4, m.session.cwd);
    try ins.bindInt64(5, m.session.started_at);
    if (m.session.ended_at) |e| try ins.bindInt64(6, e) else try ins.bindNull(6);
    if (m.session.exit_code) |c| try ins.bindInt64(7, c) else try ins.bindNull(7);
    try ins.bindText(8, m.session.status);
    try ins.bindText(9, branch);
    _ = try ins.step();
    const new_id = database.lastRowId();

    for (m.events) |ev| {
        var ie = try database.prepare(
            "INSERT INTO events(session_id, seq, ts, type, path, prev_path, prev_hash, new_hash, size) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);",
        );
        defer ie.finalize();
        try ie.bindInt64(1, new_id);
        try ie.bindInt64(2, ev.seq);
        try ie.bindInt64(3, ev.ts);
        try ie.bindText(4, ev.type);
        try ie.bindText(5, ev.path);
        if (ev.prev_path) |p| try ie.bindText(6, p) else try ie.bindText(6, "");
        if (ev.prev_hash) |h| try ie.bindText(7, h) else try ie.bindNull(7);
        if (ev.new_hash) |h| try ie.bindText(8, h) else try ie.bindNull(8);
        try ie.bindInt64(9, ev.size);
        _ = try ie.step();
    }

    try database.exec("COMMIT;");
    const pad = try session.padId(allocator, new_id);
    defer allocator.free(pad);
    try out.print("imported {d} event(s) as session {s} on branch '{s}'\n", .{ m.events.len, pad, branch });
    try out.flush();
}
