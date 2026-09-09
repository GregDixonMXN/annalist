// `annalist sessions` and `annalist inspect` rendering.

const std = @import("std");
const db = @import("db.zig");
const session = @import("session.zig");
const events = @import("events.zig");
const store = @import("store.zig");
const hash = @import("hash.zig");
const diff = @import("diff.zig");

pub fn listSessions(allocator: std.mem.Allocator, database: *db.Db, project_id: []const u8, branch_filter: ?[]const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    var stmt = try database.prepare(
        "SELECT id, command, started_at, ended_at, exit_code, status, branch FROM sessions WHERE project_id = ?1 AND (?2 IS NULL OR branch = ?2) ORDER BY id ASC;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, project_id);
    if (branch_filter) |b| try stmt.bindText(2, b) else try stmt.bindNull(2);

    try out.writeAll("ID   BRANCH        COMMAND              STARTED             DURATION   CHANGES   STATUS\n");
    var count: usize = 0;
    while (try stmt.step()) {
        const id = stmt.columnInt64(0);
        const command = stmt.columnText(1);
        const started = stmt.columnInt64(2);
        const ended = if (stmt.columnIsNull(3)) started else stmt.columnInt64(3);
        const status = stmt.columnText(5);
        const branch = stmt.columnText(6);

        const started_s = try session.formatStarted(allocator, started);
        defer allocator.free(started_s);
        const dur = try session.formatElapsed(allocator, started, ended);
        defer allocator.free(dur);
        const changes = events.countFileEvents(database, id) catch events.Counts{};

        // Truncate long commands for the table.
        const cmd_show = if (command.len > 20) command[0..20] else command;
        const id_s = try session.padId(allocator, id);
        defer allocator.free(id_s);
        const changes_s = try std.fmt.allocPrint(allocator, "{d}", .{changes.changed()});
        defer allocator.free(changes_s);
        try out.writeAll(id_s);
        try out.writeAll("  ");
        const branch_show = if (branch.len > 12) branch[0..12] else branch;
        try out.writeAll(branch_show);
        var bpad: usize = 12;
        while (bpad > branch_show.len) : (bpad -= 1) try out.writeAll(" ");
        try out.writeAll("  ");
        try out.writeAll(cmd_show);
        var pad: usize = 20;
        while (pad > cmd_show.len) : (pad -= 1) try out.writeAll(" ");
        try out.writeAll(" ");
        try out.writeAll(started_s);
        try out.writeAll("  ");
        try out.writeAll(dur);
        pad = 8;
        while (pad > dur.len) : (pad -= 1) try out.writeAll(" ");
        try out.writeAll("  ");
        try out.writeAll(changes_s);
        pad = 9;
        while (pad > changes_s.len) : (pad -= 1) try out.writeAll(" ");
        try out.writeAll(status);
        try out.writeAll("\n");
        count += 1;
    }
    if (count == 0) {
        try out.writeAll("(no sessions yet — run `annalist run -- <command>`)\n");
    }
    try out.flush();
}

pub fn inspectSession(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    id_text: []const u8,
    as_json: bool,
    file: ?[]const u8,
) !void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch {
        return error.BadSessionId;
    };
    var stmt = try database.prepare(
        "SELECT command, cwd, started_at, ended_at, exit_code, status FROM sessions WHERE id = ?1 AND project_id = ?2;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    try stmt.bindText(2, project_id);
    if (!(try stmt.step())) return error.NoSuchSession;

    // Copy out before finalizing.
    const command = try allocator.dupe(u8, stmt.columnText(0));
    defer allocator.free(command);
    const cwd = try allocator.dupe(u8, stmt.columnText(1));
    defer allocator.free(cwd);
    const started = stmt.columnInt64(2);
    const ended: ?i64 = if (stmt.columnIsNull(3)) null else stmt.columnInt64(3);
    const exit_code: ?i64 = if (stmt.columnIsNull(4)) null else stmt.columnInt64(4);
    const status = try allocator.dupe(u8, stmt.columnText(5));
    defer allocator.free(status);

    if (as_json) {
        return printJson(allocator, id, command, cwd, started, ended, exit_code, status);
    }

    if (file) |f| {
        return printFileHistory(allocator, database, project_root, id, f);
    }

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    const started_s = try session.formatStarted(allocator, started);
    defer allocator.free(started_s);
    const dur_s = if (ended) |e| try session.formatElapsed(allocator, started, e) else try allocator.dupe(u8, "running");
    defer allocator.free(dur_s);
    const id_s = try session.padId(allocator, id);
    defer allocator.free(id_s);

    const counts = events.countFileEvents(database, id) catch events.Counts{};
    const total = events.countAll(database, id) catch 0;

    try out.print(
        \\Annalist Session {s}
        \\
        \\Command:        {s}
        \\Working dir:    {s}
        \\Started:        {s}
        \\Duration:       {s}
        \\Exit status:    {any}
        \\Status:         {s}
        \\
        \\File changes
        \\────────────────────────────
        \\Created        {d}
        \\Modified       {d}
        \\Deleted        {d}
        \\Renamed        {d}
        \\
        \\Events        {d}
        \\
        \\Timeline
        \\────────────────────────────
        \\
    , .{
        id_s,
        command,
        cwd,
        started_s,
        dur_s,
        exit_code,
        status,
        counts.created,
        counts.modified,
        counts.deleted,
        counts.renamed,
        total,
    });
    try printTimeline(allocator, database, id, out);
    try out.flush();
}

fn eventLabel(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "session_started")) return "SESSION STARTED";
    if (std.mem.eql(u8, t, "session_ended")) return "SESSION ENDED";
    if (std.mem.eql(u8, t, "process_started")) return "PROCESS STARTED";
    if (std.mem.eql(u8, t, "process_exited")) return "PROCESS EXITED";
    if (std.mem.eql(u8, t, "file_created")) return "CREATE";
    if (std.mem.eql(u8, t, "file_modified")) return "MODIFY";
    if (std.mem.eql(u8, t, "file_deleted")) return "DELETE";
    if (std.mem.eql(u8, t, "file_renamed")) return "RENAME";
    if (std.mem.eql(u8, t, "snapshot_created")) return "SNAPSHOT";
    if (std.mem.eql(u8, t, "git_state")) return "GIT";
    if (std.mem.eql(u8, t, "error")) return "ERROR";
    return t;
}

