// Local read-only HTTP server (loopback only). Serves the JSON API used by
// the dashboard plus the embedded single-file UI. No mutation endpoints exist.

const std = @import("std");
const db = @import("db.zig");
const log = @import("log.zig");
const events = @import("events.zig");
const store = @import("store.zig");
const hash = @import("hash.zig");

const index_html = @embedFile("ui/index.html");

pub const DEFAULT_PORT: u16 = 8901;

pub const Server = struct {
    allocator: std.mem.Allocator,
    database: db.Db,
    project_id: []u8,
    project_root: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        database: db.Db,
        project_id: []u8,
        project_root: []u8,
    ) Server {
        return .{
            .allocator = allocator,
            .database = database,
            .project_id = project_id,
            .project_root = project_root,
        };
    }

    pub fn deinit(self: *Server) void {
        self.database.close();
        self.allocator.free(self.project_id);
        self.allocator.free(self.project_root);
    }

    pub fn serve(self: *Server, port: u16) !void {
        const addr = try std.net.Address.parseIp4("127.0.0.1", port);
        var net_server = try addr.listen(.{ .reuse_address = true });
        defer net_server.deinit();
        log.info("annalist ui on http://127.0.0.1:{d} (loopback only)", .{port});
        var out_buf: [512]u8 = undefined;
        var fw = std.fs.File.stdout().writer(&out_buf);
        try fw.interface.print("Annalist dashboard: http://127.0.0.1:{d}\n", .{port});
        try fw.interface.flush();
        while (true) {
            const conn = net_server.accept() catch |err| {
                log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            };
            self.handleConn(conn.stream) catch |err| {
                log.warn("request failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn handleConn(self: *Server, stream: std.net.Stream) !void {
        defer stream.close();
        var req_buf: [8192]u8 = undefined;
        const n = stream.read(&req_buf) catch return;
        if (n == 0) return;
        const req = req_buf[0..n];
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const line = req[0..line_end];
        var parts = std.mem.splitScalar(u8, line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;
        if (!std.mem.eql(u8, method, "GET")) {
            return self.writeResponse(stream, 405, "text/plain", "method not allowed");
        }
        // Strip query string for routing (kept separately where needed).
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |q| target[0..q] else target;
        const query = if (qmark) |q| target[q + 1 ..] else "";

        if (std.mem.eql(u8, path, "/")) {
            return self.writeResponse(stream, 200, "text/html", index_html);
        }
        if (std.mem.eql(u8, path, "/api/sessions")) {
            const body = try self.sessionsJson();
            defer self.allocator.free(body);
            return self.writeResponse(stream, 200, "application/json", body);
        }
        if (std.mem.startsWith(u8, path, "/api/sessions/")) {
            const rest = path["/api/sessions/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                // /api/sessions/:id/events
                const id_text = rest[0..slash];
                const tail = rest[slash..];
                if (!std.mem.eql(u8, tail, "/events")) {
                    return self.writeResponse(stream, 404, "text/plain", "not found");
                }
                const id = std.fmt.parseInt(i64, id_text, 10) catch {
                    return self.writeResponse(stream, 400, "text/plain", "bad id");
                };
                const body = try self.eventsJson(id);
                defer self.allocator.free(body);
                return self.writeResponse(stream, 200, "application/json", body);
            }
            const id = std.fmt.parseInt(i64, rest, 10) catch {
                return self.writeResponse(stream, 400, "text/plain", "bad id");
            };
            const body = try self.sessionJson(id) orelse {
                return self.writeResponse(stream, 404, "text/plain", "no such session");
            };
            defer self.allocator.free(body);
            return self.writeResponse(stream, 200, "application/json", body);
        }
        if (std.mem.eql(u8, path, "/api/files/history")) {
            const sid = queryParam(query, "session") orelse {
                return self.writeResponse(stream, 400, "text/plain", "missing session");
            };
            const fpath_raw = queryParam(query, "path") orelse {
                return self.writeResponse(stream, 400, "text/plain", "missing path");
            };
            const fpath = try pctDecode(self.allocator, fpath_raw);
            defer self.allocator.free(fpath);
            const id = std.fmt.parseInt(i64, sid, 10) catch {
                return self.writeResponse(stream, 400, "text/plain", "bad session");
            };
            if (std.mem.indexOf(u8, fpath, "..") != null) {
                return self.writeResponse(stream, 400, "text/plain", "bad path");
            }
            const body = try self.fileHistoryJson(id, fpath);
            defer self.allocator.free(body);
            return self.writeResponse(stream, 200, "application/json", body);
        }
        return self.writeResponse(stream, 404, "text/plain", "not found");
    }

    fn writeResponse(
        self: *Server,
        stream: std.net.Stream,
        code: u16,
        content_type: []const u8,
        body: []const u8,
    ) !void {
        _ = self;
        var buf: [4096]u8 = undefined;
        var fw = stream.writer(&buf);
        const w = &fw.interface;
        const reason: []const u8 = switch (code) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            else => "Error",
        };
        try w.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ code, reason, content_type, body.len },
        );
        try w.writeAll(body);
        try w.flush();
    }

    fn sessionsJson(self: *Server) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        var stmt = try self.database.prepare(
            "SELECT id, command, started_at, ended_at, exit_code, status FROM sessions WHERE project_id = ?1 ORDER BY id ASC;",
        );
        defer stmt.finalize();
        try stmt.bindText(1, self.project_id);
        var first = true;
        while (try stmt.step()) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const id = stmt.columnInt64(0);
            const counts = events.countFileEvents(&self.database, id) catch events.Counts{};
            const total = events.countAll(&self.database, id) catch 0;
            const cmd_esc = try db.jsonEscape(self.allocator, stmt.columnText(1));
            defer self.allocator.free(cmd_esc);
            const status_esc = try db.jsonEscape(self.allocator, stmt.columnText(5));
            defer self.allocator.free(status_esc);
            try out.writer(self.allocator).print(
                \\{{"id":{d},"command":{s},"started_at":{d},"ended_at":{any},"exit_code":{any},"status":{s},"changes":{d},"events":{d}}}
            , .{
                id,
                cmd_esc,
                stmt.columnInt64(2),
                if (stmt.columnIsNull(3)) null else stmt.columnInt64(3),
                if (stmt.columnIsNull(4)) null else stmt.columnInt64(4),
                status_esc,
                counts.changed(),
                total,
            });
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn sessionJson(self: *Server, id: i64) !?[]u8 {
        var stmt = try self.database.prepare(
            "SELECT command, cwd, started_at, ended_at, exit_code, status FROM sessions WHERE id = ?1 AND project_id = ?2;",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, self.project_id);
        if (!(try stmt.step())) return null;
        const counts = events.countFileEvents(&self.database, id) catch events.Counts{};
        const total = events.countAll(&self.database, id) catch 0;
        const cmd_esc = try db.jsonEscape(self.allocator, stmt.columnText(0));
        defer self.allocator.free(cmd_esc);
        const cwd_esc = try db.jsonEscape(self.allocator, stmt.columnText(1));
        defer self.allocator.free(cwd_esc);
        const status_esc = try db.jsonEscape(self.allocator, stmt.columnText(5));
        defer self.allocator.free(status_esc);
        const body: []u8 = try std.fmt.allocPrint(
            self.allocator,
            \\{{"id":{d},"command":{s},"cwd":{s},"started_at":{d},"ended_at":{any},"exit_code":{any},"status":{s},"changes":{d},"events":{d}}}
        ,
            .{
                id,
                cmd_esc,
                cwd_esc,
                stmt.columnInt64(2),
                if (stmt.columnIsNull(3)) null else stmt.columnInt64(3),
                if (stmt.columnIsNull(4)) null else stmt.columnInt64(4),
                status_esc,
                counts.changed(),
                total,
            },
        );
        return body;
    }

    fn eventsJson(self: *Server, id: i64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        var stmt = try self.database.prepare(
            "SELECT seq, ts, type, path, prev_path, size FROM events WHERE session_id = ?1 AND session_id IN (SELECT id FROM sessions WHERE project_id = ?2) ORDER BY seq ASC LIMIT 500;",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, self.project_id);
        var first = true;
        while (try stmt.step()) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const type_esc = try db.jsonEscape(self.allocator, stmt.columnText(2));
            defer self.allocator.free(type_esc);
            const path_esc = try db.jsonEscape(self.allocator, stmt.columnText(3));
            defer self.allocator.free(path_esc);
            const prev_esc = try db.jsonEscape(self.allocator, stmt.columnText(4));
            defer self.allocator.free(prev_esc);
            try out.writer(self.allocator).print(
                \\{{"seq":{d},"ts":{d},"type":{s},"path":{s},"prev_path":{s},"size":{d}}}
            , .{
                stmt.columnInt64(0),
                stmt.columnInt64(1),
                type_esc,
                path_esc,
                prev_esc,
                stmt.columnInt64(5),
            });
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn fileHistoryJson(self: *Server, id: i64, path: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        var stmt = try self.database.prepare(
            "SELECT ts, type, prev_hash, new_hash FROM events WHERE session_id = ?1 AND (path = ?2 OR prev_path = ?2) AND session_id IN (SELECT id FROM sessions WHERE project_id = ?3) ORDER BY seq ASC;",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, path);
        try stmt.bindText(3, self.project_id);
        var first = true;
        while (try stmt.step()) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const before_json = try self.blobJson(&stmt, 2);
            defer self.allocator.free(before_json);
            const after_json = try self.blobJson(&stmt, 3);
            defer self.allocator.free(after_json);
            const type_esc = try db.jsonEscape(self.allocator, stmt.columnText(1));
            defer self.allocator.free(type_esc);
            try out.writer(self.allocator).print(
                \\{{"ts":{d},"type":{s},"before":{s},"after":{s}}}
            , .{ stmt.columnInt64(0), type_esc, before_json, after_json });
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    /// Blob as JSON string, null when missing/binary/oversize.
    fn blobJson(self: *Server, stmt: *db.Stmt, idx: c_int) ![]u8 {
        if (stmt.columnIsNull(idx)) return self.allocator.dupe(u8, "null");
        const h = stmt.columnText(idx);
        const bytes = store.get(self.allocator, self.project_root, h, 256 * 1024) catch {
            return self.allocator.dupe(u8, "null");
        };
        defer self.allocator.free(bytes);
        if (hash.isBinary(bytes)) return self.allocator.dupe(u8, "null");
        const esc = try db.jsonEscape(self.allocator, bytes);
        defer self.allocator.free(esc);
        return self.allocator.dupe(u8, esc);
    }
};

/// Parse a ?a=b&c=d query string for one key. Borrowed slice or null.
fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// Minimal percent-decoder for query values (+ stays literal).
fn pctDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 <= s.len) {
            const hex = s[i + 1 .. i + 3];
            const v = std.fmt.parseInt(u8, hex, 16) catch {
                try out.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, v);
            i += 3;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}
