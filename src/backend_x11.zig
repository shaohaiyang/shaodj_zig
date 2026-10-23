//! Linux（X11）图形后端：X11 + cairo。
//!
//! 运行时用 dlopen 加载 libX11 / libcairo，所以不需要 X11、cairo 的开发包，
//! 编译时只要有 libc 即可。
//!
//! 文字用 cairo 的 toy API 绘制，字号单位是「像素」，不受 X server 的 DPI 影响。

const std = @import("std");

pub const Size = struct { w: i32, h: i32 };
pub const Popup = opaque {};

// ===================== 最小 X11 类型声明 =====================

const Display = opaque {};
const Visual = opaque {};
const XID = u64;
const Window = XID;
const Drawable = XID;

const XSetWindowAttributes = extern struct {
    background_pixmap: XID,
    background_pixel: u64,
    border_pixmap: XID,
    border_pixel: u64,
    bit_gravity: c_int,
    win_gravity: c_int,
    backing_store: c_int,
    backing_planes: u64,
    backing_pixel: u64,
    save_under: c_int,
    event_mask: c_long,
    do_not_propagate_mask: c_long,
    override_redirect: c_int,
    colormap: XID,
    cursor: XID,
};

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

const XExposeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    count: c_int,
};

const XErrorEvent = extern struct {
    type: c_int,
    display: ?*Display,
    resourceid: XID,
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};

const XEvent = extern union {
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xexpose: XExposeEvent,
    pad: [24]c_long,
};

// ===================== X11 常量 =====================

const CW_BACK_PIXEL: c_ulong = 1 << 1;
const CW_BORDER_PIXEL: c_ulong = 1 << 3;
const CW_OVERRIDE_REDIRECT: c_ulong = 1 << 9;
const CW_EVENT_MASK: c_ulong = 1 << 11;

const INPUT_OUTPUT: c_uint = 1;

const KEY_PRESS_MASK: c_long = 1 << 0;
const BUTTON_PRESS_MASK: c_long = 1 << 2;
const EXPOSE_MASK: c_long = 1 << 15;

const KEY_PRESS: c_int = 2;
const BUTTON_PRESS: c_int = 4;
const EXPOSE: c_int = 12;

const ANY_MODIFIER: c_uint = 32768;
const GRAB_MODE_ASYNC: c_int = 0;
const XK_ESCAPE: c_ulong = 0xFF1B;

const CAIRO_FONT_SLANT_NORMAL: c_int = 0;
const CAIRO_FONT_WEIGHT_NORMAL: c_int = 0;

// ===================== cairo 类型 =====================

const cairo_t = opaque {};
const cairo_surface_t = opaque {};

// ===================== 动态加载的函数指针 =====================

const X = struct {
    open_display: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    close_display: *const fn (*Display) callconv(.c) c_int,
    default_screen: *const fn (*Display) callconv(.c) c_int,
    display_width: *const fn (*Display, c_int) callconv(.c) c_int,
    display_height: *const fn (*Display, c_int) callconv(.c) c_int,
    root_window: *const fn (*Display, c_int) callconv(.c) Window,
    default_visual: *const fn (*Display, c_int) callconv(.c) ?*Visual,
    default_depth: *const fn (*Display, c_int) callconv(.c) c_int,
    create_window: *const fn (
        *Display,
        Window,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_uint,
        c_int,
        c_uint,
        ?*Visual,
        c_ulong,
        ?*XSetWindowAttributes,
    ) callconv(.c) Window,
    map_window: *const fn (*Display, Window) callconv(.c) c_int,
    destroy_window: *const fn (*Display, Window) callconv(.c) c_int,
    select_input: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    next_event: *const fn (*Display, *XEvent) callconv(.c) c_int,
    pending: *const fn (*Display) callconv(.c) c_int,
    flush: *const fn (*Display) callconv(.c) c_int,
    sync: *const fn (*Display, c_int) callconv(.c) c_int,
    store_name: *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int,
    grab_key: *const fn (*Display, c_uint, c_uint, Window, c_int, c_int, c_int) callconv(.c) c_int,
    keysym_to_keycode: *const fn (*Display, c_ulong) callconv(.c) c_int,
    set_error_handler: *const fn (*const fn (?*Display, ?*XErrorEvent) callconv(.c) c_int) callconv(.c) ?*const fn (?*Display, ?*XErrorEvent) callconv(.c) c_int,
};

