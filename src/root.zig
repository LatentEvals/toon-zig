//! TOON (Token-Oriented Object Notation) encoder and decoder.
//!
//! Implements the TOON v3.0 specification. See https://toonformat.dev
//! and https://github.com/toon-format/spec/blob/main/SPEC.md.

const std = @import("std");

pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const escape = @import("escape.zig");
pub const number = @import("number.zig");

pub const Value = std.json.Value;

pub const Delimiter = enum {
    comma,
    tab,
    pipe,

    pub fn char(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .pipe => '|',
        };
    }

    pub fn headerSymbol(self: Delimiter) ?u8 {
        return switch (self) {
            .comma => null,
            .tab => '\t',
            .pipe => '|',
        };
    }
};

pub const KeyFolding = enum { off, safe };
pub const ExpandPaths = enum { off, safe };

pub const EncodeOptions = struct {
    indent: u8 = 2,
    delimiter: Delimiter = .comma,
    key_folding: KeyFolding = .off,
    flatten_depth: ?u32 = null, // null means infinity
};

pub const DecodeOptions = struct {
    indent: u8 = 2,
    strict: bool = true,
    expand_paths: ExpandPaths = .off,
};

pub const EncodeError = error{
    OutOfMemory,
    WriteFailed,
    InvalidNumber,
    NoSpaceLeft,
    Overflow,
    InvalidCharacter,
};

pub const DecodeError = error{
    OutOfMemory,
    InvalidEscape,
    UnterminatedString,
    MissingColon,
    InvalidHeader,
    InvalidIndentation,
    TabInIndentation,
    CountMismatch,
    FieldCountMismatch,
    BlankLineInArray,
    DelimiterMismatch,
    InvalidNumber,
    InvalidDocument,
    ExpansionConflict,
    Overflow,
    InvalidCharacter,
};

/// Encode a JSON value to TOON. Caller owns the returned slice.
pub fn stringify(
    allocator: std.mem.Allocator,
    value: Value,
    options: EncodeOptions,
) EncodeError![]u8 {
    return encoder.stringify(allocator, value, options);
}

/// Parse a TOON document into a JSON value. The returned ParseResult owns its memory.
/// Call `result.deinit()` to free.
pub const ParseResult = struct {
    arena: *std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: ParseResult) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: DecodeOptions,
) DecodeError!ParseResult {
    return decoder.parse(allocator, input, options);
}

test {
    std.testing.refAllDecls(@This());
}
