// `annalist score <id>`: one Jev risk judgment over a recorded session.
// What ran, what it touched, how it ended — scored 0-100 and stored on the
// session row, so `sessions` answers "show me everything above 70%".
// Opt-in only: no key, no call. The gate path never calls out (CI stays
// offline); scoring is a deliberate local act after the fact.

const std = @import("std");
const db = @import("db.zig");

pub const default_endpoint = "https://api.typesafe.ai/v1/systemone";
pub const default_threshold = 70;
pub const min_confidence = 50; // percent; below this the score is shown but not trusted

const levels = [_][]const u8{
    "Routine command with trivial or read-only file effects",
    "Normal development work within ordinary bounds",
    "Notable: broad file effects, sensitive paths nearby, or an unusual command for the project",
    "Suspicious: secret-adjacent writes, mass deletion, or behavior inconsistent with development",
    "Clearly abusive: likely exfiltration, sabotage, or deliberate policy evasion",
};

pub const Risk = struct {
    score: u8, // 0-100
    confidence: u8, // 0-100 percent
};

/// Map a Jev Score value (0-4 level scale) onto 0-100.
pub fn score100FromScore(score: f64) u8 {
    const scaled = score * 25.0 + 0.5;
    if (scaled <= 0) return 0;
    if (scaled >= 100) return 100;
    return @intFromFloat(scaled);
}

const RiskAnswers = struct {
    answers: struct {
        risk: struct {
            score: f64,
            confidence: f64,
        },
    },
};

/// Decode the risk judgment from a systemone response body.
pub fn decodeRisk(body: []const u8, allocator: std.mem.Allocator) !Risk {
    const parsed = try std.json.parseFromSlice(
        RiskAnswers,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const r = parsed.value.answers.risk;
    const conf_scaled = r.confidence * 100.0 + 0.5;
    return .{
        .score = score100FromScore(r.score),
        .confidence = if (conf_scaled <= 0) 0 else if (conf_scaled >= 100) 100 else @intFromFloat(conf_scaled),
    };
}

const ScoredFile = struct {
    path: []const u8,
    size: i64,
};

/// Collect up to max changed files for one session (paths + sizes only,
// never contents) for the judgment state.
pub fn collectFiles(
    allocator: std.mem.Allocator,
    database: *db.Db,
    session_id: i64,
    max: usize,
) !std.ArrayList(ScoredFile) {
    var out = std.ArrayList(ScoredFile){};
    errdefer out.deinit(allocator);
    var stmt = try database.prepare(
        "SELECT path, size FROM events WHERE session_id = ?1 AND type LIKE 'file_%' ORDER BY seq ASC LIMIT 200;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, session_id);
    while (try stmt.step()) {
        if (out.items.len >= max) break;
        const path = try allocator.dupe(u8, stmt.columnText(0));
        errdefer allocator.free(path);
        try out.append(allocator, .{ .path = path, .size = stmt.columnInt64(1) });
    }
    return out;
}

fn freeFiles(allocator: std.mem.Allocator, files: *std.ArrayList(ScoredFile)) void {
    for (files.items) |f| allocator.free(f.path);
    files.deinit(allocator);
}

const SessionInfo = struct {
    command: []u8,
    argv_json: []u8,
    cwd: []u8,
    exit_code: ?i64,
    status: []u8,
};

fn loadSession(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    id: i64,
) !SessionInfo {
    var stmt = try database.prepare(
        "SELECT command, argv_json, cwd, exit_code, status FROM sessions WHERE id = ?1 AND project_id = ?2;",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    try stmt.bindText(2, project_id);
    if (!(try stmt.step())) return error.NoSuchSession;
    return .{
        .command = try allocator.dupe(u8, stmt.columnText(0)),
        .argv_json = try allocator.dupe(u8, stmt.columnText(1)),
        .cwd = try allocator.dupe(u8, stmt.columnText(2)),
        .exit_code = if (stmt.columnIsNull(3)) null else stmt.columnInt64(3),
        .status = try allocator.dupe(u8, stmt.columnText(4)),
    };
}

fn postRisk(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    key: []const u8,
    payload: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    defer allocator.free(auth);
    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .response_writer = &body_writer.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        },
    });
    if (result.status != .ok) return error.JevRequestFailed;
    return body_writer.toOwnedSlice();
}