const Cairo = struct {
    xlib_surface_create: *const fn (*Display, Drawable, ?*Visual, c_int, c_int) callconv(.c) ?*cairo_surface_t,
    image_surface_create: *const fn (c_int, c_int, c_int) callconv(.c) ?*cairo_surface_t,
    create: *const fn (*cairo_surface_t) callconv(.c) ?*cairo_t,
    destroy: *const fn (*cairo_t) callconv(.c) void,
    surface_destroy: *const fn (*cairo_surface_t) callconv(.c) void,
    set_source_rgb: *const fn (*cairo_t, f64, f64, f64) callconv(.c) void,
    paint: *const fn (*cairo_t) callconv(.c) void,
    move_to: *const fn (*cairo_t, f64, f64) callconv(.c) void,
    select_font_face: *const fn (*cairo_t, [*:0]const u8, c_int, c_int) callconv(.c) void,
    set_font_size: *const fn (*cairo_t, f64) callconv(.c) void,
    text_extents: *const fn (*cairo_t, [*:0]const u8, *[6]f64) callconv(.c) void,
    show_text: *const fn (*cairo_t, [*:0]const u8) callconv(.c) void,
};

// ===================== 全局状态 =====================

var lib_x11: ?std.DynLib = null;
var lib_cairo: ?std.DynLib = null;
var x: X = undefined;
var cr: Cairo = undefined;

var dpy: ?*Display = null;
var root: Window = 0;
var visual: ?*Visual = null;
var depth: c_int = 0;
var screen_w: i32 = 0;
var screen_h: i32 = 0;

var quit_requested = false;
var escape_keycode: c_int = 0;
var escape_state: i32 = 0; // 1=已抓取 0=抓取失败 -1=用户禁用
var last_error: u8 = 0;
var debug_enabled = false;

var font_family: [:0]const u8 = "sans-serif";
var font_size_px: f64 = 35;

/// 字体候选：优先行书 / 行楷，其次普通中文字体（与 Python 版一致）
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
    "Microsoft YaHei",
    "PingFang SC",
    "Noto Sans CJK SC",
    "SimHei",
    "WenQuanYi Micro Hei",
    "Arial Unicode MS",
};

/// 弹窗登记表，用于 Expose 时重绘
const Rec = struct {
    win: Window,
    w: i32,
    h: i32,
    rgb: u32,
    text: [:0]const u8,
};
var recs: [512]Rec = undefined;
var rec_count: usize = 0;

// ===================== 工具 =====================

/// 从动态库里查找一个函数（或全局变量）的地址。
///
/// 参数 T 是这个函数在 Zig 里的类型；找不到就返回错误。
fn sym(comptime T: type, handle: *std.DynLib, name: [:0]const u8) !T {
    return handle.lookup(T, name) orelse error.MissingSymbol;
}

/// X11 的错误回调：只记录最近一次错误码，不打印、不退出。
///
/// 抓取 Esc 键失败时 X11 会异步报错，我们靠这个回调判断是否抓取成功。
fn xErrorHandler(dpy_: ?*Display, ev: ?*XErrorEvent) callconv(.c) c_int {
    _ = dpy_;
    if (ev) |e| last_error = e.error_code;
    return 0;
}

/// 打印错误信息到标准错误（相当于 Python 的 `print(..., file=sys.stderr)`）。
fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

// ===================== 字体 =====================

