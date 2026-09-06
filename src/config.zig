// Project initialization: `blackbox init`.
// Layout: .blackbox/config.toml in the project (identity only).
// Large histories live in the user-level data dir (~/.local/share/blackbox/).

const std = @import("std");
const log = @import("log.zig");

pub const CONFIG_DIR_NAME = ".blackbox";
pub const CONFIG_FILE_NAME = "config.toml";

pub const ConfigError = error{
    NotInProject,
    ConfigCorrupt,
};

/// Returns the project root: nearest ancestor (incl. cwd) containing .blackbox/.
pub fn findProjectRoot(allocator: std.mem.Allocator) !?[]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var dir_path: []const u8 = cwd;
    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ dir_path, CONFIG_DIR_NAME });
        defer allocator.free(candidate);
        std.fs.accessAbsolute(candidate, .{}) catch {
            const parent = std.fs.path.dirname(dir_path);
            if (parent == null or std.mem.eql(u8, parent.?, dir_path)) {
                if (dir_path.ptr != cwd.ptr) allocator.free(dir_path);
                return null;
            }
            const owned = try allocator.dupe(u8, parent.?);
            if (dir_path.ptr != cwd.ptr) allocator.free(dir_path);
            dir_path = owned;
            continue;
        };
        const result = try allocator.dupe(u8, dir_path);
        if (dir_path.ptr != cwd.ptr) allocator.free(dir_path);
        return result;
    }
}

fn userDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "blackbox" });
    }
    const home = std.posix.getenv("HOME") orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "blackbox" });
}

fn newProjectId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    // version/variant bits for a v4 UUID
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

pub fn runInit(allocator: std.mem.Allocator) !void {
    var out_buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&out_buf);
    const out = &fw.interface;

    if (try findProjectRoot(allocator)) |root| {
        defer allocator.free(root);
        try out.print("Blackbox already initialized in {s}\n", .{root});
        try out.flush();
        return;
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const dir_path = try std.fs.path.join(allocator, &.{ cwd, CONFIG_DIR_NAME });
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const project_id = try newProjectId(allocator);
    defer allocator.free(project_id);

    const config_path = try std.fs.path.join(allocator, &.{ dir_path, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    var file_buf: [1024]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    try file_writer.interface.print(
        \\# Blackbox project config. Identity only — history lives in the user data dir.
        \\project_id = "{s}"
        \\version = 1
        \\
    , .{project_id});
    try file_writer.interface.flush();

    // Ensure the user-level data dir exists eagerly so later failures are loud.
    const data_dir = try userDataDir(allocator);
    defer allocator.free(data_dir);
    {
        var created = std.fs.cwd().makeOpenPath(data_dir, .{ .iterate = true }) catch return error.CannotCreateDataDir;
        created.close();
    }

    try out.print("Initialized blackbox project {s} in {s}\n", .{ project_id, dir_path });
    try out.flush();
    log.info("project {s} initialized", .{project_id});
}

/// Read project_id from .blackbox/config.toml under root.
pub fn readProjectId(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024);
    defer allocator.free(data);
    // Minimal TOML: find a line starting with project_id =
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "project_id")) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"'");
        // Strip trailing quote if present.
        const clean = std.mem.trimRight(u8, val, "\"'");
        return allocator.dupe(u8, clean);
    }
    return ConfigError.ConfigCorrupt;
}

/// Read user ignore patterns from [ignore] patterns = [...] in config.toml.
/// Returns owned list (caller frees each + the slice). Empty when absent.
pub fn readIgnorePatterns(allocator: std.mem.Allocator, project_root: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch return out.toOwnedSlice(allocator);
    defer allocator.free(data);

    var in_ignore = false;
    var collecting = false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_ignore = std.mem.eql(u8, t, "[ignore]");
            collecting = false;
            continue;
        }
        if (!in_ignore) continue;
        if (!collecting) {
            if (std.mem.startsWith(u8, t, "patterns")) {
                collecting = true;
                const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
                try buf.appendSlice(allocator, t[eq + 1 ..]);
            }
            continue;
        }
        try buf.appendSlice(allocator, t);
        try buf.append(allocator, ' ');
    }
    // Parse the collected [...] body.
    const body = buf.items;
    const open = std.mem.indexOfScalar(u8, body, '[') orelse return out.toOwnedSlice(allocator);
    const close = std.mem.lastIndexOfScalar(u8, body, ']') orelse return out.toOwnedSlice(allocator);
    if (close <= open) return out.toOwnedSlice(allocator);
    var parts = std.mem.splitScalar(u8, body[open + 1 .. close], ',');
    while (parts.next()) |part| {
        const p = std.mem.trim(u8, part, " \t\"'\r\n");
        if (p.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, p));
    }
    return out.toOwnedSlice(allocator);
}

