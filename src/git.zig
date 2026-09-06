// Git integration: best-effort metadata capture. Never fails the session —
// every helper returns null outside a repo or when git misbehaves. Nothing
// is committed, staged, or configured.

const std = @import("std");

pub const GitState = struct {
    branch: []u8,
    head: []u8,
    dirty: i64,

    pub fn deinit(self: *GitState, allocator: std.mem.Allocator) void {
        allocator.free(self.branch);
        allocator.free(self.head);
    }
};

/// Run git and capture trimmed stdout. Null on any failure.
fn gitOut(allocator: std.mem.Allocator, root: []const u8, argv: []const []const u8) !?[]u8 {
    var full_argv: std.ArrayList([]const u8) = .empty;
    defer full_argv.deinit(allocator);
    try full_argv.appendSlice(allocator, argv);

    var child = std.process.Child.init(full_argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = root;
    child.spawn() catch return null;
    const out = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch null;
    const term = child.wait() catch {
        if (out) |o| allocator.free(o);
        return null;
    };
    switch (term) {
        .Exited => |c| {
            if (c != 0) {
                if (out) |o| allocator.free(o);
                return null;
            }
        },
        else => {
            if (out) |o| allocator.free(o);
            return null;
        },
    }
    const text = out orelse return null;
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return allocator.dupe(u8, trimmed) catch null;
}

/// Capture branch, HEAD, and dirty count. Null when not a repo.
/// Verifies the discovered .git actually belongs at root (git walks up
/// past the project otherwise).
pub fn capture(allocator: std.mem.Allocator, root: []const u8) !?GitState {
    const git_dir = try gitOut(allocator, root, &.{ "git", "-C", root, "rev-parse", "--git-dir" });
    if (git_dir) |g| {
        allocator.free(g);
    } else return null;

    // Contain discovery: the toplevel must be root itself.
    const top_raw = try gitOut(allocator, root, &.{ "git", "-C", root, "rev-parse", "--show-toplevel" });
    if (top_raw) |t| {
        defer allocator.free(t);
        // Compare with trailing-slash tolerance.
        const a = std.mem.trimRight(u8, t, "/");
        const b = std.mem.trimRight(u8, root, "/");
        if (!std.mem.eql(u8, a, b)) return null;
    } else return null;

    const branch_raw = try gitOut(allocator, root, &.{ "git", "-C", root, "branch", "--show-current" });
    defer if (branch_raw) |b| allocator.free(b);
    const head_raw = try gitOut(allocator, root, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    defer if (head_raw) |h| allocator.free(h);
    const status_raw = try gitOut(allocator, root, &.{ "git", "-C", root, "status", "--porcelain=v1" });
    defer if (status_raw) |s| allocator.free(s);

    const branch = if (branch_raw) |b| (if (b.len > 0) b else "HEAD") else "HEAD";
    const head = if (head_raw) |h| h else "";
    var dirty: i64 = 0;
    if (status_raw) |s| {
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) dirty += 1;
        }
    }
    return .{
        .branch = try allocator.dupe(u8, branch),
        .head = try allocator.dupe(u8, head),
        .dirty = dirty,
    };
}

const testing = std.testing;

test "capture outside repo is null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    // No .git here; must return null, never error.
    const state = try capture(testing.allocator, root);
    try testing.expect(state == null);
}
