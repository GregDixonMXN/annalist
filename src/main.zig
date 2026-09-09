// Annalist: local-first flight recorder for autonomous coding agents.

const std = @import("std");
const cli = @import("cli.zig");
const log = @import("log.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const views = @import("views.zig");
const server = @import("server.zig");
const doctor = @import("doctor.zig");
const rewind = @import("rewind.zig");
const bundle = @import("export.zig");
const branch = @import("branch.zig");
const policy = @import("policy.zig");
const unbundle = @import("import.zig");
const gate = @import("gate.zig");

pub const version_string = "1.0.0-rc.2";

const ProjectCtx = struct {
    root: []u8,
    id: []u8,
    lock: ?std.fs.File,

    fn deinit(self: *ProjectCtx, allocator: std.mem.Allocator) void {
        if (self.lock) |f| f.close();
        allocator.free(self.root);
        allocator.free(self.id);
    }
};

fn requireProject(allocator: std.mem.Allocator, lock: bool) !ProjectCtx {
    const root = try config.findProjectRoot(allocator) orelse {
        log.err("not an annalist project (no .annalist/ found). Run `annalist init` first.", .{});
        std.process.exit(4);
    };
    errdefer allocator.free(root);
    const id = config.readProjectId(allocator, root) catch {
        log.err("project config unreadable. Re-run `annalist init`?", .{});
        std.process.exit(4);
    };
    const lock_path = try std.fs.path.join(allocator, &.{ root, ".annalist", "operation.lock" });
    defer allocator.free(lock_path);
    const file: ?std.fs.File = if (lock) std.fs.createFileAbsolute(lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .mode = 0o600 }) catch {
        log.err("project busy: stop the other recording or maintenance command first", .{});
        std.process.exit(1);
    } else null;
    return .{ .root = root, .id = id, .lock = file };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    session.child_umask = std.c.umask(0o077);
    log.init();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd = cli.parse(args) catch |err| {
        switch (err) {
            cli.ParseError.NoCommand => {
                try cli.printHelp();
                return;
            },
            cli.ParseError.UnknownCommand => {
                log.err("unknown command: '{s}'", .{args[1]});
                try cli.printHelp();
                std.process.exit(2);
            },
            cli.ParseError.MissingSeparator => {
                log.err("usage: annalist run -- <command> [args...]", .{});
                std.process.exit(2);
            },
            cli.ParseError.MissingSessionId => {
                log.err("usage: annalist inspect <session-id> [--json]", .{});
                std.process.exit(2);
            },
            cli.ParseError.MissingDiffIds => {
                log.err("usage: annalist diff <session-a> <session-b>", .{});
                std.process.exit(2);
            },
            cli.ParseError.MissingRewindTarget => {
                log.err("usage: annalist rewind <session-id> [seq] [--force]", .{});
                std.process.exit(2);
            },
            cli.ParseError.MissingExportTarget => {
                log.err("usage: annalist export <session-id>|--all [--out <dir>]", .{});
                std.process.exit(2);
            },
            cli.ParseError.InvalidArgs => {
                log.err("invalid arguments (see `annalist help`)", .{});
                std.process.exit(2);
            },
        }
    };

    switch (cmd) {
        .help => try cli.printHelp(),
        .version => try cli.printVersion(version_string),
        .init => config.runInit(allocator) catch |err| {
            log.err("init failed: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
        .run => |r| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            // runSession finalizes the row then exits with the child's code.
            session.runSession(allocator, proj.id, proj.root, r.child_argv, r.branch) catch |err| {
                switch (err) {
                    error.BadBranchName => log.err("bad branch name (1-64 chars of A-Za-z0-9_.-)", .{}),
                    else => log.err("run failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .sessions => |opts| {
            var proj = try requireProject(allocator, false);
            defer proj.deinit(allocator);
            var database = session.openDb(allocator) catch |err| {
                log.err("cannot open database: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            defer database.close();
            views.listSessions(allocator, &database, proj.id, opts.branch) catch |err| {
                log.err("sessions failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .inspect => |opts| {
            var proj = try requireProject(allocator, false);
            defer proj.deinit(allocator);
            var database = session.openDb(allocator) catch |err| {
                log.err("cannot open database: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            defer database.close();
            views.inspectSession(allocator, &database, proj.id, proj.root, opts.id, opts.json, opts.file) catch |err| {
                switch (err) {
                    error.NoSuchSession => log.err("no session '{s}' in this project", .{opts.id}),
                    error.BadSessionId => log.err("bad session id '{s}'", .{opts.id}),
                    else => log.err("inspect failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .ui => {
            var proj = try requireProject(allocator, false);
            defer proj.deinit(allocator);
            const port = config.readUiPort(allocator, proj.root) catch 8901;
            const database = try session.openDb(allocator);
            var srv = server.Server.init(allocator, database, proj.id, proj.root);
            // ProjectCtx owns the project strings; server borrows them.
            defer srv.database.close();
            srv.serve(port) catch |err| {
                log.err("ui server failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
        },
        .doctor => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            const rep = doctor.runDoctor(allocator, &database, proj.id, proj.root, opts.fix, opts.gc) catch |err| {
                log.err("doctor failed: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            const problems: i64 = (if (opts.fix) @as(i64, 0) else rep.stale_sessions) +
                (if (rep.integrity_ok) @as(i64, 0) else @as(i64, 1)) +
                rep.missing_blobs + (if (opts.gc) rep.orphan_blobs - rep.collected else @as(i64, 0));
            if (problems > 0) std.process.exit(1);
        },
        .diff => |opts| {
            var proj = try requireProject(allocator, false);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            views.diffSessions(allocator, &database, proj.id, opts.a, opts.b) catch |err| {
                switch (err) {
                    error.NoSuchSession => log.err("no such session in this project", .{}),
                    error.BadSessionId => log.err("bad session id", .{}),
                    else => log.err("diff failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .bundle => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            bundle.runExport(allocator, &database, proj.id, proj.root, opts.id, opts.out, opts.all) catch |err| {
                switch (err) {
                    error.NoSuchSession => log.err("no such session in this project", .{}),
                    error.BadSessionId => log.err("bad session id", .{}),
                    error.BundleExists => log.err("bundle already exists (remove it or use --out)", .{}),
                    error.BlobMissing => log.err("export failed: content missing from object store (run doctor)", .{}),
                    error.MissingTarget => log.err("usage: annalist export <session-id>|--all [--out <dir>]", .{}),
                    else => log.err("export failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .branch => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            branch.runBranch(allocator, &database, proj.id, proj.root, opts.name) catch |err| {
                switch (err) {
                    error.BadBranchName => log.err("bad branch name (1-64 chars of A-Za-z0-9_.-)", .{}),
                    else => log.err("branch failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .policy => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            policy.runPolicy(allocator, proj.root, opts.set_max_age) catch |err| {
                switch (err) {
                    error.BadRetention => log.err("bad retention (0-36500 days)", .{}),
                    else => log.err("policy failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .prune => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            policy.runPrune(allocator, &database, proj.id, proj.root, opts.older_than, opts.dry_run) catch |err| {
                switch (err) {
                    error.BadRetention => log.err("bad --older-than value (positive days)", .{}),
                    error.NeedRetention => log.err("no retention configured; pass --older-than <days>", .{}),
                    else => log.err("prune failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .unbundle => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            unbundle.runImport(allocator, &database, proj.id, proj.root, opts.dir, opts.force) catch |err| {
                switch (err) {
                    error.BadBundle => log.err("not a valid bundle (manifest.json unreadable or bad format)", .{}),
                    error.BlobMissing => log.err("bundle incomplete: blob file missing", .{}),
                    error.CorruptBundle => log.err("bundle corrupt: blob content does not match its hash", .{}),
                    error.AlreadyImported => log.err("session already imported (re-run with --force)", .{}),
                    else => log.err("import failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .gate => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            gate.runGate(allocator, &database, proj.id, proj.root, opts.session, opts.policy) catch |err| {
                switch (err) {
                    error.PolicyDeny => std.process.exit(2),
                    error.NoSuchSession => log.err("no session '{s}' in this project", .{opts.session}),
                    error.BadSessionId => log.err("bad session id '{s}'", .{opts.session}),
                    error.UnfinishedSession => log.err("session '{s}' is still running", .{opts.session}),
                    error.DoctorDirty => log.err("gate: storage unhealthy (run doctor)", .{}),
                    error.BlobMissing => log.err("gate: content missing from object store (run doctor)", .{}),
                    error.NoSuchPolicy => log.err("gate: policy file not found", .{}),
                    error.UnknownPolicyKey => log.err("gate: policy file has an unknown key", .{}),
                    error.BadPolicyValue => log.err("gate: policy file value is malformed", .{}),
                    error.TreeTooLarge => log.err("gate: working tree too large to scan fully", .{}),
                    else => log.err("gate failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
        .future => |name| {
            log.err("'{s}' is on the roadmap but not implemented in v0.3", .{name});
            std.process.exit(3);
        },
        .rewind => |opts| {
            var proj = try requireProject(allocator, true);
            defer proj.deinit(allocator);
            var database = try session.openDb(allocator);
            defer database.close();
            rewind.runRewind(allocator, &database, proj.id, proj.root, opts.id, opts.seq, opts.force, opts.dry_run) catch |err| {
                switch (err) {
                    error.NoSuchSession => log.err("no session '{s}' in this project", .{opts.id}),
                    error.BadSessionId => log.err("bad session id '{s}'", .{opts.id}),
                    error.BadSeq => log.err("bad event seq (must be a positive integer)", .{}),
                    error.NothingToRewind => log.err("session '{s}' recorded no file changes", .{opts.id}),
                    error.UnsafePath => log.err("refusing: session contains paths outside the project", .{}),
                    error.FileNotFound => log.err("rewind incomplete: content missing from object store (run doctor)", .{}),
                    error.Divergent => std.process.exit(1),
                    else => log.err("rewind failed: {s}", .{@errorName(err)}),
                }
                std.process.exit(1);
            };
        },
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("branch.zig"));
    std.testing.refAllDecls(@import("cli.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("db.zig"));
    std.testing.refAllDecls(@import("diff.zig"));
    std.testing.refAllDecls(@import("doctor.zig"));
    std.testing.refAllDecls(@import("events.zig"));
    std.testing.refAllDecls(@import("export.zig"));
    std.testing.refAllDecls(@import("git.zig"));
    std.testing.refAllDecls(@import("hash.zig"));
    std.testing.refAllDecls(@import("ignore.zig"));
    std.testing.refAllDecls(@import("import.zig"));
    std.testing.refAllDecls(@import("gate.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    std.testing.refAllDecls(@import("policy.zig"));
    std.testing.refAllDecls(@import("record.zig"));
    std.testing.refAllDecls(@import("rewind.zig"));
    std.testing.refAllDecls(@import("safe_fs.zig"));
    std.testing.refAllDecls(@import("scan.zig"));
    std.testing.refAllDecls(@import("server.zig"));
    std.testing.refAllDecls(@import("session.zig"));
    std.testing.refAllDecls(@import("store.zig"));
    std.testing.refAllDecls(@import("views.zig"));
}
