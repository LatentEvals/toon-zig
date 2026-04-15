//! TOON decoder: TOON text → std.json.Value.
//!
//! The decoder uses an arena allocator for the returned value so callers can
//! free it by calling `ParseResult.deinit()`.

const std = @import("std");
const root = @import("root.zig");
const esc = @import("escape.zig");
const num = @import("number.zig");

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: root.DecodeOptions,
) !root.ParseResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var d: Decoder = .{
        .arena = arena.allocator(),
        .options = options,
        .input = input,
    };
    try d.splitLines();

    const value = try d.parseDocument();
    return .{ .arena = arena, .value = value };
}

fn allSegmentsAreIdent(key: []const u8) bool {
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| if (!esc.isIdentifierSegment(seg)) return false;
    return true;
}

fn insertPathSafe(
    arena: std.mem.Allocator,
    target: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
    strict: bool,
) DErr!void {
    var it = std.mem.splitScalar(u8, key, '.');
    var current: *std.json.ObjectMap = target;
    var last_seg: []const u8 = it.first();
    while (it.next()) |next_seg| {
        const seg = last_seg;
        last_seg = next_seg;
        const gop = try current.getOrPut(seg);
        if (gop.found_existing) {
            switch (gop.value_ptr.*) {
                .object => current = &gop.value_ptr.object,
                else => {
                    if (strict) return error.ExpansionConflict;
                    gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(arena) };
                    current = &gop.value_ptr.object;
                },
            }
        } else {
            gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(arena) };
            current = &gop.value_ptr.object;
        }
    }
    const seg = last_seg;
    if (current.getPtr(seg)) |existing_ptr| {
        try mergeOrConflict(arena, existing_ptr, value, strict);
    } else {
        try current.put(seg, value);
    }
}

fn mergeOrConflict(
    arena: std.mem.Allocator,
    target: *std.json.Value,
    incoming: std.json.Value,
    strict: bool,
) DErr!void {
    if (target.* == .object and incoming == .object) {
        var inc_it = incoming.object.iterator();
        while (inc_it.next()) |entry| {
            const tkey = entry.key_ptr.*;
            const tval = entry.value_ptr.*;
            if (target.object.getPtr(tkey)) |t_existing_ptr| {
                try mergeOrConflict(arena, t_existing_ptr, tval, strict);
            } else {
                try target.object.put(tkey, tval);
            }
        }
    } else if (strict) {
        return error.ExpansionConflict;
    } else {
        target.* = incoming;
    }
}

const Line = struct {
    raw: []const u8, // full line without the trailing \n
    content: []const u8, // line with leading indentation stripped
    depth: u32, // indentation depth (in indent units)
    indent_spaces: u32, // raw number of leading spaces
    blank: bool,
    number: u32,
    has_tab_indent: bool,
};

const DErr = root.DecodeError;

