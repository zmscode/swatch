/// swatch — a comptime color conversion library for Zig.
///
/// Converts between Hex, RGBA, and OKLCH color formats using a single
/// generic `convert` function. All conversions route through RGBA as
/// the intermediate representation.
///
/// Usage:
///   const swatch = @import("swatch");
///   const oklch = swatch.convert("#ff00ff", .hex, .oklch);
///   const hex = swatch.convert(oklch, .oklch, .hex);
///   std.debug.print("{s}\n", .{hex.slice()});
const std = @import("std");

pub fn main(_: std.process.Init) !void {}

/// Standard 8-bit RGBA color.
/// Alpha is optional — `null` means fully opaque.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: ?u8,
};

/// OKLCH perceptual color space.
///
/// - `l`: lightness, range [0, 1]
/// - `c`: chroma, range [0, ~0.4]
/// - `h`: hue angle in degrees, range [0, 360)
/// - `a`: alpha opacity, range [0, 1]
///
/// Based on Björn Ottosson's OKLab color space.
/// See: https://bottosson.github.io/posts/oklab/
pub const Oklch = struct {
    l: f64,
    c: f64,
    h: f64,
    a: f64,
};

/// Stack-allocated hex color string — no allocator required.
///
/// Holds either `#RRGGBB` (len 7) or `#RRGGBBAA` (len 9).
/// Use `.slice()` to get the string content.
pub const Hex = struct {
    buf: [9]u8,
    len: u8,

    /// Returns the hex string as a slice, e.g. `"#ff00ff"`.
    pub fn slice(self: *const Hex) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Color format tag, used as comptime parameters for `convert`.
///
/// Each variant maps to a concrete Zig type via `Type()`:
/// - `.hex`   → `Hex`
/// - `.rgba`  → `Rgba`
/// - `.oklch` → `Oklch`
pub const Format = enum {
    hex,
    rgba,
    oklch,

    /// Returns the Zig type corresponding to this format tag.
    pub fn Type(comptime self: Format) type {
        return switch (self) {
            .hex => Hex,
            .rgba => Rgba,
            .oklch => Oklch,
        };
    }
};

/// Converts a color value between any two supported formats.
///
/// The conversion pipeline routes through RGBA as the hub:
///   `from` → `Rgba` → `to`
///
/// Input and return types are resolved at comptime based on the format
/// tags. For hex input, pass a `[]const u8` (e.g. `"#ff00ff"` or
/// `"#ff00ff80"`). The leading `#` is optional.
///
/// Identity conversions (same `from` and `to`) pass the value through
/// unchanged with no work done.
///
/// ```zig
/// const oklch = convert("#110011", .hex, .oklch);
/// const rgba  = convert(oklch,     .oklch, .rgba);
/// const hex   = convert(rgba,      .rgba,  .hex);
/// ```
pub fn convert(value: anytype, comptime from: Format, comptime to: Format) to.Type() {
    // Identity — pass through unchanged.
    if (from == to) return value;

    // Step 1: normalise input to RGBA.
    const rgba: Rgba = switch (from) {
        .rgba => value,
        .hex => parseHex(value),
        .oklch => oklchToRgba(value),
    };

    // Step 2: convert RGBA to the target format.
    return switch (to) {
        .rgba => rgba,
        .oklch => rgbaToOklch(rgba),
        .hex => formatHex(rgba),
    };
}

/// Decodes a single ASCII hex character to its 0–15 numeric value.
/// Returns 0 for invalid characters.
fn hexDigit(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// Combines two hex ASCII characters into a single byte.
/// e.g. hexPair('f', 'f') → 255
fn hexPair(hi: u8, lo: u8) u8 {
    return hexDigit(hi) << 4 | hexDigit(lo);
}

/// Encodes a 4-bit value as a lowercase hex ASCII character.
fn toHexDigit(n: u4) u8 {
    const v: u8 = n;
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

/// Writes a byte as two lowercase hex characters into `buf` at `offset`.
fn writeByte(buf: *[9]u8, offset: u8, byte: u8) void {
    buf[offset] = toHexDigit(@truncate(byte >> 4));
    buf[offset + 1] = toHexDigit(@truncate(byte & 0x0f));
}

/// Parses a `#RRGGBB` or `#RRGGBBAA` hex string into an `Rgba` value.
///
/// The leading `#` is optional. Missing channels default to 0.
/// Alpha defaults to `null` (fully opaque) when not provided.
fn parseHex(input: anytype) Rgba {
    const raw: []const u8 = input;
    // Strip optional '#' prefix.
    const s = if (raw.len > 0 and raw[0] == '#') raw[1..] else raw;

    return .{
        .r = if (s.len >= 2) hexPair(s[0], s[1]) else 0,
        .g = if (s.len >= 4) hexPair(s[2], s[3]) else 0,
        .b = if (s.len >= 6) hexPair(s[4], s[5]) else 0,
        .a = if (s.len >= 8) hexPair(s[6], s[7]) else null,
    };
}

/// Formats an `Rgba` value as a lowercase hex string.
///
/// Produces `#RRGGBB` when alpha is `null`, or `#RRGGBBAA` when present.
fn formatHex(rgba: Rgba) Hex {
    var h: Hex = .{ .buf = undefined, .len = undefined };

    h.buf[0] = '#';
    writeByte(&h.buf, 1, rgba.r);
    writeByte(&h.buf, 3, rgba.g);
    writeByte(&h.buf, 5, rgba.b);

    if (rgba.a) |a| {
        writeByte(&h.buf, 7, a);
        h.len = 9;
    } else {
        h.len = 7;
    }

    return h;
}

/// sRGB gamma companding: linear [0,1] → sRGB [0,1].
///
/// Implements the IEC 61966-2-1 piecewise transfer function.
/// Values below 0.0031308 use a linear segment; above that,
/// a power curve with exponent 1/2.4.
fn linearToSrgb(c: f64) f64 {
    return if (c <= 0.0031308)
        12.92 * c
    else
        1.055 * std.math.pow(f64, c, 1.0 / 2.4) - 0.055;
}

/// sRGB inverse companding: sRGB [0,1] → linear [0,1].
///
/// Reverses the gamma curve to recover linear-light values
/// needed for colorspace matrix transforms.
fn srgbToLinear(c: f64) f64 {
    return if (c <= 0.04045)
        c / 12.92
    else
        std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// Converts a [0,1] float to a [0,255] `u8`, rounding to nearest.
///
/// Values outside [0,1] are clamped before conversion.
fn floatToU8(v: f64) u8 {
    return @intFromFloat(@max(0.0, @min(255.0, @round(v * 255.0))));
}

/// Converts an `Rgba` color to `Oklch`.
///
/// Pipeline:
///   1. sRGB [0,255] → linear RGB [0,1] (inverse gamma)
///   2. Linear RGB → LMS cone response (M1 matrix)
///   3. Cube root for perceptual uniformity
///   4. LMS → OKLab L,a,b (M2 matrix)
///   5. OKLab cartesian → OKLCH polar (L, chroma, hue)
///
/// M1 and M2 matrices from Björn Ottosson's OKLab specification.
fn rgbaToOklch(rgba: Rgba) Oklch {
    // sRGB [0,255] → linear RGB [0,1]
    const r = srgbToLinear(@as(f64, @floatFromInt(rgba.r)) / 255.0);
    const g = srgbToLinear(@as(f64, @floatFromInt(rgba.g)) / 255.0);
    const b = srgbToLinear(@as(f64, @floatFromInt(rgba.b)) / 255.0);

    // Linear RGB → LMS (M1 matrix + cube root)
    const l_ = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m_ = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s_ = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

    // LMS → OKLab (M2 matrix)
    const lab_l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const lab_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const lab_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    // OKLab → OKLCH (cartesian → polar)
    const hue_deg = std.math.atan2(lab_b, lab_a) * (180.0 / std.math.pi);
    const alpha: f64 = if (rgba.a) |a| @as(f64, @floatFromInt(a)) / 255.0 else 1.0;

    return .{
        .l = lab_l,
        .c = @sqrt(lab_a * lab_a + lab_b * lab_b),
        .h = if (hue_deg < 0) hue_deg + 360.0 else hue_deg,
        .a = alpha,
    };
}

/// Converts an `Oklch` color to `Rgba`.
///
/// Pipeline (reverse of `rgbaToOklch`):
///   1. OKLCH polar → OKLab cartesian (hue,chroma → a,b)
///   2. OKLab → LMS (M2⁻¹ inverse matrix)
///   3. Cube to undo the cube root
///   4. LMS → linear sRGB (M1⁻¹ inverse matrix)
///   5. Linear → sRGB gamma → clamp to u8
///
/// Alpha ≥ 1.0 maps to `null` (fully opaque).
fn oklchToRgba(oklch_val: Oklch) Rgba {
    // OKLCH → OKLab (polar → cartesian)
    const h_rad = oklch_val.h * (std.math.pi / 180.0);
    const lab_a = oklch_val.c * @cos(h_rad);
    const lab_b = oklch_val.c * @sin(h_rad);

    // OKLab → LMS (M2⁻¹ inverse matrix)
    const l_ = oklch_val.l + 0.3963377774 * lab_a + 0.2158037573 * lab_b;
    const m_ = oklch_val.l - 0.1055613458 * lab_a - 0.0638541728 * lab_b;
    const s_ = oklch_val.l - 0.0894841775 * lab_a - 1.2914855480 * lab_b;

    // Cube to undo cube root
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    // LMS → linear sRGB (M1⁻¹ inverse matrix)
    const r_lin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g_lin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const b_lin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return .{
        .r = floatToU8(linearToSrgb(r_lin)),
        .g = floatToU8(linearToSrgb(g_lin)),
        .b = floatToU8(linearToSrgb(b_lin)),
        .a = if (oklch_val.a >= 1.0) null else floatToU8(oklch_val.a),
    };
}

// ---- Tests ----------------------------------------------------------------

test "hex to oklch" {
    const result = convert("#110011", .hex, .oklch);
    try std.testing.expect(result.l > 0.0);
    try std.testing.expect(result.c >= 0.0);
}

test "hex with alpha to rgba" {
    const result = convert("#ff00ff80", .hex, .rgba);
    try std.testing.expectEqual(@as(u8, 255), result.r);
    try std.testing.expectEqual(@as(u8, 0), result.g);
    try std.testing.expectEqual(@as(u8, 255), result.b);
    try std.testing.expectEqual(@as(?u8, 128), result.a);
}

test "rgba to hex roundtrip" {
    const rgba = Rgba{ .r = 17, .g = 0, .b = 17, .a = null };
    const hex = convert(rgba, .rgba, .hex);
    try std.testing.expectEqualStrings("#110011", hex.slice());
}

test "rgba to hex with alpha" {
    const rgba = Rgba{ .r = 255, .g = 0, .b = 255, .a = 128 };
    const hex = convert(rgba, .rgba, .hex);
    try std.testing.expectEqualStrings("#ff00ff80", hex.slice());
}

test "rgba to oklch to rgba roundtrip" {
    const original = Rgba{ .r = 100, .g = 150, .b = 200, .a = null };
    const oklch_val = convert(original, .rgba, .oklch);
    const back = convert(oklch_val, .oklch, .rgba);
    // Allow +/-1 due to floating point rounding through the pipeline.
    try std.testing.expect(@abs(@as(i16, original.r) - @as(i16, back.r)) <= 1);
    try std.testing.expect(@abs(@as(i16, original.g) - @as(i16, back.g)) <= 1);
    try std.testing.expect(@abs(@as(i16, original.b) - @as(i16, back.b)) <= 1);
}

test "identity conversion" {
    const original = Rgba{ .r = 42, .g = 100, .b = 200, .a = 128 };
    const result = convert(original, .rgba, .rgba);
    try std.testing.expectEqual(original, result);
}

test "hex to hex roundtrip" {
    const hex_in = "#abcdef";
    const rgba = convert(hex_in, .hex, .rgba);
    const hex_out = convert(rgba, .rgba, .hex);
    try std.testing.expectEqualStrings(hex_in, hex_out.slice());
}
