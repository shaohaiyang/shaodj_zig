//! macOS 图形后端：AppKit + CoreGraphics + CoreText。
//!
//! 全部框架都在运行时用 dlopen 加载（而不是链接 -framework），
//! 这样在 Linux 上用 zig 也能交叉编译出 macOS 的 Mach-O 可执行文件，
//! 不需要 macOS SDK；同时也避免依赖任何系统头文件。
//!
//! Objective-C 的方法调用通过 objc_msgSend 的 IMP 实现来转发：
//! 取 IMP（class_getMethodImplementation / class_getClassMethodImplementation）
//! 后转换成具体签名的函数指针再调用。之所以不用 msgSend，是因为
//! msgSend 是可变参函数，Zig 无法调用可变参的 C 函数。

const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct { w: i32, h: i32 };
pub const Popup = opaque {};

// ===================== 基础类型 =====================

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

const CGFloat = f64;
const NSPoint = extern struct { x: CGFloat, y: CGFloat };
const NSSize = extern struct { width: CGFloat, height: CGFloat };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

const CGColorSpaceRef = ?*anyopaque;
const CGContextRef = ?*anyopaque;
const CGImageRef = ?*anyopaque;
const CGColorRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFAllocatorRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CFAttributedStringRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CTLineRef = ?*anyopaque;
const CGGlyph = u16;

// ===================== 常量 =====================

const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kCGImageAlphaPremultipliedLast: u32 = 1;
const NSApplicationActivationPolicyRegular: isize = 0;
const NSBackingStoreBuffered: c_ulong = 2;
const NSWindowStyleMaskBorderless: c_ulong = 0;
const NSWindowStyleMaskUtilityPanel: c_ulong = 1 << 4;
const kCGFloatingWindowLevel: isize = 3;
const NSEventTypeLeftMouseDown: u64 = 1;
const NSEventTypeLeftMouseUp: u64 = 2;
const NSEventTypeKeyDown: u64 = 10;
const NSEventMaskAny: c_ulong = 0xFFFF_FFFF;
const kVK_Escape: u16 = 53;

// ===================== 动态加载 =====================

const OBJC = struct {
    get_class: *const fn ([*:0]const u8) callconv(.c) Id,
    sel_register_name: *const fn ([*:0]const u8) callconv(.c) Sel,
    // 所有 Objective-C 消息都通过 objc_msgSend 发送。
    //
    // 注意：不能直接调用 class_getMethodImplementation 返回的 IMP —— AppKit 内部
    // 大量使用 objc_direct 方法，直接调 IMP 会跳进错误的代码并崩溃
    // （表现为 -[NSImage initWithCGImage:size:] / -[NSImageView setImage:] 段错误）。
    msg_send: *const fn (Id, Sel) callconv(.c) Id,
    // x86_64 上返回大结构体的方法要用 objc_msgSend_stret（arm64 没有这个变体）。
    msg_send_stret: ?*const fn (Id, Sel) callconv(.c) Id,
    release: *const fn (Id) callconv(.c) void,
};

const CF = struct {
    string_create: *const fn (CFAllocatorRef, [*:0]const u8, u32) callconv(.c) CFStringRef,
    release: *const fn (?*anyopaque) callconv(.c) void,
    attributed_create: *const fn (CFAllocatorRef, CFStringRef, CFDictionaryRef) callconv(.c) CFAttributedStringRef,
    dictionary_create: *const fn (
        CFAllocatorRef,
        ?*const ?*const anyopaque,
        ?*const ?*const anyopaque,
        c_int,
        ?*const anyopaque,
        ?*const anyopaque,
    ) callconv(.c) CFDictionaryRef,
};

