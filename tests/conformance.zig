//! Runs the language-agnostic conformance fixtures from the TOON spec repo
//! against our encoder and decoder.

const std = @import("std");
const toon = @import("toon");

const encode_fixtures = [_][]const u8{
    @embedFile("fixtures/encode/primitives.json"),
    @embedFile("fixtures/encode/objects.json"),
    @embedFile("fixtures/encode/arrays-primitive.json"),
    @embedFile("fixtures/encode/arrays-tabular.json"),
    @embedFile("fixtures/encode/arrays-nested.json"),
    @embedFile("fixtures/encode/arrays-objects.json"),
    @embedFile("fixtures/encode/delimiters.json"),
    @embedFile("fixtures/encode/whitespace.json"),
    @embedFile("fixtures/encode/key-folding.json"),
};

const encode_names = [_][]const u8{
    "encode/primitives",
    "encode/objects",
    "encode/arrays-primitive",
    "encode/arrays-tabular",
    "encode/arrays-nested",
    "encode/arrays-objects",
    "encode/delimiters",
    "encode/whitespace",
    "encode/key-folding",
};

const decode_fixtures = [_][]const u8{
    @embedFile("fixtures/decode/primitives.json"),
    @embedFile("fixtures/decode/numbers.json"),
    @embedFile("fixtures/decode/objects.json"),
    @embedFile("fixtures/decode/arrays-primitive.json"),
    @embedFile("fixtures/decode/arrays-tabular.json"),
    @embedFile("fixtures/decode/arrays-nested.json"),
    @embedFile("fixtures/decode/delimiters.json"),
    @embedFile("fixtures/decode/whitespace.json"),
    @embedFile("fixtures/decode/root-form.json"),
    @embedFile("fixtures/decode/validation-errors.json"),
    @embedFile("fixtures/decode/indentation-errors.json"),
    @embedFile("fixtures/decode/blank-lines.json"),
    @embedFile("fixtures/decode/path-expansion.json"),
};

const decode_names = [_][]const u8{
    "decode/primitives",
    "decode/numbers",
    "decode/objects",
    "decode/arrays-primitive",
    "decode/arrays-tabular",
    "decode/arrays-nested",
    "decode/delimiters",
    "decode/whitespace",
    "decode/root-form",
    "decode/validation-errors",
    "decode/indentation-errors",
    "decode/blank-lines",
    "decode/path-expansion",
};

const TestCase = struct {
    name: []const u8,
    input: std.json.Value,
    expected: std.json.Value,
    options: ?std.json.Value = null,
    should_error: bool = false,
};

fn getEncodeOptions(opts: ?std.json.Value) toon.EncodeOptions {
    var o = toon.EncodeOptions{};
    if (opts) |v| {
        if (v != .object) return o;
        if (v.object.get("indent")) |i| switch (i) {
            .integer => |n| o.indent = @intCast(n),
            else => {},
        };
        if (v.object.get("delimiter")) |d| switch (d) {
            .string => |s| {
                if (std.mem.eql(u8, s, ",")) o.delimiter = .comma;
                if (std.mem.eql(u8, s, "\t")) o.delimiter = .tab;
                if (std.mem.eql(u8, s, "|")) o.delimiter = .pipe;
            },
            else => {},
        };
        if (v.object.get("keyFolding")) |k| switch (k) {
            .string => |s| {
                if (std.mem.eql(u8, s, "safe")) o.key_folding = .safe;
            },
            else => {},
        };
        if (v.object.get("flattenDepth")) |f| switch (f) {
            .integer => |n| o.flatten_depth = @intCast(n),
            else => {},
        };
    }
    return o;
}

fn getDecodeOptions(opts: ?std.json.Value) toon.DecodeOptions {
    var o = toon.DecodeOptions{};
    if (opts) |v| {
        if (v != .object) return o;
        if (v.object.get("indent")) |i| switch (i) {
            .integer => |n| o.indent = @intCast(n),
            else => {},
        };
        if (v.object.get("strict")) |s| switch (s) {
            .bool => |b| o.strict = b,
            else => {},
        };
        if (v.object.get("expandPaths")) |e| switch (e) {
            .string => |s| {
                if (std.mem.eql(u8, s, "safe")) o.expand_paths = .safe;
            },
            else => {},
        };
    }
    return o;
}

