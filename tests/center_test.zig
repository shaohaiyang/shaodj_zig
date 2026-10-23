//! 回归测试：弹窗里的文字必须水平居中、且不能被裁掉。
//!
//! 曾经的 bug：drawText 用 CTLineGetTypographicBounds 的 **width 出参** 来算居中位置。
//! 但部分系统（本机虚拟机）根本不写回这个出参，width 变成 0，
//! 于是 x = (w - 0) / 2 = w / 2 —— 文字从窗口正中间开始画，右半截被裁掉，
//! 看起来就是「没居中、只显示了一半」。
//!
//! 正确做法：用 CTLineGetTypographicBounds 的 **返回值**（它返回的就是宽度）。
//!
//! 跑法：`zig build test`（仅 macOS）

const std = @import("std");

// ===== 最小 CoreFoundation / CoreText / CoreGraphics 类型声明 =====

const CFAllocatorRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFAttributedStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CTLineRef = ?*anyopaque;
const CGFloat = f64;
const CGContextRef = ?*anyopaque;
const CGColorSpaceRef = ?*anyopaque;
const CGColorRef = ?*anyopaque;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

// ===== 测试参数 =====

const W: usize = 180; // 弹窗宽（点）
const H: usize = 100; // 弹窗高（点）
const SCALE: usize = 2; // backingScaleFactor
const FONT_SIZE: CGFloat = 35;
const TEXT = "平安喜乐";

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCGImageAlphaPremultipliedLast: u32 = 1;

/// 深色像素（也就是文字墨迹）的包围盒。
const BBox = struct {
    min_x: usize,
    max_x: usize,
    min_y: usize,
    max_y: usize,
    count: usize,
};

/// 一行文字的测量结果。
const LineMetrics = struct {
    width: CGFloat,
    ascent: CGFloat,
    descent: CGFloat,
};

// ===== 动态加载的函数指针 =====