const Decoder = struct {
    arena: std.mem.Allocator,
    options: root.DecodeOptions,
    input: []const u8,
    lines: []Line = &.{},

    /// Insert a (key, value) pair into `obj`, applying safe path expansion when enabled.
    /// `was_quoted` indicates whether the key came from a quoted token in the source.
    fn putField(
        self: *Decoder,
        obj: *std.json.ObjectMap,
        key: []const u8,
        value: std.json.Value,
        was_quoted: bool,
    ) DErr!void {
        if (self.options.expand_paths == .safe and !was_quoted and
            std.mem.indexOfScalar(u8, key, '.') != null and allSegmentsAreIdent(key))
        {
            try insertPathSafe(self.arena, obj, key, value, self.options.strict);
            return;
        }
        if (obj.getPtr(key)) |existing_ptr| {
            try mergeOrConflict(self.arena, existing_ptr, value, self.options.strict);
        } else {
            try obj.put(key, value);
        }
    }

    fn splitLines(self: *Decoder) !void {
        var list = try std.ArrayList(Line).initCapacity(self.arena, 32);

        var i: usize = 0;
        var line_no: u32 = 1;
        while (i < self.input.len) {
            const start = i;
            while (i < self.input.len and self.input[i] != '\n') : (i += 1) {}
            var raw = self.input[start..i];
            // trim trailing \r for CRLF tolerance
            if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

            var spaces: u32 = 0;
            var j: usize = 0;
            var has_tab_indent = false;
            while (j < raw.len) : (j += 1) {
                if (raw[j] == ' ') {
                    spaces += 1;
                } else if (raw[j] == '\t') {
                    has_tab_indent = true;
                    break;
                } else break;
            }
            const content = raw[j..];
            const blank = content.len == 0 and !has_tab_indent;

            const depth_real: u32 = if (self.options.indent == 0) 0 else spaces / @as(u32, self.options.indent);

            try list.append(self.arena, .{
                .raw = raw,
                .content = content,
                .depth = depth_real,
                .indent_spaces = spaces,
                .blank = blank,
                .number = line_no,
                .has_tab_indent = has_tab_indent,
            });

            line_no += 1;
            if (i < self.input.len) i += 1; // skip '\n'
        }

        self.lines = try list.toOwnedSlice(self.arena);
    }

    fn parseDocument(self: *Decoder) DErr!std.json.Value {
        // Find first non-blank depth-0 line.
        var first_non_blank: ?usize = null;
        for (self.lines, 0..) |ln, idx| {
            if (!ln.blank) {
                first_non_blank = idx;
                break;
            }
        }

        if (first_non_blank == null) {
            // Empty document → empty object.
            return .{ .object = std.json.ObjectMap.init(self.arena) };
        }

        const idx = first_non_blank.?;
        const line = self.lines[idx];

        // Strict: tab indent anywhere is an error.
        if (self.options.strict) {
            for (self.lines) |ln| {
                if (!ln.blank and ln.has_tab_indent) return error.TabInIndentation;
                if (!ln.blank and self.options.indent != 0 and ln.indent_spaces % @as(u32, self.options.indent) != 0) return error.InvalidIndentation;
            }
        }

        // Root array header? (must have no key — starts with '[')
        if (line.depth == 0 and line.content.len > 0 and line.content[0] == '[' and isArrayHeaderLine(line.content)) {
            var cursor: usize = idx;
            const arr = try self.parseArrayFromHeader(null, line.content, 0, &cursor);
            if (self.options.strict) {
                var k = cursor + 1;
                while (k < self.lines.len) : (k += 1) {
                    if (!self.lines[k].blank) return error.InvalidDocument;
                }
            }
            return arr;
        }

        // Single primitive root?
        if (isSinglePrimitiveDocument(self.lines, idx)) {
            return try self.decodePrimitiveToken(line.content);
        }

        // Otherwise object.
        var cursor: usize = idx;
        return try self.parseObject(0, &cursor);
    }

    /// Parse an object consisting of sibling key-value / nested lines at `depth`.
    /// `cursor` starts at the first line of the object.
    fn parseObject(self: *Decoder, depth: u32, cursor: *usize) DErr!std.json.Value {
        var obj = std.json.ObjectMap.init(self.arena);

        while (cursor.* < self.lines.len) {
            const ln = self.lines[cursor.*];
            if (ln.blank) {
                cursor.* += 1;
                continue;
            }
            if (ln.depth < depth) break;
            if (ln.depth > depth) {
                // Unexpected deeper line at object scope.
                return error.InvalidIndentation;
            }

            const field = try self.parseKeyLine(ln.content);

            switch (field.kind) {
                .primitive => {
                    try self.putField(&obj, field.key, try self.decodePrimitiveToken(field.value), field.quoted);
                    cursor.* += 1;
                },
                .empty_object_or_container => {
                    cursor.* += 1;
                    if (self.peekDeeper(cursor.*, depth)) {
                        const nested = try self.parseObject(depth + 1, cursor);
                        try self.putField(&obj, field.key, nested, field.quoted);
                    } else {
                        try self.putField(&obj, field.key, .{ .object = std.json.ObjectMap.init(self.arena) }, field.quoted);
                    }
                },
                .array_header => {
                    var c = cursor.*;
                    const arr_val = try self.parseArrayFromHeader(field.key, ln.content, depth, &c);
                    try self.putField(&obj, field.key, arr_val, field.quoted);
                    cursor.* = c + 1;
                },
            }
        }

        return .{ .object = obj };
    }

    fn peekDeeper(self: *Decoder, from: usize, depth: u32) bool {
        var i = from;
        while (i < self.lines.len) : (i += 1) {
            const ln = self.lines[i];
            if (ln.blank) continue;
            return ln.depth > depth;
        }
        return false;
    }

    const FieldKind = enum { primitive, empty_object_or_container, array_header };
    const Field = struct {
        key: []const u8,
        kind: FieldKind,
        value: []const u8 = "",
        quoted: bool = false,
    };

    /// Parse a key: value or header line. Returns what was found.
    fn parseKeyLine(self: *Decoder, content: []const u8) !Field {
        if (isArrayHeaderLine(content)) {
            const header = try parseHeader(self.arena, content);
            return .{ .key = header.key orelse "", .kind = .array_header, .quoted = header.key_quoted };
        }

        const key_info = try parseKeyToken(self.arena, content);
        const rest = content[key_info.consumed..];
        if (rest.len == 0 or rest[0] != ':') return error.MissingColon;
        const after = rest[1..];
        if (after.len == 0) {
            return .{ .key = key_info.key, .kind = .empty_object_or_container, .quoted = key_info.quoted };
        }
        if (after[0] != ' ') return error.MissingColon;
        const value_str = after[1..];
        return .{ .key = key_info.key, .kind = .primitive, .value = value_str, .quoted = key_info.quoted };
    }

    fn decodePrimitiveToken(self: *Decoder, token: []const u8) DErr!std.json.Value {
        return try decodeValueToken(self.arena, token);
    }

    /// Parse an array given a header line (content) at `depth`, with `cursor` pointing
    /// at the header's line index. On return, `cursor` points at the last line consumed.
    fn parseArrayFromHeader(
        self: *Decoder,
        expected_key: ?[]const u8,
        content: []const u8,
        depth: u32,
        cursor: *usize,
    ) DErr!std.json.Value {
        _ = expected_key;
        const header = try parseHeader(self.arena, content);
        const dchar = header.delim;

        // Inline primitive array?
        if (header.inline_values) |inline_s| {
            if (header.fields != null) return error.InvalidHeader; // fields + inline is nonsense
            var arr = std.json.Array.init(self.arena);
            if (header.length == 0) {
                // length 0 but inline present → error (only empty header form)
                if (inline_s.len > 0) return error.CountMismatch;
            } else {
                try splitAndDecode(self.arena, inline_s, dchar, &arr);
            }
            if (self.options.strict and arr.items.len != header.length) return error.CountMismatch;
            return .{ .array = arr };
        }

        if (header.length == 0) {
            // Empty array
            return .{ .array = std.json.Array.init(self.arena) };
        }

        // Tabular?
        if (header.fields) |fields| {
            return try self.parseTabularRows(fields, header.field_quoted, dchar, header.length, depth, cursor);
        }

        // Expanded list
        return try self.parseExpandedList(dchar, header.length, depth, cursor);
    }

    fn parseTabularRows(
        self: *Decoder,
        fields: [][]const u8,
        field_quoted: ?[]bool,
        dchar: u8,
        count: u32,
        depth: u32,
        cursor: *usize,
    ) DErr!std.json.Value {
        var arr = std.json.Array.init(self.arena);
        const row_depth = depth + 1;
        var rows_read: u32 = 0;

        var saw_nonblank_after_header = false;
        var i = cursor.* + 1;
        while (i < self.lines.len) : (i += 1) {
            const ln = self.lines[i];
            if (ln.blank) {
                if (self.options.strict and saw_nonblank_after_header and rows_read < count) return error.BlankLineInArray;
                continue;
            }
            if (ln.depth < row_depth) break;
            if (ln.depth > row_depth) return error.InvalidIndentation;
            saw_nonblank_after_header = true;

            if (rows_read >= count) break;

            // Decode row
            var row_obj = std.json.ObjectMap.init(self.arena);
            var tokens = try std.ArrayList([]const u8).initCapacity(self.arena, fields.len);
            try splitDelimited(self.arena, ln.content, dchar, &tokens);
            if (self.options.strict and tokens.items.len != fields.len) return error.FieldCountMismatch;
            if (tokens.items.len != fields.len) return error.FieldCountMismatch;
            for (fields, 0..) |f, k| {
                const fq = if (field_quoted) |fqs| fqs[k] else false;
                try self.putField(&row_obj, f, try decodeValueToken(self.arena, std.mem.trim(u8, tokens.items[k], " ")), fq);
            }
            try arr.append(.{ .object = row_obj });
            rows_read += 1;
            cursor.* = i;
        }

        if (self.options.strict and rows_read != count) return error.CountMismatch;
        return .{ .array = arr };
    }

    fn parseExpandedList(
        self: *Decoder,
        dchar: u8,
        count: u32,
        depth: u32,
        cursor: *usize,
    ) DErr!std.json.Value {
        _ = dchar;
        var arr = std.json.Array.init(self.arena);
        const item_depth = depth + 1;
        var items_read: u32 = 0;

        var saw_nonblank_after_header = false;
        var i = cursor.* + 1;
        while (i < self.lines.len) {
            const ln = self.lines[i];
            if (ln.blank) {
                if (self.options.strict and saw_nonblank_after_header and items_read < count) return error.BlankLineInArray;
                i += 1;
                continue;
            }
            if (ln.depth < item_depth) break;
            if (ln.depth > item_depth) return error.InvalidIndentation;
            saw_nonblank_after_header = true;

            if (items_read >= count) break;

            if (ln.content.len == 0 or ln.content[0] != '-') return error.InvalidDocument;
            // Empty list item: "-" by itself → empty object
            if (ln.content.len == 1) {
                try arr.append(.{ .object = std.json.ObjectMap.init(self.arena) });
                cursor.* = i;
                items_read += 1;
                i += 1;
                continue;
            }
            if (ln.content[1] != ' ') return error.InvalidDocument;
            const after = ln.content[2..];

            // Three cases:
            //  - inline array:  "[M]: ..." or "[M<d>]: ..."
            //  - object with first field: "key:" or "key: val" or "key[N]..."
            //  - primitive:     other
            if (after.len > 0 and after[0] == '[') {
                // Item is an inline array
                var c = i;
                const val = try self.parseInlineArrayItem(after, &c);
                try arr.append(val);
                cursor.* = c;
                i = c + 1;
            } else if (looksLikeObjectHead(after)) {
                var c = i;
                const val = try self.parseListItemObject(after, item_depth, &c);
                try arr.append(val);
                cursor.* = c;
                i = c + 1;
            } else {
                // Primitive
                const val = try decodeValueToken(self.arena, after);
                try arr.append(val);
                cursor.* = i;
                i += 1;
            }
            items_read += 1;
        }

        if (self.options.strict and items_read != count) return error.CountMismatch;
        return .{ .array = arr };
    }

    fn parseInlineArrayItem(self: *Decoder, after: []const u8, cursor: *usize) DErr!std.json.Value {
        // after starts with '[' and represents a full inline array header.
        const header = try parseHeader(self.arena, after);
        _ = header;
        // Re-use parseArrayFromHeader with the same content; cursor handling would duplicate
        // logic. Do a minimal path: only inline (with values) or empty are valid here per §9.2.
        // For expanded inner (nested), we'd need multi-line continuation which §9.2 does not
        // generally require at the list-item position (primitive arrays only).
        // We delegate:
        return try self.parseArrayFromHeader(null, after, self.lines[cursor.*].depth, cursor);
    }

    fn parseListItemObject(self: *Decoder, after: []const u8, item_depth: u32, cursor: *usize) DErr!std.json.Value {
        var obj = std.json.ObjectMap.init(self.arena);

        // "- key: val" → first field on hyphen line, siblings at item_depth+1.
        // "- key[N]{...}:" → tabular at +2 per §10.
        if (isArrayHeaderLine(after)) {
            const header = try parseHeader(self.arena, after);
            const dchar = header.delim;
            if (header.fields) |fields| {
                // Tabular header at hyphen line: rows at item_depth+1? Spec says +2 of hyphen,
                // meaning item_depth + 1 below hyphen. But hyphen is at item_depth. So rows
                // are at item_depth + 2 (hyphen + 2 indent units from hyphen's "line" col?).
                // Spec §10: rows at depth +2 relative to hyphen line; other fields at depth +1.
                // Hyphen line depth == item_depth. Rows at item_depth + 2.
                const row_depth = item_depth + 2;
                var rows_read: u32 = 0;
                var rows = std.json.Array.init(self.arena);
                var saw_nonblank = false;
                var i = cursor.* + 1;
                while (i < self.lines.len) {
                    const ln = self.lines[i];
                    if (ln.blank) {
                        if (self.options.strict and saw_nonblank and rows_read < header.length) return error.BlankLineInArray;
                        i += 1;
                        continue;
                    }
                    if (ln.depth < item_depth + 1) break;
                    if (ln.depth == row_depth and rows_read < header.length) {
                        saw_nonblank = true;
                        var row_obj = std.json.ObjectMap.init(self.arena);
                        var tokens = try std.ArrayList([]const u8).initCapacity(self.arena, fields.len);
                        try splitDelimited(self.arena, ln.content, dchar, &tokens);
                        if (self.options.strict and tokens.items.len != fields.len) return error.FieldCountMismatch;
                        for (fields, 0..) |f, k| {
                            const fq = if (header.field_quoted) |fqs| fqs[k] else false;
                            try self.putField(&row_obj, f, try decodeValueToken(self.arena, std.mem.trim(u8, tokens.items[k], " ")), fq);
                        }
                        try rows.append(.{ .object = row_obj });
                        rows_read += 1;
                        cursor.* = i;
                        i += 1;
                        continue;
                    }
                    if (ln.depth == item_depth + 1) {
                        // Sibling field of the list-item object.
                        break;
                    }
                    return error.InvalidIndentation;
                }
                if (self.options.strict and rows_read != header.length) return error.CountMismatch;
                try self.putField(&obj, header.key orelse "", .{ .array = rows }, header.key_quoted);

                var c = cursor.*;
                try self.parseObjectFieldsInto(&obj, item_depth + 1, &c);
                cursor.* = c;
                return .{ .object = obj };
            } else {
                var c = cursor.*;
                const val = try self.parseArrayWithHeaderAtDepth(after, item_depth + 1, &c);
                try self.putField(&obj, header.key orelse "", val, header.key_quoted);
                cursor.* = c;
                var c2 = cursor.*;
                try self.parseObjectFieldsInto(&obj, item_depth + 1, &c2);
                cursor.* = c2;
                return .{ .object = obj };
            }
        }

        const key_info = try parseKeyToken(self.arena, after);
        const rest = after[key_info.consumed..];
        if (rest.len == 0 or rest[0] != ':') return error.MissingColon;
        const after_colon = rest[1..];
        if (after_colon.len == 0) {
            if (self.peekDeeper(cursor.* + 1, item_depth + 1)) {
                var c = cursor.* + 1;
                const nested = try self.parseObject(item_depth + 2, &c);
                try self.putField(&obj, key_info.key, nested, key_info.quoted);
                cursor.* = if (c == 0) 0 else c - 1;
            } else {
                try self.putField(&obj, key_info.key, .{ .object = std.json.ObjectMap.init(self.arena) }, key_info.quoted);
            }
        } else {
            if (after_colon[0] != ' ') return error.MissingColon;
            const val = try decodeValueToken(self.arena, after_colon[1..]);
            try self.putField(&obj, key_info.key, val, key_info.quoted);
        }

        // Siblings at item_depth+1
        var c2 = cursor.*;
        try self.parseObjectFieldsInto(&obj, item_depth + 1, &c2);
        cursor.* = c2;
        return .{ .object = obj };
    }

    /// Parse sibling fields of an existing object at `depth`. `cursor` is the last line
    /// already consumed (so we start at cursor+1).
    fn parseObjectFieldsInto(self: *Decoder, obj: *std.json.ObjectMap, depth: u32, cursor: *usize) DErr!void {
        var i = cursor.* + 1;
        while (i < self.lines.len) {
            const ln = self.lines[i];
            if (ln.blank) {
                i += 1;
                continue;
            }
            if (ln.depth < depth) break;
            if (ln.depth > depth) return error.InvalidIndentation;

            if (isArrayHeaderLine(ln.content)) {
                const header = try parseHeader(self.arena, ln.content);
                var c = i;
                const arr_val = try self.parseArrayWithHeaderAtDepth(ln.content, depth, &c);
                try self.putField(obj, header.key orelse "", arr_val, header.key_quoted);
                i = c + 1;
                cursor.* = c;
                continue;
            }

            const key_info = try parseKeyToken(self.arena, ln.content);
            const rest = ln.content[key_info.consumed..];
            if (rest.len == 0 or rest[0] != ':') return error.MissingColon;
            const after_colon = rest[1..];
            if (after_colon.len == 0) {
                if (self.peekDeeper(i + 1, depth)) {
                    var c: usize = i + 1;
                    const nested = try self.parseObject(depth + 1, &c);
                    try self.putField(obj, key_info.key, nested, key_info.quoted);
                    i = c;
                    cursor.* = if (c == 0) 0 else c - 1;
                } else {
                    try self.putField(obj, key_info.key, .{ .object = std.json.ObjectMap.init(self.arena) }, key_info.quoted);
                    cursor.* = i;
                    i += 1;
                }
                continue;
            }
            if (after_colon[0] != ' ') return error.MissingColon;
            try self.putField(obj, key_info.key, try decodeValueToken(self.arena, after_colon[1..]), key_info.quoted);
            cursor.* = i;
            i += 1;
        }
    }

    /// Parse an array whose header line is at `depth`. `cursor` starts at that line,
    /// ends at the last consumed line.
    fn parseArrayWithHeaderAtDepth(self: *Decoder, content: []const u8, depth: u32, cursor: *usize) DErr!std.json.Value {
        return try self.parseArrayFromHeader(null, content, depth, cursor);
    }
};