fn printFileHistory(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_root: []const u8,
    session_id: i64,
    path: []const u8,
) !void {
    var out_buf: [8192]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&out_buf);
    const out = &fw.interface;

    var stmt = try database.prepare(
        "SELECT ts, type, prev_hash, new_hash, size, prev_path FROM events WHERE session_id = ?1 AND (path = ?2 OR prev_path = ?2) ORDER BY seq ASC;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    try stmt.bindText(2, path);

    var shown: usize = 0;
    while (try stmt.step()) {
        const ts = stmt.columnInt64(0);
        const t = stmt.columnText(1);
        const has_prev = !stmt.columnIsNull(2);
        const has_new = !stmt.columnIsNull(3);
        const size = stmt.columnInt64(4);
        const clock = try session.formatClock(allocator, ts);
        defer allocator.free(clock);
        shown += 1;

        var before: ?[]u8 = null;
        defer if (before) |b| allocator.free(b);
        var after: ?[]u8 = null;
        defer if (after) |a| allocator.free(a);
        if (has_prev) {
            const h = stmt.columnText(2);
            before = store.get(allocator, project_root, h, 1 * 1024 * 1024) catch null;
        }
        if (has_new) {
            const h = stmt.columnText(3);
            after = store.get(allocator, project_root, h, 1 * 1024 * 1024) catch null;
        }

        try out.print("{s}  {s} {s} ({d} bytes)\n", .{ clock, eventLabel(t), path, size });
        if (std.mem.eql(u8, t, "file_deleted")) {
            if (before) |b| {
                if (hash.isBinary(b)) {
                    try out.print("[binary file, {d} bytes, content not shown]\n", .{b.len});
                } else {
                    try printCapped(out, b);
                }
            } else {
                try out.writeAll("[before-state unavailable]\n");
            }
        } else if (std.mem.eql(u8, t, "file_created")) {
            if (after) |a| {
                if (hash.isBinary(a)) {
                    try out.print("[binary file, {d} bytes, content not shown]\n", .{a.len});
                } else {
                    try printCapped(out, a);
                }
            }
        } else {
            if (before == null and after == null) {
                try out.writeAll("[content unavailable]\n");
            } else if (before) |b| {
                if (after) |a| {
                    if (hash.isBinary(b) or hash.isBinary(a)) {
                        try out.writeAll("[binary file changed]\n");
                    } else {
                        const hunks = try diff.diffLines(allocator, b, a);
                        defer allocator.free(hunks);
                        try out.writeAll("--- before\n+++ after\n");
                        for (hunks) |h| {
                            try out.print("{c} {s}\n", .{ h.prefix, h.line });
                        }
                    }
                }
            } else if (after) |a| {
                if (!hash.isBinary(a)) try printCapped(out, a);
            }
        }
        try out.writeAll("\n");
    }
    if (shown == 0) {
        try out.print("No recorded changes for '{s}' in this session.\n", .{path});
    }
    try out.flush();
}

