// Local read-only HTTP server (loopback only). Serves the JSON API used by
// the dashboard plus the embedded single-file UI. No mutation endpoints exist.

const std = @import("std");
const db = @import("db.zig");
const log = @import("log.zig");
const events = @import("events.zig");
const store = @import("store.zig");
const hash = @import("hash.zig");
const safe_fs = @import("safe_fs.zig");

const index_html = @embedFile("ui/index.html");

pub const DEFAULT_PORT: u16 = 8901;
const HEADER_TIMEOUT_NS = 2 * std.time.ns_per_s;
const HISTORY_LIMIT = 100;
const PREVIEW_BUDGET = 2 * 1024 * 1024;

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
            self.handleConn(conn.stream, port) catch |err| {
                log.warn("request failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn handleConn(self: *Server, stream: std.net.Stream, port: u16) !void {
        defer stream.close();
        var req_buf: [8192]u8 = undefined;
        const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
        var timer = try std.time.Timer.start();
        var n: usize = 0;
        while (n < req_buf.len) {
            // An absolute deadline prevents a trickling client from monopolizing
            // this deliberately small, single-connection loopback server.
            const elapsed = timer.read();
            if (elapsed >= HEADER_TIMEOUT_NS) return;
            const remaining_us = @max(1, (HEADER_TIMEOUT_NS - elapsed) / std.time.ns_per_us);
            const remaining = std.posix.timeval{ .sec = @intCast(remaining_us / std.time.us_per_s), .usec = @intCast(remaining_us % std.time.us_per_s) };
            try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&remaining));
            const got = stream.read(req_buf[n..]) catch return;
            if (got == 0) return;
            n += got;
            if (std.mem.indexOf(u8, req_buf[0..n], "\r\n\r\n") != null) break;
        }
        if (std.mem.indexOf(u8, req_buf[0..n], "\r\n\r\n") == null) return self.writeResponse(stream, 400, "text/plain", "request too large");
        if (n == 0) return;
        const req = req_buf[0..n];
        const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const line = req[0..line_end];
        var parts = std.mem.splitScalar(u8, line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;
        const version = parts.next() orelse return self.writeResponse(stream, 400, "text/plain", "bad request line");
        if (parts.next() != null or (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) or target.len == 0 or target[0] != '/') return self.writeResponse(stream, 400, "text/plain", "bad request line");
        if (!std.mem.eql(u8, method, "GET")) {
            return self.writeResponse(stream, 405, "text/plain", "method not allowed");
        }
        // Reject DNS rebinding and cross-site browser requests, even on loopback.
        var headers = std.mem.splitSequence(u8, req[line_end + 2 ..], "\r\n");
        var host_ok = false;
        var host_seen = false;
        while (headers.next()) |header| {
            if (header.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, header, ':') orelse return self.writeResponse(stream, 400, "text/plain", "bad header");
            const key = header[0..colon];
            const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(key, "host")) {
                if (host_seen) return self.writeResponse(stream, 400, "text/plain", "duplicate host");
                host_seen = true;
                host_ok = validHost(value, port);
            }
            if (std.ascii.eqlIgnoreCase(key, "sec-fetch-site") and !std.mem.eql(u8, value, "same-origin") and !std.mem.eql(u8, value, "none")) return self.writeResponse(stream, 403, "text/plain", "cross-site request denied");
            if (std.ascii.eqlIgnoreCase(key, "origin")) return self.writeResponse(stream, 403, "text/plain", "origin request denied");
        }
        if (!host_ok) return self.writeResponse(stream, 403, "text/plain", "invalid host");
        // Strip query string for routing (kept separately where needed).
        const qmark = std.mem.indexOfScalar(u8, target, '?');
        const path = if (qmark) |q| target[0..q] else target;
        const query = if (qmark) |q| target[q + 1 ..] else "";

        if (std.mem.eql(u8, path, "/")) {
            return self.writeResponse(stream, 200, "text/html", index_html);
        }
        if (std.mem.eql(u8, path, "/api/project")) {
            const name = try db.jsonEscape(self.allocator, std.fs.path.basename(self.project_root));
            defer self.allocator.free(name);
            const body = try std.fmt.allocPrint(self.allocator, "{{\"name\":{s},\"version\":\"1.0.0-rc.1\",\"session_limit\":1000,\"event_limit\":10000}}", .{name});
            defer self.allocator.free(body);
            return self.writeResponse(stream, 200, "application/json", body);
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
            if (!safe_fs.validPath(fpath)) {
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
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            else => "Error",
        };
        try w.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n",
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
            "SELECT id, command, started_at, ended_at, exit_code, status FROM sessions WHERE project_id = ?1 ORDER BY id DESC LIMIT 1000;",
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
            "SELECT seq, ts, type, path, prev_path, size FROM events WHERE session_id = ?1 AND session_id IN (SELECT id FROM sessions WHERE project_id = ?2) ORDER BY seq ASC LIMIT 10000;",
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
            "SELECT ts, type, prev_hash, new_hash FROM events WHERE session_id = ?1 AND (path = ?2 OR prev_path = ?2) AND session_id IN (SELECT id FROM sessions WHERE project_id = ?3) ORDER BY seq ASC LIMIT ?4;",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, path);
        try stmt.bindText(3, self.project_id);
        try stmt.bindInt64(4, HISTORY_LIMIT);
        var first = true;
        var preview_budget: usize = PREVIEW_BUDGET;
        while (try stmt.step()) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            var preview_limited = false;
            const before_json = try self.blobJson(&stmt, 2, &preview_budget, &preview_limited);
            defer self.allocator.free(before_json);
            const after_json = try self.blobJson(&stmt, 3, &preview_budget, &preview_limited);
            defer self.allocator.free(after_json);
            const type_esc = try db.jsonEscape(self.allocator, stmt.columnText(1));
            defer self.allocator.free(type_esc);
            try out.writer(self.allocator).print(
                \\{{"ts":{d},"type":{s},"before":{s},"after":{s},"preview_limited":{}}}
            , .{ stmt.columnInt64(0), type_esc, before_json, after_json, preview_limited });
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    /// Blob as JSON string, null when missing/binary/oversize.
    fn blobJson(self: *Server, stmt: *db.Stmt, idx: c_int, budget: *usize, limited: *bool) ![]u8 {
        if (stmt.columnIsNull(idx)) return self.allocator.dupe(u8, "null");
        if (budget.* == 0) {
            limited.* = true;
            return self.allocator.dupe(u8, "null");
        }
        const h = stmt.columnText(idx);
        const bytes = store.get(self.allocator, self.project_root, h, 256 * 1024) catch {
            return self.allocator.dupe(u8, "null");
        };
        defer self.allocator.free(bytes);
        if (hash.isBinary(bytes) or !std.unicode.utf8ValidateSlice(bytes)) return self.allocator.dupe(u8, "null");
        const esc = try db.jsonEscape(self.allocator, bytes);
        if (esc.len > budget.*) {
            self.allocator.free(esc);
            budget.* = 0;
            limited.* = true;
            return self.allocator.dupe(u8, "null");
        }
        budget.* -= esc.len;
        return esc;
    }
};

