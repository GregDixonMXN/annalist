// Ignore patterns: subset of glob supporting `*` (within a segment),
// trailing `/**` (whole subtree), and exact paths. Always ignores `.annalist`.

const std = @import("std");

pub const default_ignores = [_][]const u8{
    ".git/**",
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "id_rsa",
    "id_ed25519",
    ".ssh/**",
    ".aws/**",
    ".venv/**",
    "__pycache__/**",
    ".annalist/**",
    "node_modules/**",
    "zig-cache/**",
    ".zig-cache/**",
    "zig-out/**",
    "target/**",
    "build/**",
    "dist/**",
};

fn segmentMatch(pattern: []const u8, name: []const u8) bool {
    // Single `*` / `?` glob, no slashes.
    var px: usize = 0;
    var nx: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;
    while (nx < name.len) {
        if (px < pattern.len and (pattern[px] == '?' or pattern[px] == name[nx])) {
            px += 1;
            nx += 1;
        } else if (px < pattern.len and pattern[px] == '*') {
            star = px;
            star_n = nx;
            px += 1;
        } else if (star != null) {
            star_n += 1;
            nx = star_n;
            px = star.? + 1;
        } else {
            return false;
        }
    }
    while (px < pattern.len and pattern[px] == '*') px += 1;
    return px == pattern.len;
}

pub fn matches(pattern: []const u8, rel_path: []const u8) bool {
    if (std.mem.eql(u8, pattern, "**")) return true;
    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        if (std.mem.startsWith(u8, prefix, "**/")) {
            // Leading **/: subtree match at any depth.
            const needle = prefix[3..];
            if (needle.len == 0) return true;
            var components = std.mem.splitScalar(u8, rel_path, '/');
            var offset: usize = 0;
            while (components.next()) |component| {
                const rest = rel_path[offset..];
                if (std.mem.eql(u8, rest, needle)) return true;
                if (rest.len > needle.len and std.mem.startsWith(u8, rest, needle) and rest[needle.len] == '/') return true;
                offset += component.len + 1;
            }
            return false;
        }
        if (rel_path.len < prefix.len) return false;
        if (!std.mem.startsWith(u8, rel_path, prefix)) return false;
        return rel_path.len == prefix.len or rel_path[prefix.len] == '/';
    }
    // Segment-wise comparison; lengths must agree.
    var pseg = std.mem.splitScalar(u8, pattern, '/');
    var nseg = std.mem.splitScalar(u8, rel_path, '/');
    while (true) {
        const p = pseg.next();
        const n = nseg.next();
        if (p == null and n == null) return true;
        if (p == null or n == null) return false;
        if (std.mem.eql(u8, p.?, "**")) {
            // Mid-pattern ** : match rest greedily (v0.1: rest must match tail).
            // Simplest correct subset: treat as match-all from here.
            return true;
        }
        if (!segmentMatch(p.?, n.?)) return false;
    }
}

pub fn isIgnored(patterns: []const []const u8, rel_path: []const u8) bool {
    if (matches(".annalist/**", rel_path)) return true;
    if (std.mem.eql(u8, rel_path, ".annalist")) return true;
    // Built-in sensitive/cache names apply at every directory depth.
    var components = std.mem.splitScalar(u8, rel_path, '/');
    var offset: usize = 0;
    while (components.next()) |component| {
        for (default_ignores) |p| if (matches(p, rel_path[offset..])) return true;
        offset += component.len + 1;
    }
    for (patterns) |p| {
        if (matches(p, rel_path)) return true;
    }
    return false;
}

const testing = std.testing;

test "ignore matching" {
    try testing.expect(matches(".git/**", ".git/objects/abc"));
    try testing.expect(matches("node_modules/**", "node_modules/foo/bar.js"));
    try testing.expect(!matches("node_modules/**", "src/node_modules_x"));
    try testing.expect(matches("*.log", "debug.log"));
    try testing.expect(!matches("*.log", "a/debug.log"));
    try testing.expect(matches("build/**", "build"));
    try testing.expect(!matches("dist/**", "src/dist/file"));
    try testing.expect(isIgnored(&default_ignores, ".annalist/objects/ab"));
    try testing.expect(isIgnored(&default_ignores, "zig-out/bin/x"));
    try testing.expect(!isIgnored(&default_ignores, "src/main.zig"));
    try testing.expect(matches("**/secrets/**", "a/secrets/dump.sql"));
    try testing.expect(matches("**/secrets/**", "secrets/dump.sql"));
    try testing.expect(matches("**/secrets/**", "a/b/secrets"));
    try testing.expect(!matches("**/secrets/**", "a/secret/dump.sql"));
    try testing.expect(!matches("**/secrets/**", "src/main.zig"));
}
