// `annalist gate`: policy decision over one recorded session.
// Exit 0 pass, 2 policy deny, 1 broken (bad session, corrupt index,
// missing content, export failure, bad policy file).
//
// The gate checks session file events against allow_paths, deny_globs and
// max_files_changed, then scans the working tree for secret-glob matches.
// The tree scan is deliberate: the recorder ignores secrets by default, so a
// session that writes `.env` records no event for it — without the scan the
// secret demo could never go red.

const std = @import("std");
const db = @import("db.zig");
const views = @import("views.zig");
const ignore = @import("ignore.zig");
const store = @import("store.zig");
const bundle = @import("export.zig");

/// Secret globs that apply when fail_on_secret is set (the default), even
/// with no policy file.
pub const default_secret_globs = [_][]const u8{
    ".env",
    ".env.*",
    "*.pem",
    "**/secrets/**",
};

pub const Policy = struct {
    allow_paths: [][]u8 = &.{},
    deny_globs: [][]u8 = &.{},
    max_files_changed: ?i64 = null,
    fail_on_secret: bool = true,

    fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        for (self.allow_paths) |p| allocator.free(p);
        allocator.free(self.allow_paths);
        for (self.deny_globs) |p| allocator.free(p);
        allocator.free(self.deny_globs);
    }
};

/// Match a glob at any directory depth (secret names count anywhere).
fn matchesAnywhere(pattern: []const u8, rel_path: []const u8) bool {
    var components = std.mem.splitScalar(u8, rel_path, '/');
    var offset: usize = 0;
    while (components.next()) |component| {
        if (ignore.matches(pattern, rel_path[offset..])) return true;
        offset += component.len + 1;
    }
    return false;
}

fn underDir(path: []const u8, dir: []const u8) bool {
    const clean = std.mem.trimRight(u8, dir, "/");
    if (clean.len == 0) return true;
    if (std.mem.eql(u8, path, clean)) return true;
    if (path.len <= clean.len) return false;
    return std.mem.startsWith(u8, path, clean) and path[clean.len] == '/';
}

fn parseBool(val: []const u8) !bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return error.BadPolicyValue;
}

/// Parse a flat policy TOML file. Unknown keys are an error.
pub fn parsePolicy(allocator: std.mem.Allocator, path: []const u8) !Policy {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024) catch {
        return error.NoSuchPolicy;
    };
    defer allocator.free(data);

    var policy = Policy{};
    errdefer policy.deinit(allocator);
    var allows: std.ArrayList([]u8) = .empty;
    defer allows.deinit(allocator);
    var denies: std.ArrayList([]u8) = .empty;
    defer denies.deinit(allocator);

    // Collect multi-line [...] array bodies per key.
    var collecting: ?u8 = null; // 0 = allow, 1 = deny
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') return error.BadPolicyValue; // no sections in gate policy
        if (collecting) |which| {
            try buf.appendSlice(allocator, t);
            try buf.append(allocator, ' ');
            if (std.mem.indexOfScalar(u8, t, ']') != null) {
                const list = try parseStrArray(allocator, buf.items);
                if (which == 0) try allows.appendSlice(allocator, list) else try denies.appendSlice(allocator, list);
                allocator.free(list);
                collecting = null;
                buf.clearRetainingCapacity();
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse return error.BadPolicyValue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "allow_paths") or std.mem.eql(u8, key, "deny_globs")) {
            const which: u8 = if (std.mem.eql(u8, key, "allow_paths")) 0 else 1;
            if (std.mem.indexOfScalar(u8, val, ']') != null) {
                const list = try parseStrArray(allocator, val);
                if (which == 0) try allows.appendSlice(allocator, list) else try denies.appendSlice(allocator, list);
                allocator.free(list);
            } else {
                collecting = which;
                try buf.appendSlice(allocator, val);
                try buf.append(allocator, ' ');
            }
        } else if (std.mem.eql(u8, key, "max_files_changed")) {
            policy.max_files_changed = std.fmt.parseInt(i64, val, 10) catch return error.BadPolicyValue;
        } else if (std.mem.eql(u8, key, "fail_on_secret")) {
            policy.fail_on_secret = try parseBool(val);
        } else {
            return error.UnknownPolicyKey;
        }
    }
    if (collecting != null) return error.BadPolicyValue;
    policy.allow_paths = try allows.toOwnedSlice(allocator);
    policy.deny_globs = try denies.toOwnedSlice(allocator);
    return policy;
}

