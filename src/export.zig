// `annalist export`: write portable session bundles.
// `export <id> [--out <dir>]` or `export --all [--out <dir>]`.
// Layout: <out>/manifest.json + <out>/blobs/xx/rest (sharded like the store).
// manifest.json: {"format":1,"project_id","session":{...},"events":[...]}
// Blobs cover every prev_hash/new_hash referenced by the exported events.
// Missing blobs are a hard error (no silent incomplete bundles).

const std = @import("std");
const db = @import("db.zig");
const views = @import("views.zig");
const session = @import("session.zig");
const store = @import("store.zig");

pub const MAX_BLOB_READ: usize = 64 * 1024 * 1024;

fn writeJsonStr(out: anytype, allocator: std.mem.Allocator, s: []const u8) !void {
    const esc = try db.jsonEscape(allocator, s);
    defer allocator.free(esc);
    try out.writeAll(esc);
}

fn writeJsonStrOrNull(out: anytype, allocator: std.mem.Allocator, stmt: *db.Stmt, col: c_int) !void {
    if (stmt.columnIsNull(col)) {
        try out.writeAll("null");
    } else {
        try writeJsonStr(out, allocator, stmt.columnText(col));
    }
}

/// Export one session into out_dir (created). Returns blobs copied.
fn exportOne(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    session_id: i64,
    out_dir: []const u8,
) !usize {
    try views.assertSession(database, project_id, session_id);

    // Work with an absolute dir: downstream file APIs require it.
    const abs_dir = if (std.fs.path.isAbsolute(out_dir))
        try allocator.dupe(u8, out_dir)
    else blk: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, out_dir });
    };
    defer allocator.free(abs_dir);
    const out_dir_abs = abs_dir;

    std.fs.cwd().makePath(out_dir_abs) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const manifest_path = try std.fs.path.join(allocator, &.{ out_dir_abs, "manifest.json" });
    defer allocator.free(manifest_path);
    // Refuse to silently clobber an existing bundle.
    if (std.fs.accessAbsolute(manifest_path, .{})) {
        return error.BundleExists;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    var mbuf: std.ArrayList(u8) = .empty;
    defer mbuf.deinit(allocator);
    const out = mbuf.writer(allocator);

    try out.writeAll("{\"format\":1,\"project_id\":");
    {
        const esc = try db.jsonEscape(allocator, project_id);
        defer allocator.free(esc);
        try out.writeAll(esc);
    }
    // Session row.
    {
        var q = try database.prepare(
            "SELECT id, command, argv_json, cwd, started_at, ended_at, exit_code, status FROM sessions WHERE id = ?1;",
        );
        defer q.finalize();
        try q.bindInt64(1, session_id);
        if (!(try q.step())) return error.NoSuchSession;
        try out.writeAll(",\"session\":{\"id\":");
        try out.print("{d},\"command\":", .{q.columnInt64(0)});
        try writeJsonStr(out, allocator, q.columnText(1));
        try out.writeAll(",\"argv_json\":");
        const argv = q.columnText(2);
        try out.writeAll(if (argv.len > 0) argv else "[]");
        try out.writeAll(",\"cwd\":");
        try writeJsonStr(out, allocator, q.columnText(3));
        try out.print(",\"started_at\":{d},\"ended_at\":", .{q.columnInt64(4)});
        if (q.columnIsNull(5)) try out.writeAll("null") else try out.print("{d}", .{q.columnInt64(5)});
        try out.writeAll(",\"exit_code\":");
        if (q.columnIsNull(6)) try out.writeAll("null") else try out.print("{d}", .{q.columnInt64(6)});
        try out.writeAll(",\"status\":");
        try writeJsonStr(out, allocator, q.columnText(7));
        try out.writeAll("}");
    }
    // Events + referenced hashes.
    var referenced = std.StringHashMap(void).init(allocator);
    defer {
        var it = referenced.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        referenced.deinit();
    }
    {
        try out.writeAll(",\"events\":[");
        var q = try database.prepare(
            "SELECT seq, ts, type, path, prev_path, prev_hash, new_hash, size FROM events WHERE session_id = ?1 ORDER BY seq ASC;",
        );
        defer q.finalize();
        try q.bindInt64(1, session_id);
        var first = true;
        while (try q.step()) {
            if (!first) try out.writeAll(",");
            first = false;
            try out.print("{{\"seq\":{d},\"ts\":{d},\"type\":", .{ q.columnInt64(0), q.columnInt64(1) });
            try writeJsonStr(out, allocator, q.columnText(2));
            try out.writeAll(",\"path\":");
            try writeJsonStr(out, allocator, q.columnText(3));
            try out.writeAll(",\"prev_path\":");
            try writeJsonStrOrNull(out, allocator, &q, 4);
            try out.writeAll(",\"prev_hash\":");
            try writeJsonStrOrNull(out, allocator, &q, 5);
            try out.writeAll(",\"new_hash\":");
            try writeJsonStrOrNull(out, allocator, &q, 6);
            try out.print(",\"size\":{d}}}", .{q.columnInt64(7)});
            for ([2]c_int{ 5, 6 }) |col| {
                if (!q.columnIsNull(col)) {
                    const gop = try referenced.getOrPut(q.columnText(col));
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try allocator.dupe(u8, q.columnText(col));
                    }
                }
            }
        }
        try out.writeAll("]}");
    }
    var mf = try std.fs.createFileAbsolute(manifest_path, .{ .exclusive = true });
    defer mf.close();
    try mf.writeAll(mbuf.items);

    // Blobs.
    var copied: usize = 0;
    var it = referenced.iterator();
    while (it.next()) |kv| {
        const hex = kv.key_ptr.*;
        const bytes = store.get(allocator, project_root, hex, MAX_BLOB_READ) catch |err| {
            if (err == error.FileNotFound) return error.BlobMissing;
            return err;
        };
        defer allocator.free(bytes);
        const dest = try std.fs.path.join(allocator, &.{ out_dir_abs, "blobs", hex[0..2], hex[2..] });
        defer allocator.free(dest);
        if (std.fs.path.dirname(dest)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        const f = try std.fs.createFileAbsolute(dest, .{ .exclusive = true });
        defer f.close();
        try f.writeAll(bytes);
        copied += 1;
    }
    return copied;
}

