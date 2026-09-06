// Session supervision: launch, observe, and finalize a recorded command.
// stdio is inherited so interactive agents behave normally. SIGINT/SIGTERM
// are forwarded to the child; the session row is always finalized.

const std = @import("std");
const db = @import("db.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const branch = @import("branch.zig");
const ignore = @import("ignore.zig");
const record = @import("record.zig");
const events = @import("events.zig");
const git = @import("git.zig");

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
    if (h > 0) return std.fmt.allocPrint(allocator, "{d}h{d:0>2}m", .{ h, m });
    if (m > 0) return std.fmt.allocPrint(allocator, "{d}m {d:0>2}s", .{ m, s });
    return std.fmt.allocPrint(allocator, "{d}s", .{s});
}

pub fn formatStarted(allocator: std.mem.Allocator, millis: i64) ![]u8 {
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
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |err| {
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
    // Put the child in its own process group so interrupts reach the whole
    // subtree (agents spawn servers, test runners, etc.). Best-effort: the
    // child may exec before we set this; the direct kill still applies.
    std.posix.setpgid(child.id, child.id) catch {};
    child_pgid.store(child.id, .seq_cst);
    recorder.startPolling() catch |err| {
        log.warn("filesystem polling unavailable: {s}", .{@errorName(err)});
    };
    const term = child.wait() catch |err| {
        recorder.stopPolling();
        try finalize(&database, session_id, std.time.milliTimestamp(), null, .failed);
        log.err("failed waiting for child: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    child_pgid.store(-1, .seq_cst);
    recorder.stopPolling();
    // Final synchronous pass catches anything the poller missed.
    recorder.rescan() catch |err| {
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
    const status = SessionStatus.fromExit(term, was_interrupted);
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
    std.process.exit(code);
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