const CG = struct {
    color_space_create: *const fn () callconv(.c) CGColorSpaceRef,
    color_space_release: *const fn (CGColorSpaceRef) callconv(.c) void,
    bitmap_context_create: *const fn (
        ?*anyopaque,
        usize,
        usize,
        usize,
        usize,
        CGColorSpaceRef,
        u32,
    ) callconv(.c) CGContextRef,
    context_release: *const fn (CGContextRef) callconv(.c) void,
    context_create_image: *const fn (CGContextRef) callconv(.c) CGImageRef,
    image_release: *const fn (CGImageRef) callconv(.c) void,
    set_rgb_fill: *const fn (CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void,
    fill_rect: *const fn (CGContextRef, CGRect) callconv(.c) void,
    scale_ctm: *const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void,
    set_text_position: *const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void,
    color_create: *const fn (CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) CGColorRef,
    color_release: *const fn (CGColorRef) callconv(.c) void,
};

const CT = struct {
    font_create: *const fn (CFStringRef, CGFloat, ?*const anyopaque) callconv(.c) CTFontRef,
    font_get_glyphs: *const fn (CTFontRef, [*]const u16, [*]CGGlyph, isize) callconv(.c) bool,
    line_create: *const fn (CFAttributedStringRef) callconv(.c) CTLineRef,
    // 注意：返回值才是可靠的宽度。部分系统（本机虚拟机）不会写回 width 出参，
    // 用出参会得到 0，文字就会从窗口正中间开始画、右半截被裁掉。
    line_bounds: *const fn (CTLineRef, ?*CGFloat, ?*CGFloat, ?*CGFloat, ?*CGFloat) callconv(.c) CGFloat,
    line_draw: *const fn (CTLineRef, CGContextRef) callconv(.c) void,
};

var lib_objc: ?std.DynLib = null;
var lib_cf: ?std.DynLib = null;
var lib_cg: ?std.DynLib = null;
var lib_ct: ?std.DynLib = null;
// AppKit 必须一直留在内存里（下面的类方法/窗口都要用到它），所以运行期间不 dlclose
var lib_appkit: ?std.DynLib = null;

var objc: OBJC = undefined;
var cf: CF = undefined;
var cg: CG = undefined;
var ct: CT = undefined;

// 全局数据符号
var kCFAllocatorDefault: CFAllocatorRef = null;
var kCFRunLoopDefaultMode: Id = null;
var kCTFontAttributeName: CFStringRef = null;
var kCTForegroundColorAttributeName: CFStringRef = null;
var kCFTypeDictionaryKeyCallBacks: ?*const anyopaque = null;
var kCFTypeDictionaryValueCallBacks: ?*const anyopaque = null;

var app: Id = null;
var screen_w: i32 = 0;
var screen_h: i32 = 0;
var scale: CGFloat = 1.0;
var quit_requested = false;
var font_family: [:0]const u8 = "PingFang SC";
var font_size_px: CGFloat = 35;
var debug_enabled = false;

// ===================== 加载辅助 =====================

/// 打印错误信息到标准错误（相当于 Python 的 `print(..., file=sys.stderr)`）。
fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

/// 从动态库里查找一个函数的地址。
fn sym(comptime T: type, handle: *std.DynLib, name: [:0]const u8) !T {
    return handle.lookup(T, name) orelse error.MissingSymbol;
}

/// 取数据符号的值（例如 kCTFontAttributeName 这种「指针型」符号）
fn dataSymbol(comptime T: type, handle: *std.DynLib, name: [:0]const u8) ?T {
    const p = handle.lookup(*const T, name) orelse return null;
    return p.*;
}

/// 取数据符号的地址（例如 kCFTypeDictionaryKeyCallBacks 这种「结构体型」符号）
fn dataAddr(comptime T: type, handle: *std.DynLib, name: [:0]const u8) ?*const T {
    return handle.lookup(*const T, name);
}

// ===================== Objective-C 调用封装 =====================

/// 按名字取得 Objective-C 类，例如 cls("NSWindow")。
fn cls(name: [:0]const u8) Id {
    return objc.get_class(name);
}

/// 按名字取得方法选择器（selector），例如 sel("orderFrontRegardless")。
fn sel(name: [:0]const u8) Sel {
    return objc.sel_register_name(name);
}

/// 发送 Objective-C 消息（无参数）：[obj sel]
///
/// 统一走 objc_msgSend：直接调用方法 IMP 在 AppKit 上会崩（见 OBJC.msg_send 注释）。
fn send0(comptime Ret: type, obj: Id, sel_: Sel) Ret {
    const F = *const fn (Id, Sel) callconv(.c) Ret;
    const f: F = @ptrCast(objc.msg_send);
    return f(obj, sel_);
}

/// 发送 Objective-C 消息（1 个参数）：[obj sel:a0]
fn send1(comptime Ret: type, obj: Id, sel_: Sel, a0: anytype) Ret {
    const F = *const fn (Id, Sel, @TypeOf(a0)) callconv(.c) Ret;
    const f: F = @ptrCast(objc.msg_send);
    return f(obj, sel_, a0);
}

/// 发送 Objective-C 消息（2 个参数）
fn send2(comptime Ret: type, obj: Id, sel_: Sel, a0: anytype, a1: anytype) Ret {
    const F = *const fn (Id, Sel, @TypeOf(a0), @TypeOf(a1)) callconv(.c) Ret;
    const f: F = @ptrCast(objc.msg_send);
    return f(obj, sel_, a0, a1);
}

/// 发送 Objective-C 消息（3 个参数）
fn send3(comptime Ret: type, obj: Id, sel_: Sel, a0: anytype, a1: anytype, a2: anytype) Ret {
    const F = *const fn (Id, Sel, @TypeOf(a0), @TypeOf(a1), @TypeOf(a2)) callconv(.c) Ret;
    const f: F = @ptrCast(objc.msg_send);
    return f(obj, sel_, a0, a1, a2);
}

/// 发送 Objective-C 消息（4 个参数）
fn send4(comptime Ret: type, obj: Id, sel_: Sel, a0: anytype, a1: anytype, a2: anytype, a3: anytype) Ret {
    const F = *const fn (Id, Sel, @TypeOf(a0), @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) Ret;
    const f: F = @ptrCast(objc.msg_send);
    return f(obj, sel_, a0, a1, a2, a3);
}

/// 发送返回大结构体（如 NSRect）的消息。
/// x86_64 的 ABI 里大结构体通过隐藏指针返回，此时必须用 objc_msgSend_stret，
/// 否则 objc_msgSend 会把隐藏指针当成 receiver，直接崩。
fn sendStruct(comptime Ret: type, obj: Id, sel_: Sel) Ret {
    const F = *const fn (Id, Sel) callconv(.c) Ret;
    const f: F = if (comptime builtin.cpu.arch == .x86_64)
        @ptrCast(objc.msg_send_stret orelse @panic("objc_msgSend_stret 不可用"))
    else
        @ptrCast(objc.msg_send);
    return f(obj, sel_);
}

// ===================== 字体 =====================

const preferred_fonts = [_][:0]const u8{
    "STXingkai",
    "华文行楷",
    "Xingkai SC",
    "Hanzipen SC",
    "Hannotate SC",
    "方正行楷简体",
    "方正行楷繁体",
    "汉仪行楷简",
    "汉仪行楷繁",
    "叶根友行书",
    "叶根友毛笔行书",
    "李旭科毛笔行书",
    "钟齐志莽行书",
    "Kaiti SC",
    "Microsoft YaHei",
    "PingFang SC",
    "Noto Sans CJK SC",
    "SimHei",
    "Heiti SC",
    "Arial Unicode MS",
};

/// UTF-8 解码结果：Unicode 码点 + 这个字符占用的字节数。
const DecodedChar = struct { codepoint: u21, len: usize };

/// 从 UTF-8 字符串的 start 位置解码一个字符。
///
/// 如果剩余字节不够（字符串被截断），返回 null。
fn decodeUtf8(text: []const u8, start: usize) ?DecodedChar {
    const first = text[start];
    var codepoint: u21 = 0;
    var len: usize = 1;

    if (first < 0x80) {
        codepoint = first;
    } else if (first & 0xE0 == 0xC0) {
        codepoint = first & 0x1F;
        len = 2;
    } else if (first & 0xF0 == 0xE0) {
        codepoint = first & 0x0F;
        len = 3;
    } else if (first & 0xF8 == 0xF0) {
        codepoint = first & 0x07;
        len = 4;
    } else {
        codepoint = first;
    }

    if (start + len > text.len) return null;

    // 把后续字节的低 6 位依次拼进码点。
    var k: usize = 1;
    while (k < len) : (k += 1) {
        codepoint = (codepoint << 6) | (text[start + k] & 0x3F);
    }

    return .{ .codepoint = codepoint, .len = len };
}

/// 把 UTF-8 转成 UTF-16 码元（BMP 内的汉字一个码元即可）。
///
/// 这里手写最小版本，而不是引入额外依赖；转换结果用于向 CoreText 查询字形。
fn utf16Units(text: []const u8, buf: []u16) usize {
    var n: usize = 0;
    var i: usize = 0;

    while (i < text.len and n < buf.len) {
        const decoded = decodeUtf8(text, i) orelse break;
        i += decoded.len;
        n = appendUtf16(buf, n, decoded.codepoint);
    }

    return n;
}

/// 把一个 Unicode 码点追加到 UTF-16 缓冲区，返回新的写入位置。
///
/// 超过 0xFFFF 的字符要拆成两个“代理码元”才能放进 UTF-16。
fn appendUtf16(buf: []u16, n: usize, codepoint: u21) usize {
    if (codepoint < 0x10000) {
        buf[n] = @intCast(codepoint);
        return n + 1;
    }

    const cp = codepoint - 0x10000;
    if (n + 1 < buf.len) {
        buf[n] = @intCast(0xD800 + (cp >> 10));
        buf[n + 1] = @intCast(0xDC00 + (cp & 0x3FF));
        return n + 2;
    }
    return n;
}

/// 按字体名和字号创建 CoreText 字体对象。
///
/// 字体名不存在时返回 null，调用方会继续尝试下一个候选字体。
fn makeFont(family: [:0]const u8, size: CGFloat) CTFontRef {
    const name = cf.string_create(kCFAllocatorDefault, family.ptr, kCFStringEncodingUTF8) orelse return null;
    defer cf.release(name);
    return ct.font_create(name, size, null);
}

/// 判断字体是否含有中文字形
fn fontHasCjk(family: [:0]const u8) bool {
    const font = makeFont(family, font_size_px) orelse return false;
    // CTFont 是 CF 类型，用 CFRelease 释放（不依赖 CTFontRelease 是否被导出）
    defer cf.release(font);

    var chars: [16]u16 = undefined;
    var glyphs: [16]CGGlyph = undefined;
    const n = utf16Units("平安喜乐", &chars);
    if (n == 0) return false;
    const ok = ct.font_get_glyphs(font, &chars, &glyphs, @intCast(n));
    if (debug_enabled) {
        errPrint("[debug] font '{s}' 中文字形 {s}\n", .{ family, if (ok) "齐全" else "缺失" });
    }
    return ok;
}

/// 同步地从候选列表里挑第一个含中文字形的字体。
///
/// 注意：这个函数可能因为系统弹字体授权框而卡住，
/// 所以实际使用时由 pickFontFamily 放到子线程里调用。
fn pickFontFamilySync() [:0]const u8 {
    for (preferred_fonts) |f| {
        if (fontHasCjk(f)) return f;
    }
    return "PingFang SC";
}

// —— 字体探测的超时保护 ——
//
// macOS 上部分中文「受保护」字体第一次被使用时，系统可能弹出字体授权界面；
// 在没有交互界面的环境里（远程/虚拟机/后台运行）这一步会一直阻塞，
// 把整个程序卡死。这里把探测放到子线程里做，主线程最多等
// FONT_PROBE_TIMEOUT_MS 毫秒，超时就直接用系统自带的 PingFang SC。
const FONT_PROBE_TIMEOUT_MS: u64 = 2000;

const FontProbe = struct {
    /// 0 = 还在探测，1 = 探测完成
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    buf: [64]u8 = undefined,
    len: usize = 0,
};

/// 探测线程用的全局状态（线程 detach 后主函数可能已经返回，必须是全局的）
var font_probe: FontProbe = .{};
var picked_font: [64]u8 = undefined;

/// 子线程入口：调用同步探测，把结果写进全局 font_probe。
fn fontProbeThread() void {
    const family = pickFontFamilySync();
    const n = @min(family.len, font_probe.buf.len);
    @memcpy(font_probe.buf[0..n], family[0..n]);
    font_probe.len = n;
    font_probe.state.store(1, .release);
}

/// 睡眠（毫秒）
fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// 在子线程里探测中文字体，主线程最多等 FONT_PROBE_TIMEOUT_MS 毫秒。
///
/// 如果系统因为字体授权而卡住探测，就退回系统自带的 PingFang SC，
/// 确保程序不会一直卡在启动阶段。
fn pickFontFamily() [:0]const u8 {
    const thread = std.Thread.spawn(.{}, fontProbeThread, .{}) catch {
        // 起不了线程就直接同步探测
        return pickFontFamilySync();
    };
    thread.detach();

    var waited: u64 = 0;
    while (waited < FONT_PROBE_TIMEOUT_MS) {
        if (font_probe.state.load(.acquire) == 1) {
            const n = @min(font_probe.len, picked_font.len - 1);
            @memcpy(picked_font[0..n], font_probe.buf[0..n]);
            picked_font[n] = 0;
            if (debug_enabled) errPrint("[debug] 选中字体 '{s}'\n", .{picked_font[0..n :0]});
            return picked_font[0..n :0];
        }
        sleepMs(10);
        waited += 10;
    }
    if (debug_enabled) errPrint("[debug] 字体探测超时，改用 PingFang SC\n", .{});
    return "PingFang SC";
}

// ===================== 文字渲染 =====================

/// 一行文字的体积信息：宽度、基线以上高度、基线以下高度。
const LineMetrics = struct {
    width: CGFloat,
    ascent: CGFloat,
    descent: CGFloat,
};

/// 文字应该画在哪个位置（左下角原点坐标系）。
const TextPlacement = struct { x: CGFloat, y: CGFloat };

/// 把一段文字包装成 CoreText 的 CTLine（已经设置好字体和黑色）。
///
/// 返回的 CTLine 由调用方负责用 CFRelease 释放。
fn makeAttributedLine(text: [:0]const u8) CTLineRef {
    const font = makeFont(font_family, font_size_px) orelse return null;
    defer cf.release(font);

    const cf_text = cf.string_create(kCFAllocatorDefault, text.ptr, kCFStringEncodingUTF8) orelse return null;
    defer cf.release(cf_text);

    // 属性字典：字体 + 前景色
    const black = cg.color_create(0, 0, 0, 1);
    defer cg.color_release(black);

    var keys = [_]?*const anyopaque{ kCTFontAttributeName, kCTForegroundColorAttributeName };
    var values = [_]?*const anyopaque{ font, black };
    const attrs = cf.dictionary_create(
        kCFAllocatorDefault,
        @ptrCast(&keys),
        @ptrCast(&values),
        2,
        kCFTypeDictionaryKeyCallBacks,
        kCFTypeDictionaryValueCallBacks,
    ) orelse return null;
    defer cf.release(attrs);

    const attributed = cf.attributed_create(kCFAllocatorDefault, cf_text, attrs) orelse return null;
    defer cf.release(attributed);

    return ct.line_create(attributed);
}

/// 测量一行文字有多宽、基线上下各有多高。
fn measureLine(line: CTLineRef, text_len: usize) LineMetrics {
    var ascent: CGFloat = 0;
    var descent: CGFloat = 0;
    var leading: CGFloat = 0;

    // 宽度取函数返回值：CTLineGetTypographicBounds 的 width 出参在部分系统上
    // 不会被写回（拿到 0），那样算出来的居中位置会偏到窗口正中间，
    // 文字右边一半被裁掉。返回值在任何系统上都是正确的宽度。
    var width = ct.line_bounds(line, &ascent, &descent, &leading, null);
    if (!(width > 0)) {
        // 兜底：连返回值都拿不到时，按「每个汉字一个字宽」估算
        width = @as(CGFloat, @floatFromInt(text_len)) * font_size_px;
    }

    return .{ .width = width, .ascent = ascent, .descent = descent };
}

/// 计算文字的落笔位置，让它在 w×h 的矩形里水平、垂直居中。
///
/// 位图上下文的原点在左下角，所以 y 要加上 descent，
/// 才能让文字的“视觉中心”而不是“基线”居中。
fn placeLine(metrics: LineMetrics, w: CGFloat, h: CGFloat) TextPlacement {
    const text_height = metrics.ascent + metrics.descent;
    return .{
        .x = (w - metrics.width) / 2.0,
        .y = (h - text_height) / 2.0 + metrics.descent,
    };
}

/// 用 CoreText 把文字居中画到 CGContext 上。
fn drawText(ctx: CGContextRef, text: [:0]const u8, w: CGFloat, h: CGFloat) void {
    if (text.len == 0) return;

    const line = makeAttributedLine(text) orelse return;
    defer cf.release(line);

    const metrics = measureLine(line, text.len);
    const placement = placeLine(metrics, w, h);

    if (debug_enabled) {
        errPrint("[debug] text='{s}' font={s} ascent={d} descent={d} width={d} x={d} y={d} (w={d} h={d})\n", .{
            text, font_family, metrics.ascent, metrics.descent, metrics.width, placement.x, placement.y, w, h,
        });
    }

    cg.set_text_position(ctx, placement.x, placement.y);
    ct.line_draw(line, ctx);
}

/// 生成一个带背景色和文字的图片。
///
/// 返回的图片由调用方负责用 CGImageRelease 释放。
fn renderImage(w: i32, h: i32, rgb: u32, text: [:0]const u8) CGImageRef {
    // 位图像素尺寸要乘以屏幕缩放比例（Retina 屏 scale=2）。
    const pw = scaledPixels(w);
    const ph = scaledPixels(h);

    const space = cg.color_space_create() orelse return null;
    defer cg.color_space_release(space);

    const ctx = cg.bitmap_context_create(null, pw, ph, 8, 0, space, kCGImageAlphaPremultipliedLast) orelse return null;
    defer cg.context_release(ctx);
    if (debug_enabled) {
        errPrint("[debug] renderImage {d}x{d} scale={d} bitmap={d}x{d} ctx={x}\n", .{ w, h, scale, pw, ph, @intFromPtr(ctx) });
    }

    fillBackground(ctx, pw, ph, rgb);

    // 缩放到点坐标，方便按点排版
    cg.scale_ctm(ctx, scale, scale);
    drawText(ctx, text, @floatFromInt(w), @floatFromInt(h));

    const image = cg.context_create_image(ctx) orelse return null;
    if (debug_enabled) errPrint("[debug] renderImage -> image={x}\n", .{@intFromPtr(image)});
    return image;
}

/// 把“点”换算成位图像素（Retina 屏上 1 点 = 2 像素）。
fn scaledPixels(points: i32) usize {
    return @intCast(@as(i64, points) * @as(i64, @intFromFloat(scale)));
}

/// 用指定的 0xRRGGBB 颜色把整张位图填满。
fn fillBackground(ctx: CGContextRef, pw: usize, ph: usize, rgb: u32) void {
    cg.set_rgb_fill(
        ctx,
        @as(f64, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt(rgb & 0xFF)) / 255.0,
        1.0,
    );
    cg.fill_rect(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(pw), .height = @floatFromInt(ph) } });
}