//
// --- Shared helpers (file-scope) --------------------------------------------
//

fn isSinglePrimitiveDocument(lines: []const Line, first_idx: usize) bool {
    const first = lines[first_idx];
    if (first.depth != 0) return false;
    if (isArrayHeaderLine(first.content)) return false;
    // Must not contain an unquoted colon.
    if (containsUnquotedColon(first.content)) return false;
    // Ensure no other non-blank line exists.
    var i: usize = first_idx + 1;
    while (i < lines.len) : (i += 1) {
        if (!lines[i].blank) return false;
    }
    return true;
}

fn containsUnquotedColon(s: []const u8) bool {
    var in_quotes = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_quotes) {
            if (c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_quotes = false;
            continue;
        }
        if (c == '"') {
            in_quotes = true;
            continue;
        }
        if (c == ':') return true;
    }
    return false;
}

fn looksLikeObjectHead(after: []const u8) bool {
    // Any unquoted colon? Then it's an object-on-hyphen-line.
    return containsUnquotedColon(after);
}

fn isArrayHeaderLine(content: []const u8) bool {
    // Matches: [key]?[N<d>]({fields})?:   where key may be unquoted or quoted.
    // Easier: we parse optional key, then expect '[', digits, optional HTAB/'|', ']',
    // optional {...}, then ':' (optionally followed by space + values).
    if (content.len == 0) return false;

    var i: usize = 0;

    // Skip optional key.
    if (content[0] == '"') {
        // Quoted key: scan to matching quote
        i = 1;
        while (i < content.len) : (i += 1) {
            if (content[i] == '\\' and i + 1 < content.len) {
                i += 1;
                continue;
            }
            if (content[i] == '"') {
                i += 1;
                break;
            }
        }
    } else {
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (c == '[' or c == ':' or c == ' ' or c == '\t') break;
        }
    }

    if (i >= content.len or content[i] != '[') return false;
    i += 1;
    const digit_start = i;
    while (i < content.len and std.ascii.isDigit(content[i])) : (i += 1) {}
    if (i == digit_start) return false;
    // Optional delim symbol
    if (i < content.len and (content[i] == '\t' or content[i] == '|')) i += 1;
    if (i >= content.len or content[i] != ']') return false;
    i += 1;
    // Optional fields segment
    if (i < content.len and content[i] == '{') {
        // scan to matching '}' respecting quotes
        var in_q = false;
        i += 1;
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (in_q) {
                if (c == '\\' and i + 1 < content.len) {
                    i += 1;
                    continue;
                }
                if (c == '"') in_q = false;
                continue;
            }
            if (c == '"') {
                in_q = true;
                continue;
            }
            if (c == '}') {
                i += 1;
                break;
            }
        }
    }
    // Must be followed by ':'
    if (i >= content.len or content[i] != ':') return false;
    // After ':' must be end of line or single space.
    const after = content[i + 1 ..];
    if (after.len == 0 or after[0] == ' ') return true;
    return false;
}

