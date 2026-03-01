# swatch

Comptime color conversion library for Zig. Convert between Hex, RGBA, and OKLCH with a single generic function.

## Installation

Fetch the package:

```sh
zig fetch --save git+https://github.com/zmscode/swatch
```

Then add it as an import in your `build.zig`:

```zig
const swatch = b.dependency("swatch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("swatch", swatch.module("swatch"));
```

## Usage

```zig
const swatch = @import("swatch");

const oklch = swatch.convert("#ff00ff", .hex, .oklch);
const rgba = swatch.convert(oklch, .oklch, .rgba);
const hex = swatch.convert(rgba, .rgba, .hex);

std.debug.print("{s}\n", .{hex.slice()});
// "#ff00ff"
```

### Supported formats

| Format  | Type            | Description                              |
|---------|-----------------|------------------------------------------|
| `.hex`  | `[]const u8`    | `"#RRGGBB"` or `"#RRGGBBAA"` string     |
| `.rgba` | `swatch.Rgba`   | 8-bit RGBA with optional alpha           |
| `.oklch`| `swatch.Oklch`  | Perceptual OKLCH (lightness/chroma/hue)  |

Any format can convert to any other format. All conversions route through RGBA internally.

### Hex output

Hex output returns a stack-allocated `swatch.Hex` struct (no allocator needed). Use `.slice()` to get the string:

```zig
const hex = swatch.convert(my_rgba, .rgba, .hex);
const str: []const u8 = hex.slice(); // "#ff00ff" or "#ff00ff80"
```

## Tests

```sh
zig build test
```
