//! shaodj_zig —— shaodj_1.py（Python + Tkinter）的 Zig 重写版。
//!
//! 本文件只放平台无关的逻辑：参数、祝福语、爱心曲线、配色、动画时间轴。
//! 图形层由 build.zig 按目标平台注入：
//!   - Linux/其它 unix：src/backend_x11.zig（X11 + cairo）
//!   - macOS：src/backend_mac.zig（AppKit + CoreGraphics + CoreText）
//!
//! 阅读提示：如果你学过 Python，可以把
//!   `fn 名字(参数) 返回类型 { ... }`
//! 理解成
//!   `def 名字(参数):`
//! `const` 相当于常量，`var` 相当于变量，`!void` 表示“可能失败的函数”。

const std = @import("std");
const backend = @import("backend");

// ===== 可调参数 =====
const WIN_W: i32 = 180; // 每个弹窗大小
const WIN_H: i32 = 100;
const FONT_SIZE: f64 = 35; // 祝福语字体大小（像素）
const DRAW_DELAY_MS: u64 = 50; // 顺时针绘制间隔
const CLOSE_DELAY_MS: u64 = 30; // 逆时针关闭间隔
const RANDOM_DELAY_MS: u64 = 30; // 随机弹窗出现间隔
const MIN_COUNT: usize = 100; // 弹窗数量范围
const MAX_COUNT: usize = 150;

/// 爱心曲线用多少个点来近似（点越多曲线越平滑，但计算越慢）
const CURVE_SAMPLE_COUNT: usize = 2000;

// 每个弹窗循环显示的 4 字祝福语
const BLESSINGS = [_][:0]const u8{
    "平安喜乐",
    "万事如意",
    "心想事成",
    "岁岁平安",
    "天天开心",
    "笑口常开",
    "诸事顺遂",
    "未来可期",
    "前程似锦",
    "幸福安康",
    "喜气洋洋",
    "福星高照",
    "吉星高照",
    "财源广进",
    "好运连连",
    "梦想成真",
    "身体健康",
    "阖家欢乐",
    "顺风顺水",
    "所愿皆成",
    "一切顺利",
    "喜乐无忧",
    "得偿所愿",
    "万事胜意",
    "平安顺遂",
    "开心快乐",
    "生活美满",
    "好运常伴",
    "温暖如春",
    "长乐未央",
    "喜上眉梢",
    "福气满满",
    "顺心如意",
    "欢喜自在",
    "幸福满满",
    "四季平安",
};

/// 屏幕上的整数坐标（窗口左上角用）
const Point = struct { x: i32, y: i32 };

/// 带小数的二维坐标（爱心曲线计算过程中用）
const PointF = struct { x: f64, y: f64 };

/// 爱心曲线的包围盒：最左、最右、最下、最上
const Bounds = struct {
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,
};

/// 采样后的爱心曲线：xs/ys 一一对应，bounds 是它的包围盒
const Curve = struct {
    xs: []f64,
    ys: []f64,
    bounds: Bounds,

    /// 归还采样点占用的内存（相当于 Python 里不再使用这个列表）
    fn deinit(self: Curve, gpa: std.mem.Allocator) void {
        gpa.free(self.xs);
        gpa.free(self.ys);
    }
};

/// HSV 颜色（色相 h、饱和度 s、明度 v），三个分量都在 0~1 之间
const Hsv = struct { h: f64, s: f64, v: f64 };

/// 程序入口：初始化图形后端，然后依次播放三个阶段，最后等待退出。
pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    try backend.init();
    defer backend.shutdown();

    const size = backend.screenSize();
    const points = try buildPoints(gpa, size.w, size.h);
    defer gpa.free(points);

    var prng = std.Random.DefaultPrng.init(nowNanos());
    const rnd = prng.random();

    printStartupInfo(size, points.len);

    // 第一阶段：沿爱心顺时针逐个弹出，并把窗口记在 dots 里。
    // `orelse return` 的意思是：如果中途用户退出（返回 null），就直接结束程序。
    var dots: [MAX_COUNT]?*backend.Popup = undefined;
    const dot_count = drawHeartPhase(points, rnd, &dots) orelse return;

    // 第二阶段：逆时针逐个关闭刚才弹出的窗口。
    if (!closeHeartPhase(dots[0..dot_count])) return;

    // 第三阶段：在屏幕各处随机弹窗，并一直保留。
    if (!scatterPhase(size, points.len, rnd)) return;

    // 保持窗口，直到用户点击或按 Esc。
    waitForExit();
}

