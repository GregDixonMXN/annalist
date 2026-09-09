// CLI parsing and help text. Pure dispatch, no side effects.

const std = @import("std");

pub const ParseError = error{
    NoCommand,
    UnknownCommand,
    MissingSeparator,
    MissingSessionId,
    MissingDiffIds,
    MissingRewindTarget,
    MissingExportTarget,
    InvalidArgs,
};

pub const Command = union(enum) {
    help,
    version,
    init,
    run: RunOpts,
    sessions: SessionsOpts,
    inspect: InspectOpts,
    ui,
    doctor: DoctorOpts,
    diff: DiffOpts,
    rewind: RewindOpts,
    bundle: ExportOpts,
    branch: BranchOpts,
    policy: PolicyOpts,
    prune: PruneOpts,
    unbundle: ImportOpts,
    gate: GateOpts,
    future: []const u8,
};

pub const RunOpts = struct {
    child_argv: []const []const u8,
    branch: ?[]const u8 = null,
};

pub const SessionsOpts = struct {
    branch: ?[]const u8 = null,
};

pub const BranchOpts = struct {
    name: ?[]const u8 = null,
};

pub const PolicyOpts = struct {
    set_max_age: ?[]const u8 = null,
};

pub const PruneOpts = struct {
    older_than: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const ImportOpts = struct {
    dir: []const u8,
    force: bool = false,
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
    dry_run: bool = false,
    id: []const u8,
    seq: ?[]const u8 = null,
    force: bool = false,
};

pub const ExportOpts = struct {
    id: ?[]const u8 = null,
    out: ?[]const u8 = null,
    all: bool = false,
};

pub const GateOpts = struct {
    session: []const u8,
    policy: ?[]const u8 = null,
};

/// Commands reserved for later. Listed so help stays honest.
const future_commands = [_][]const u8{};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return ParseError.NoCommand;
    const name = args[1];

    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h"))
        return .help;
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V"))
        return .version;
    if (std.mem.eql(u8, name, "init")) {
        if (args.len != 2) return ParseError.InvalidArgs;
        return .init;
    }
    if (std.mem.eql(u8, name, "sessions")) {
        var branch: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--branch")) {
                i += 1;
                if (i >= args.len) return ParseError.InvalidArgs;
                branch = args[i];
            } else {
                return ParseError.InvalidArgs;
            }
        }
        return Command{ .sessions = .{ .branch = branch } };
    }
    if (std.mem.eql(u8, name, "branch")) {
        if (args.len > 3) return ParseError.InvalidArgs;
        const nm: ?[]const u8 = if (args.len == 3) args[2] else null;
        return Command{ .branch = .{ .name = nm } };
    }
    if (std.mem.eql(u8, name, "policy")) {
        var set_age: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--set-max-age")) {
                i += 1;
                if (i >= args.len) return ParseError.InvalidArgs;
                set_age = args[i];
            } else {
                return ParseError.InvalidArgs;
            }
        }
        return Command{ .policy = .{ .set_max_age = set_age } };
    }
    if (std.mem.eql(u8, name, "prune")) {
        var older: ?[]const u8 = null;
        var dry = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--dry-run")) {
                dry = true;
            } else if (std.mem.eql(u8, a, "--older-than")) {
                i += 1;
                if (i >= args.len) return ParseError.InvalidArgs;
                older = args[i];
            } else {
                return ParseError.InvalidArgs;
            }
        }
        return Command{ .prune = .{ .older_than = older, .dry_run = dry } };
    }
    if (std.mem.eql(u8, name, "gate")) {
        var session: ?[]const u8 = null;
        var policy: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--session")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingSessionId;
                session = args[i];
            } else if (std.mem.eql(u8, a, "--policy")) {
                i += 1;
                if (i >= args.len) return ParseError.InvalidArgs;
                policy = args[i];
            } else {
                return ParseError.InvalidArgs;
            }
        }
        if (session == null) return ParseError.MissingSessionId;
        return Command{ .gate = .{ .session = session.?, .policy = policy } };
    }
    if (std.mem.eql(u8, name, "import")) {
        if (args.len < 3) return ParseError.InvalidArgs;
        var force = false;
        for (args[3..]) |a| {
            if (std.mem.eql(u8, a, "--force")) {
                force = true;
            } else {
                return ParseError.InvalidArgs;
            }
        }
        return Command{ .unbundle = .{ .dir = args[2], .force = force } };
    }
    if (std.mem.eql(u8, name, "ui")) {
        if (args.len != 2) return ParseError.InvalidArgs;
        return .ui;
    }
    if (std.mem.eql(u8, name, "doctor")) {
        var fix = false;
        var gc = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--fix")) {
                fix = true;
            } else if (std.mem.eql(u8, a, "--gc")) {
                gc = true;
            } else return ParseError.InvalidArgs;
        }
        return Command{ .doctor = .{ .fix = fix, .gc = gc } };
    }
    if (std.mem.eql(u8, name, "diff")) {
        if (args.len != 4) return ParseError.MissingDiffIds;
        return Command{ .diff = .{ .a = args[2], .b = args[3] } };
    }
    if (std.mem.eql(u8, name, "export")) {
        var id: ?[]const u8 = null;
        var out: ?[]const u8 = null;
        var all = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--all")) {
                all = true;
            } else if (std.mem.eql(u8, a, "--out")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingExportTarget;
                out = args[i];
            } else if (id == null and !all) {
                id = a;
            } else {
                return ParseError.MissingExportTarget;
            }
        }
        if (all and id != null) return ParseError.InvalidArgs;
        if (!all and id == null) return ParseError.MissingExportTarget;
        return Command{ .bundle = .{ .id = id, .out = out, .all = all } };
    }
    if (std.mem.eql(u8, name, "rewind")) {
        if (args.len < 3) return ParseError.MissingRewindTarget;
        var seq: ?[]const u8 = null;
        var dry_run = false;
        var force = false;
        for (args[3..]) |a| {
            if (std.mem.eql(u8, a, "--force")) {
                force = true;
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                dry_run = true;
            } else if (seq == null and !std.mem.startsWith(u8, a, "-")) {
                seq = a;
            } else {
                return ParseError.MissingRewindTarget;
            }
        }
        return Command{ .rewind = .{ .id = args[2], .seq = seq, .force = force, .dry_run = dry_run } };
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
        var branch: ?[]const u8 = null;
        var i: usize = 2;
        while (i < s) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--branch")) {
                i += 1;
                if (i >= s) return ParseError.InvalidArgs;
                if (branch != null) return ParseError.InvalidArgs;
                branch = args[i];
            } else {
                return ParseError.InvalidArgs;
            }
        }
        return Command{ .run = .{ .child_argv = args[s + 1 ..], .branch = branch } };
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
            } else return ParseError.InvalidArgs;
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
    try out.print("annalist {s}\n", .{version});
    try out.flush();
}

