// Event model: versioned, append-only rows. Everything observed becomes an event.
// Schema v1 event types: session_started/ended, process_started/exited,
// file_created/modified/deleted/renamed, snapshot_created, git_state, error.

const std = @import("std");
const db = @import("db.zig");
const hash = @import("hash.zig");

pub const SCHEMA_VERSION: u32 = 1;

pub const QueuedEvent = struct {
    ts: i64,
    type: []const u8, // static strings only
    path: []const u8, // owned iff path_owned
    path_owned: bool,
    prev_path: []const u8 = "",
    prev_path_owned: bool = false,
    prev_hash: ?[hash.HASH_HEX_LEN]u8,
    new_hash: ?[hash.HASH_HEX_LEN]u8,
    size: i64,

    pub fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        if (self.path_owned) allocator.free(self.path);
        if (self.prev_path_owned) allocator.free(self.prev_path);
    }
};

pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList(QueuedEvent) = .empty,

    pub fn push(self: *Queue, allocator: std.mem.Allocator, ev: QueuedEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, ev);
    }

    /// Drain all items into a caller-owned slice (queue left empty, always freeable).
    pub fn drain(self: *Queue, allocator: std.mem.Allocator) ![]QueuedEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.dupe(QueuedEvent, self.items.items);
        self.items.clearRetainingCapacity();
        return out;
    }
};

pub fn insert(
    database: *db.Db,
    session_id: i64,
    seq: *i64,
    ev: *const QueuedEvent,
) !void {
    var stmt = try database.prepare(
        "INSERT INTO events(session_id, seq, ts, type, path, prev_path, prev_hash, new_hash, size) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    try stmt.bindInt64(2, seq.*);
    seq.* += 1;
    try stmt.bindInt64(3, ev.ts);
    try stmt.bindText(4, ev.type);
    try stmt.bindText(5, ev.path);
    try stmt.bindText(6, ev.prev_path);
    if (ev.prev_hash) |h| try stmt.bindText(7, &h) else try stmt.bindNull(7);
    if (ev.new_hash) |h| try stmt.bindText(8, &h) else try stmt.bindNull(8);
    try stmt.bindInt64(9, ev.size);
    _ = try stmt.step();
}

pub const Counts = struct {
    created: i64 = 0,
    modified: i64 = 0,
    deleted: i64 = 0,
    renamed: i64 = 0,
    total: i64 = 0,

    pub fn changed(self: Counts) i64 {
        return self.created + self.modified + self.deleted + self.renamed;
    }
};

pub fn countFileEvents(database: *db.Db, session_id: i64) !Counts {
    var c = Counts{};
    var stmt = try database.prepare(
        "SELECT type, COUNT(*) FROM events WHERE session_id = ?1 AND type LIKE 'file_%' GROUP BY type;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    while (try stmt.step()) {
        const t = stmt.columnText(0);
        const n = stmt.columnInt64(1);
        c.total += n;
        if (std.mem.eql(u8, t, "file_created")) c.created = n;
        if (std.mem.eql(u8, t, "file_modified")) c.modified = n;
        if (std.mem.eql(u8, t, "file_deleted")) c.deleted = n;
        if (std.mem.eql(u8, t, "file_renamed")) c.renamed = n;
    }
    return c;
}

pub fn countAll(database: *db.Db, session_id: i64) !i64 {
    var stmt = try database.prepare("SELECT COUNT(*) FROM events WHERE session_id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    if (try stmt.step()) return stmt.columnInt64(0);
    return 0;
}

const testing = std.testing;

test "queue push/drain" {
    const allocator = testing.allocator;
    var q = Queue{};
    try q.push(allocator, .{
        .ts = 1,
        .type = "file_created",
        .path = "a.txt",
        .path_owned = false,
        .prev_hash = null,
        .new_hash = null,
        .size = 5,
    });
    const items = try q.drain(allocator);
    defer allocator.free(items);
    try testing.expectEqual(@as(usize, 1), items.len);
    const empty = try q.drain(allocator);
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
