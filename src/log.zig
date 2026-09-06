// Structured internal logging. BLACKBOX_LOG=debug|info|warn|error (default warn).
// Normal command output goes to stdout; logs go to stderr.

const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

var current_level: Level = .warn;

pub fn init() void {
    const v = std.posix.getenv("BLACKBOX_LOG") orelse return;
    if (std.ascii.eqlIgnoreCase(v, "debug")) current_level = .debug;
    if (std.ascii.eqlIgnoreCase(v, "info")) current_level = .info;
    if (std.ascii.eqlIgnoreCase(v, "warn")) current_level = .warn;
    if (std.ascii.eqlIgnoreCase(v, "error") or std.ascii.eqlIgnoreCase(v, "err")) current_level = .err;
}

fn active(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(current_level);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!active(.debug)) return;
    logLine("debug", fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!active(.info)) return;
    logLine("info", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!active(.warn)) return;
    logLine("warn", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (!active(.err)) return;
    logLine("error", fmt, args);
}

fn logLine(level_name: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    const stderr = &fw.interface;
    stderr.print("[blackbox:{s}] ", .{level_name}) catch return;
    stderr.print(fmt ++ "\n", args) catch return;
    stderr.flush() catch return;
}