// ===================== 对外接口 =====================

/// 初始化 macOS 后端：加载系统框架、创建应用、读取屏幕、建键盘窗口、选字体。
///
/// 所有框架都在运行时用 dlopen 加载，因此可以在 Linux 上交叉编译。
pub fn init() !void {
    // 中途任何一步失败，都调用 shutdown 把已经加载的库关掉。
    errdefer shutdown();

    try loadFrameworks();
    objc = try loadObjcFunctions();
    cf = try loadCfFunctions();
    cg = try loadCgFunctions();
    ct = try loadCtFunctions();

    try loadDataSymbols();

    debug_enabled = std.c.getenv("SHAODJ_DEBUG") != null;

    try setupApplication();
    try readMainScreen();
    createKeyboardPanel();

    font_family = pickFontFamily();
}

/// 打开 libobjc 和 4 个系统框架，并保存到全局变量里。
fn loadFrameworks() !void {
    var h_objc = try std.DynLib.open("/usr/lib/libobjc.A.dylib");
    errdefer h_objc.close();
    var h_cf = try std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
    errdefer h_cf.close();
    var h_cg = try std.DynLib.open("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics");
    errdefer h_cg.close();
    var h_ct = try std.DynLib.open("/System/Library/Frameworks/CoreText.framework/CoreText");
    errdefer h_ct.close();
    // AppKit 不会被系统自动加载：不显式 dlopen 的话，
    // objc_getClass("NSApplication") 会返回 NULL，后面所有窗口都建不出来。
    var h_appkit = try std.DynLib.open("/System/Library/Frameworks/AppKit.framework/AppKit");
    errdefer h_appkit.close();

    lib_objc = h_objc;
    lib_cf = h_cf;
    lib_cg = h_cg;
    lib_ct = h_ct;
    lib_appkit = h_appkit;
}