/// 打印屏幕尺寸、字体、窗口数量，以及 Esc 键是否可用的提示。
fn printStartupInfo(size: backend.Size, count: usize) void {
    print("屏幕 {d}x{d}，字体 {s}，弹出 {d} 个窗口（点击任意窗口或按 Esc 退出）\n", .{
        size.w, size.h, backend.fontFamily(), count,
    });

    switch (backend.escapeState()) {
        0 => print("提示：Esc 键未能被接管，请用鼠标左键点击窗口退出\n", .{}),
        -1 => print("提示：已禁用全局 Esc 抓取，请用鼠标左键点击窗口退出\n", .{}),
        else => {},
    }
}

/// 第一阶段：沿爱心曲线依次弹出窗口。
///
/// 返回值是成功创建的窗口数量；如果用户中途要求退出，则返回 null。
fn drawHeartPhase(
    points: []const Point,
    rnd: std.Random,
    dots: []?*backend.Popup,
) ?usize {
    var count: usize = 0;

    for (points, 0..) |p, i| {
        const text = BLESSINGS[i % BLESSINGS.len];

        // 创建成功才登记；dots 满了就忽略后面的窗口。
        if (backend.createPopup(p.x, p.y, WIN_W, WIN_H, randomBgColor(rnd), text)) |win| {
            if (count < dots.len) {
                dots[count] = win;
                count += 1;
            }
        }

        if (!sleepInterruptible(DRAW_DELAY_MS)) return null;
    }

    return count;
}

/// 第二阶段：按创建顺序的倒序把窗口逐个关掉。
///
/// 返回 false 表示用户在中途要求退出。
fn closeHeartPhase(dots: []?*backend.Popup) bool {
    if (!sleepInterruptible(500)) return false;

    var idx = dots.len;
    while (idx > 0) {
        idx -= 1;
        if (dots[idx]) |win| backend.destroyPopup(win);
        if (!sleepInterruptible(CLOSE_DELAY_MS)) return false;
    }

    return true;
}

/// 第三阶段：在屏幕范围内随机位置弹窗，窗口保持不关。
///
/// 返回 false 表示用户在中途要求退出。
fn scatterPhase(size: backend.Size, count: usize, rnd: std.Random) bool {
    if (!sleepInterruptible(400)) return false;

    // 允许窗口坐标的最大值，避免窗口跑出屏幕右边/下边。
    const max_x = @max(0, size.w - WIN_W);
    const max_y = @max(0, size.h - WIN_H);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const x = rnd.intRangeAtMost(i32, 0, max_x);
        const y = rnd.intRangeAtMost(i32, 0, max_y);
        _ = backend.createPopup(x, y, WIN_W, WIN_H, randomBgColor(rnd), BLESSINGS[i % BLESSINGS.len]);
        if (!sleepInterruptible(RANDOM_DELAY_MS)) return false;
    }

    return true;
}

/// 最后一阶段：不断处理界面事件，直到用户点击窗口或按 Esc。
fn waitForExit() void {
    while (!backend.pollEvents()) {
        sleepMs(20);
    }
}

// ===== 小工具 =====

/// 当前时间（纳秒），用作随机数种子。
/// 相当于 Python 的 `time.time_ns()`。
fn nowNanos() u64 {
    var tv: std.c.timeval = undefined;
    if (std.c.gettimeofday(&tv, null) != 0) return 0;
    const sec: u64 = @intCast(tv.sec);
    const usec: u64 = @intCast(tv.usec);
    return sec * std.time.ns_per_s + usec * std.time.ns_per_us;
}

/// 打印一行到标准输出。
///
/// 这里没有直接用 `std.debug.print`，因为它写的是标准错误，
/// 而且格式化和缓冲区在跨平台时更容易出问题。
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

/// 让程序暂停 ms 毫秒（相当于 Python 的 `time.sleep(ms / 1000)`）。
fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// 等待 ms 毫秒，但每 5 毫秒检查一次用户有没有退出。
///
/// 返回 false 表示等待期间用户点了鼠标或按了 Esc。
fn sleepInterruptible(ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) {
        if (backend.pollEvents()) return false;

        // 最后一段可能不足 5 毫秒，避免睡过头。
        const step = @min(@as(u64, 5), ms - waited);
        sleepMs(step);
        waited += step;
    }
    return !backend.pollEvents();
}

// ===== 爱心曲线 =====