pub fn runExport(
    allocator: std.mem.Allocator,
    database: *db.Db,
    project_id: []const u8,
    project_root: []const u8,
    id_text: ?[]const u8,
    out_opt: ?[]const u8,
    export_all: bool,
) !void {
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;

    if (export_all) {
        const base = if (out_opt) |o| try allocator.dupe(u8, o) else try std.fmt.allocPrint(allocator, "annalist-export-all", .{});
        defer allocator.free(base);
        var q = try database.prepare(
            "SELECT id FROM sessions WHERE project_id = ?1 ORDER BY id ASC;",
        );
        defer q.finalize();
        try q.bindText(1, project_id);
        var n: usize = 0;
        var blobs: usize = 0;
        while (try q.step()) {
            const sid = q.columnInt64(0);
            const pad = try session.padId(allocator, sid);
            defer allocator.free(pad);
            const dir = try std.fs.path.join(allocator, &.{ base, pad });
            defer allocator.free(dir);
            blobs += try exportOne(allocator, database, project_id, project_root, sid, dir);
            n += 1;
        }
        try out.print("exported {d} session(s), {d} blob(s) to {s}/\n", .{ n, blobs, base });
        try out.flush();
        return;
    }

    const id_t = id_text orelse return error.MissingTarget;
    const sid = std.fmt.parseInt(i64, id_t, 10) catch return error.BadSessionId;
    const pad = try session.padId(allocator, sid);
    defer allocator.free(pad);
    const dest = if (out_opt) |o| try allocator.dupe(u8, o) else try std.fmt.allocPrint(allocator, "annalist-export-{s}", .{pad});
    defer allocator.free(dest);
    const blobs = try exportOne(allocator, database, project_id, project_root, sid, dest);
    try out.print("exported session {s} ({d} blob(s)) to {s}/\n", .{ pad, blobs, dest });
    try out.flush();
}
