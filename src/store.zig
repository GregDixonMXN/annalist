// Content-addressed blob store: <project>/.annalist/objects/xx/rest.
// Idempotent puts; identical content stored once. Never touches source files.

const std = @import("std");
const hash = @import("hash.zig");

pub const OBJECTS_DIR = "objects";

pub fn objectsDir(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, ".annalist", OBJECTS_DIR });
}

fn blobPath(allocator: std.mem.Allocator, project_root: []const u8, hex: *const [hash.HASH_HEX_LEN]u8) ![]u8 {
    return std.fs.path.join(allocator, &.{
        project_root,
        ".annalist",
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

    if (get(allocator, project_root, &hex, bytes.len + 1)) |existing| {
        allocator.free(existing);
        return allocator.dupe(u8, &hex);
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    const dir_path = std.fs.path.dirname(path).?;
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var af = try dir.atomicFile(std.fs.path.basename(path), .{ .mode = 0o600, .write_buffer = &.{} });
    defer af.deinit();
    try af.file_writer.file.writeAll(bytes);
    try af.file_writer.file.sync();
    try af.finish();
    try std.posix.fsync(dir.fd);
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
    for (hex) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.BadHash;
    var fixed: [hash.HASH_HEX_LEN]u8 = undefined;
    @memcpy(&fixed, hex);
    const path = try blobPath(allocator, project_root, &fixed);
    defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
    errdefer allocator.free(bytes);
    var digest: [hash.HASH_HEX_LEN]u8 = undefined;
    hash.sha256Hex(bytes, &digest);
    if (!std.mem.eql(u8, &digest, hex)) return error.CorruptBlob;
    return bytes;
}

const testing = std.testing;

test "blob round trip + dedup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    // .annalist/objects must exist for exclusive create of subdirs.
    const h1 = try put(testing.allocator, root, "hello world");
    defer testing.allocator.free(h1);
    const h2 = try put(testing.allocator, root, "hello world");
    defer testing.allocator.free(h2);
    try testing.expectEqualStrings(h1, h2);
    const back = try get(testing.allocator, root, h1, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello world", back);
}

test "corrupt existing blob is refused on read and put" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const hex = try put(testing.allocator, root, "original");
    defer testing.allocator.free(hex);
    var fixed: [hash.HASH_HEX_LEN]u8 = undefined;
    @memcpy(&fixed, hex);
    const path = try blobPath(testing.allocator, root, &fixed);
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "tampered" });
    try testing.expectError(error.CorruptBlob, get(testing.allocator, root, hex, 1024));
    try testing.expectError(error.CorruptBlob, put(testing.allocator, root, "original"));
}