const Header = struct {
    key: ?[]const u8,
    key_quoted: bool = false,
    length: u32,
    delim: u8,
    delim_sym: ?u8,
    fields: ?[][]const u8,
    field_quoted: ?[]bool = null,
    inline_values: ?[]const u8, // non-null iff the header has a single space + values after ':'
};

fn parseHeader(alloc: std.mem.Allocator, content: []const u8) !Header {
    var i: usize = 0;
    var key_str: ?[]const u8 = null;
    var key_quoted = false;

    // Parse optional key.
    if (i < content.len and content[i] != '[') {
        if (content[i] == '"') {
            const res = try esc.unescape(alloc, content[i..]);
            key_str = res.string;
            i += res.consumed;
            key_quoted = true;
        } else {
            const start = i;
            while (i < content.len and content[i] != '[' and content[i] != ':') : (i += 1) {}
            if (i == start) return error.InvalidHeader;
            key_str = content[start..i];
        }
    }

    if (i >= content.len or content[i] != '[') return error.InvalidHeader;
    i += 1;
    const d_start = i;
    while (i < content.len and std.ascii.isDigit(content[i])) : (i += 1) {}
    if (i == d_start) return error.InvalidHeader;
    const length = try std.fmt.parseInt(u32, content[d_start..i], 10);

    var delim_sym: ?u8 = null;
    if (i < content.len and (content[i] == '\t' or content[i] == '|')) {
        delim_sym = content[i];
        i += 1;
    }
    if (i >= content.len or content[i] != ']') return error.InvalidHeader;
    i += 1;
    const delim_char: u8 = delim_sym orelse ',';

    var fields_out: ?[][]const u8 = null;
    var field_quoted_out: ?[]bool = null;
    if (i < content.len and content[i] == '{') {
        i += 1;
        const fstart = i;
        var in_q = false;
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (in_q) {
                if (c == '\\' and i + 1 < content.len) {
                    i += 1;
                    continue;
                }
                if (c == '"') in_q = false;
                continue;
            }
            if (c == '"') {
                in_q = true;
                continue;
            }
            if (c == '}') break;
        }
        if (i >= content.len or content[i] != '}') return error.InvalidHeader;
        const fields_s = content[fstart..i];
        i += 1;

        var fields_list = try std.ArrayList([]const u8).initCapacity(alloc, 4);
        var quoted_list = try std.ArrayList(bool).initCapacity(alloc, 4);
        var tokens = try std.ArrayList([]const u8).initCapacity(alloc, 4);
        try splitDelimitedRaw(alloc, fields_s, delim_char, &tokens);
        for (tokens.items) |t| {
            const trimmed = std.mem.trim(u8, t, " ");
            if (trimmed.len > 0 and trimmed[0] == '"') {
                const r = try esc.unescape(alloc, trimmed);
                try fields_list.append(alloc, r.string);
                try quoted_list.append(alloc, true);
            } else {
                try fields_list.append(alloc, trimmed);
                try quoted_list.append(alloc, false);
            }
        }
        fields_out = try fields_list.toOwnedSlice(alloc);
        field_quoted_out = try quoted_list.toOwnedSlice(alloc);
    }

    if (i >= content.len or content[i] != ':') return error.InvalidHeader;
    i += 1;
    var inline_val: ?[]const u8 = null;
    if (i < content.len) {
        if (content[i] != ' ') return error.InvalidHeader;
        inline_val = content[i + 1 ..];
    }

    return .{
        .key = key_str,
        .key_quoted = key_quoted,
        .length = length,
        .delim = delim_char,
        .delim_sym = delim_sym,
        .fields = fields_out,
        .field_quoted = field_quoted_out,
        .inline_values = inline_val,
    };
}