/// 填写 Objective-C 运行时函数表。
fn loadObjcFunctions() !OBJC {
    const handle = if (lib_objc) |*lib| lib else return error.MissingLibrary;

    return .{
        .get_class = try sym(*const fn ([*:0]const u8) callconv(.c) Id, handle, "objc_getClass"),
        .sel_register_name = try sym(*const fn ([*:0]const u8) callconv(.c) Sel, handle, "sel_registerName"),
        .msg_send = try sym(*const fn (Id, Sel) callconv(.c) Id, handle, "objc_msgSend"),
        // 只有 x86_64 需要 stret 变体，其它架构取不到也没关系
        .msg_send_stret = handle.lookup(*const fn (Id, Sel) callconv(.c) Id, "objc_msgSend_stret"),
        .release = try sym(*const fn (Id) callconv(.c) void, handle, "objc_release"),
    };
}

/// 填写 CoreFoundation 函数表。
fn loadCfFunctions() !CF {
    const handle = if (lib_cf) |*lib| lib else return error.MissingLibrary;

    return .{
        .string_create = try sym(*const fn (CFAllocatorRef, [*:0]const u8, u32) callconv(.c) CFStringRef, handle, "CFStringCreateWithCString"),
        .release = try sym(*const fn (?*anyopaque) callconv(.c) void, handle, "CFRelease"),
        .attributed_create = try sym(*const fn (CFAllocatorRef, CFStringRef, CFDictionaryRef) callconv(.c) CFAttributedStringRef, handle, "CFAttributedStringCreate"),
        .dictionary_create = try sym(*const fn (CFAllocatorRef, ?*const ?*const anyopaque, ?*const ?*const anyopaque, c_int, ?*const anyopaque, ?*const anyopaque) callconv(.c) CFDictionaryRef, handle, "CFDictionaryCreate"),
    };
}