fn parseStrArray(allocator: std.mem.Allocator, body: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    const open = std.mem.indexOfScalar(u8, body, '[') orelse return error.BadPolicyValue;
    const close = std.mem.lastIndexOfScalar(u8, body, ']') orelse return error.BadPolicyValue;
    if (close <= open) return error.BadPolicyValue;
    var parts = std.mem.splitScalar(u8, body[open + 1 .. close], ',');
    while (parts.next()) |part| {
        const p = std.mem.trim(u8, part, " \t\"'\r\n");
        if (p.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, p));
    }
    return out.toOwnedSlice(allocator);
}

const Denial = struct {
    path: []const u8,
    reason: []const u8,
};

/// Deny reason for one touched path, or null when the path is allowed.
fn evalPath(path: []const u8, policy: *const Policy) ?[]const u8 {
    for (policy.deny_globs) |g| {
        if (matchesAnywhere(g, path)) return "policy deny_glob";
    }
    if (policy.fail_on_secret) {
        for (default_secret_globs) |g| {
            if (matchesAnywhere(g, path)) return "secret";
        }
    }
    if (policy.allow_paths.len > 0) {
        for (policy.allow_paths) |d| {
            if (underDir(path, d)) return null;
        }
        return "outside allow_paths";
    }
    return null;
}

fn checkIntegrity(database: *db.Db) !bool {
    var stmt = try database.prepare("PRAGMA integrity_check;");
    defer stmt.finalize();
    if (try stmt.step()) return std.mem.eql(u8, stmt.columnText(0), "ok");
    return false;
}

/// Blobs referenced by this session that are absent or corrupt.
fn countSessionMissingBlobs(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    session_id: i64,
    project_root: []const u8,
) !i64 {
    var missing: i64 = 0;
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        seen.deinit();
    }
    var q = try database.prepare(
        "SELECT e.prev_hash, e.new_hash FROM events e WHERE e.session_id = ?1 AND e.session_id IN (SELECT id FROM sessions WHERE project_id = ?2) AND (e.prev_hash IS NOT NULL OR e.new_hash IS NOT NULL);",
    );
    defer q.finalize();
    try q.bindInt64(1, session_id);
    try q.bindText(2, project_id);
    while (try q.step()) {
        for ([2]?[]const u8{
            if (q.columnIsNull(0)) null else q.columnText(0),
            if (q.columnIsNull(1)) null else q.columnText(1),
        }) |h| {
            const hex = h orelse continue;
            const fresh = try allocator.dupe(u8, hex);
            const gop = try seen.getOrPut(fresh);
            if (gop.found_existing) {
                allocator.free(fresh);
                continue;
            }
            const bytes = store.get(allocator, project_root, hex, 64 * 1024 * 1024) catch {
                missing += 1;
                continue;
            };
            allocator.free(bytes);
        }
    }
    return missing;
}

const MAX_TREE_SCAN: usize = 20000;

/// Working-tree files matching deny/secret globs. The recorder ignores
/// secrets, so presence on disk is the only signal a session wrote one.
fn scanTreeSecrets(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    policy: *const Policy,
    denials: *std.ArrayList(Denial),
    seen_denied: *std.StringHashMap(void),
) !void {
    var dir = std.fs.openDirAbsolute(project_root, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next()) |entry| {
        if (n >= MAX_TREE_SCAN) return error.TreeTooLarge;
        n += 1;
        if (entry.kind != .file) continue;
        const rel = entry.path;
        if (std.mem.startsWith(u8, rel, ".annalist/") or std.mem.eql(u8, rel, ".annalist")) continue;
        if (std.mem.startsWith(u8, rel, ".git/") or std.mem.eql(u8, rel, ".git")) continue;
        var reason: ?[]const u8 = null;
        for (policy.deny_globs) |g| {
            if (matchesAnywhere(g, rel)) {
                reason = "policy deny_glob";
                break;
            }
        }
        if (reason == null and policy.fail_on_secret) {
            for (default_secret_globs) |g| {
                if (matchesAnywhere(g, rel)) {
                    reason = "secret";
                    break;
                }
            }
        }
        if (reason) |r| {
            if (seen_denied.contains(rel)) continue;
            try seen_denied.put(try allocator.dupe(u8, rel), {});
            try denials.append(allocator, .{ .path = try allocator.dupe(u8, rel), .reason = r });
        }
    }
}

