// Session supervision: launch, observe, and finalize a recorded command.
// stdio is inherited so interactive agents behave normally. SIGINT/SIGTERM
// are forwarded to the child; the session row is always finalized.

const std = @import("std");
const tty = @cImport(@cInclude("unistd.h"));
const db = @import("db.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const branch = @import("branch.zig");
const ignore = @import("ignore.zig");
const record = @import("record.zig");
const events = @import("events.zig");
const git = @import("git.zig");

pub var child_umask: std.c.mode_t = 0o022;

var child_pgid: std.atomic.Value(std.posix.pid_t) = std.atomic.Value(std.posix.pid_t).init(-1);
var got_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn forwardSignal(sig: i32) callconv(.c) void {
    got_signal.store(true, .seq_cst);
    const pgid = child_pgid.load(.seq_cst);
    if (pgid > 0) {
        // Kill the whole process group so agent subprocess trees die too.
        // Negative pid targets the group; async-signal-safe, ignore errors.
        const neg: std.posix.pid_t = -pgid;
        std.posix.kill(neg, @intCast(sig)) catch {};
    }
}

fn installForwarding() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = forwardSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub const SessionStatus = enum {
    success,
    failed,
    signaled,
    interrupted,

    pub fn fromExit(term: std.process.Child.Term, was_interrupted: bool) SessionStatus {
        if (was_interrupted) return .interrupted;
        return switch (term) {
            .Exited => |code| if (code == 0) .success else .failed,
            else => .signaled,
        };
    }

    pub fn name(self: SessionStatus) []const u8 {
        return switch (self) {
            .success => "success",
            .failed => "failed",
            .signaled => "signaled",
            .interrupted => "interrupted",
        };
    }
};

pub const SessionRow = struct {
    id: i64,
    command: []u8,
    cwd: []u8,
    started_at: i64,
    ended_at: ?i64,
    exit_code: ?i64,
    status: []u8,

    pub fn deinit(self: *SessionRow, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.status);
    }
};

