//! Canonical number formatting and parsing per TOON §2.

const std = @import("std");

/// Format an integer (i64) in canonical form.
pub fn formatInt(writer: *std.Io.Writer, value: i64) !void {
    if (value == 0) {
        try writer.writeByte('0');
        return;
    }
    try writer.print("{d}", .{value});
}

/// Format an unsigned integer in canonical form.
pub fn formatUint(writer: *std.Io.Writer, value: u64) !void {
    try writer.print("{d}", .{value});
}

/// Canonical float formatting:
/// - no exponent notation
/// - no leading zeros except single "0"
/// - no trailing fractional zeros
/// - integer form if fractional part is zero
/// - -0 → 0
pub fn formatFloat(writer: *std.Io.Writer, raw: f64) !void {
    if (std.math.isNan(raw) or std.math.isInf(raw)) {
        try writer.writeAll("null");
        return;
    }
    var value = raw;
    if (value == 0) value = 0; // normalize -0 to 0

    // If integer-valued and within i64 range, emit as integer.
    if (@floor(value) == value and value >= -9.2233720368547758e18 and value <= 9.2233720368547758e18) {
        const as_int: i64 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(as_int)) == value) {
            try formatInt(writer, as_int);
            return;
        }
    }

    // Use a large buffer for full precision decimal formatting.
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});

    // Zig's {d} may produce exponent form for very small/large values. Detect and reformat if so.
    if (std.mem.indexOfAny(u8, s, "eE") != null) {
        try formatFloatDecimal(writer, value);
        return;
    }
    try writer.writeAll(canonicalizeDecimal(s));
}

/// Strip trailing zeros in the fractional part; drop trailing '.'.
fn canonicalizeDecimal(s: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return s;
    var end = s.len;
    while (end > dot + 1 and s[end - 1] == '0') : (end -= 1) {}
    if (end == dot + 1) end = dot; // drop trailing '.'
    return s[0..end];
}

/// Format a float as plain decimal without exponent notation.
/// Handles very small / very large numbers by converting an exponent form manually.
fn formatFloatDecimal(writer: *std.Io.Writer, value: f64) !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{e}", .{value});
    try expandExponent(writer, s);
}

/// Convert `{e}` output (e.g. "1.5e+06", "1e-06") to plain decimal.
fn expandExponent(writer: *std.Io.Writer, s: []const u8) !void {
    const e_idx = std.mem.indexOfAny(u8, s, "eE") orelse {
        try writer.writeAll(canonicalizeDecimal(s));
        return;
    };
    const mantissa = s[0..e_idx];
    const exp_str = s[e_idx + 1 ..];
    const exp = try std.fmt.parseInt(i32, exp_str, 10);

    var negative = false;
    var m = mantissa;
    if (m.len > 0 and m[0] == '-') {
        negative = true;
        m = m[1..];
    } else if (m.len > 0 and m[0] == '+') {
        m = m[1..];
    }

    const dot = std.mem.indexOfScalar(u8, m, '.');
    const int_part = if (dot) |d| m[0..d] else m;
    const frac_part = if (dot) |d| m[d + 1 ..] else "";

    // Combine digits without the decimal point.
    var digits_buf: [128]u8 = undefined;
    var digit_len: usize = 0;
    @memcpy(digits_buf[0..int_part.len], int_part);
    digit_len += int_part.len;
    @memcpy(digits_buf[digit_len..][0..frac_part.len], frac_part);
    digit_len += frac_part.len;

    const decimal_pos_original: i32 = @intCast(int_part.len);
    const decimal_pos: i32 = decimal_pos_original + exp;

    if (negative) try writer.writeByte('-');

    if (decimal_pos <= 0) {
        try writer.writeAll("0.");
        var i: i32 = 0;
        while (i < -decimal_pos) : (i += 1) try writer.writeByte('0');
        // Write digits with trailing zeros trimmed
        var end = digit_len;
        while (end > 0 and digits_buf[end - 1] == '0') : (end -= 1) {}
        try writer.writeAll(digits_buf[0..end]);
        // If all trimmed, we need at least one digit after decimal.
        if (end == 0) try writer.writeByte('0');
    } else if (@as(usize, @intCast(decimal_pos)) >= digit_len) {
        try writer.writeAll(digits_buf[0..digit_len]);
        var pad: i32 = @intCast(@as(i32, @intCast(decimal_pos)) - @as(i32, @intCast(digit_len)));
        while (pad > 0) : (pad -= 1) try writer.writeByte('0');
    } else {
        const split: usize = @intCast(decimal_pos);
        try writer.writeAll(digits_buf[0..split]);
        try writer.writeByte('.');
        var end = digit_len;
        while (end > split and digits_buf[end - 1] == '0') : (end -= 1) {}
        try writer.writeAll(digits_buf[split..end]);
    }
}

