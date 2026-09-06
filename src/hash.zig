// Content hashing and binary sniffing.

const std = @import("std");

pub const HASH_HEX_LEN = 64;

pub fn sha256Hex(data: []const u8, out_hex: *[HASH_HEX_LEN]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out_hex[i * 2] = hex[b >> 4];
        out_hex[i * 2 + 1] = hex[b & 0xf];
    }
}

/// NUL byte in the first sniff_len bytes => binary.
pub fn isBinary(data: []const u8) bool {
    const n = @min(data.len, 8192);
    return std.mem.indexOfScalar(u8, data[0..n], 0) != null;
}

const testing = std.testing;

test "sha256 stable" {
    var a: [HASH_HEX_LEN]u8 = undefined;
    var b: [HASH_HEX_LEN]u8 = undefined;
    sha256Hex("hello", &a);
    sha256Hex("hello", &b);
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &a,
    );
}

test "binary sniff" {
    try testing.expect(isBinary(&.{ 1, 2, 0, 3 }));
    try testing.expect(!isBinary("plain text\n"));
}