pub fn runGate(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    session_text: []const u8,
    policy_path: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const A = arena.allocator();

    const id = std.fmt.parseInt(i64, session_text, 10) catch return error.BadSessionId;
    try views.assertSession(database, project_id, id);

    var buf: [8192]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    // 1. Finished session only.
    {
        var st = try database.prepare("SELECT ended_at FROM sessions WHERE id = ?1;");
        defer st.finalize();
        try st.bindInt64(1, id);
        if (try st.step()) {
            if (st.columnIsNull(0)) return error.UnfinishedSession;
        }
    }

    // 2. Storage health: integrity + this session's blobs.
    if (!(try checkIntegrity(database))) return error.DoctorDirty;
    if ((try countSessionMissingBlobs(A, database, project_id, id, project_root)) > 0)
        return error.DoctorDirty;

    // 3. Export must succeed (proves the bundle path CI will use).
    {
        const stage = try std.fmt.allocPrint(A, "{s}/.annalist/tmp-gate-{d}-{x}", .{
            project_root, std.time.milliTimestamp(), std.crypto.random.int(u64),
        });
        _ = bundle.exportOne(A, database, project_id, project_root, id, stage) catch |err| {
            std.fs.deleteTreeAbsolute(stage) catch {};
            return err;
        };
        std.fs.deleteTreeAbsolute(stage) catch {};
    }

    var policy: Policy = if (policy_path) |p| try parsePolicy(A, p) else Policy{};
    // Arena owns policy memory; no deinit needed.

    // 4. Collect session file events.
    const Mask = struct {
        bits: u8 = 0, // 1 created, 2 modified, 4 deleted
    };
    var touched = std.StringHashMap(Mask).init(A);
    var created: usize = 0;
    var modified: usize = 0;
    var deleted: usize = 0;
    {
        var q = try database.prepare(
            "SELECT type, path, prev_path FROM events WHERE session_id = ?1 AND session_id IN (SELECT id FROM sessions WHERE project_id = ?2) ORDER BY seq ASC;",
        );
        defer q.finalize();
        try q.bindInt64(1, id);
        try q.bindText(2, project_id);
        while (try q.step()) {
            const t = q.columnText(0);
            const path = q.columnText(1);
            const prev: ?[]const u8 = if (q.columnIsNull(2)) null else q.columnText(2);
            if (std.mem.eql(u8, t, "file_created")) {
                const gop = try touched.getOrPut(try A.dupe(u8, path));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .bits = 1 };
                    created += 1;
                } else if (gop.value_ptr.bits & 1 == 0) {
                    gop.value_ptr.bits |= 1;
                    created += 1;
                }
            } else if (std.mem.eql(u8, t, "file_modified")) {
                const gop = try touched.getOrPut(try A.dupe(u8, path));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .bits = 2 };
                    modified += 1;
                } else if (gop.value_ptr.bits & 2 == 0) {
                    gop.value_ptr.bits |= 2;
                    modified += 1;
                }
            } else if (std.mem.eql(u8, t, "file_deleted")) {
                const gop = try touched.getOrPut(try A.dupe(u8, path));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .bits = 4 };
                    deleted += 1;
                } else if (gop.value_ptr.bits & 4 == 0) {
                    gop.value_ptr.bits |= 4;
                    deleted += 1;
                }
            } else if (std.mem.eql(u8, t, "file_renamed")) {
                if (prev) |pp| {
                    const gop = try touched.getOrPut(try A.dupe(u8, pp));
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .bits = 4 };
                        deleted += 1;
                    } else if (gop.value_ptr.bits & 4 == 0) {
                        gop.value_ptr.bits |= 4;
                        deleted += 1;
                    }
                }
                const gop = try touched.getOrPut(try A.dupe(u8, path));
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .bits = 1 };
                    created += 1;
                } else if (gop.value_ptr.bits & 1 == 0) {
                    gop.value_ptr.bits |= 1;
                    created += 1;
                }
            }
        }
    }

    // 5. Evaluate.
    var denials: std.ArrayList(Denial) = .empty;
    var seen_denied = std.StringHashMap(void).init(A);
    var files_total: usize = 0;
    var it = touched.iterator();
    while (it.next()) |kv| {
        files_total += 1;
        if (evalPath(kv.key_ptr.*, &policy)) |reason| {
            if (seen_denied.contains(kv.key_ptr.*)) continue;
            try seen_denied.put(try A.dupe(u8, kv.key_ptr.*), {});
            try denials.append(A, .{ .path = kv.key_ptr.*, .reason = reason });
        }
    }
    if (policy.max_files_changed) |max| {
        if (@as(i64, @intCast(files_total)) > max) {
            try denials.append(A, .{
                .path = try std.fmt.allocPrint(A, "{d} files changed", .{files_total}),
                .reason = try std.fmt.allocPrint(A, "over max_files_changed={d}", .{max}),
            });
        }
    }
    try scanTreeSecrets(A, project_root, &policy, &denials, &seen_denied);

    // 6. One-screen report.
    if (policy_path) |p| {
        try out.print("policy: {s} (allow {d}, deny {d}, max {s}, secrets {s})\n", .{
            p,
            policy.allow_paths.len,
            policy.deny_globs.len,
            if (policy.max_files_changed) |m| try std.fmt.allocPrint(A, "{d}", .{m}) else "none",
            if (policy.fail_on_secret) "on" else "off",
        });
    } else {
        try out.print("policy: defaults (secrets on, no allow list, no max)\n", .{});
    }
    try out.print("session {d}: created {d} modified {d} deleted {d} files {d}\n", .{
        id, created, modified, deleted, files_total,
    });
    const show = @min(denials.items.len, 20);
    for (denials.items[0..show]) |d| {
        try out.print("  DENY {s} ({s})\n", .{ d.path, d.reason });
    }
    if (denials.items.len > show) {
        try out.print("  ... +{d} more\n", .{denials.items.len - show});
    }
    if (denials.items.len > 0) {
        try out.print("gate session {d}: DENY ({d})\n", .{ id, denials.items.len });
        try out.flush();
        return error.PolicyDeny;
    }
    try out.print("gate session {d}: PASS\n", .{id});
    try out.flush();
}

