# TOON Format for Zig

[![Spec v3.0](https://img.shields.io/badge/spec-v3.0-blue)](https://github.com/toon-format/spec)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/conformance-358%2F358-brightgreen)](https://github.com/toon-format/spec/tree/main/tests)
[![Zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org)

Token-Oriented Object Notation (TOON) is a compact, human-readable format
designed for passing structured data to Large Language Models with significantly
reduced token usage.

This is a Zig implementation of the
[official TOON specification](https://github.com/toon-format/spec/blob/main/SPEC.md).

## Quick Example

```zig
const std = @import("std");
const toon = @import("toon");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const src =
        \\users[2]{id,name,role}:
        \\  1,Alice,admin
        \\  2,Bob,user
    ;

    var result = try toon.parse(alloc, src, .{});
    defer result.deinit();
    // result.value is a std.json.Value

    const encoded = try toon.stringify(alloc, result.value, .{});
    defer alloc.free(encoded);
    // encoded == src
}
```

## Features

- **Spec-compliant** with TOON v3.0; passes all 358 official conformance fixtures.
- **Encoder** (JSON value -> TOON) with tabular array detection, delimiter scoping
  (comma / tab / pipe), canonical number formatting, and deterministic quoting.
- **Decoder** (TOON -> JSON value) with strict-mode validation, indentation
  enforcement, root-form detection, and full quoted-string escape handling.
- **v1.5 features**: key folding (`safe`, with `flattenDepth`) on encode; path
  expansion (`safe`, deep-merge, conflict detection) on decode.
- **No external dependencies** beyond the Zig standard library.
- **Arena-allocated decode output** -- single `deinit` call frees the entire tree.

## Installation

Requires Zig 0.15.2.

Add the dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .toon = .{
        .url = "https://github.com/LatentEvals/toon-zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "toon-0.1.0-1wXXCQo3AQA8jk3o16MvgNLkKYZul2F4N9N_SlbVWczW",
    },
},
```

Then in your `build.zig`:

```zig
const toon_dep = b.dependency("toon", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toon", toon_dep.module("toon"));
```

For local development, you can also point at a path:

```zig
.toon = .{ .path = "../toon-zig" },
```

## Library Usage

### Decoding

```zig
const result = try toon.parse(alloc, input, .{});
defer result.deinit();

switch (result.value) {
    .object => |obj| {
        if (obj.get("name")) |name| {
            std.debug.print("name = {s}\n", .{name.string});
        }
    },
    else => {},
}
```

### Encoding

```zig
var obj: std.json.ObjectMap = .init(alloc);
defer obj.deinit();
try obj.put("id", .{ .integer = 1 });
try obj.put("name", .{ .string = "Ada" });

const out = try toon.stringify(alloc, .{ .object = obj }, .{});
defer alloc.free(out);
// out == "id: 1\nname: Ada"
```

### Round-tripping JSON

```zig
var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
defer parsed.deinit();

const toon_text = try toon.stringify(alloc, parsed.value, .{});
defer alloc.free(toon_text);
```

## API Reference

### `toon.parse`

```zig
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: DecodeOptions,
) DecodeError!ParseResult
```

Parses a TOON document into a `std.json.Value`. The returned `ParseResult`
owns its memory via an internal arena -- call `result.deinit()` to free.

### `toon.stringify`

```zig
pub fn stringify(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    options: EncodeOptions,
) EncodeError![]u8
```

Encodes a JSON value to a freshly allocated TOON string. Caller owns the slice.

### `EncodeOptions`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `indent` | `u8` | `2` | Spaces per indentation level. |
| `delimiter` | `Delimiter` | `.comma` | Document delimiter: `.comma`, `.tab`, or `.pipe`. |
| `key_folding` | `KeyFolding` | `.off` | `.off` or `.safe` -- collapse single-key chains into dotted paths. |
| `flatten_depth` | `?u32` | `null` | Max segments to fold (`null` = unlimited). v1.5+. |

### `DecodeOptions`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `indent` | `u8` | `2` | Expected spaces per indentation level. |
| `strict` | `bool` | `true` | Enforce count, indentation, delimiter rules from spec §14. |
| `expand_paths` | `ExpandPaths` | `.off` | `.off` or `.safe` -- split dotted keys into nested objects. v1.5+. |

## v1.5 Features

### Key Folding (Encode)

```zig
const opts: toon.EncodeOptions = .{ .key_folding = .safe };
// {"a": {"b": {"c": 1}}} -> "a.b.c: 1"

const partial: toon.EncodeOptions = .{ .key_folding = .safe, .flatten_depth = 2 };
// {"a": {"b": {"c": {"d": 1}}}} -> "a.b:\n  c:\n    d: 1"
```

Folding is collision-aware: chains are skipped when the resulting dotted key
would clash with a literal sibling or a root-level dotted key.

### Path Expansion (Decode)

```zig
const opts: toon.DecodeOptions = .{ .expand_paths = .safe };
// "a.b.c: 1" -> {"a": {"b": {"c": 1}}}
// Multiple dotted keys deep-merge; quoted dotted keys are preserved as literals.
```

In `strict = true` mode (default), conflicting paths raise
`error.ExpansionConflict`. With `strict = false`, last-write-wins applies.

## Error Handling

`parse` returns a tagged `DecodeError`; common variants include:

- `error.MissingColon` -- key without trailing `:`.
- `error.InvalidEscape` / `error.UnterminatedString` -- malformed quoted strings.
- `error.CountMismatch` / `error.FieldCountMismatch` -- array length / row width
  doesn't match the declared `[N]` / fields.
- `error.InvalidIndentation` / `error.TabInIndentation` -- strict-mode whitespace
  violations.
- `error.BlankLineInArray` -- blank line inside an array body in strict mode.
- `error.ExpansionConflict` -- path-expansion deep-merge conflict in strict mode.

`stringify` only returns allocator/write errors plus `error.InvalidNumber` for
non-finite numeric inputs that can't be normalized.

## Testing

```bash
zig build test
```

The test suite includes both the library's unit tests and the full
language-agnostic conformance suite from the
[spec repository](https://github.com/toon-format/spec/tree/main/tests).

## Resources

- [TOON Specification (v3.0)](https://github.com/toon-format/spec/blob/main/SPEC.md)
- [Conformance Test Fixtures](https://github.com/toon-format/spec/tree/main/tests)
- [Other implementations](https://toonformat.dev/ecosystem/implementations.html)
- [Reference TypeScript implementation](https://github.com/toon-format/toon)

## License

MIT