/// 填写 CoreGraphics 函数表。
fn loadCgFunctions() !CG {
    const handle = if (lib_cg) |*lib| lib else return error.MissingLibrary;

    return .{
        .color_space_create = try sym(*const fn () callconv(.c) CGColorSpaceRef, handle, "CGColorSpaceCreateDeviceRGB"),
        .color_space_release = try sym(*const fn (CGColorSpaceRef) callconv(.c) void, handle, "CGColorSpaceRelease"),
        .bitmap_context_create = try sym(*const fn (?*anyopaque, usize, usize, usize, usize, CGColorSpaceRef, u32) callconv(.c) CGContextRef, handle, "CGBitmapContextCreate"),
        .context_release = try sym(*const fn (CGContextRef) callconv(.c) void, handle, "CGContextRelease"),
        .context_create_image = try sym(*const fn (CGContextRef) callconv(.c) CGImageRef, handle, "CGBitmapContextCreateImage"),
        .image_release = try sym(*const fn (CGImageRef) callconv(.c) void, handle, "CGImageRelease"),
        .set_rgb_fill = try sym(*const fn (CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void, handle, "CGContextSetRGBFillColor"),
        .fill_rect = try sym(*const fn (CGContextRef, CGRect) callconv(.c) void, handle, "CGContextFillRect"),
        .scale_ctm = try sym(*const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void, handle, "CGContextScaleCTM"),
        .set_text_position = try sym(*const fn (CGContextRef, CGFloat, CGFloat) callconv(.c) void, handle, "CGContextSetTextPosition"),
        .color_create = try sym(*const fn (CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) CGColorRef, handle, "CGColorCreateGenericRGB"),
        .color_release = try sym(*const fn (CGColorRef) callconv(.c) void, handle, "CGColorRelease"),
    };
}

/// 填写 CoreText 函数表。
fn loadCtFunctions() !CT {
    const handle = if (lib_ct) |*lib| lib else return error.MissingLibrary;

    return .{
        .font_create = try sym(*const fn (CFStringRef, CGFloat, ?*const anyopaque) callconv(.c) CTFontRef, handle, "CTFontCreateWithName"),
        .font_get_glyphs = try sym(*const fn (CTFontRef, [*]const u16, [*]CGGlyph, isize) callconv(.c) bool, handle, "CTFontGetGlyphsForCharacters"),
        .line_create = try sym(*const fn (CFAttributedStringRef) callconv(.c) CTLineRef, handle, "CTLineCreateWithAttributedString"),
        .line_bounds = try sym(*const fn (CTLineRef, ?*CGFloat, ?*CGFloat, ?*CGFloat, ?*CGFloat) callconv(.c) CGFloat, handle, "CTLineGetTypographicBounds"),
        .line_draw = try sym(*const fn (CTLineRef, CGContextRef) callconv(.c) void, handle, "CTLineDraw"),
    };
}

/// 读取 CoreFoundation / CoreText 里的全局常量（例如字体属性名）。
fn loadDataSymbols() !void {
    const h_cf = if (lib_cf) |*lib| lib else return error.MissingLibrary;
    const h_ct = if (lib_ct) |*lib| lib else return error.MissingLibrary;

    kCFAllocatorDefault = dataSymbol(*anyopaque, h_cf, "kCFAllocatorDefault") orelse null;
    kCFRunLoopDefaultMode = dataSymbol(*anyopaque, h_cf, "kCFRunLoopDefaultMode") orelse null;
    kCFTypeDictionaryKeyCallBacks = dataAddr(anyopaque, h_cf, "kCFTypeDictionaryKeyCallBacks");
    kCFTypeDictionaryValueCallBacks = dataAddr(anyopaque, h_cf, "kCFTypeDictionaryValueCallBacks");
    kCTFontAttributeName = dataSymbol(*anyopaque, h_ct, "kCTFontAttributeName") orelse null;
    kCTForegroundColorAttributeName = dataSymbol(*anyopaque, h_ct, "kCTForegroundColorAttributeName") orelse null;

    if (kCTFontAttributeName == null) {
        errPrint("[mac] 无法取到 kCTFontAttributeName，CoreText 初始化失败\n", .{});
        return error.InitFailed;
    }
}

/// 创建并激活 NSApplication，让程序能接收鼠标和键盘事件。
fn setupApplication() !void {
    const app_cls = cls("NSApplication");
    app = send0(Id, app_cls, sel("sharedApplication"));
    if (app == null) return error.InitFailed;

    send1(void, app.?, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    send0(void, app.?, sel("finishLaunching"));
    activateApplication();
}

/// 激活应用：新版 macOS 用 activate，老版本退回 activateIgnoringOtherApps。
fn activateApplication() void {
    const responds = send1(bool, app.?, sel("respondsToSelector:"), sel("activate"));
    if (responds) {
        _ = send0(bool, app.?, sel("activate"));
    } else {
        send1(void, app.?, sel("activateIgnoringOtherApps:"), true);
    }
}

/// 读取主屏幕尺寸（点）和 Retina 缩放比例。
///
/// 都从 NSScreen 取，避免依赖部分系统上没导出的 CGMainDisplaySize。
fn readMainScreen() !void {
    const screen_cls = cls("NSScreen");
    const scr = send0(Id, screen_cls, sel("mainScreen"));
    if (scr != null) {
        // frame 返回 NSRect 这种大结构体，x86_64 上必须走 objc_msgSend_stret。
        const rect = sendStruct(NSRect, scr.?, sel("frame"));
        screen_w = @intFromFloat(rect.size.width);
        screen_h = @intFromFloat(rect.size.height);

        scale = send0(CGFloat, scr.?, sel("backingScaleFactor"));
        if (scale <= 0) scale = 1;
    }

    if (screen_w <= 0 or screen_h <= 0) {
        errPrint("[mac] 拿不到主屏幕尺寸\n", .{});
        return error.InitFailed;
    }
}

/// 建一个 1×1 的透明窗口，专门用来接收键盘（Esc）。
///
/// macOS 只会把键盘事件发给当前活动窗口，所以需要一个常驻的小窗口。
fn createKeyboardPanel() void {
    const panel_cls = cls("NSPanel");
    const panel = send0(Id, panel_cls, sel("alloc"));
    const key_panel = send4(
        Id,
        panel,
        sel("initWithContentRect:styleMask:backing:defer:"),
        NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 1 } },
        NSWindowStyleMaskBorderless | NSWindowStyleMaskUtilityPanel,
        NSBackingStoreBuffered,
        false,
    );
    if (key_panel != null) {
        send1(void, key_panel.?, sel("setOpaque:"), false);
        send1(void, key_panel.?, sel("makeKeyAndOrderFront:"), @as(Id, null));
    }
}