/// 经典爱心参数方程：给定参数 t，返回曲线上的一个点。
///
/// 公式：x = 16·sin³t，y = 13·cos t − 5·cos 2t − 2·cos 3t − cos 4t
fn heartXY(t: f64) PointF {
    const s = @sin(t);
    return .{
        .x = 16.0 * s * s * s,
        .y = 13.0 * @cos(t) - 5.0 * @cos(2.0 * t) - 2.0 * @cos(3.0 * t) - @cos(4.0 * t),
    };
}

/// 计算爱心轮廓上每个弹窗的位置（与 Python 版算法一致）。
///
/// 大致步骤：
///   1. 用很多个 t 采样出爱心曲线；
///   2. 计算每个采样点距离起点的“弧长”；
///   3. 按弧长均匀取若干个点，保证窗口间距一致；
///   4. 缩放并平移到屏幕中央。
fn buildPoints(gpa: std.mem.Allocator, screen_w: i32, screen_h: i32) ![]Point {
    const curve = try sampleHeartCurve(gpa, CURVE_SAMPLE_COUNT);
    defer curve.deinit(gpa);

    const lengths = try cumulativeLengths(gpa, curve.xs, curve.ys);
    defer gpa.free(lengths);

    const total_length = lengths[lengths.len - 1];
    const scale = fitScale(curve.bounds, screen_w, screen_h);
    const count = estimateWindowCount(total_length, scale);

    const points = try gpa.alloc(Point, count);
    errdefer gpa.free(points);

    const curve_center = boundsCenter(curve.bounds);
    const screen_center = PointF{
        .x = @as(f64, @floatFromInt(@divTrunc(screen_w, 2))),
        .y = @as(f64, @floatFromInt(@divTrunc(screen_h, 2))),
    };

    // cursor 记录上次扫描到第几个采样点，避免每次都从头找，速度更快。
    var cursor: usize = 0;
    for (points, 0..) |*point, i| {
        const target = total_length * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count));
        const on_curve = pointAtDistance(curve.xs, curve.ys, lengths, target, &cursor);
        point.* = toScreenPoint(on_curve, curve_center, screen_center, scale);
    }

    return points;
}

/// 在 0~2π 之间均匀取 sample_count + 1 个 t，算出爱心曲线上的点。
fn sampleHeartCurve(gpa: std.mem.Allocator, sample_count: usize) !Curve {
    const n = sample_count + 1;
    const xs = try gpa.alloc(f64, n);
    errdefer gpa.free(xs);
    const ys = try gpa.alloc(f64, n);
    errdefer gpa.free(ys);

    var bounds = Bounds{
        .min_x = std.math.inf(f64),
        .max_x = -std.math.inf(f64),
        .min_y = std.math.inf(f64),
        .max_y = -std.math.inf(f64),
    };

    for (0..n) |i| {
        const t = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(sample_count));
        const p = heartXY(t);
        xs[i] = p.x;
        ys[i] = p.y;

        bounds.min_x = @min(bounds.min_x, p.x);
        bounds.max_x = @max(bounds.max_x, p.x);
        bounds.min_y = @min(bounds.min_y, p.y);
        bounds.max_y = @max(bounds.max_y, p.y);
    }

    return .{ .xs = xs, .ys = ys, .bounds = bounds };
}

/// 计算从起点到每个采样点的累计弧长。
///
/// 例如 lengths[3] 表示“从第 0 个点沿曲线走到第 3 个点的总长度”。
fn cumulativeLengths(gpa: std.mem.Allocator, xs: []const f64, ys: []const f64) ![]f64 {
    const lengths = try gpa.alloc(f64, xs.len);
    lengths[0] = 0.0;

    var i: usize = 1;
    while (i < xs.len) : (i += 1) {
        const dx = xs[i] - xs[i - 1];
        const dy = ys[i] - ys[i - 1];
        lengths[i] = lengths[i - 1] + std.math.hypot(dx, dy);
    }

    return lengths;
}

/// 计算爱心缩放比例：让整颗心大约占屏幕的 72%。
fn fitScale(bounds: Bounds, screen_w: i32, screen_h: i32) f64 {
    const width = bounds.max_x - bounds.min_x;
    const height = bounds.max_y - bounds.min_y;
    const screen_wf = @as(f64, @floatFromInt(screen_w));
    const screen_hf = @as(f64, @floatFromInt(screen_h));

    return @min(screen_wf * 0.72 / width, screen_hf * 0.72 / height);
}