/// Read [branch] current from config.toml. Default "main" when absent.
pub fn readCurrentBranch(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch
        return allocator.dupe(u8, "main");
    defer allocator.free(data);
    var in_branch = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_branch = std.mem.eql(u8, t, "[branch]");
            continue;
        }
        if (!in_branch) continue;
        if (std.mem.startsWith(u8, t, "current")) {
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
            const clean = std.mem.trim(u8, val, "\"'");
            if (clean.len == 0) continue;
            return allocator.dupe(u8, clean);
        }
    }
    return allocator.dupe(u8, "main");
}

/// Write [branch] current, preserving all other config content.
/// The name must already be validated (no quotes/newlines possible).
pub fn writeCurrentBranch(allocator: std.mem.Allocator, project_root: []const u8, name: []const u8) !void {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024);
    defer allocator.free(data);
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(allocator);
    var in_branch = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '[') {
            in_branch = std.mem.eql(u8, t, "[branch]");
            if (!in_branch) {
                try kept.appendSlice(allocator, line);
                try kept.append(allocator, '\n');
            }
            continue;
        }
        if (in_branch) continue; // drop old [branch] body
        try kept.appendSlice(allocator, line);
        try kept.append(allocator, '\n');
    }
    try kept.appendSlice(allocator, "[branch]\n");
    try kept.writer(allocator).print("current = \"{s}\"\n", .{name});
    const f = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(kept.items);
 }

/// Read [retention] max_age_days from config.toml. Default 0 (keep forever).
pub fn readRetentionDays(allocator: std.mem.Allocator, project_root: []const u8) !i64 {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch return 0;
    defer allocator.free(data);
    var in_retention = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_retention = std.mem.eql(u8, t, "[retention]");
            continue;
        }
        if (!in_retention) continue;
        if (std.mem.startsWith(u8, t, "max_age_days")) {
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"'");
            const days = std.fmt.parseInt(i64, val, 10) catch continue;
            if (days < 0) continue;
            return days;
        }
    }
    return 0;
}

/// Write [retention] max_age_days, preserving all other config content.
pub fn writeRetentionDays(allocator: std.mem.Allocator, project_root: []const u8, days: i64) !void {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = try std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024);
    defer allocator.free(data);
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(allocator);
    var in_retention = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '[') {
            in_retention = std.mem.eql(u8, t, "[retention]");
            if (!in_retention) {
                try kept.appendSlice(allocator, line);
                try kept.append(allocator, '\n');
            }
            continue;
        }
        if (in_retention) continue; // drop old [retention] body
        try kept.appendSlice(allocator, line);
        try kept.append(allocator, '\n');
    }
    try kept.appendSlice(allocator, "[retention]\n");
    try kept.writer(allocator).print("max_age_days = {d}\n", .{days});
    const f = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(kept.items);
}

/// Read [ui] port from config.toml. Default 8901; 0 is rejected (fixed port).
pub fn readUiPort(allocator: std.mem.Allocator, project_root: []const u8) !u16 {
    const config_path = try std.fs.path.join(allocator, &.{ project_root, CONFIG_DIR_NAME, CONFIG_FILE_NAME });
    defer allocator.free(config_path);
    const data = std.fs.cwd().readFileAlloc(allocator, config_path, 64 * 1024) catch return 8901;
    defer allocator.free(data);
    var in_ui = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            in_ui = std.mem.eql(u8, t, "[ui]");
            continue;
        }
        if (!in_ui) continue;
        if (std.mem.startsWith(u8, t, "port")) {
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
            const port = std.fmt.parseInt(u16, val, 10) catch continue;
            if (port == 0) continue;
            return port;
        }
    }
    return 8901;
}

const testing = std.testing;

test "uuid format" {
    const id = try newProjectId(testing.allocator);
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 36), id.len);
    try testing.expect(id[8] == '-' and id[13] == '-' and id[18] == '-' and id[23] == '-');
}