pub fn printHelp() !void {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const out = &fw.interface;
    try out.writeAll(
        \\Annalist — local-first flight recorder for autonomous coding agents.
        \\
        \\Usage:
        \\  annalist init                        initialize this project
        \\  annalist run [--branch <name>] -- <command> [args]  record a session
        \\  annalist sessions [--branch <name>]    list recorded sessions
        \\  annalist branch [name]               list or switch workstream
        \\  annalist inspect <session-id>        inspect a session
        \\  annalist diff <a> <b>                  compare two sessions
        \\  annalist rewind <session> [seq] [--dry-run] [--force]  restore files to a recorded point
        \\  annalist gate --session <id> [--policy <file>]  policy check: 0 pass, 2 deny, 1 broken
        \\  annalist export <session>|--all [--out <dir>]  portable session bundle(s)
        \\  annalist import <dir> [--force]          restore session(s) from a bundle
        \\  annalist policy [--set-max-age <days>]  show/set retention
        \\  annalist prune [--dry-run] [--older-than <days>]  delete old sessions
        \\  annalist doctor [--fix] [--gc]         health check + repair
        \\  annalist ui                          localhost dashboard
        \\  annalist version                     print version
        \\  annalist help                        this help
        \\
        \\Examples:
        \\  annalist run -- codex
        \\  annalist run -- claude -p "fix tests"
        \\
    );
    try out.flush();
}

const testing = std.testing;

test "parse run with separator" {
    const args = [_][]const u8{ "annalist", "run", "--", "codex", "-x" };
    const cmd = try parse(&args);
    try testing.expect(cmd == .run);
    try testing.expectEqual(@as(usize, 2), cmd.run.child_argv.len);
}

test "parse run without separator fails" {
    const args = [_][]const u8{ "annalist", "run", "codex" };
    try testing.expectError(ParseError.MissingSeparator, parse(&args));
}

test "parse inspect requires id" {
    const args = [_][]const u8{ "annalist", "inspect" };
    try testing.expectError(ParseError.MissingSessionId, parse(&args));
}

test "rewind requires a target" {
    const args = [_][]const u8{ "annalist", "rewind" };
    try testing.expectError(ParseError.MissingRewindTarget, parse(&args));
}