var string_create: *const fn (CFAllocatorRef, [*:0]const u8, u32) callconv(.c) CFStringRef = undefined;
var attributed_create: *const fn (CFAllocatorRef, CFStringRef, CFDictionaryRef) callconv(.c) CFAttributedStringRef = undefined;
var dictionary_create: *const fn (CFAllocatorRef, ?*const ?*const anyopaque, ?*const ?*const anyopaque, c_int, ?*const anyopaque, ?*const anyopaque) callconv(.c) CFDictionaryRef = undefined;
var font_create: *const fn (CFStringRef, CGFloat, ?*const anyopaque) callconv(.c) CTFontRef = undefined;
var line_create: *const fn (CFAttributedStringRef) callconv(.c) CTLineRef = undefined;
var line_bounds: *const fn (CTLineRef, ?*CGFloat, ?*CGFloat, ?*CGFloat, ?*CGFloat) callconv(.c) CGFloat = undefined;
var line_draw: *const fn (CTLineRef, CGContextRef) callconv(.c) void = undefined;
var bitmap_context_create: *const fn (?*anyopaque, usize, usize, usize, usize, CGColorSpaceRef, u32) callconv(.c) CGContextRef = undefined;
var context_release: *const fn (CGContextRef) callconv(.c) void = undefined;
var color_space_create: *const fn () callconv(.c) CGColorSpaceRef = undefined;
var color_space_release: *const fn (CGColorSpaceRef) callconv(.c) void = undefined;
var color_create: *const fn (CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) CGColorRef = undefined;
var color_release: *const fn (CGColorRef) callconv(.c) void = undefined;
var set_rgb_fill: *const fn (CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void = undefined;
var fill_rect: *const fn (CGContextRef, CGRect) callconv(.c) void = undefined;
var scale_ctm: *const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void = undefined;
var set_text_position: *const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void = undefined;

// ===== 动态加载的全局常量 =====

var kCTFontAttributeName: ?*const anyopaque = null;
var kCTForegroundColorAttributeName: ?*const anyopaque = null;
var kCFAllocatorDefault: CFAllocatorRef = null;
var kCFTypeDictionaryKeyCallBacks: ?*const anyopaque = null;
var kCFTypeDictionaryValueCallBacks: ?*const anyopaque = null;

/// 自带缓冲区：stride 明确 = W*SCALE*4，读回来的像素不会错位。
var pixels: [W * SCALE * H * SCALE * 4]u8 = undefined;

/// 程序入口：加载系统 API，跑完所有字体检查，最后打印结果。
pub fn main() !void {
    try loadApis();
    const failures = try runAllChecks();
    report(failures);
}

/// 打开 macOS 系统框架，并把需要的函数和常量地址填进全局变量。
fn loadApis() !void {
    var h_cf = try std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
    var h_ct = try std.DynLib.open("/System/Library/Frameworks/CoreText.framework/CoreText");
    var h_cg = try std.DynLib.open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics");

    string_create = h_cf.lookup(*const fn (CFAllocatorRef, [*:0]const u8, u32) callconv(.c) CFStringRef, "CFStringCreateWithCString").?;
    attributed_create = h_cf.lookup(*const fn (CFAllocatorRef, CFStringRef, CFDictionaryRef) callconv(.c) CFAttributedStringRef, "CFAttributedStringCreate").?;
    dictionary_create = h_cf.lookup(*const fn (CFAllocatorRef, ?*const ?*const anyopaque, ?*const ?*const anyopaque, c_int, ?*const anyopaque, ?*const anyopaque) callconv(.c) CFDictionaryRef, "CFDictionaryCreate").?;
    font_create = h_ct.lookup(*const fn (CFStringRef, CGFloat, ?*const anyopaque) callconv(.c) CTFontRef, "CTFontCreateWithName").?;
    line_create = h_ct.lookup(*const fn (CFAttributedStringRef) callconv(.c) CTLineRef, "CTLineCreateWithAttributedString").?;
    line_bounds = h_ct.lookup(*const fn (CTLineRef, ?*CGFloat, ?*CGFloat, ?*CGFloat, ?*CGFloat) callconv(.c) CGFloat, "CTLineGetTypographicBounds").?;
    line_draw = h_ct.lookup(*const fn (CTLineRef, CGContextRef) callconv(.c) void, "CTLineDraw").?;
    bitmap_context_create = h_cg.lookup(*const fn (?*anyopaque, usize, usize, usize, usize, CGColorSpaceRef, u32) callconv(.c) CGContextRef, "CGBitmapContextCreate").?;
    context_release = h_cg.lookup(*const fn (CGContextRef) callconv(.c) void, "CGContextRelease").?;
    color_space_create = h_cg.lookup(*const fn () callconv(.c) CGColorSpaceRef, "CGColorSpaceCreateDeviceRGB").?;
    color_space_release = h_cg.lookup(*const fn (CGColorSpaceRef) callconv(.c) void, "CGColorSpaceRelease").?;
    // 注意：CGColorCreate 在部分系统上会崩，用 CGColorCreateGenericRGB。
    color_create = h_cg.lookup(*const fn (CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) CGColorRef, "CGColorCreateGenericRGB").?;
    color_release = h_cg.lookup(*const fn (CGColorRef) callconv(.c) void, "CGColorRelease").?;
    set_rgb_fill = h_cg.lookup(*const fn (CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void, "CGContextSetRGBFillColor").?;
    fill_rect = h_cg.lookup(*const fn (CGContextRef, CGRect) callconv(.c) void, "CGContextFillRect").?;
    scale_ctm = h_cg.lookup(*const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void, "CGContextScaleCTM").?;
    set_text_position = h_cg.lookup(*const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void, "CGContextSetTextPosition").?;

    kCTFontAttributeName = h_ct.lookup(*const ?*const anyopaque, "kCTFontAttributeName").?.*;
    kCTForegroundColorAttributeName = h_ct.lookup(*const ?*const anyopaque, "kCTForegroundColorAttributeName").?.*;
    kCFAllocatorDefault = h_cf.lookup(*const CFAllocatorRef, "kCFAllocatorDefault").?.*;
    kCFTypeDictionaryKeyCallBacks = h_cf.lookup(*const ?*const anyopaque, "kCFTypeDictionaryKeyCallBacks").?.*;
    kCFTypeDictionaryValueCallBacks = h_cf.lookup(*const ?*const anyopaque, "kCFTypeDictionaryValueCallBacks").?.*;
}

/// 依次执行所有检查，返回失败的检查项数量。
fn runAllChecks() !usize {
    // 旧做法（本机的 width 出参拿不到值）：只打印，不作为断言。
    try printOldBehavior();

    var failures: usize = 0;
    for ([_][:0]const u8{ "Kaiti SC", "PingFang SC", "STSong", "Heiti SC", "Songti SC" }) |family| {
        failures += try checkFont(family);
    }
    return failures;
}

/// 用旧做法渲染一次并打印结果，方便和正确做法对比。
fn printOldBehavior() !void {
    const bbox = try render("Kaiti SC", false);
    std.debug.print("旧做法（宽度取出参）: ink x=[{d}..{d}] count={d} 居中={}\n", .{
        bbox.min_x, bbox.max_x, bbox.count, isCentered(bbox),
    });
}

/// 检查一个字体：文字必须画出来、水平居中、左右都不能被裁掉。
///
/// 返回这个字体失败的检查项数量（0 表示全部通过）。
fn checkFont(family: [:0]const u8) !usize {
    const bbox = try render(family, true);
    const centered = isCentered(bbox);

    std.debug.print("新做法（宽度取返回值）font={s: <12} ink x=[{d}..{d}] y=[{d}..{d}] count={d} 居中={}\n", .{
        family, bbox.min_x, bbox.max_x, bbox.min_y, bbox.max_y, bbox.count, centered,
    });

    if (bbox.count == 0) {
        std.debug.print("  !! 没有画出任何文字\n", .{});
        return 1;
    }

    var failures: usize = 0;
    if (!centered) {
        std.debug.print("  !! 文字没有水平居中\n", .{});
        failures += 1;
    }
    if (bbox.max_x >= W * SCALE) {
        std.debug.print("  !! 文字被右边缘裁掉\n", .{});
        failures += 1;
    }
    if (bbox.min_x == 0) {
        std.debug.print("  !! 文字被左边缘裁掉\n", .{});
        failures += 1;
    }
    return failures;
}

/// 打印最终结果；有失败项就用退出码 1 结束。
fn report(failures: usize) void {
    if (failures > 0) {
        std.debug.print("\nFAILED: {d} 项检查没通过\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nPASS: 文字水平居中且完整\n", .{});
}

/// 按 backend_mac.zig 的做法把一段文字画进位图，返回文字像素的包围盒。
///
/// width_from_return = true  → 宽度取 CTLineGetTypographicBounds 的返回值（正确做法）
/// width_from_return = false → 宽度取 width 出参（旧做法，部分系统上拿到 0）
fn render(family: [:0]const u8, width_from_return: bool) !BBox {
    const line = try makeLine(family);
    const metrics = measureLine(line, width_from_return);
    try drawToBitmap(line, metrics);
    return findInkBox();
}

/// 创建一行带字体和黑色前景色的 CoreText 文本。
fn makeLine(family: [:0]const u8) !CTLineRef {
    const name = string_create(kCFAllocatorDefault, family.ptr, kCFStringEncodingUTF8) orelse return error.Str;
    const font = font_create(name, FONT_SIZE, null) orelse return error.Font;
    const text_str = string_create(kCFAllocatorDefault, TEXT.ptr, kCFStringEncodingUTF8) orelse return error.Str;

    const black = color_create(0, 0, 0, 1) orelse return error.Color;
    defer color_release(black);

    var keys = [_]?*const anyopaque{ kCTFontAttributeName, kCTForegroundColorAttributeName };
    var values = [_]?*const anyopaque{ font, black };
    const attrs = dictionary_create(
        kCFAllocatorDefault,
        @ptrCast(&keys),
        @ptrCast(&values),
        2,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks,
    ) orelse return error.Dict;

    const attr = attributed_create(kCFAllocatorDefault, text_str, attrs) orelse return error.Attr;
    return line_create(attr) orelse error.Line;
}

/// 测量一行文字：宽度、基线以上高度、基线以下高度。
fn measureLine(line: CTLineRef, width_from_return: bool) LineMetrics {
    var ascent: CGFloat = 0;
    var descent: CGFloat = 0;
    var leading: CGFloat = 0;
    var width: CGFloat = 0;

    if (width_from_return) {
        width = line_bounds(line, &ascent, &descent, &leading, null);
    } else {
        _ = line_bounds(line, &ascent, &descent, &leading, &width);
    }

    return .{ .width = width, .ascent = ascent, .descent = descent };
}

/// 把文字画进全局像素缓冲区（白底黑字）。
fn drawToBitmap(line: CTLineRef, metrics: LineMetrics) !void {
    const space = color_space_create() orelse return error.Space;
    defer color_space_release(space);

    const pw = W * SCALE;
    const ph = H * SCALE;
    const ctx = bitmap_context_create(&pixels, pw, ph, 8, pw * 4, space, kCGImageAlphaPremultipliedLast) orelse return error.Ctx;
    defer context_release(ctx);

    // 白底
    set_rgb_fill(ctx, 1, 1, 1, 1);
    fill_rect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(pw), .height = @floatFromInt(ph) } });

    // 缩放到点坐标，方便按点排版
    scale_ctm(ctx, @floatFromInt(SCALE), @floatFromInt(SCALE));

    const text_height = metrics.ascent + metrics.descent;
    const x = (@as(CGFloat, @floatFromInt(W)) - metrics.width) / 2.0;
    const y = (@as(CGFloat, @floatFromInt(H)) - text_height) / 2.0 + metrics.descent;

    set_text_position(ctx, x, y);
    line_draw(line, ctx);
}