const KeyToken = struct {
    key: []const u8,
    consumed: usize, // bytes consumed from the source (including the key)
    quoted: bool = false,
};

fn parseKeyToken(alloc: std.mem.Allocator, s: []const u8) !KeyToken {
    if (s.len == 0) return error.MissingColon;
    if (s[0] == '"') {
        const r = try esc.unescape(alloc, s);
        return .{ .key = r.string, .consumed = r.consumed, .quoted = true };
    }
    var i: usize = 0;
    while (i < s.len and s[i] != ':') : (i += 1) {}
    if (i == 0) return error.MissingColon;
    return .{ .key = s[0..i], .consumed = i };
}

/// Decode a single value token (trimmed) to a JSON value.
pub fn decodeValueToken(alloc: std.mem.Allocator, raw: []const u8) DErr!std.json.Value {
    const token = std.mem.trim(u8, raw, " ");
    if (token.len == 0) return .{ .string = "" };
    if (token[0] == '"') {
        const r = try esc.unescape(alloc, token);
        if (r.consumed != token.len) return error.InvalidEscape;
        return .{ .string = r.string };
    }
    if (std.mem.eql(u8, token, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, token, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, token, "null")) return .{ .null = {} };
    if (num.isNumericToken(token)) return try num.parseNumberToken(alloc, token);
    // Else: string (duplicated into arena)
    return .{ .string = try alloc.dupe(u8, token) };
}