fn printCapped(out: anytype, content: []const u8) !void {
    const cap = 20 * 1024;
    if (content.len <= cap) {
        try out.writeAll(content);
        if (content.len == 0 or content[content.len - 1] != '\n') try out.writeAll("\n");
    } else {
        try out.writeAll(content[0..cap]);
        try out.print("\n[... truncated {d} of {d} bytes ...]\n", .{ content.len - cap, content.len });
    }
}

fn printTimeline(
    allocator: std.mem.Allocator,
    database: *db.Db,
    session_id: i64,
    out: anytype,
) !void {
    var stmt = try database.prepare(
        "SELECT ts, type, path, prev_path, size FROM events WHERE session_id = ?1 ORDER BY seq ASC LIMIT 60;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    while (try stmt.step()) {
        const ts = stmt.columnInt64(0);
        const t = stmt.columnText(1);
        const path = stmt.columnText(2);
        const prev_path = stmt.columnText(3);
        const clock = try session.formatClock(allocator, ts);
        defer allocator.free(clock);
        if (std.mem.eql(u8, t, "git_state")) {
            const dirty = stmt.columnInt64(4);
            const head_show = if (prev_path.len >= 8) prev_path[0..8] else prev_path;
            try out.print("{s}  GIT {s}@{s} ({d} dirty)\n", .{ clock, path, head_show, dirty });
        } else if (path.len == 0) {
            try out.print("{s}  {s}\n", .{ clock, eventLabel(t) });
        } else if (prev_path.len > 0) {
            try out.print("{s}  {s} {s} -> {s}\n", .{ clock, eventLabel(t), prev_path, path });
        } else {
            try out.print("{s}  {s} {s}\n", .{ clock, eventLabel(t), path });
        }
    }
}

fn printJson(
    allocator: std.mem.Allocator,
    id: i64,
    command: []const u8,
    cwd: []const u8,
    started: i64,
    ended: ?i64,
    exit_code: ?i64,
    status: []const u8,
) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    const cmd_esc = try db.jsonEscape(allocator, command);
    defer allocator.free(cmd_esc);
    const cwd_esc = try db.jsonEscape(allocator, cwd);
    defer allocator.free(cwd_esc);
    const status_esc = try db.jsonEscape(allocator, status);
    defer allocator.free(status_esc);

    try out.print(
        \\{{"id":{d},"command":{s},"cwd":{s},"started_at":{d},"ended_at":{any},"exit_code":{any},"status":{s}}}
        \\
    , .{ id, cmd_esc, cwd_esc, started, ended, exit_code, status_esc });
    try out.flush();
}

/// Compare what two sessions each changed: per-session file event sets.
/// (Project end-state comparison would need full history replay; the
/// per-session change sets answer "what did each agent run do".)
pub fn diffSessions(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    a_text: []const u8,
    b_text: []const u8,
) !void {
    const a = std.fmt.parseInt(i64, a_text, 10) catch return error.BadSessionId;
    const b = std.fmt.parseInt(i64, b_text, 10) catch return error.BadSessionId;
    try assertSession(database, project_id, a);
    try assertSession(database, project_id, b);

    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    const a_s = try session.padId(allocator, a);
    defer allocator.free(a_s);
    const b_s = try session.padId(allocator, b);
    defer allocator.free(b_s);
    try out.print("session {s} changed:\n", .{a_s});
    try printChangeSet(allocator, database, a, out);
    try out.print("session {s} changed:\n", .{b_s});
    try printChangeSet(allocator, database, b, out);
    try out.flush();
}