/// Zero-padded 3-digit session id for display ("018").
pub fn padId(allocator: std.mem.Allocator, id: i64) ![]u8 {
    if (id < 0) return std.fmt.allocPrint(allocator, "{d}", .{id});
    if (id < 10) return std.fmt.allocPrint(allocator, "00{d}", .{id});
    if (id < 100) return std.fmt.allocPrint(allocator, "0{d}", .{id});
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

/// HH:MM:SS clock time from epoch millis (UTC rendering; v0.1).
pub fn formatClock(allocator: std.mem.Allocator, millis: i64) ![]u8 {
    if (!validTimestamp(millis)) return allocator.dupe(u8, "Invalid timestamp");
    const secs: i64 = @divTrunc(millis, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const day_seconds = epoch.getDaySeconds();
    const h: u8 = @intCast(day_seconds.getHoursIntoDay());
    const m: u8 = @intCast(day_seconds.getMinutesIntoHour());
    const s: u8 = @intCast(day_seconds.getSecondsIntoMinute());
    var buf: [8]u8 = undefined;
    buf[0] = '0' + h / 10;
    buf[1] = '0' + h % 10;
    buf[2] = ':';
    buf[3] = '0' + m / 10;
    buf[4] = '0' + m % 10;
    buf[5] = ':';
    buf[6] = '0' + s / 10;
    buf[7] = '0' + s % 10;
    return allocator.dupe(u8, &buf);
}

/// Human duration: "47m 18s", "1h12m", "3h04m", "12s".
pub fn formatDuration(allocator: std.mem.Allocator, millis: i64) ![]u8 {
    const total_s: i64 = @divTrunc(millis, 1000);
    const h = @divTrunc(total_s, 3600);
    const m = @divTrunc(@mod(total_s, 3600), 60);
    const s = @mod(total_s, 60);
    if (h > 0) return std.fmt.allocPrint(allocator, "{d}h{d:0>2}m", .{ @as(u64, @intCast(h)), @as(u64, @intCast(m)) });
    if (m > 0) return std.fmt.allocPrint(allocator, "{d}m {d:0>2}s", .{ @as(u64, @intCast(m)), @as(u64, @intCast(s)) });
    return std.fmt.allocPrint(allocator, "{d}s", .{s});
}

/// Validate stored endpoints before subtracting; legacy/corrupt rows may span i64.
pub fn formatElapsed(allocator: std.mem.Allocator, started: i64, ended: i64) ![]u8 {
    if (!validTimestamp(started) or !validTimestamp(ended) or ended < started)
        return allocator.dupe(u8, "Invalid duration");
    return formatDuration(allocator, ended - started);
}

// UTC milliseconds in the supported civil-calendar range, 1970 through 9999.
pub const max_timestamp_ms: i64 = 253402300799999;
pub fn validTimestamp(millis: i64) bool {
    return millis >= 0 and millis <= max_timestamp_ms;
}

pub fn formatStarted(allocator: std.mem.Allocator, millis: i64) ![]u8 {
    if (!validTimestamp(millis)) return allocator.dupe(u8, "Invalid timestamp");
    const secs: i64 = @divTrunc(millis, 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const h = day_seconds.getHoursIntoDay();
    const m = day_seconds.getMinutesIntoHour();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, h, m },
    );
}

fn joinCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (argv, 0..) |a, i| {
        total += a.len;
        if (i + 1 < argv.len) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (argv, 0..) |a, i| {
        @memcpy(buf[pos .. pos + a.len], a);
        pos += a.len;
        if (i + 1 < argv.len) {
            buf[pos] = ' ';
            pos += 1;
        }
    }
    return buf;
}

fn argvJson(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (argv, 0..) |a, i| {
        if (i > 0) try out.append(allocator, ',');
        const esc = try db.jsonEscape(allocator, a);
        defer allocator.free(esc);
        try out.appendSlice(allocator, esc);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn dbPath(allocator: std.mem.Allocator) ![:0]u8 {
    const base = if (std.posix.getenv("XDG_DATA_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "annalist" })
    else if (std.posix.getenv("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".local", "share", "annalist" })
    else
        return error.MissingHome;
    defer allocator.free(base);
    return std.fs.path.joinZ(allocator, &.{ base, "annalist.db" });
}

pub fn openDb(allocator: std.mem.Allocator) !db.Db {
    const path = try dbPath(allocator);
    defer allocator.free(path);
    // Ensure the directory exists.
    {
        var created = std.fs.cwd().makeOpenPath(std.fs.path.dirname(path).?, .{ .iterate = true }) catch
            return error.CannotCreateDataDir;
        created.close();
    }
    var database = try db.Db.open(path);
    errdefer database.close();
    try database.migrate(allocator);
    return database;
}

pub fn ensureProject(
    database: *db.Db,
    project_id: []const u8,
    project_path: []const u8,
) !void {
    var stmt = try database.prepare("INSERT OR IGNORE INTO projects(id, path, created_at) VALUES (?1, ?2, ?3);");
    defer stmt.finalize();
    try stmt.bindText(1, project_id);
    try stmt.bindText(2, project_path);
    try stmt.bindInt64(3, std.time.milliTimestamp());
    _ = try stmt.step();
}

/// Run the child, record the session, propagate the exit code.
/// Never returns normally: exits the process with the child's outcome.
pub fn runSession(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    project_root: []const u8,
    child_argv: []const []const u8,
    branch_override: ?[]const u8,
) !void {
    var database = try openDb(allocator);
    defer database.close();
    try ensureProject(&database, project_id, project_root);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const command = try joinCommand(allocator, child_argv);
    defer allocator.free(command);
    const argv_json = try argvJson(allocator, child_argv);
    defer allocator.free(argv_json);
    const started = std.time.milliTimestamp();

    var ins = try database.prepare(
        "INSERT INTO sessions(project_id, command, argv_json, cwd, started_at, status, branch) VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6);",
    );
    defer ins.finalize();
    try ins.bindText(1, project_id);
    try ins.bindText(2, command);
    try ins.bindText(3, argv_json);
    try ins.bindText(4, cwd);
    try ins.bindInt64(5, started);
    if (branch_override) |bo| {
        if (!branch.validName(bo)) return error.BadBranchName;
        try ins.bindText(6, bo);
    } else {
        const current = try config.readCurrentBranch(allocator, project_root);
        defer allocator.free(current);
        try ins.bindText(6, current);
    }
    _ = try ins.step();
    const session_id = database.lastRowId();
    errdefer finalize(&database, session_id, std.time.milliTimestamp(), null, .failed) catch {};

    printRecordingHeader(session_id, command, project_root);

    // Observation setup: user patterns over defaults, baseline scan + blobs.
    const user_patterns = try config.readIgnorePatterns(allocator, project_root);
    defer {
        for (user_patterns) |p| allocator.free(p);
        allocator.free(user_patterns);
    }
    var all_patterns: std.ArrayList([]const u8) = .empty;
    defer all_patterns.deinit(allocator);
    try all_patterns.appendSlice(allocator, &ignore.default_ignores);
    try all_patterns.appendSlice(allocator, user_patterns);

    var queue = events.Queue{};
    defer queue.deinit(allocator);
    var recorder = try record.Recorder.init(allocator, project_root, all_patterns.items, &queue);
    defer recorder.deinit();

    var seq: i64 = 0;
    try events.insert(&database, session_id, &seq, &.{
        .ts = started,
        .type = "session_started",
        .path = "",
        .path_owned = false,
        .prev_hash = null,
        .new_hash = null,
        .size = 0,
    });
    // Best-effort git snapshot at session start (silent outside repos).
    if (try git.capture(allocator, project_root)) |g| {
        var gs = g;
        defer gs.deinit(allocator);
        try events.insert(&database, session_id, &seq, &.{
            .ts = std.time.milliTimestamp(),
            .type = "git_state",
            .path = gs.branch,
            .path_owned = false,
            .prev_path = gs.head,
            .prev_hash = null,
            .new_hash = null,
            .size = gs.dirty,
        });
    }

    installForwarding();
    var child = std.process.Child.init(child_argv, allocator);
    child.pgid = 0;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = std.c.umask(child_umask);
    const spawned = child.spawn();
    _ = std.c.umask(0o077);
    spawned catch |err| {
        // Spawn failure is itself a finalized session.
        try events.insert(&database, session_id, &seq, &.{
            .ts = std.time.milliTimestamp(),
            .type = "error",
            .path = "",
            .path_owned = false,
            .prev_hash = null,
            .new_hash = null,
            .size = 0,
        });
        try finalize(&database, session_id, std.time.milliTimestamp(), null, .failed);
        log.err("failed to launch '{s}': {s}", .{ child_argv[0], @errorName(err) });
        std.process.exit(127);
    };
    const process_group = child.id;
    child_pgid.store(process_group, .seq_cst);
    // Give interactive commands the controlling terminal. A separate background
    // group would otherwise stop on its first read (SIGTTIN).
    const tty_group = tty.tcgetpgrp(std.posix.STDIN_FILENO);
    const foreground: ?std.posix.pid_t = if (tty_group > 0) tty_group else null;
    var old_ttou: std.posix.Sigaction = undefined;
    if (foreground != null) {
        const ignore_ttou = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.TTOU, &ignore_ttou, &old_ttou);
        _ = tty.tcsetpgrp(std.posix.STDIN_FILENO, process_group);
        std.posix.kill(-process_group, std.posix.SIG.CONT) catch {};
    }
    var reaped = false;
    errdefer {
        if (!reaped) {
            std.posix.kill(-process_group, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
        }
        if (foreground) |group| {
            _ = tty.tcsetpgrp(std.posix.STDIN_FILENO, group);
            std.posix.sigaction(std.posix.SIG.TTOU, &old_ttou, null);
        }
        child_pgid.store(-1, .seq_cst);
    }
    const proc_started_ts = std.time.milliTimestamp();
    try events.insert(&database, session_id, &seq, &.{
        .ts = proc_started_ts,
        .type = "process_started",
        .path = "",
        .path_owned = false,
        .prev_hash = null,
        .new_hash = null,
        .size = 0,
    });
    recorder.startPolling() catch |err| {
        recorder.failed.store(true, .seq_cst);
        log.warn("filesystem polling unavailable: {s}", .{@errorName(err)});
    };
    // Stop and join before recorder/queue destruction on every error path.
    defer recorder.stopPolling();
    var waiter = ChildWait{ .child = &child };
    const wait_thread = try std.Thread.spawn(.{}, ChildWait.run, .{&waiter});
    while (!waiter.done.load(.acquire)) {
        persistQueue(allocator, &database, session_id, &seq, &queue) catch |err| {
            std.posix.kill(-process_group, std.posix.SIG.KILL) catch {};
            wait_thread.join();
            reaped = true;
            recorder.stopPolling();
            return err;
        };
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    wait_thread.join();
    reaped = true;
    if (foreground) |group| {
        _ = tty.tcsetpgrp(std.posix.STDIN_FILENO, group);
        std.posix.sigaction(std.posix.SIG.TTOU, &old_ttou, null);
    }
    const term = waiter.term orelse return error.ChildWaitFailed;
    child_pgid.store(-1, .seq_cst);
    recorder.stopPolling();
    // Final synchronous pass catches anything the poller missed.
    recorder.rescan() catch |err| {
        recorder.failed.store(true, .seq_cst);
        log.warn("final scan failed: {s}", .{@errorName(err)});
    };
    // Drain polled file events into the DB in detection order.
    const drained = try queue.drain(allocator);
    defer {
        for (drained) |*ev| ev.deinit(allocator);
        allocator.free(drained);
    }
    for (drained) |*ev| {
        try events.insert(&database, session_id, &seq, ev);
    }

    const ended = std.time.milliTimestamp();
    const was_interrupted = got_signal.load(.seq_cst);
    const status = if (recorder.failed.load(.seq_cst)) SessionStatus.failed else SessionStatus.fromExit(term, was_interrupted);
    if (recorder.failed.load(.seq_cst)) log.err("recording incomplete: one or more filesystem scans failed", .{});
    const exit_code: ?i64 = switch (term) {
        .Exited => |c| c,
        .Signal => |s| 128 + @as(i64, s),
        .Stopped => |s| 128 + @as(i64, s),
        .Unknown => |u| @as(i64, u),
    };
    try events.insert(&database, session_id, &seq, &.{
        .ts = ended,
        .type = "process_exited",
        .path = "",
        .path_owned = false,
        .prev_hash = null,
        .new_hash = null,
        .size = 0,
    });
    if (try git.capture(allocator, project_root)) |g| {
        var gs = g;
        defer gs.deinit(allocator);
        try events.insert(&database, session_id, &seq, &.{
            .ts = ended,
            .type = "git_state",
            .path = gs.branch,
            .path_owned = false,
            .prev_path = gs.head,
            .prev_hash = null,
            .new_hash = null,
            .size = gs.dirty,
        });
    }
    try events.insert(&database, session_id, &seq, &.{
        .ts = ended,
        .type = "session_ended",
        .path = "",
        .path_owned = false,
        .prev_hash = null,
        .new_hash = null,
        .size = 0,
    });
    try finalize(&database, session_id, ended, exit_code, status);

    const counts = events.countFileEvents(&database, session_id) catch events.Counts{};
    const total = events.countAll(&database, session_id) catch 0;
    printSummary(session_id, ended - started, exit_code, status, counts, total);

    // Propagate the outcome to our own exit code.
    const code: u8 = if (exit_code) |c| @truncate(@as(u64, @bitCast(c))) else 1;
    std.process.exit(if (recorder.failed.load(.seq_cst) and code == 0) 1 else code);
}

fn finalize(
    database: *db.Db,
    session_id: i64,
    ended: i64,
    exit_code: ?i64,
    status: SessionStatus,
) !void {
    var stmt = try database.prepare(
        "UPDATE sessions SET ended_at = ?1, exit_code = ?2, status = ?3 WHERE id = ?4;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, ended);
    if (exit_code) |c| try stmt.bindInt64(2, c) else try stmt.bindNull(2);
    try stmt.bindText(3, status.name());
    try stmt.bindInt64(4, session_id);
    _ = try stmt.step();
}

fn printRecordingHeader(session_id: i64, command: []const u8, project_root: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    const gpa = std.heap.page_allocator;
    const id_s = padId(gpa, session_id) catch "?";
    defer if (!std.mem.eql(u8, id_s, "?")) gpa.free(id_s);
    out.print(
        \\● Annalist recording
        \\
        \\  Session   {s}
        \\  Command   {s}
        \\  Project   {s}
        \\
        \\Press Ctrl+C to stop.
        \\
    , .{ id_s, command, project_root }) catch return;
    out.flush() catch return;
}

fn printSummary(
    session_id: i64,
    elapsed_ms: i64,
    exit_code: ?i64,
    status: SessionStatus,
    counts: events.Counts,
    total: i64,
) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    const gpa = std.heap.page_allocator;
    const dur = formatDuration(gpa, elapsed_ms) catch "??";
    defer if (!std.mem.eql(u8, dur, "??")) gpa.free(dur);
    const id_s = padId(gpa, session_id) catch "?";
    defer if (!std.mem.eql(u8, id_s, "?")) gpa.free(id_s);
    out.print(
        \\
        \\✓ Session complete
        \\
        \\  Duration       {s}
        \\  Files changed  {d}
        \\  Events         {d}
        \\  Exit status    {any}
        \\  Status         {s}
        \\
        \\Inspect:
        \\  annalist inspect {s}
        \\
    , .{ dur, counts.changed(), total, exit_code, status.name(), id_s }) catch return;
    out.flush() catch return;
}

const testing = std.testing;

test "formatDuration" {
    const a = try formatDuration(testing.allocator, 47 * 60 * 1000 + 18 * 1000);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("47m 18s", a);
    const b = try formatDuration(testing.allocator, 72 * 60 * 1000);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("1h12m", b);
    const c = try formatDuration(testing.allocator, 9000);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("9s", c);
}

const ChildWait = struct {
    child: *std.process.Child,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    term: ?std.process.Child.Term = null,
    fn run(self: *ChildWait) void {
        self.term = self.child.wait() catch null;
        self.done.store(true, .release);
    }
};
fn persistQueue(allocator: std.mem.Allocator, database: *db.Db, id: i64, seq: *i64, queue: *events.Queue) !void {
    const batch = try queue.drain(allocator);
    defer {
        for (batch) |*ev| ev.deinit(allocator);
        allocator.free(batch);
    }
    if (batch.len == 0) return;
    try database.exec("BEGIN IMMEDIATE;");
    errdefer database.exec("ROLLBACK;") catch {};
    for (batch) |*ev| try events.insert(database, id, seq, ev);
    try database.exec("COMMIT;");
}

test "timestamp formatting bounds tolerate malformed history" {
    const a = std.testing.allocator;
    for ([_]i64{ -1, std.math.maxInt(i64), std.math.minInt(i64) }) |value| {
        const formatted = try formatStarted(a, value);
        defer a.free(formatted);
        try std.testing.expectEqualStrings("Invalid timestamp", formatted);
    }
    const last = try formatStarted(a, max_timestamp_ms);
    defer a.free(last);
    try std.testing.expectEqualStrings("9999-12-31 23:59", last);
}

test "stored duration rejects malformed endpoints before subtraction" {
    const a = std.testing.allocator;
    const invalid = try formatElapsed(a, std.math.minInt(i64), std.math.maxInt(i64));
    defer a.free(invalid);
    try std.testing.expectEqualStrings("Invalid duration", invalid);
    const reversed = try formatElapsed(a, 1000, 0);
    defer a.free(reversed);
    try std.testing.expectEqualStrings("Invalid duration", reversed);
    const valid = try formatElapsed(a, 1000, 10000);
    defer a.free(valid);
    try std.testing.expectEqualStrings("9s", valid);
}