/// 返回屏幕尺寸（点，不是像素）。
pub fn screenSize() Size {
    return .{ .w = screen_w, .h = screen_h };
}

/// 手动指定字体和字号；传 0 或空字符串表示保持原值。
pub fn setFont(family: [:0]const u8, size_px: f64) void {
    if (family.len > 0) font_family = family;
    if (size_px > 0) font_size_px = size_px;
}

/// 返回当前使用的字体名。
pub fn fontFamily() [:0]const u8 {
    return font_family;
}

/// macOS 直接接收键盘事件，所以 Esc 总是可用（返回 1）。
pub fn escapeState() i32 {
    return 1; // macOS 直接接收键盘事件
}

/// 创建一个无边框弹窗：先渲染图片，再依次包成 NSImage、NSImageView、NSPanel。
///
/// 返回窗口句柄；任何一步失败都返回 null。
pub fn createPopup(px: i32, py: i32, w: i32, h: i32, rgb: u32, text: [:0]const u8) ?*Popup {
    if (app == null) return null;

    const image = renderImage(w, h, rgb, text) orelse return null;
    defer cg.image_release(image);

    const ns_image = makeNSImage(image, w, h) orelse return null;
    defer objc.release(ns_image);

    const image_view = makeImageView(ns_image, w, h) orelse return null;
    defer objc.release(image_view);

    const win = makePopupPanel(px, py, w, h, image_view) orelse return null;
    return @ptrFromInt(@intFromPtr(win));
}

