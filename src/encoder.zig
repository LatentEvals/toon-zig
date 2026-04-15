//! TOON encoder: JSON value → TOON text.

const std = @import("std");
const root = @import("root.zig");
const escape = @import("escape.zig");
const num = @import("number.zig");

const EncodeErr = root.EncodeError;

pub fn stringify(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    options: root.EncodeOptions,
) EncodeErr![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var enc: Encoder = .{
        .w = &aw.writer,
        .options = options,
        .doc_delim = options.delimiter.char(),
        .scratch = arena.allocator(),
    };
    try enc.encodeRoot(value);

    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
}

const Encoder = struct {
    w: *std.Io.Writer,
    options: root.EncodeOptions,
    doc_delim: u8,
    scratch: std.mem.Allocator,
    root_literal_keys: ?std.StringHashMapUnmanaged(void) = null,

    fn writeIndent(self: *Encoder, depth: usize) !void {
        const n = depth * @as(usize, self.options.indent);
        var i: usize = 0;
        while (i < n) : (i += 1) try self.w.writeByte(' ');
    }

    fn encodeRoot(self: *Encoder, value: std.json.Value) EncodeErr!void {
        switch (value) {
            .array => |arr| try self.encodeRootArray(arr.items),
            .object => |obj| {
                if (obj.count() == 0) return; // empty object → empty document
                if (self.options.key_folding == .safe) {
                    var set: std.StringHashMapUnmanaged(void) = .empty;
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '.') != null) {
                            try set.put(self.scratch, entry.key_ptr.*, {});
                        }
                    }
                    self.root_literal_keys = set;
                }
                try self.encodeObjectFieldsCtx(obj, 0, true, "", self.options.flatten_depth);
            },
            else => try self.encodePrimitiveLine(value),
        }
    }

    /// Root-form single primitive: emit on one line with no trailing newline.
    fn encodePrimitiveLine(self: *Encoder, value: std.json.Value) !void {
        try self.writePrimitive(value, self.doc_delim);
    }

    fn encodeRootArray(self: *Encoder, items: []const std.json.Value) !void {
        try self.encodeArrayHeader(items, 0);
    }

    /// Encode object fields starting at `depth`. If `is_root`, do not emit a leading newline.
    fn encodeObjectFields(
        self: *Encoder,
        obj: std.json.ObjectMap,
        depth: usize,
        is_root: bool,
    ) EncodeErr!void {
        try self.encodeObjectFieldsCtx(obj, depth, is_root, "", self.options.flatten_depth);
    }

    fn encodeObjectFieldsCtx(
        self: *Encoder,
        obj: std.json.ObjectMap,
        depth: usize,
        is_root: bool,
        path_prefix: []const u8,
        remaining_depth: ?u32,
    ) EncodeErr!void {
        var first = is_root;
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (!first) try self.w.writeByte('\n');
            first = false;
            try self.writeIndent(depth);
            try self.encodeFieldCtx(entry.key_ptr.*, entry.value_ptr.*, depth, obj, path_prefix, remaining_depth);
        }
    }

    fn encodeField(
        self: *Encoder,
        key: []const u8,
        value: std.json.Value,
        depth: usize,
        siblings: ?std.json.ObjectMap,
    ) EncodeErr!void {
        try self.encodeFieldCtx(key, value, depth, siblings, "", self.options.flatten_depth);
    }

    fn encodeFieldCtx(
        self: *Encoder,
        key: []const u8,
        value: std.json.Value,
        depth: usize,
        siblings: ?std.json.ObjectMap,
        path_prefix: []const u8,
        remaining_depth: ?u32,
    ) EncodeErr!void {
        // Try safe-mode folding first if enabled.
        if (self.options.key_folding == .safe) {
            if (try self.tryFold(key, value, depth, siblings, path_prefix, remaining_depth)) return;
        }

        try escape.writeKey(self.w, key);
        switch (value) {
            .null, .bool, .integer, .float, .number_string, .string => {
                try self.w.writeAll(": ");
                try self.writePrimitive(value, self.doc_delim);
            },
            .array => |arr| try self.encodeArrayHeader(arr.items, depth),
            .object => |obj| {
                if (obj.count() == 0) {
                    try self.w.writeAll(":");
                } else {
                    try self.w.writeAll(":\n");
                    const new_prefix = try self.joinPath(path_prefix, key);
                    try self.encodeObjectFieldsCtx(obj, depth + 1, true, new_prefix, remaining_depth);
                }
            },
        }
    }

    fn joinPath(self: *Encoder, prefix: []const u8, key: []const u8) ![]const u8 {
        if (prefix.len == 0) return try self.scratch.dupe(u8, key);
        const out = try self.scratch.alloc(u8, prefix.len + 1 + key.len);
        @memcpy(out[0..prefix.len], prefix);
        out[prefix.len] = '.';
        @memcpy(out[prefix.len + 1 ..], key);
        return out;
    }

    /// Attempt to fold a single-key object chain rooted at `(key, value)`.
    /// Returns `true` if folding was applied (and the line was written).
    fn tryFold(
        self: *Encoder,
        key: []const u8,
        value: std.json.Value,
        depth: usize,
        siblings: ?std.json.ObjectMap,
        path_prefix: []const u8,
        remaining_depth: ?u32,
    ) EncodeErr!bool {
        if (value != .object) return false;
        if (!escape.isIdentifierSegment(key)) return false;

        const max_fold = remaining_depth orelse std.math.maxInt(u32);
        if (max_fold < 2) return false;

        // Walk the chain up to max_fold segments.
        var segs_buf: [64][]const u8 = undefined;
        var seg_len: usize = 1;
        segs_buf[0] = key;
        var leaf: std.json.Value = value;
        while (seg_len < max_fold and seg_len < segs_buf.len) {
            if (leaf != .object or leaf.object.count() != 1) break;
            const child_key = leaf.object.keys()[0];
            if (!escape.isIdentifierSegment(child_key)) break;
            segs_buf[seg_len] = child_key;
            seg_len += 1;
            leaf = leaf.object.values()[0];
        }
        if (seg_len < 2) return false;

        const d = seg_len;

        // Determine if chain stops at a leaf (primitive/array/empty-object) — this means
        // we fully folded the chain (no remainder).
        const fully_folded = !(leaf == .object and leaf.object.count() != 0);

        // Build the folded key string (in scratch).
        var folded_key_len: usize = 0;
        for (segs_buf[0..d], 0..) |seg, i| {
            if (i != 0) folded_key_len += 1;
            folded_key_len += seg.len;
        }
        const folded_key_buf = try self.scratch.alloc(u8, folded_key_len);
        {
            var off: usize = 0;
            for (segs_buf[0..d], 0..) |seg, i| {
                if (i != 0) {
                    folded_key_buf[off] = '.';
                    off += 1;
                }
                @memcpy(folded_key_buf[off..][0..seg.len], seg);
                off += seg.len;
            }
        }
        const folded_key = folded_key_buf;

        // Sibling-level collision.
        if (siblings) |parent| {
            var it = parent.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
                if (std.mem.eql(u8, entry.key_ptr.*, folded_key)) return false;
            }
        }

        // Root literal-key collision (against the absolute path).
        if (self.root_literal_keys) |*set| {
            const abs_path = try self.joinPath(path_prefix, folded_key);
            if (set.contains(abs_path)) return false;
        }

        // Write the folded key.
        try self.w.writeAll(folded_key);

        if (fully_folded) {
            switch (leaf) {
                .null, .bool, .integer, .float, .number_string, .string => {
                    try self.w.writeAll(": ");
                    try self.writePrimitive(leaf, self.doc_delim);
                },
                .array => |arr| try self.encodeArrayHeader(arr.items, depth),
                .object => |obj| {
                    if (obj.count() == 0) {
                        try self.w.writeAll(":");
                    } else unreachable;
                },
            }
        } else {
            // Partial fold: emit remaining structure with folding still enabled but with
            // a reduced depth budget.
            try self.w.writeAll(":\n");
            const new_remaining: ?u32 = if (remaining_depth) |r|
                if (r >= @as(u32, @intCast(d))) r - @as(u32, @intCast(d)) else 0
            else
                null;
            const new_prefix = try self.joinPath(path_prefix, folded_key);
            try self.encodeObjectFieldsCtx(leaf.object, depth + 1, true, new_prefix, new_remaining);
        }
        return true;
    }

    /// Encode an array's header and contents starting after any key prefix the caller
    /// has already written. Does not emit a trailing newline.
    fn encodeArrayHeader(
        self: *Encoder,
        items: []const std.json.Value,
        depth: usize,
    ) EncodeErr!void {
        const delim = self.options.delimiter;
        const dchar = delim.char();

        // Classify array shape.
        if (items.len == 0) {
            try self.writeBracketSegment(items.len, delim);
            try self.w.writeByte(':');
            return;
        }

        if (isPrimitiveArray(items)) {
            try self.writeBracketSegment(items.len, delim);
            try self.w.writeAll(": ");
            for (items, 0..) |item, i| {
                if (i != 0) try self.w.writeByte(dchar);
                try self.writePrimitive(item, dchar);
            }
            return;
        }

        if (detectTabular(items)) |field_order| {
            try self.writeBracketSegment(items.len, delim);
            try self.w.writeByte('{');
            for (field_order, 0..) |f, i| {
                if (i != 0) try self.w.writeByte(dchar);
                try escape.writeKey(self.w, f);
            }
            try self.w.writeAll("}:");
            for (items) |obj_val| {
                try self.w.writeByte('\n');
                try self.writeIndent(depth + 1);
                const obj = obj_val.object;
                for (field_order, 0..) |f, i| {
                    if (i != 0) try self.w.writeByte(dchar);
                    const v = obj.get(f).?;
                    try self.writePrimitive(v, dchar);
                }
            }
            return;
        }

        // Expanded / mixed array
        try self.writeBracketSegment(items.len, delim);
        try self.w.writeByte(':');
        for (items) |item| {
            try self.w.writeByte('\n');
            try self.writeIndent(depth + 1);
            if (item == .object and item.object.count() == 0) {
                try self.w.writeByte('-');
            } else {
                try self.w.writeAll("- ");
                try self.encodeListItem(item, depth + 1);
            }
        }
    }

    fn encodeListItem(self: *Encoder, value: std.json.Value, depth: usize) EncodeErr!void {
        switch (value) {
            .null, .bool, .integer, .float, .number_string, .string => {
                try self.writePrimitive(value, self.doc_delim);
            },
            .array => |arr| {
                // "- [M]: v,v..." for primitive-only; or "- [M]:" + nested.
                try self.encodeListItemArray(arr.items, depth);
            },
            .object => |obj| try self.encodeListItemObject(obj, depth),
        }
    }

    fn encodeListItemArray(self: *Encoder, items: []const std.json.Value, depth: usize) EncodeErr!void {
        const delim = self.options.delimiter;
        const dchar = delim.char();
        if (items.len == 0) {
            try self.writeBracketSegment(items.len, delim);
            try self.w.writeByte(':');
            return;
        }
        if (isPrimitiveArray(items)) {
            try self.writeBracketSegment(items.len, delim);
            try self.w.writeAll(": ");
            for (items, 0..) |item, i| {
                if (i != 0) try self.w.writeByte(dchar);
                try self.writePrimitive(item, dchar);
            }
            return;
        }
        // Non-primitive inner: expand recursively.
        try self.writeBracketSegment(items.len, delim);
        try self.w.writeByte(':');
        for (items) |item| {
            try self.w.writeByte('\n');
            try self.writeIndent(depth + 1);
            try self.w.writeAll("- ");
            try self.encodeListItem(item, depth + 1);
        }
    }

    fn encodeListItemObject(self: *Encoder, obj: std.json.ObjectMap, depth: usize) EncodeErr!void {
        if (obj.count() == 0) {
            // Bare hyphen: but we're past the "- " already. Rewind is awkward; emit nothing.
            // The caller wrote "- "; we need an empty-object form — which is just "-" with no space.
            // Since we already emitted "- ", the trailing space is incorrect. We'll emit nothing
            // and rely on the general rule being "- " followed by content. For empty object, spec
            // says a bare "-" at the list-item depth.
            // TODO(spec): this path shouldn't happen if caller pre-checks; for now produce "".
            return;
        }

        // If first field is a tabular array, emit on hyphen line per §10.
        var it = obj.iterator();
        const first = it.next().?;
        const first_key = first.key_ptr.*;
        const first_val = first.value_ptr.*;

        if (first_val == .array and first_val.array.items.len > 0 and isTabularCandidate(first_val.array.items)) {
            // "- key[N]{fields}:" on hyphen line
            try escape.writeKey(self.w, first_key);
            const delim = self.options.delimiter;
            const dchar = delim.char();
            try self.writeBracketSegment(first_val.array.items.len, delim);
            try self.w.writeByte('{');
            const field_order = detectTabular(first_val.array.items).?;
            for (field_order, 0..) |f, i| {
                if (i != 0) try self.w.writeByte(dchar);
                try escape.writeKey(self.w, f);
            }
            try self.w.writeAll("}:");
            for (first_val.array.items) |obj_val| {
                try self.w.writeByte('\n');
                try self.writeIndent(depth + 2);
                const row_obj = obj_val.object;
                for (field_order, 0..) |f, i| {
                    if (i != 0) try self.w.writeByte(dchar);
                    const v = row_obj.get(f).?;
                    try self.writePrimitive(v, dchar);
                }
            }
            // Remaining fields at depth+1
            while (it.next()) |entry| {
                try self.w.writeByte('\n');
                try self.writeIndent(depth + 1);
                try self.encodeField(entry.key_ptr.*, entry.value_ptr.*, depth + 1, obj);
            }
            return;
        }

        // Otherwise: first field on hyphen line, remaining at depth+1.
        try self.encodeField(first_key, first_val, depth + 1, obj);
        while (it.next()) |entry| {
            try self.w.writeByte('\n');
            try self.writeIndent(depth + 1);
            try self.encodeField(entry.key_ptr.*, entry.value_ptr.*, depth + 1, obj);
        }
    }

    fn writeBracketSegment(self: *Encoder, n: usize, delim: root.Delimiter) !void {
        try self.w.writeByte('[');
        try self.w.print("{d}", .{n});
        if (delim.headerSymbol()) |c| try self.w.writeByte(c);
        try self.w.writeByte(']');
    }

    fn writePrimitive(self: *Encoder, value: std.json.Value, delim: u8) !void {
        switch (value) {
            .null => try self.w.writeAll("null"),
            .bool => |b| try self.w.writeAll(if (b) "true" else "false"),
            .integer => |i| try num.formatInt(self.w, i),
            .float => |f| try num.formatFloat(self.w, f),
            .number_string => |s| try self.w.writeAll(s),
            .string => |s| try escape.writeStringValue(self.w, s, delim),
            .array, .object => unreachable, // not a primitive
        }
    }
};

