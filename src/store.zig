// Content-addressed blob store: <project>/.blackbox/objects/xx/rest.
// Idempotent puts; identical content stored once. Never touches source files.

const std = @import("std");
const hash = @import("hash.zig");

pub const OBJECTS_DIR = "objects";

pub fn objectsDir(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, ".blackbox", OBJECTS_DIR });
}

fn blobPath(allocator: std.mem.Allocator, project_root: []const u8, hex: *const [hash.HASH_HEX_LEN]u8) ![]u8 {
    return std.fs.path.join(allocator, &.{
        project_root,
        ".blackbox",
        OBJECTS_DIR,
        hex[0..2],
        hex[2..],
    });
}

/// Store bytes under their SHA-256 hex. Returns the hex (caller-owned).
pub fn put(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    bytes: []const u8,
) ![]u8 {
    var hex: [hash.HASH_HEX_LEN]u8 = undefined;
    hash.sha256Hex(bytes, &hex);
    const path = try blobPath(allocator, project_root, &hex);
    defer allocator.free(path);

    // Fast path: already stored.
    std.fs.accessAbsolute(path, .{}) catch {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        const f = try std.fs.createFileAbsolute(path, .{ .exclusive = true });
        defer f.close();
        try f.writeAll(bytes);
        return allocator.dupe(u8, &hex);
    };
    return allocator.dupe(u8, &hex);
}

/// Load a blob by hex. Returns error.FileNotFound when absent.
pub fn get(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    hex: []const u8,
    max_bytes: usize,
) ![]u8 {
    if (hex.len != hash.HASH_HEX_LEN) return error.BadHash;
    var fixed: [hash.HASH_HEX_LEN]u8 = undefined;
    @memcpy(&fixed, hex);
    const path = try blobPath(allocator, project_root, &fixed);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

const testing = std.testing;

test "blob round trip + dedup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    // .blackbox/objects must exist for exclusive create of subdirs.
    const h1 = try put(testing.allocator, root, "hello world");
    defer testing.allocator.free(h1);
    const h2 = try put(testing.allocator, root, "hello world");
    defer testing.allocator.free(h2);
    try testing.expectEqualStrings(h1, h2);
    const back = try get(testing.allocator, root, h1, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello world", back);
}