pub fn scoreSession(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    id_text: []const u8,
) !void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch {
        return error.BadSessionId;
    };
    const key = std.process.getEnvVarOwned(allocator, "JEV_API_KEY") catch {
        std.log.err("score needs JEV_API_KEY in the environment", .{});
        return error.MissingKey;
    };
    defer allocator.free(key);
    const endpoint = std.process.getEnvVarOwned(allocator, "JEV_API_URL") catch
        try allocator.dupe(u8, default_endpoint);
    defer allocator.free(endpoint);

    const info = try loadSession(allocator, database, project_id, id);
    defer allocator.free(info.command);
    defer allocator.free(info.argv_json);
    defer allocator.free(info.cwd);
    defer allocator.free(info.status);

    var files = try collectFiles(allocator, database, id, 40);
    defer freeFiles(allocator, &files);

    var payload_writer = std.Io.Writer.Allocating.init(allocator);
    defer payload_writer.deinit();
    var payload_json: std.json.Stringify = .{ .writer = &payload_writer.writer };
    try payload_json.beginObject();
    try payload_json.objectField("model");
    try payload_json.write("jev-latest");
    try payload_json.objectField("state");
    try payload_json.beginObject();
    try payload_json.objectField("command");
    try payload_json.write(info.command);
    try payload_json.objectField("argv");
    try payload_json.write(info.argv_json);
    try payload_json.objectField("cwd");
    try payload_json.write(info.cwd);
    try payload_json.objectField("exit_code");
    if (info.exit_code) |c| try payload_json.write(c) else try payload_json.write(@as(?i64, null));
    try payload_json.objectField("status");
    try payload_json.write(info.status);
    try payload_json.objectField("files");
    try payload_json.beginArray();
    for (files.items) |f| {
        try payload_json.beginObject();
        try payload_json.objectField("path");
        try payload_json.write(f.path);
        try payload_json.objectField("size");
        try payload_json.write(f.size);
        try payload_json.endObject();
    }
    try payload_json.endArray();
    try payload_json.endObject();
    try payload_json.objectField("questions");
    try payload_json.beginObject();
    try payload_json.objectField("risk");
    try payload_json.beginObject();
    try payload_json.objectField("type");
    try payload_json.write("score");
    try payload_json.objectField("instructions");
    try payload_json.write("How risky is this recorded coding session? Weigh the command, the files it touched, and how it ended.");
    try payload_json.objectField("criteria");
    try payload_json.beginArray();
    for (levels) |level| try payload_json.write(level);
    try payload_json.endArray();
    try payload_json.endObject();
    try payload_json.endObject();
    try payload_json.endObject();
    const payload = try payload_writer.toOwnedSlice();
    defer allocator.free(payload);

    const body = postRisk(allocator, endpoint, key, payload) catch |err| {
        std.log.err("score failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(body);
    const risk = decodeRisk(body, allocator) catch {
        std.log.err("score failed: unreadable judgment", .{});
        return error.JevBadResponse;
    };

    var upd = try database.prepare(
        "UPDATE sessions SET risk_score = ?1, risk_confidence = ?2 WHERE id = ?3 AND project_id = ?4;",
    );
    defer upd.finalize();
    try upd.bindInt64(1, risk.score);
    try upd.bindInt64(2, risk.confidence);
    try upd.bindInt64(3, id);
    try upd.bindText(4, project_id);
    _ = try upd.step();

    var buf: [256]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    if (risk.confidence < min_confidence) {
        try out.print("session {d}: risk {d} (confidence {d} — below {d}, treat as unscored)\n", .{ id, risk.score, risk.confidence, min_confidence });
    } else {
        try out.print("session {d}: risk {d} (confidence {d})\n", .{ id, risk.score, risk.confidence });
    }
    try out.flush();
}

test "score maps level scale to 0-100" {
    try std.testing.expectEqual(0, score100FromScore(0));
    try std.testing.expectEqual(85, score100FromScore(3.4));
    try std.testing.expectEqual(100, score100FromScore(4));
    try std.testing.expectEqual(100, score100FromScore(9));
    try std.testing.expectEqual(0, score100FromScore(-1));
}

test "decode risk judgment" {
    const risk_body = "{\"model\":\"jev-latest\",\"answers\":{\"risk\":{\"type\":\"score\",\"score\":3.16,\"confidence\":0.69,\"legend\":{},\"probabilities\":{}}},\"usage\":{}}";
    const risk = try decodeRisk(risk_body, std.testing.allocator);
    try std.testing.expectEqual(79, risk.score);
    try std.testing.expectEqual(69, risk.confidence);
}

test "decode rejects missing risk" {
    const body =
        \\{"answers": {}}
    ;
    try std.testing.expectError(error.MissingField, decodeRisk(body, std.testing.allocator));
}