/// One line per changed path: + created, ~ modified, - deleted, > renamed.
fn printChangeSet(
    allocator: std.mem.Allocator,
    database: *db.Db,
    session_id: i64,
    out: anytype,
) !void {
    _ = allocator;
    var stmt = try database.prepare(
        "SELECT type, path, prev_path FROM events WHERE session_id = ?1 AND type LIKE 'file_%' ORDER BY seq ASC;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    var n: usize = 0;
    while (try stmt.step()) {
        const t = stmt.columnText(0);
        const path = stmt.columnText(1);
        const prev = stmt.columnText(2);
        n += 1;
        if (std.mem.eql(u8, t, "file_created")) {
            try out.print("  + {s}\n", .{path});
        } else if (std.mem.eql(u8, t, "file_modified")) {
            try out.print("  ~ {s}\n", .{path});
        } else if (std.mem.eql(u8, t, "file_deleted")) {
            try out.print("  - {s}\n", .{path});
        } else if (std.mem.eql(u8, t, "file_renamed")) {
            try out.print("  > {s} -> {s}\n", .{ prev, path });
        }
    }
    if (n == 0) try out.writeAll("  (no file changes)\n");
}

const EndState = struct {
    // path (owned) -> new_hash hex (owned) or null when unhashable.
    map: std.StringHashMap(?[]u8),
};

fn endStateDeinit(allocator: std.mem.Allocator, st: *EndState) void {
    // Keys/values freed by the caller during iteration; only the map itself.
    _ = allocator;
    st.map.deinit();
}

pub fn assertSession(database: *db.Db, project_id: []const u8, id: i64) !void {
    var stmt = try database.prepare(
        "SELECT 1 FROM sessions WHERE id = ?1 AND project_id = ?2;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    try stmt.bindText(2, project_id);
    if (!(try stmt.step())) return error.NoSuchSession;
}

/// Insert or replace path -> hash, freeing any previous entry.
fn upsert(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(?[]u8),
    path: []const u8,
    h: ?[]const u8,
) !void {
    const gop = try map.getOrPut(path);
    if (gop.found_existing) {
        if (gop.value_ptr.*) |old| allocator.free(old);
    } else {
        gop.key_ptr.* = try allocator.dupe(u8, path);
    }
    gop.value_ptr.* = if (h) |hh| try allocator.dupe(u8, hh) else null;
}

fn dropPath(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(?[]u8),
    path: []const u8,
) void {
    if (map.fetchRemove(path)) |kv| {
        allocator.free(kv.key);
        if (kv.value) |h| allocator.free(h);
    }
}

/// Last file event per path; renames move the entry to the new path.
fn endState(allocator: std.mem.Allocator, database: *db.Db, session_id: i64) !EndState {
    var map = std.StringHashMap(?[]u8).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |h| allocator.free(h);
        }
        map.deinit();
    }
    var stmt = try database.prepare(
        "SELECT type, path, prev_path, new_hash FROM events WHERE session_id = ?1 AND type LIKE 'file_%' ORDER BY seq ASC;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    while (try stmt.step()) {
        const t = stmt.columnText(0);
        const cur = stmt.columnText(1);
        if (std.mem.eql(u8, t, "file_renamed")) {
            dropPath(allocator, &map, stmt.columnText(2));
            const h: ?[]const u8 = if (stmt.columnIsNull(3)) null else stmt.columnText(3);
            try upsert(allocator, &map, cur, h);
        } else if (std.mem.eql(u8, t, "file_deleted")) {
            dropPath(allocator, &map, cur);
        } else {
            const h: ?[]const u8 = if (stmt.columnIsNull(3)) null else stmt.columnText(3);
            try upsert(allocator, &map, cur, h);
        }
    }
    return .{ .map = map };
}
