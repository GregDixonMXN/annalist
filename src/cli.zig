// CLI parsing and help text. Pure dispatch, no side effects.

const std = @import("std");

pub const ParseError = error{
    NoCommand,
    UnknownCommand,
    MissingSeparator,
    MissingSessionId,
    MissingDiffIds,
    MissingRewindTarget,
};

pub const Command = union(enum) {
    help,
    version,
    init,
    run: RunOpts,
    sessions,
    inspect: InspectOpts,
    ui,
    doctor: DoctorOpts,
    diff: DiffOpts,
    rewind: RewindOpts,
    future: []const u8,
};

pub const RunOpts = struct {
    child_argv: []const []const u8,
};

pub const InspectOpts = struct {
    id: []const u8,
    json: bool,
    file: ?[]const u8 = null,
};

pub const DoctorOpts = struct {
    fix: bool = false,
    gc: bool = false,
};

pub const DiffOpts = struct {
    a: []const u8,
    b: []const u8,
};

pub const RewindOpts = struct {
    id: []const u8,
    seq: ?[]const u8 = null,
    force: bool = false,
};

/// Commands reserved for post-v0.1. Listed so help stays honest.
const future_commands = [_][]const u8{
    "branch",
    "policy",
    "export",
};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return ParseError.NoCommand;
    const name = args[1];

    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h"))
        return .help;
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V"))
        return .version;
    if (std.mem.eql(u8, name, "init")) return .init;
    if (std.mem.eql(u8, name, "sessions")) return .sessions;
    if (std.mem.eql(u8, name, "ui")) return .ui;
    if (std.mem.eql(u8, name, "doctor")) {
        var fix = false;
        var gc = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--fix")) fix = true;
            if (std.mem.eql(u8, a, "--gc")) gc = true;
        }
        return Command{ .doctor = .{ .fix = fix, .gc = gc } };
    }
    if (std.mem.eql(u8, name, "diff")) {
        if (args.len < 4) return ParseError.MissingDiffIds;
        return Command{ .diff = .{ .a = args[2], .b = args[3] } };
    }
    if (std.mem.eql(u8, name, "rewind")) {
        if (args.len < 3) return ParseError.MissingRewindTarget;
        var seq: ?[]const u8 = null;
        var force = false;
        for (args[3..]) |a| {
            if (std.mem.eql(u8, a, "--force")) {
                force = true;
            } else if (seq == null) {
                seq = a;
            } else {
                return ParseError.MissingRewindTarget;
            }
        }
        return Command{ .rewind = .{ .id = args[2], .seq = seq, .force = force } };
    }

    if (std.mem.eql(u8, name, "run")) {
        var sep: ?usize = null;
        for (args, 0..) |a, i| {
            if (i >= 2 and std.mem.eql(u8, a, "--")) {
                sep = i;
                break;
            }
        }
        const s = sep orelse return ParseError.MissingSeparator;
        if (s + 1 >= args.len) return ParseError.MissingSeparator;
        return Command{ .run = .{ .child_argv = args[s + 1 ..] } };
    }

    if (std.mem.eql(u8, name, "inspect")) {
        if (args.len < 3) return ParseError.MissingSessionId;
        var as_json = false;
        var file: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--json")) {
                as_json = true;
            } else if (std.mem.eql(u8, a, "--file")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingSessionId;
                file = args[i];
            }
        }
        return Command{ .inspect = .{ .id = args[2], .json = as_json, .file = file } };
    }

    for (future_commands) |f| {
        if (std.mem.eql(u8, name, f)) return Command{ .future = f };
    }

    return ParseError.UnknownCommand;
}

pub fn printVersion(version: []const u8) !void {
    var buf: [256]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    try out.print("blackbox {s}\n", .{version});
    try out.flush();
}

pub fn printHelp() !void {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    try out.writeAll(
        \\Blackbox — local-first flight recorder for autonomous coding agents.
        \\
        \\Usage:
        \\  blackbox init                        initialize this project
        \\  blackbox run -- <command> [args]     record a session
        \\  blackbox sessions                    list recorded sessions
        \\  blackbox inspect <session-id>        inspect a session
        \\  blackbox diff <a> <b>                  compare two sessions
        \\  blackbox rewind <session> [seq] [--force]  restore files to a recorded point
        \\  blackbox doctor [--fix] [--gc]         health check + repair
        \\  blackbox ui                          localhost dashboard
        \\  blackbox version                     print version
        \\  blackbox help                        this help
        \\
        \\Planned (not in v0.2): branch, policy, export
        \\
        \\Examples:
        \\  blackbox run -- codex
        \\  blackbox run -- claude --dangerously-skip-permissions -p "fix tests"
        \\
    );
    try out.flush();
}

const testing = std.testing;

test "parse run with separator" {
    const args = [_][]const u8{ "blackbox", "run", "--", "codex", "-x" };
    const cmd = try parse(&args);
    try testing.expect(cmd == .run);
    try testing.expectEqual(@as(usize, 2), cmd.run.child_argv.len);
}

test "parse run without separator fails" {
    const args = [_][]const u8{ "blackbox", "run", "codex" };
    try testing.expectError(ParseError.MissingSeparator, parse(&args));
}

test "parse inspect requires id" {
    const args = [_][]const u8{ "blackbox", "inspect" };
    try testing.expectError(ParseError.MissingSessionId, parse(&args));
}

test "future commands route to roadmap stub" {
    const args = [_][]const u8{ "blackbox", "rewind" };
    const cmd = try parse(&args);
    try testing.expect(cmd == .future);
}