/// 判断字体能否显示中文：4 个汉字在给定字号下的宽度应接近 4 倍字号，
/// 缺字形时会退化成窄窄的 .notdef 方块。
fn fontHasCjk(family: [:0]const u8) bool {
    const surface = cr.image_surface_create(0, 16, 16) orelse return true;
    defer cr.surface_destroy(surface);
    const ctx = cr.create(surface) orelse return true;
    defer cr.destroy(ctx);

    cr.select_font_face(ctx, family.ptr, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cr.set_font_size(ctx, font_size_px);

    var ext: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
    cr.text_extents(ctx, "平安喜乐".ptr, &ext);

    const ok = ext[2] > font_size_px * 3.0;
    if (debug_enabled) {
        errPrint("[debug] font '{s}' 中文字宽={d:.1}（期望>{d:.1}）-> {s}\n", .{
            family, ext[2], font_size_px * 3.0,
            if (ok) "可用" else "缺字形",
        });
    }
    return ok;
}

/// 从候选列表里挑第一个真正含中文字形的字体。
///
/// 如果一个都没有，就退回系统默认的 sans-serif（可能显示不好，但不会崩）。
fn pickFontFamily() [:0]const u8 {
    for (preferred_fonts) |f| {
        if (fontHasCjk(f)) return f;
    }
    return "sans-serif";
}

// ===================== 绘制 =====================

/// 把背景色和祝福语画到一个 X11 窗口里。
///
/// 绘制分两步：先铺背景色，再用黑色画居中的文字。
fn drawContent(win: Window, w: i32, h: i32, rgb: u32, text: [:0]const u8) void {
    const disp = dpy orelse return;

    const surface = cr.xlib_surface_create(disp, win, visual, w, h) orelse return;
    defer cr.surface_destroy(surface);
    const ctx = cr.create(surface) orelse return;
    defer cr.destroy(ctx);

    paintBackground(ctx, rgb);
    drawCenteredText(ctx, w, h, text);
}

/// 用指定的 0xRRGGBB 颜色铺满整个绘图区域。
fn paintBackground(ctx: *cairo_t, rgb: u32) void {
    cr.set_source_rgb(
        ctx,
        @as(f64, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
        @as(f64, @floatFromInt(rgb & 0xFF)) / 255.0,
    );
    cr.paint(ctx);
}

/// 在 w×h 的矩形里，用黑色把 text 水平、垂直居中画出来。
fn drawCenteredText(ctx: *cairo_t, w: i32, h: i32, text: [:0]const u8) void {
    if (text.len == 0) return;

    cr.set_source_rgb(ctx, 0.0, 0.0, 0.0); // 文字用黑色
    cr.select_font_face(ctx, font_family.ptr, CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cr.set_font_size(ctx, font_size_px);

    var ext: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
    cr.text_extents(ctx, text.ptr, &ext);

    // ext[0]=x_bearing, ext[1]=y_bearing, ext[2]=width, ext[3]=height。
    // 减去 bearing，是为了把文字真正的外框放到中间，
    // 而不是把“落笔的位置”放到中间。
    const x_pos = (@as(f64, @floatFromInt(w)) - ext[2]) / 2.0 - ext[0];
    const y_pos = (@as(f64, @floatFromInt(h)) - ext[3]) / 2.0 - ext[1];
    cr.move_to(ctx, x_pos, y_pos);
    cr.show_text(ctx, text.ptr);

    if (debug_enabled) {
        errPrint("[debug] text='{s}' font='{s}' size={d} extents={d:.1}x{d:.1}\n", .{
            text, font_family, @as(i32, @intFromFloat(font_size_px)), ext[2], ext[3],
        });
    }
}

/// 把一个窗口登记到 recs 表里，供 Expose（窗口需要重绘）时使用。
fn recAdd(win: Window, w: i32, h: i32, rgb: u32, text: [:0]const u8) void {
    if (rec_count >= recs.len) return;
    recs[rec_count] = .{ .win = win, .w = w, .h = h, .rgb = rgb, .text = text };
    rec_count += 1;
}

/// 从登记表里删除一个窗口。
///
/// 这里用“把最后一个元素挪到空位”的办法，删除很快，
/// 而且不需要关心登记顺序。
fn recRemove(win: Window) void {
    var i: usize = 0;
    while (i < rec_count) : (i += 1) {
        if (recs[i].win == win) {
            recs[i] = recs[rec_count - 1];
            rec_count -= 1;
            return;
        }
    }
}

/// 按窗口编号查找登记信息；找不到返回 null。
fn recFind(win: Window) ?*Rec {
    var i: usize = 0;
    while (i < rec_count) : (i += 1) {
        if (recs[i].win == win) return &recs[i];
    }
    return null;
}

// ===================== 对外接口 =====================

/// 初始化 Linux 后端：加载动态库、连接 X server、抓 Esc、选字体。
///
/// 这里故意用 dlopen 在运行时加载库，所以编译时不需要 X11/cairo 开发包。
pub fn init() !void {
    // 中途任何一步失败，都把已经加载的库关掉。
    errdefer shutdown();

    try loadLibraries();
    try loadXFunctions();
    try loadCairoFunctions();

    _ = x.set_error_handler(xErrorHandler);

    try openDisplay();
    debug_enabled = std.c.getenv("SHAODJ_DEBUG") != null;

    readScreenInfo();
    registerRootEvents();
    grabEscapeKey();

    font_family = pickFontFamily();
}

/// 运行时打开 libX11 和 libcairo，并保存到全局变量里。
fn loadLibraries() !void {
    var h_x11 = try std.DynLib.open("libX11.so.6");
    errdefer h_x11.close();
    var h_cairo = try std.DynLib.open("libcairo.so.2");
    errdefer h_cairo.close();

    lib_x11 = h_x11;
    lib_cairo = h_cairo;
}

/// 把要用到的 X11 函数地址填进 x 表里。
///
/// 每一行都是“Zig 里的函数类型 = libX11 里的函数名”，
/// 可以把它当成一张“名字 → 地址”的字典。
fn loadXFunctions() !void {
    const handle = if (lib_x11) |*lib| lib else return error.MissingLibrary;

    x = .{
        .open_display = try sym(*const fn (?[*:0]const u8) callconv(.c) ?*Display, handle, "XOpenDisplay"),
        .close_display = try sym(*const fn (*Display) callconv(.c) c_int, handle, "XCloseDisplay"),
        .default_screen = try sym(*const fn (*Display) callconv(.c) c_int, handle, "XDefaultScreen"),
        .display_width = try sym(*const fn (*Display, c_int) callconv(.c) c_int, handle, "XDisplayWidth"),
        .display_height = try sym(*const fn (*Display, c_int) callconv(.c) c_int, handle, "XDisplayHeight"),
        .root_window = try sym(*const fn (*Display, c_int) callconv(.c) Window, handle, "XRootWindow"),
        .default_visual = try sym(*const fn (*Display, c_int) callconv(.c) ?*Visual, handle, "XDefaultVisual"),
        .default_depth = try sym(*const fn (*Display, c_int) callconv(.c) c_int, handle, "XDefaultDepth"),
        .create_window = try sym(*const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_int, c_uint, ?*Visual, c_ulong, ?*XSetWindowAttributes) callconv(.c) Window, handle, "XCreateWindow"),
        .map_window = try sym(*const fn (*Display, Window) callconv(.c) c_int, handle, "XMapWindow"),
        .destroy_window = try sym(*const fn (*Display, Window) callconv(.c) c_int, handle, "XDestroyWindow"),
        .select_input = try sym(*const fn (*Display, Window, c_long) callconv(.c) c_int, handle, "XSelectInput"),
        .next_event = try sym(*const fn (*Display, *XEvent) callconv(.c) c_int, handle, "XNextEvent"),
        .pending = try sym(*const fn (*Display) callconv(.c) c_int, handle, "XPending"),
        .flush = try sym(*const fn (*Display) callconv(.c) c_int, handle, "XFlush"),
        .sync = try sym(*const fn (*Display, c_int) callconv(.c) c_int, handle, "XSync"),
        .store_name = try sym(*const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int, handle, "XStoreName"),
        .grab_key = try sym(*const fn (*Display, c_uint, c_uint, Window, c_int, c_int, c_int) callconv(.c) c_int, handle, "XGrabKey"),
        .keysym_to_keycode = try sym(*const fn (*Display, c_ulong) callconv(.c) c_int, handle, "XKeysymToKeycode"),
        .set_error_handler = try sym(*const fn (*const fn (?*Display, ?*XErrorEvent) callconv(.c) c_int) callconv(.c) ?*const fn (?*Display, ?*XErrorEvent) callconv(.c) c_int, handle, "XSetErrorHandler"),
    };
}

/// 把要用到的 cairo 函数地址填进 cr 表里。
fn loadCairoFunctions() !void {
    const handle = if (lib_cairo) |*lib| lib else return error.MissingLibrary;

    cr = .{
        .xlib_surface_create = try sym(*const fn (*Display, Drawable, ?*Visual, c_int, c_int) callconv(.c) ?*cairo_surface_t, handle, "cairo_xlib_surface_create"),
        .image_surface_create = try sym(*const fn (c_int, c_int, c_int) callconv(.c) ?*cairo_surface_t, handle, "cairo_image_surface_create"),
        .create = try sym(*const fn (*cairo_surface_t) callconv(.c) ?*cairo_t, handle, "cairo_create"),
        .destroy = try sym(*const fn (*cairo_t) callconv(.c) void, handle, "cairo_destroy"),
        .surface_destroy = try sym(*const fn (*cairo_surface_t) callconv(.c) void, handle, "cairo_surface_destroy"),
        .set_source_rgb = try sym(*const fn (*cairo_t, f64, f64, f64) callconv(.c) void, handle, "cairo_set_source_rgb"),
        .paint = try sym(*const fn (*cairo_t) callconv(.c) void, handle, "cairo_paint"),
        .move_to = try sym(*const fn (*cairo_t, f64, f64) callconv(.c) void, handle, "cairo_move_to"),
        .select_font_face = try sym(*const fn (*cairo_t, [*:0]const u8, c_int, c_int) callconv(.c) void, handle, "cairo_select_font_face"),
        .set_font_size = try sym(*const fn (*cairo_t, f64) callconv(.c) void, handle, "cairo_set_font_size"),
        .text_extents = try sym(*const fn (*cairo_t, [*:0]const u8, *[6]f64) callconv(.c) void, handle, "cairo_text_extents"),
        .show_text = try sym(*const fn (*cairo_t, [*:0]const u8) callconv(.c) void, handle, "cairo_show_text"),
    };
}

/// 连接 X server；如果连不上就打印原因并返回错误。
fn openDisplay() !void {
    const display_name: ?[*:0]const u8 = if (std.c.getenv("DISPLAY")) |d| @as([*:0]const u8, d) else null;

    dpy = x.open_display(display_name) orelse {
        errPrint("[x11] 无法连接 X display: {s}\n", .{if (display_name) |d| std.mem.span(d) else "(默认)"});
        return error.CannotOpenDisplay;
    };
}

/// 读取默认屏幕的尺寸、根窗口、颜色深度等信息。
fn readScreenInfo() void {
    const screen = x.default_screen(dpy.?);
    root = x.root_window(dpy.?, screen);
    visual = x.default_visual(dpy.?, screen);
    depth = x.default_depth(dpy.?, screen);
    screen_w = x.display_width(dpy.?, screen);
    screen_h = x.display_height(dpy.?, screen);
}

/// 监听根窗口（也就是桌面）的鼠标点击和按键。
///
/// 这样即使弹窗都关掉了，点桌面空白处也能退出。
fn registerRootEvents() void {
    _ = x.select_input(dpy.?, root, KEY_PRESS_MASK | BUTTON_PRESS_MASK);
}

/// 尝试全局抓取 Esc 键；抓不到也不影响“鼠标点击退出”。
///
/// 设置环境变量 SHAODJ_NO_ESC=1 可以完全关闭这个功能，
/// 避免抢走其它程序的 Esc 键。
fn grabEscapeKey() void {
    if (std.c.getenv("SHAODJ_NO_ESC") != null) {
        escape_state = -1;
        return;
    }

    escape_keycode = x.keysym_to_keycode(dpy.?, XK_ESCAPE);
    if (escape_keycode <= 0) return;

    // 先试“无修饰键”的 Esc；如果被别的程序占用，再试 AnyModifier。
    if (tryGrabEscape(0)) {
        escape_state = 1;
        return;
    }
    if (tryGrabEscape(ANY_MODIFIER)) escape_state = 1;
}

/// 真正执行一次 XGrabKey，并返回是否成功。
///
/// X11 的抓键错误是异步通知的：调用 XSync 后检查 last_error 是否被回调改写。
fn tryGrabEscape(modifier: c_uint) bool {
    last_error = 0;
    _ = x.grab_key(dpy.?, @intCast(escape_keycode), modifier, root, 1, GRAB_MODE_ASYNC, GRAB_MODE_ASYNC);
    _ = x.sync(dpy.?, 0);
    return last_error == 0;
}

/// 返回屏幕尺寸（像素）。
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

/// 返回 Esc 键的状态：1=已抓取，0=抓取失败，-1=用户主动禁用。
pub fn escapeState() i32 {
    return escape_state;
}

/// 创建一个无边框弹窗，画上背景和文字，然后显示出来。
///
/// 返回窗口句柄；创建失败时返回 null。
pub fn createPopup(px: i32, py: i32, w: i32, h: i32, rgb: u32, text: [:0]const u8) ?*Popup {
    const disp = dpy orelse return null;
    var attrs = makeWindowAttributes(rgb);

    const win = x.create_window(
        disp,
        root,
        px,
        py,
        @intCast(w),
        @intCast(h),
        0,
        depth,
        INPUT_OUTPUT,
        visual,
        CW_BACK_PIXEL | CW_BORDER_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK,
        &attrs,
    );
    if (win == 0) return null;

    if (text.len > 0) _ = x.store_name(disp, win, text.ptr);

    recAdd(win, w, h, rgb, text);

    _ = x.map_window(disp, win);
    drawContent(win, w, h, rgb, text);
    _ = x.flush(disp);
    return @ptrFromInt(win);
}

/// 构造新窗口的属性：背景色、无边框、监听鼠标点击和重绘事件。
fn makeWindowAttributes(rgb: u32) XSetWindowAttributes {
    var attrs: XSetWindowAttributes = std.mem.zeroes(XSetWindowAttributes);
    attrs.background_pixel = rgb;
    attrs.border_pixel = rgb;
    attrs.override_redirect = 1; // 无边框、无标题栏，避免窗口管理器介入
    attrs.event_mask = BUTTON_PRESS_MASK | EXPOSE_MASK;
    return attrs;
}

/// 关闭并销毁一个弹窗。
pub fn destroyPopup(popup: *Popup) void {
    const disp = dpy orelse return;
    const win: Window = @intFromPtr(popup);
    if (win == 0) return;

    recRemove(win);
    _ = x.destroy_window(disp, win);
    _ = x.flush(disp);
}

/// 处理当前所有待处理的界面事件；返回 true 表示用户要求退出。
pub fn pollEvents() bool {
    const disp = dpy orelse return true;

    while (x.pending(disp) > 0) {
        var ev: XEvent = undefined;
        _ = x.next_event(disp, &ev);
        handleEvent(&ev);
    }
    return quit_requested;
}

/// 根据事件类型，把事件交给对应的处理函数。
fn handleEvent(ev: *const XEvent) void {
    const any: *const XAnyEvent = @ptrCast(ev);
    switch (any.type) {
        BUTTON_PRESS => onButtonPress(),
        KEY_PRESS => onKeyPress(@ptrCast(ev)),
        EXPOSE => onExpose(@ptrCast(ev)),
        else => {},
    }
}

/// 鼠标点击：请求退出程序。
fn onButtonPress() void {
    if (debug_enabled) errPrint("[debug] 收到鼠标点击事件，退出\n", .{});
    quit_requested = true;
}

/// 键盘按下：只有 Esc 会触发退出。
fn onKeyPress(ev: *const XKeyEvent) void {
    if (escape_state == 1 and ev.keycode == @as(c_uint, @intCast(escape_keycode))) {
        if (debug_enabled) errPrint("[debug] 收到 Esc 按键事件，退出\n", .{});
        quit_requested = true;
    }
}

/// 窗口需要重绘（比如被别的窗口挡住后又露出来）：按登记信息重新画一遍。
fn onExpose(ev: *const XExposeEvent) void {
    if (ev.window == 0) return;
    if (recFind(ev.window)) |rec| {
        drawContent(rec.win, rec.w, rec.h, rec.rgb, rec.text);
    }
}

/// 关闭 display、释放动态库并清空窗口登记表。
pub fn shutdown() void {
    if (dpy) |d| {
        _ = x.close_display(d);
        dpy = null;
    }
    rec_count = 0;

    closeLibrary(&lib_x11);
    closeLibrary(&lib_cairo);
}

/// 关闭一个可选的动态库，并把变量清成 null，避免重复关闭。
fn closeLibrary(lib: *?std.DynLib) void {
    if (lib.*) |*h| {
        h.close();
        lib.* = null;
    }
}