/// 把 CGImage 包成 NSImage。
///
/// initWithCGImage: 会 retain 这张图片；返回的对象由调用方负责 release。
fn makeNSImage(image: CGImageRef, w: i32, h: i32) Id {
    const image_cls = cls("NSImage");
    const img = send0(Id, image_cls, sel("alloc"));
    return send2(
        Id,
        img,
        sel("initWithCGImage:size:"),
        image,
        NSSize{ .width = @floatFromInt(w), .height = @floatFromInt(h) },
    );
}

/// 创建 NSImageView，并把图片放进去。
///
/// 返回的对象由调用方负责 release。
fn makeImageView(ns_image: Id, w: i32, h: i32) Id {
    const view_cls = cls("NSImageView");
    const view = send0(Id, view_cls, sel("alloc"));
    const image_view = send1(
        Id,
        view,
        sel("initWithFrame:"),
        NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } },
    ) orelse return null;

    send1(void, image_view, sel("setImage:"), ns_image);
    return image_view;
}

/// 创建真正显示在屏幕上的 NSPanel，并把内容视图设成 image_view。
fn makePopupPanel(px: i32, py: i32, w: i32, h: i32, image_view: Id) Id {
    const panel_cls = cls("NSPanel");
    const panel = send0(Id, panel_cls, sel("alloc"));

    // AppKit 的屏幕坐标原点在左下角，而主程序用的是左上角原点，这里翻转 Y。
    const appkit_y = screen_h - py - h;
    const win = send4(
        Id,
        panel,
        sel("initWithContentRect:styleMask:backing:defer:"),
        NSRect{ .origin = .{ .x = @floatFromInt(px), .y = @floatFromInt(appkit_y) }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } },
        NSWindowStyleMaskBorderless,
        NSBackingStoreBuffered,
        false,
    ) orelse return null;

    send1(void, win, sel("setContentView:"), image_view);
    send1(void, win, sel("setOpaque:"), false);
    send1(void, win, sel("setLevel:"), kCGFloatingWindowLevel);
    send1(void, win, sel("setHasShadow:"), false);
    // 只有在必要时才成为 key，避免把接收 Esc 的窗口踢下线。
    send1(void, win, sel("setBecomesKeyOnlyIfNeeded:"), true);
    send0(void, win, sel("orderFrontRegardless"));

    return win;
}

