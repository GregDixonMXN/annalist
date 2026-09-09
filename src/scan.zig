// Directory scanning: walk the project, apply ignores, stat + hash files.
// Fast path uses size+mtime; hashing happens for new/changed files.

const std = @import("std");
const ignore = @import("ignore.zig");
const hash = @import("hash.zig");

pub const MAX_FILE_BYTES: u64 = 10 * 1024 * 1024;

pub const Kind = enum { file, symlink };

pub const Entry = struct {
    size: i64,
    mtime_ns: i128,
    hash_hex: [hash.HASH_HEX_LEN]u8,
    hashed: bool, // false when over the size limit (size/mtime only)
    is_binary: bool,
    kind: Kind,
    symlink_target: ?[]u8 = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.symlink_target) |t| allocator.free(t);
    }
};

pub const Scan = struct {
    map: std.StringHashMap(Entry),

    pub fn deinit(self: *Scan) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.map.allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(self.map.allocator);
        }
        self.map.deinit();
    }
};

/// Read at most limit+1 bytes; returns bytes read and whether truncated.
fn readCapped(
    allocator: std.mem.Allocator,
    abs_path: []const u8,
    limit: u64,
) !struct { bytes: []u8, truncated: bool } {
    const f = try std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only });
    defer f.close();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [65536]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        if (total + n > limit + 1) {
            const room = limit + 1 - total;
            try out.appendSlice(allocator, buf[0..room]);
            return .{ .bytes = try out.toOwnedSlice(allocator), .truncated = true };
        }
        try out.appendSlice(allocator, buf[0..n]);
        total += n;
    }
    return .{ .bytes = try out.toOwnedSlice(allocator), .truncated = false };
}

pub fn scanDir(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    patterns: []const []const u8,
) !Scan {
    var map = std.StringHashMap(Entry).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        map.deinit();
    }

    var root_dir = try std.fs.openDirAbsolute(project_root, .{ .iterate = true });
    defer root_dir.close();
    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (ignore.isIgnored(patterns, entry.path)) {
            if (entry.kind == .directory) {
                var skipped = walker.stack.pop().?;
                skipped.iter.dir.close();
            }
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const abs = try std.fs.path.join(allocator, &.{ project_root, entry.path });
        defer allocator.free(abs);

        if (entry.kind == .sym_link) {
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try std.posix.readlink(abs, &link_buf);
            var hex: [hash.HASH_HEX_LEN]u8 = undefined;
            hash.sha256Hex(target, &hex);
            const key = try allocator.dupe(u8, entry.path);
            errdefer allocator.free(key);
            const tgt = try allocator.dupe(u8, target);
            try map.put(key, .{
                .size = @intCast(target.len),
                .mtime_ns = 0,
                .hash_hex = hex,
                .hashed = false,
                .is_binary = false,
                .kind = .symlink,
                .symlink_target = tgt,
            });
            continue;
        }

        const stat = try std.fs.cwd().statFile(abs);
        const key = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(key);
        const size_i64: i64 = @intCast(@min(stat.size, std.math.maxInt(i64)));
        if (@as(u64, @intCast(@max(stat.size, 0))) > MAX_FILE_BYTES) {
            try map.put(key, .{
                .size = size_i64,
                .mtime_ns = stat.mtime,
                .hash_hex = [_]u8{0} ** hash.HASH_HEX_LEN,
                .hashed = false,
                .is_binary = false,
                .kind = .file,
            });
            continue;
        }
        const safe_bytes = (try @import("safe_fs.zig").read(allocator, project_root, entry.path, MAX_FILE_BYTES + 1)) orelse return error.FileNotFound;
        const content = .{ .bytes = safe_bytes, .truncated = safe_bytes.len > MAX_FILE_BYTES };
        defer allocator.free(content.bytes);
        if (content.truncated) {
            try map.put(key, .{
                .size = size_i64,
                .mtime_ns = stat.mtime,
                .hash_hex = [_]u8{0} ** hash.HASH_HEX_LEN,
                .hashed = false,
                .is_binary = false,
                .kind = .file,
            });
            continue;
        }
        var hex: [hash.HASH_HEX_LEN]u8 = undefined;
        hash.sha256Hex(content.bytes, &hex);
        try map.put(key, .{
            .size = size_i64,
            .mtime_ns = stat.mtime,
            .hash_hex = hex,
            .hashed = true,
            .is_binary = hash.isBinary(content.bytes),
            .kind = .file,
        });
    }

    return .{ .map = map };
}

const testing = std.testing;

test "scan detects files and ignores" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = "x" });
    try tmp.dir.makePath(".git");
    try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = "ref" });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var scan = try scanDir(testing.allocator, root, &ignore.default_ignores);
    defer scan.deinit();
    try testing.expect(scan.map.get("a.txt") != null);
    try testing.expect(scan.map.get("big.bin") != null);
    try testing.expect(scan.map.get(".git/HEAD") == null);
    const a = scan.map.get("a.txt").?;
    try testing.expect(a.hashed and !a.is_binary);
}
