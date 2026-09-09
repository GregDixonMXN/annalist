// Filesystem recorder: baseline scan, periodic re-scan, diff, blob seeding.
// The poller thread writes blobs and queues events; the main thread owns the DB.
// Rename detection pairs a deleted path with a created path sharing one hash.

const std = @import("std");
const scan = @import("scan.zig");
const store = @import("store.zig");
const events = @import("events.zig");
const hash = @import("hash.zig");
const log = @import("log.zig");

pub const POLL_INTERVAL_NS: u64 = 2 * std.time.ns_per_s;

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8, // borrowed
    patterns: []const []const u8, // borrowed
    baseline: scan.Scan,
    queue: *events.Queue,
    stop: std.atomic.Value(bool),
    thread: ?std.Thread = null,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        project_root: []const u8,
        patterns: []const []const u8,
        queue: *events.Queue,
    ) !Recorder {
        var baseline = try scan.scanDir(allocator, project_root, patterns);
        errdefer baseline.deinit();
        // Seed the blob store so every before-state is reconstructible.
        try seedBlobs(allocator, project_root, &baseline);
        return .{
            .allocator = allocator,
            .project_root = project_root,
            .patterns = patterns,
            .baseline = baseline,
            .queue = queue,
            .stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.baseline.deinit();
    }

    pub fn startPolling(self: *Recorder) !void {
        self.thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    pub fn stopPolling(self: *Recorder) void {
        self.stop.store(true, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// One synchronous re-scan + diff, used by the poller and the final pass.
    pub fn rescan(self: *Recorder) !void {
        var next = try scan.scanDir(self.allocator, self.project_root, self.patterns);
        errdefer next.deinit();
        try self.diffInto(&next);
        // Adopt the new baseline (errdefer disarmed on success).
        self.baseline.deinit();
        self.baseline = next;
    }

    fn pollLoop(self: *Recorder) void {
        while (!self.stop.load(.seq_cst)) {
            std.Thread.sleep(POLL_INTERVAL_NS);
            if (self.stop.load(.seq_cst)) break;
            self.rescan() catch |err| {
                self.failed.store(true, .seq_cst);
                log.warn("rescan failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn seedBlobs(allocator: std.mem.Allocator, project_root: []const u8, base: *scan.Scan) !void {
        var it = base.map.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            if (entry.kind != .file) {
                entry.hashed = false;
                continue;
            }
            if (!entry.hashed) continue;
            const abs = try std.fs.path.join(allocator, &.{ project_root, kv.key_ptr.* });
            defer allocator.free(abs);
            const content = (try @import("safe_fs.zig").read(allocator, project_root, kv.key_ptr.*, scan.MAX_FILE_BYTES)) orelse return error.FileNotFound;
            defer allocator.free(content);
            const stored = try store.put(allocator, project_root, content);
            @memcpy(&entry.hash_hex, stored);
            allocator.free(stored);
        }
    }

    fn diffInto(self: *Recorder, next: *scan.Scan) !void {
        const allocator = self.allocator;
        const now = std.time.milliTimestamp();

        // Stored hashes pinned per path this pass. Applied to next.map at
        // the end via iterator (mutable access): get() returns const.
        var pinned = std.StringHashMap(?[hash.HASH_HEX_LEN]u8).init(allocator);
        defer pinned.deinit();

        // Collect created + deleted for rename pairing.
        var created: std.ArrayList([]const u8) = .empty;
        defer created.deinit(allocator);
        var deleted: std.ArrayList([]const u8) = .empty;
        defer deleted.deinit(allocator);

        var it = next.map.iterator();
        while (it.next()) |kv| {
            const path = kv.key_ptr.*;
            if (self.baseline.map.get(path)) |old| {
                if (entryChanged(old, kv.value_ptr.*)) {
                    const stored = try self.emitModified(path, old, kv.value_ptr.*, now);
                    // Pin the map to stored bytes: future prev_hash refs must
                    // resolve in the store, never to scanned-but-lost content.
                    try pinned.put(path, stored);
                }
            } else {
                try created.append(allocator, path);
            }
        }
        var old_it = self.baseline.map.iterator();
        while (old_it.next()) |kv| {
            if (next.map.get(kv.key_ptr.*) == null) {
                try deleted.append(allocator, kv.key_ptr.*);
            }
        }

        // Rename pairing: deleted path + created path with identical hash.
        var used_new = std.AutoHashMap(usize, void).init(allocator);
        defer used_new.deinit();
        for (deleted.items) |old_path| {
            const old = self.baseline.map.get(old_path).?;
            if (!old.hashed) {
                try self.emitDeleted(old_path, old, now);
                continue;
            }
            var paired = false;
            for (created.items, 0..) |new_path, i| {
                if (used_new.get(i) != null) continue;
                const new_entry = next.map.get(new_path).?;
                if (!new_entry.hashed) continue;
                if (!std.mem.eql(u8, &old.hash_hex, &new_entry.hash_hex)) continue;
                const stored_r = try self.emitRenamed(old_path, new_path, old, new_entry, now);
                try pinned.put(new_path, stored_r);
                try used_new.put(i, {});
                paired = true;
                break;
            }
            if (!paired) try self.emitDeleted(old_path, old, now);
        }
        for (created.items, 0..) |new_path, i| {
            if (used_new.get(i) != null) continue;
            const new_entry = next.map.get(new_path).?;
            const stored_c = try self.emitCreated(new_path, new_entry, now);
            try pinned.put(new_path, stored_c);
        }

        // Apply pinned hashes: recorded state references stored bytes only.
        // Unstored observations become unhashed (future prev_hash = null).
        var fix = next.map.iterator();
        while (fix.next()) |kv| {
            if (pinned.get(kv.key_ptr.*)) |stored| {
                if (stored) |s| {
                    kv.value_ptr.hash_hex = s;
                } else {
                    kv.value_ptr.hashed = false;
                }
            }
        }
    }

    fn entryChanged(old: scan.Entry, new_entry: scan.Entry) bool {
        if (old.kind != new_entry.kind) return true;
        if (old.kind == .symlink) {
            const ot = old.symlink_target orelse "";
            const nt = new_entry.symlink_target orelse "";
            return !std.mem.eql(u8, ot, nt);
        }
        if (old.hashed != new_entry.hashed) return true;
        if (old.hashed and new_entry.hashed)
            return !std.mem.eql(u8, &old.hash_hex, &new_entry.hash_hex);
        return old.size != new_entry.size or old.mtime_ns != new_entry.mtime_ns;
    }

    fn absPath(self: *Recorder, rel: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.project_root, rel });
    }

    fn storeAfter(self: *Recorder, rel: []const u8, entry: scan.Entry) ?[hash.HASH_HEX_LEN]u8 {
        if (!entry.hashed or entry.kind != .file) return null;
        const abs = self.absPath(rel) catch return null;
        defer self.allocator.free(abs);
        const content = (@import("safe_fs.zig").read(self.allocator, self.project_root, rel, scan.MAX_FILE_BYTES) catch {
            self.failed.store(true, .seq_cst);
            return null;
        }) orelse {
            self.failed.store(true, .seq_cst);
            return null;
        };
        defer self.allocator.free(content);
        // Re-hash what we actually read and report THAT hash: the recorded
        // state must reference stored bytes, never scanned-but-unstored ones.
        const stored = store.put(self.allocator, self.project_root, content) catch {
            self.failed.store(true, .seq_cst);
            return null;
        };
        defer self.allocator.free(stored);
        var out: [hash.HASH_HEX_LEN]u8 = undefined;
        @memcpy(&out, stored[0..hash.HASH_HEX_LEN]);
        return out;
    }

    fn emitCreated(self: *Recorder, path: []const u8, entry: scan.Entry, now: i64) !?[hash.HASH_HEX_LEN]u8 {
        const new_hash = self.storeAfter(path, entry);
        try self.queue.push(self.allocator, .{
            .ts = now,
            .type = "file_created",
            .path = try self.allocator.dupe(u8, path),
            .path_owned = true,
            .prev_hash = null,
            .new_hash = new_hash,
            .size = entry.size,
        });
        return new_hash;
    }

    fn emitModified(self: *Recorder, path: []const u8, old: scan.Entry, new_entry: scan.Entry, now: i64) !?[hash.HASH_HEX_LEN]u8 {
        const new_hash = self.storeAfter(path, new_entry);
        try self.queue.push(self.allocator, .{
            .ts = now,
            .type = "file_modified",
            .path = try self.allocator.dupe(u8, path),
            .path_owned = true,
            .prev_hash = if (old.hashed) old.hash_hex else null,
            .new_hash = new_hash,
            .size = new_entry.size,
        });
        return new_hash;
    }

    fn emitDeleted(self: *Recorder, path: []const u8, old: scan.Entry, now: i64) !void {
        try self.queue.push(self.allocator, .{
            .ts = now,
            .type = "file_deleted",
            .path = try self.allocator.dupe(u8, path),
            .path_owned = true,
            .prev_hash = if (old.hashed) old.hash_hex else null,
            .new_hash = null,
            .size = old.size,
        });
    }

    fn emitRenamed(
        self: *Recorder,
        old_path: []const u8,
        new_path: []const u8,
        old: scan.Entry,
        new_entry: scan.Entry,
        now: i64,
    ) !?[hash.HASH_HEX_LEN]u8 {
        const new_hash = self.storeAfter(new_path, new_entry);
        try self.queue.push(self.allocator, .{
            .ts = now,
            .type = "file_renamed",
            .path = try self.allocator.dupe(u8, new_path),
            .path_owned = true,
            .prev_path = try self.allocator.dupe(u8, old_path),
            .prev_path_owned = true,
            .prev_hash = if (old.hashed) old.hash_hex else null,
            .new_hash = new_hash,
            .size = new_entry.size,
        });
        return new_hash;
    }
};

fn readCapped(allocator: std.mem.Allocator, abs_path: []const u8, limit: u64) ![]u8 {
    const f = try std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only });
    defer f.close();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [65536]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        total += n;
        if (total > limit) return error.FileTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

test "unstored file observation must retry storage" {
    const old = scan.Entry{ .size = 1, .mtime_ns = 1, .hash_hex = [_]u8{0} ** hash.HASH_HEX_LEN, .hashed = false, .is_binary = false, .kind = .file };
    var next = old;
    next.hashed = true;
    try std.testing.expect(Recorder.entryChanged(old, next));
}
