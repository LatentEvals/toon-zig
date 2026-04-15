//! String escape/unescape and key/value quoting rules (§7).

const std = @import("std");
const number = @import("number.zig");

/// Write a quoted, escaped TOON string literal (including surrounding quotes).
pub fn writeQuoted(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

pub const UnescapeResult = struct {
    string: []u8,
    consumed: usize, // characters consumed including surrounding quotes
};

/// Unescape a TOON quoted string starting at src[0] (which must be '"').
/// Returns the allocated decoded string and total bytes consumed from src
/// (including both quote characters).
pub fn unescape(allocator: std.mem.Allocator, src: []const u8) !UnescapeResult {
    if (src.len == 0 or src[0] != '"') return error.UnterminatedString;
    var buf = try std.ArrayList(u8).initCapacity(allocator, src.len);
    defer buf.deinit(allocator);

    var i: usize = 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const out = try buf.toOwnedSlice(allocator);
            return .{ .string = out, .consumed = i + 1 };
        }
        if (c == '\\') {
            if (i + 1 >= src.len) return error.UnterminatedString;
            const esc = src[i + 1];
            const dec: u8 = switch (esc) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidEscape,
            };
            try buf.append(allocator, dec);
            i += 2;
            continue;
        }
        try buf.append(allocator, c);
        i += 1;
    }
    return error.UnterminatedString;
}

/// Is this key safe as an unquoted TOON key per §7.3: ^[A-Za-z_][A-Za-z0-9_.]*$
pub fn isUnquotedKey(s: []const u8) bool {
    if (s.len == 0) return false;
    const first = s[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    }
    return true;
}

/// Identifier segment for fold/expand (§1.9): ^[A-Za-z_][A-Za-z0-9_]*$
pub fn isIdentifierSegment(s: []const u8) bool {
    if (s.len == 0) return false;
    const first = s[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// Write a key, quoted if necessary.
pub fn writeKey(writer: *std.Io.Writer, key: []const u8) !void {
    if (isUnquotedKey(key)) {
        try writer.writeAll(key);
    } else {
        try writeQuoted(writer, key);
    }
}

/// Does this string need quoting per §7.2? The relevant delimiter is passed in.
pub fn needsQuoting(s: []const u8, delim: u8) bool {
    if (s.len == 0) return true;
    // Leading/trailing whitespace
    if (s[0] == ' ' or s[0] == '\t') return true;
    if (s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return true;
    // Reserved literals
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    // Numeric-like
    if (number.looksNumericForQuoting(s)) return true;
    // Leading hyphen
    if (s[0] == '-') return true;
    // Structural characters
    for (s) |c| switch (c) {
        ':', '"', '\\', '[', ']', '{', '}' => return true,
        '\n', '\r', '\t' => return true,
        else => {
            if (c == delim) return true;
        },
    };
    return false;
}

/// Write a primitive string value, quoted per §7.2 rules with the provided delimiter.
pub fn writeStringValue(writer: *std.Io.Writer, s: []const u8, delim: u8) !void {
    if (needsQuoting(s, delim)) {
        try writeQuoted(writer, s);
    } else {
        try writer.writeAll(s);
    }
}

test "isUnquotedKey" {
    try std.testing.expect(isUnquotedKey("id"));
    try std.testing.expect(isUnquotedKey("_k"));
    try std.testing.expect(isUnquotedKey("a.b.c"));
    try std.testing.expect(!isUnquotedKey("1abc"));
    try std.testing.expect(!isUnquotedKey("a-b"));
    try std.testing.expect(!isUnquotedKey(""));
}

test "needsQuoting" {
    try std.testing.expect(needsQuoting("", ','));
    try std.testing.expect(needsQuoting("true", ','));
    try std.testing.expect(needsQuoting("42", ','));
    try std.testing.expect(needsQuoting("a,b", ','));
    try std.testing.expect(needsQuoting("-foo", ','));
    try std.testing.expect(!needsQuoting("hello", ','));
    try std.testing.expect(!needsQuoting("hello world", ','));
    try std.testing.expect(!needsQuoting("café", ','));
    try std.testing.expect(!needsQuoting("a,b", '|'));
    try std.testing.expect(needsQuoting("a|b", '|'));
}
