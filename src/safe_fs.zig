// Descriptor-relative filesystem access for recovery. Never traverse symlinks.
const std = @import("std");
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".annalist") or std.mem.eql(u8, part, ".git")) return false;
    }
    return true;
}
pub fn parent(root: []const u8, path: []const u8, create: bool) !std.fs.Dir {
    if (!validPath(path)) return error.UnsafePath;
    var dir = try std.fs.openDirAbsolute(root, .{ .no_follow = true, .iterate = true });
    errdefer dir.close();
    if (std.fs.path.dirname(path)) |dirs| {
        var parts = std.mem.splitScalar(u8, dirs, '/');
        while (parts.next()) |part| {
            if (create) dir.makeDir(part) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            const next = try dir.openDir(part, .{ .no_follow = true, .iterate = true });
            dir.close();
            dir = next;
        }
    }
    return dir;
}
pub fn read(allocator: std.mem.Allocator, root: []const u8, path: []const u8, max: usize) !?[]u8 {
    var dir = parent(root, path, false) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer dir.close();
    const fd = std.posix.openat(dir.fd, std.fs.path.basename(path), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true }, 0) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    const file = std.fs.File{ .handle = fd };
    defer file.close();
    if ((try file.stat()).kind != .file) return error.UnsafePath;
    return try file.readToEndAlloc(allocator, max);
}
pub fn write(root: []const u8, path: []const u8, bytes: []const u8) !void {
    var dir = try parent(root, path, true);
    defer dir.close();
    const base = std.fs.path.basename(path);
    var mode: std.fs.File.Mode = 0o600;
    if (dir.statFile(base)) |st| {
        mode = st.mode & 0o777;
    } else |_| {}
    var af = try dir.atomicFile(base, .{ .mode = mode, .write_buffer = &.{} });
    defer af.deinit();
    try af.file_writer.file.writeAll(bytes);
    try af.file_writer.file.sync();
    try af.finish();
    try std.posix.fsync(dir.fd);
}
test "reject recovery paths outside content" {
    for ([_][]const u8{ "../x", "/tmp/x", "a/../b", ".annalist/config.toml", ".git/HEAD", "a//b", "a/./b", "a\\b" }) |p| try std.testing.expect(!validPath(p));
    try std.testing.expect(validPath("src/main.zig"));
}