/// Is this unquoted value token a valid TOON number (per §4)?
/// Returns true if the token matches the decimal/exponent form AND does not have
/// forbidden leading zeros in the integer part.
pub fn isNumericToken(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-' or s[i] == '+') i += 1;
    const int_start = i;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    const int_len = i - int_start;
    const has_frac_or_exp = i < s.len and (s[i] == '.' or s[i] == 'e' or s[i] == 'E');
    // Forbidden leading zeros in integer part (unless single "0", or followed by frac/exp).
    if (int_len > 1 and s[int_start] == '0' and !has_frac_or_exp) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == frac_start) return false; // need at least one fractional digit
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == exp_start) return false;
    }
    return i == s.len;
}

/// Pattern used by §7.2 quoting rule: /^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i OR /^0\d+$/.
pub fn looksNumericForQuoting(s: []const u8) bool {
    if (s.len == 0) return false;
    // Leading-zero decimal: 0\d+
    if (s.len >= 2 and s[0] == '0' and std.ascii.isDigit(s[1])) {
        var all_digits = true;
        for (s) |c| if (!std.ascii.isDigit(c)) {
            all_digits = false;
            break;
        };
        if (all_digits) return true;
    }
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == frac_start) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == exp_start) return false;
    }
    return i == s.len;
}

/// Parse a numeric token (assumes isNumericToken returned true).
/// Returns an std.json.Value (integer or float).
pub fn parseNumberToken(allocator: std.mem.Allocator, s: []const u8) !std.json.Value {
    _ = allocator;
    // Try integer first.
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        if (std.fmt.parseInt(i64, s, 10)) |i| {
            return .{ .integer = i };
        } else |_| {}
    }
    const f = try std.fmt.parseFloat(f64, s);
    // If float is integer-valued and in i64 range, return as integer.
    if (std.math.isFinite(f) and @floor(f) == f and f >= -9.2233720368547758e18 and f <= 9.2233720368547758e18) {
        const as_int: i64 = @intFromFloat(f);
        if (@as(f64, @floatFromInt(as_int)) == f) return .{ .integer = as_int };
    }
    var v = f;
    if (v == 0) v = 0;
    return .{ .float = v };
}

test "isNumericToken" {
    try std.testing.expect(isNumericToken("0"));
    try std.testing.expect(isNumericToken("42"));
    try std.testing.expect(isNumericToken("-3.14"));
    try std.testing.expect(isNumericToken("1e-6"));
    try std.testing.expect(isNumericToken("0.5"));
    try std.testing.expect(isNumericToken("0e1"));
    try std.testing.expect(!isNumericToken("05"));
    try std.testing.expect(!isNumericToken("0001"));
    try std.testing.expect(!isNumericToken(""));
    try std.testing.expect(!isNumericToken("abc"));
    try std.testing.expect(!isNumericToken("1."));
    try std.testing.expect(!isNumericToken(".5"));
}

test "formatFloat canonical" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatFloat(&w, 1.5);
    try std.testing.expectEqualStrings("1.5", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try formatFloat(&w, 1.0);
    try std.testing.expectEqualStrings("1", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try formatFloat(&w, 1000000.0);
    try std.testing.expectEqualStrings("1000000", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try formatFloat(&w, -0.0);
    try std.testing.expectEqualStrings("0", w.buffered());

    w = std.Io.Writer.fixed(&buf);
    try formatFloat(&w, 0.000001);
    try std.testing.expectEqualStrings("0.000001", w.buffered());
}