/// 扫描全局像素缓冲区，统计深色（文字）像素的包围盒。
fn findInkBox() BBox {
    const pw = W * SCALE;
    const ph = H * SCALE;
    const stride = pw * 4;

    var bbox = BBox{ .min_x = pw, .max_x = 0, .min_y = ph, .max_y = 0, .count = 0 };

    var yy: usize = 0;
    while (yy < ph) : (yy += 1) {
        var xx: usize = 0;
        while (xx < pw) : (xx += 1) {
            const i = yy * stride + xx * 4;

            // 透明度过半、且 RGB 都很暗，才算文字像素。
            if (pixels[i + 3] > 128 and pixels[i] < 100 and pixels[i + 1] < 100 and pixels[i + 2] < 100) {
                if (xx < bbox.min_x) bbox.min_x = xx;
                if (xx > bbox.max_x) bbox.max_x = xx;
                if (yy < bbox.min_y) bbox.min_y = yy;
                if (yy > bbox.max_y) bbox.max_y = yy;
                bbox.count += 1;
            }
        }
    }

    return bbox;
}

/// 判断左右留白是否基本相等（相差不超过总宽度的 5%）。
fn isCentered(bbox: BBox) bool {
    if (bbox.count == 0) return false;

    const pw = W * SCALE;
    const left: i64 = @intCast(bbox.min_x);
    const right: i64 = @intCast(pw - 1 - bbox.max_x);
    return @abs(left - right) * 20 <= @as(i64, @intCast(pw));
}