/// 根据曲线总长度和缩放比例估算要弹多少个窗口，并限制在 100~150 之间。
fn estimateWindowCount(total_length: f64, scale: f64) usize {
    // 窗口宽度的 1.18 倍作为相邻窗口的间距，避免挤在一起。
    const spacing = @as(f64, @floatFromInt(WIN_W * 118 / 100));
    const raw: usize = @intFromFloat(total_length * scale / spacing);
    return @max(MIN_COUNT, @min(MAX_COUNT, raw));
}

/// 返回包围盒的中心点。
fn boundsCenter(bounds: Bounds) PointF {
    return .{
        .x = (bounds.min_x + bounds.max_x) / 2.0,
        .y = (bounds.min_y + bounds.max_y) / 2.0,
    };
}

/// 在曲线上找到“距离起点 target 那么远”的点。
///
/// 因为 target 是递增的，cursor 只往前走，所以整体只需要扫描一遍。
fn pointAtDistance(
    xs: []const f64,
    ys: []const f64,
    lengths: []const f64,
    target: f64,
    cursor: *usize,
) PointF {
    while (cursor.* < xs.len - 1 and lengths[cursor.*] < target) {
        cursor.* += 1;
    }

    const j = cursor.*;
    if (j == 0) return .{ .x = xs[0], .y = ys[0] };

    // 在线段 (j-1) -> j 之间按比例插值。
    const l0 = lengths[j - 1];
    const l1 = lengths[j];
    const ratio = if (l1 != l0) (target - l0) / (l1 - l0) else 0.0;

    return .{
        .x = xs[j - 1] + (xs[j] - xs[j - 1]) * ratio,
        .y = ys[j - 1] + (ys[j] - ys[j - 1]) * ratio,
    };
}

/// 把爱心曲线坐标换算成屏幕窗口坐标（左上角原点，y 轴向下）。
fn toScreenPoint(
    p: PointF,
    curve_center: PointF,
    screen_center: PointF,
    scale: f64,
) Point {
    const half_w = @as(f64, @floatFromInt(WIN_W / 2));
    const half_h = @as(f64, @floatFromInt(WIN_H / 2));

    return .{
        .x = @intFromFloat(screen_center.x + (p.x - curve_center.x) * scale - half_w),
        .y = @intFromFloat(screen_center.y - (p.y - curve_center.y) * scale - half_h),
    };
}

// ===== 颜色 =====

/// 随机生成一个亮色背景：色相随机、饱和度适中、明度较高。
///
/// 返回 0xRRGGBB 形式的整数，例如 0xFF8800。
fn randomBgColor(rnd: std.Random) u32 {
    const hsv = randomHsv(rnd);
    return packRgb(hsvToRgb(hsv.h, hsv.s, hsv.v));
}

/// 随机生成 HSV 颜色：h 任意，s 在 0.25~0.75，v 在 0.85~1.0。
fn randomHsv(rnd: std.Random) Hsv {
    return .{
        .h = rnd.float(f64),
        .s = 0.25 + rnd.float(f64) * (0.75 - 0.25),
        .v = 0.85 + rnd.float(f64) * (1.0 - 0.85),
    };
}

/// 把三个 0~255 的 RGB 分量拼成一个整数。
fn packRgb(rgb: [3]u8) u32 {
    return (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]);
}

/// 把 HSV 颜色转成 RGB（与 Python colorsys.hsv_to_rgb 行为一致）。
fn hsvToRgb(h: f64, s: f64, v: f64) [3]u8 {
    // 色相被分成 6 个扇区，sector 决定用哪一组公式。
    const sector_f = @floor(h * 6.0);
    const f = h * 6.0 - sector_f;
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const t = v * (1.0 - (1.0 - f) * s);
    const sector = @rem(@as(i32, @intFromFloat(sector_f)), 6);

    return rgbToBytes(sectorColor(sector, v, p, q, t));
}

/// 根据扇区编号，从 v/p/q/t 四个中间值里挑出 RGB 分量（范围 0~1）。
fn sectorColor(sector: i32, v: f64, p: f64, q: f64, t: f64) [3]f64 {
    return switch (sector) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

/// 把 0~1 的 RGB 分量转换成 0~255 的整数。
fn rgbToBytes(rgb: [3]f64) [3]u8 {
    return .{
        @intFromFloat(rgb[0] * 255.0),
        @intFromFloat(rgb[1] * 255.0),
        @intFromFloat(rgb[2] * 255.0),
    };
}