fn isPrimitive(v: std.json.Value) bool {
    return switch (v) {
        .null, .bool, .integer, .float, .number_string, .string => true,
        else => false,
    };
}

fn isPrimitiveArray(items: []const std.json.Value) bool {
    for (items) |v| if (!isPrimitive(v)) return false;
    return true;
}

/// Does this array satisfy the tabular requirements of §9.3?
fn isTabularCandidate(items: []const std.json.Value) bool {
    if (items.len == 0) return false;
    for (items) |v| if (v != .object) return false;
    const first = items[0].object;
    if (first.count() == 0) return false;
    for (first.keys()) |k| {
        if (first.get(k)) |val| if (!isPrimitive(val)) return false;
    }
    for (items[1..]) |v| {
        const o = v.object;
        if (o.count() != first.count()) return false;
        for (first.keys()) |k| {
            const val = o.get(k) orelse return false;
            if (!isPrimitive(val)) return false;
        }
    }
    return true;
}

/// If items is tabular per §9.3, return the field order (from first element).
/// Returned slice is owned by the first object (keys()) — do NOT free.
fn detectTabular(items: []const std.json.Value) ?[][]const u8 {
    if (!isTabularCandidate(items)) return null;
    return @constCast(items[0].object.keys());
}

test "stringify primitive" {
    const gpa = std.testing.allocator;
    const out = try stringify(gpa, .{ .string = "hello" }, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "stringify primitive quoted" {
    const gpa = std.testing.allocator;
    const out = try stringify(gpa, .{ .string = "true" }, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("\"true\"", out);
}

test "stringify simple object" {
    const gpa = std.testing.allocator;
    var obj = std.json.ObjectMap.init(gpa);
    defer obj.deinit();
    try obj.put("id", .{ .integer = 123 });
    try obj.put("name", .{ .string = "Ada" });
    const out = try stringify(gpa, .{ .object = obj }, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("id: 123\nname: Ada", out);
}