/// 关闭并销毁一个弹窗。
pub fn destroyPopup(popup: *Popup) void {
    const win = @as(Id, @ptrFromInt(@intFromPtr(popup)));
    if (win == null) return;
    send1(void, win, sel("orderOut:"), @as(Id, null));
    objc.release(win);
}

/// 处理当前所有待处理的事件；返回 true 表示用户要求退出。
pub fn pollEvents() bool {
    if (app == null) return true;

    while (true) {
        const ev = nextEvent() orelse break;
        handleEvent(ev);
    }
    return quit_requested;
}

/// 从 macOS 事件队列里取一个事件；队列空了返回 null。
fn nextEvent() Id {
    return send4(
        Id,
        app.?,
        sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
        NSEventMaskAny,
        @as(Id, null),
        kCFRunLoopDefaultMode,
        true,
    );
}

/// 判断事件是不是“鼠标点击”或“Esc”，是就请求退出。
///
/// 不管是否退出，事件最后都要交回 AppKit（sendEvent），
/// 否则窗口系统会认为程序没有正常处理事件。
fn handleEvent(ev: Id) void {
    const t = send0(u64, ev.?, sel("type"));

    if (t == NSEventTypeLeftMouseDown or t == NSEventTypeLeftMouseUp) {
        if (debug_enabled) errPrint("[debug] 收到鼠标点击，退出\n", .{});
        quit_requested = true;
    } else if (t == NSEventTypeKeyDown) {
        const kc = send0(u16, ev.?, sel("keyCode"));
        if (kc == kVK_Escape) {
            if (debug_enabled) errPrint("[debug] 收到 Esc，退出\n", .{});
            quit_requested = true;
        }
    }

    send1(void, app.?, sel("sendEvent:"), ev.?);
}

/// 关闭已加载的动态库。
///
/// AppKit 故意不关闭：程序退出阶段窗口系统可能还会调用它，
/// 提前卸载容易导致崩溃。
pub fn shutdown() void {
    closeLibrary(&lib_objc);
    closeLibrary(&lib_cf);
    closeLibrary(&lib_cg);
    closeLibrary(&lib_ct);
}

/// 关闭一个可选的动态库，并把变量清成 null，避免重复关闭。
fn closeLibrary(lib: *?std.DynLib) void {
    if (lib.*) |*h| {
        h.close();
        lib.* = null;
    }
}