/// Split a delimited string (respecting quotes) and decode each into the array.
pub fn splitAndDecode(
    alloc: std.mem.Allocator,
    s: []const u8,
    delim: u8,
    out: *std.json.Array,
) !void {
    var tokens = try std.ArrayList([]const u8).initCapacity(alloc, 4);
    try splitDelimited(alloc, s, delim, &tokens);
    for (tokens.items) |tok| {
        try out.append(try decodeValueToken(alloc, tok));
    }
}

/// Split s on `delim` respecting unescaped double quotes. Tokens retain their content.
pub fn splitDelimited(
    alloc: std.mem.Allocator,
    s: []const u8,
    delim: u8,
    out: *std.ArrayList([]const u8),
) !void {
    try splitDelimitedRaw(alloc, s, delim, out);
}

fn splitDelimitedRaw(
    alloc: std.mem.Allocator,
    s: []const u8,
    delim: u8,
    out: *std.ArrayList([]const u8),
) !void {
    var start: usize = 0;
    var i: usize = 0;
    var in_q = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_q) {
            if (c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_q = false;
            continue;
        }
        if (c == '"') {
            in_q = true;
            continue;
        }
        if (c == delim) {
            try out.append(alloc, s[start..i]);
            start = i + 1;
        }
    }
    try out.append(alloc, s[start..]);
}

test "isArrayHeaderLine basic" {
    try std.testing.expect(isArrayHeaderLine("tags[3]: a,b,c"));
    try std.testing.expect(isArrayHeaderLine("users[2]{id,name}:"));
    try std.testing.expect(isArrayHeaderLine("[2]: 1,2"));
    try std.testing.expect(!isArrayHeaderLine("id: 42"));
    try std.testing.expect(!isArrayHeaderLine("hello"));
}