fn jsonEq(a: std.json.Value, b: std.json.Value) bool {
    if (@as(std.meta.Tag(std.json.Value), a) != @as(std.meta.Tag(std.json.Value), b)) {
        // Allow integer/float equivalence
        if (a == .integer and b == .float) return @as(f64, @floatFromInt(a.integer)) == b.float;
        if (a == .float and b == .integer) return a.float == @as(f64, @floatFromInt(b.integer));
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!jsonEq(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEq(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn runEncodeFixture(gpa: std.mem.Allocator, name: []const u8, body: []const u8, report: *Report) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const tests = parsed.value.object.get("tests").?.array.items;

    for (tests) |tc| {
        report.total += 1;
        const tc_name = tc.object.get("name").?.string;
        const input = tc.object.get("input").?;
        const expected = tc.object.get("expected").?;
        const opts_val = tc.object.get("options");
        const should_error = if (tc.object.get("shouldError")) |v| v == .bool and v.bool else false;

        const opts = getEncodeOptions(opts_val);
        const result = toon.stringify(gpa, input, opts);

        if (should_error) {
            if (result) |ok| {
                gpa.free(ok);
                report.failed += 1;
                std.debug.print("[{s}] {s}: expected error, got success\n", .{ name, tc_name });
            } else |_| {
                report.passed += 1;
            }
            continue;
        }

        if (result) |out| {
            defer gpa.free(out);
            if (expected != .string) {
                report.failed += 1;
                std.debug.print("[{s}] {s}: expected non-string\n", .{ name, tc_name });
                continue;
            }
            if (std.mem.eql(u8, out, expected.string)) {
                report.passed += 1;
            } else {
                report.failed += 1;
                std.debug.print("[{s}] {s}:\n  got:      |{s}|\n  expected: |{s}|\n", .{ name, tc_name, out, expected.string });
            }
        } else |err| {
            report.failed += 1;
            std.debug.print("[{s}] {s}: error {s}\n", .{ name, tc_name, @errorName(err) });
        }
    }
}

fn runDecodeFixture(gpa: std.mem.Allocator, name: []const u8, body: []const u8, report: *Report) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const tests = parsed.value.object.get("tests").?.array.items;

    for (tests) |tc| {
        report.total += 1;
        const tc_name = tc.object.get("name").?.string;
        const input = tc.object.get("input").?;
        const expected = tc.object.get("expected").?;
        const opts_val = tc.object.get("options");
        const should_error = if (tc.object.get("shouldError")) |v| v == .bool and v.bool else false;

        const opts = getDecodeOptions(opts_val);
        if (input != .string) {
            report.failed += 1;
            continue;
        }

        const result = toon.parse(gpa, input.string, opts);

        if (should_error) {
            if (result) |pr| {
                pr.deinit();
                report.failed += 1;
                std.debug.print("[{s}] {s}: expected error, got success\n", .{ name, tc_name });
            } else |_| {
                report.passed += 1;
            }
            continue;
        }

        if (result) |pr| {
            defer pr.deinit();
            if (jsonEq(pr.value, expected)) {
                report.passed += 1;
            } else {
                report.failed += 1;
                std.debug.print("[{s}] {s}: decoded value != expected\n", .{ name, tc_name });
            }
        } else |err| {
            report.failed += 1;
            std.debug.print("[{s}] {s}: error {s}\n", .{ name, tc_name, @errorName(err) });
        }
    }
}

const Report = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

test "conformance" {
    const gpa = std.testing.allocator;
    var report: Report = .{};

    inline for (encode_fixtures, encode_names) |body, name| {
        try runEncodeFixture(gpa, name, body, &report);
    }
    inline for (decode_fixtures, decode_names) |body, name| {
        try runDecodeFixture(gpa, name, body, &report);
    }

    std.debug.print(
        "\n=== TOON conformance: {d}/{d} passed ({d} failed) ===\n",
        .{ report.passed, report.total, report.failed },
    );
    if (report.failed > 0) return error.ConformanceFailures;
}