fn validHost(authority: []const u8, port: u16) bool {
    var buf: [32]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |hostname| {
        const expected = std.fmt.bufPrint(&buf, "{s}:{d}", .{ hostname, port }) catch unreachable;
        if (std.ascii.eqlIgnoreCase(authority, expected)) return true;
        if (port == 80 and std.ascii.eqlIgnoreCase(authority, hostname)) return true;
    }
    return false;
}

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
        if (s[i] == '%' and i + 2 < s.len) {
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

test "truncated percent escapes do not panic" {
    for ([_][]const u8{ "%", "%a", "%zz", "a%20b" }) |raw| {
        const decoded = try pctDecode(std.testing.allocator, raw);
        std.testing.allocator.free(decoded);
    }
}

test "loopback Host requires exact server authority" {
    for ([_][]const u8{ "127.0.0.1:8901", "localhost:8901", "LOCALHOST:8901" }) |host| try std.testing.expect(validHost(host, 8901));
    for ([_][]const u8{ "127.0.0.1", "127.0.0.1:8902", "127.0.0.1:8901.evil", "localhost:8901:evil", "localhost:abc", "localhost:", "localhost.evil:8901", "localhost:08901", "127.0.0.1:8901@evil" }) |host| try std.testing.expect(!validHost(host, 8901));
    try std.testing.expect(validHost("localhost", 80));
}
