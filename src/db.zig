// SQLite persistence layer. All SQL lives here — callers use typed helpers.
// Migrations are explicit and versioned; every change runs in a transaction.

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

pub const DbError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    MigrateFailed,
    OutOfMemory,
};

pub const Db = struct {
    handle: ?*c.sqlite3,

    pub fn open(path: [:0]const u8) DbError!Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |d| _ = c.sqlite3_close(d);
            return DbError.OpenFailed;
        }
        // Crash resistance basics.
        _ = c.sqlite3_busy_timeout(db, 5000);
        if (c.sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;", null, null, null) != c.SQLITE_OK) {
            _ = c.sqlite3_close(db);
            return DbError.OpenFailed;
        }
        return .{ .handle = db };
    }

    pub fn close(self: *Db) void {
        if (self.handle) |h| {
            _ = c.sqlite3_close(h);
            self.handle = null;
        }
    }

    pub fn exec(self: *Db, sql: [:0]const u8) DbError!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &errmsg);
        if (errmsg) |m| c.sqlite3_free(m);
        if (rc != c.SQLITE_OK) return DbError.ExecFailed;
    }

    pub fn lastRowId(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) DbError!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        return .{ .stmt = stmt.? };
    }

    pub fn migrate(self: *Db, allocator: std.mem.Allocator) DbError!void {
        try self.exec("BEGIN IMMEDIATE;");
        errdefer self.exec("ROLLBACK;") catch {};
        self.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations(
            \\  version INTEGER PRIMARY KEY,
            \\  applied_at INTEGER NOT NULL
            \\);
        ) catch return DbError.MigrateFailed;
        var applied = self.appliedVersions(allocator) catch return DbError.MigrateFailed;
        defer applied.deinit();
        for (migrations) |m| {
            if (applied.get(m.version) != null) continue;
            self.exec(m.sql) catch return DbError.MigrateFailed;
            var buf: [128]u8 = undefined;
            const stmt = std.fmt.bufPrintZ(
                &buf,
                "INSERT INTO schema_migrations(version, applied_at) VALUES ({d}, {d});",
                .{ m.version, std.time.milliTimestamp() },
            ) catch return DbError.OutOfMemory;
            self.exec(stmt) catch return DbError.MigrateFailed;
        }
        try self.exec("COMMIT;");
    }

    const Migration = struct {
        version: u32,
        sql: [:0]const u8,
    };

    const migrations = [_]Migration{
        .{
            .version = 1,
            .sql =
            \\CREATE TABLE IF NOT EXISTS projects(
            \\  id TEXT PRIMARY KEY,
            \\  path TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS sessions(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  project_id TEXT NOT NULL REFERENCES projects(id),
            \\  command TEXT NOT NULL,
            \\  argv_json TEXT NOT NULL DEFAULT '[]',
            \\  cwd TEXT NOT NULL DEFAULT '',
            \\  started_at INTEGER NOT NULL,
            \\  ended_at INTEGER,
            \\  exit_code INTEGER,
            \\  status TEXT NOT NULL DEFAULT 'running'
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id, id);
            ,
        },
        .{
            .version = 2,
            .sql =
            \\CREATE TABLE IF NOT EXISTS events(
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  session_id INTEGER NOT NULL REFERENCES sessions(id),
            \\  seq INTEGER NOT NULL,
            \\  ts INTEGER NOT NULL,
            \\  type TEXT NOT NULL,
            \\  path TEXT NOT NULL DEFAULT '',
            \\  prev_hash TEXT,
            \\  new_hash TEXT,
            \\  size INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, seq);
            ,
        },
        .{
            .version = 3,
            .sql =
            \\ALTER TABLE events ADD COLUMN prev_path TEXT NOT NULL DEFAULT '';
            ,
        },
        .{
            .version = 4,
            .sql =
            \\ALTER TABLE sessions ADD COLUMN branch TEXT NOT NULL DEFAULT 'main';
            ,
        },
    };

    fn appliedVersions(self: *Db, allocator: std.mem.Allocator) DbError!std.AutoHashMap(u32, void) {
        var map = std.AutoHashMap(u32, void).init(allocator);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, "SELECT version FROM schema_migrations;", -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const v = c.sqlite3_column_int(stmt, 0);
            map.put(@intCast(v), {}) catch return DbError.OutOfMemory;
        }
        return map;
    }
};

/// RAII wrapper around a prepared statement.
pub const Stmt = struct {
    stmt: *c.sqlite3_stmt,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    pub fn bindText(self: *Stmt, idx: c_int, value: []const u8) DbError!void {
        // SQLITE_TRANSIENT (-1): sqlite copies the bytes.
        const rc = c.sqlite3_bind_text(
            self.stmt,
            idx,
            value.ptr,
            @intCast(value.len),
            @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))),
        );
        if (rc != c.SQLITE_OK) return DbError.StepFailed;
    }

    pub fn bindInt64(self: *Stmt, idx: c_int, value: i64) DbError!void {
        if (c.sqlite3_bind_int64(self.stmt, idx, value) != c.SQLITE_OK)
            return DbError.StepFailed;
    }

    pub fn bindNull(self: *Stmt, idx: c_int) DbError!void {
        if (c.sqlite3_bind_null(self.stmt, idx) != c.SQLITE_OK)
            return DbError.StepFailed;
    }

    /// Step once. Returns true on ROW, false on DONE.
    pub fn step(self: *Stmt) DbError!bool {
        return switch (c.sqlite3_step(self.stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => DbError.StepFailed,
        };
    }

    pub fn columnInt64(self: *Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, idx);
    }

    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, idx);
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, idx));
        if (ptr == null or len == 0) return "";
        return ptr[0..len];
    }

    pub fn columnIsNull(self: *Stmt, idx: c_int) bool {
        return c.sqlite3_column_type(self.stmt, idx) == c.SQLITE_NULL;
    }
};

/// Escape a string as a JSON string literal (caller owns result).
pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |ch| {
        if (ch < 0x20) {
            switch (ch) {
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.writer(allocator).print("\\u{x:0>4}", .{ch}),
            }
        } else switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "jsonEscape" {
    const s = try jsonEscape(testing.allocator, "a\"b\\c\n");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", s);
}