const testing = std.testing;

test "gate policy parse round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("p.toml", .{});
    try f.writeAll(
        \\allow_paths = ["src/", "docs/"]
        \\deny_globs = ["**/secrets/**"]
        \\max_files_changed = 80
        \\fail_on_secret = true
        \\
    );
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("p.toml", &path_buf);
    var policy = try parsePolicy(testing.allocator, path);
    defer policy.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), policy.allow_paths.len);
    try testing.expectEqual(@as(usize, 1), policy.deny_globs.len);
    try testing.expectEqual(@as(?i64, 80), policy.max_files_changed);
    try testing.expect(policy.fail_on_secret);
}

test "gate policy unknown key errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("p.toml", .{});
    try f.writeAll("allow_paths = []\nbilling_tier = \"pro\"\n");
    f.close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp.dir.realpath("p.toml", &path_buf);
    try testing.expectError(error.UnknownPolicyKey, parsePolicy(testing.allocator, path));
}

test "gate path evaluation" {
    var policy = Policy{ .allow_paths = &.{}, .deny_globs = &.{}, .fail_on_secret = true };
    try testing.expect(evalPath("src/ok.txt", &policy) == null);
    try testing.expectEqualStrings("secret", evalPath(".env", &policy).?);
    try testing.expectEqualStrings("secret", evalPath("a/.env.local", &policy).?);
    try testing.expectEqualStrings("secret", evalPath("tls/key.pem", &policy).?);
    try testing.expectEqualStrings("secret", evalPath("a/secrets/dump.sql", &policy).?);
    policy.allow_paths = @constCast(&[_][]u8{@constCast("src/")});
    try testing.expect(evalPath("src/ok.txt", &policy) == null);
    try testing.expectEqualStrings("outside allow_paths", evalPath("notes.txt", &policy).?);
    // Secrets deny even inside allow_paths.
    try testing.expectEqualStrings("secret", evalPath("src/.env", &policy).?);
}
