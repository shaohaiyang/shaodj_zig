# shaodj_zig

`shaodj_1.py`（Python + Tkinter）的 Zig 重写版，**Linux 与 macOS 都能跑**，
macOS Intel（x86_64）可以直接用本机的 Zig 在 Linux 上交叉编译出二进制。

## 效果

和 Python 原版一致：

1. 沿经典爱心参数曲线**顺时针**逐个弹出小窗口（180×100，每个窗口一句 4 字祝福语，亮色随机背景）；
2. 然后**逆时针**把这些窗口逐个关掉；
3. 再在屏幕各处**随机**弹窗并一直保留；
4. **点击任意窗口**或按 **Esc** 退出。

## 编译

需要 Zig 0.14+（开发使用 0.18.0-dev）。

```bash
zig build                      # Linux，产物在 zig-out/bin/shaodj_zig
zig build -Doptimize=ReleaseSafe
zig build test                 # macOS 回归测试（文字居中等）

# macOS（Intel / Apple Silicon），在 Linux 上也能交叉编译
zig build -Dtarget=x86_64-macos.10.13  -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos.11.0 -Doptimize=ReleaseSafe

# 或者用 Makefile（会自动 strip + ad-hoc 签名）
make linux
make macos        # 产出 shaodj_zig-macos-x86_64
make macos-arm    # 产出 shaodj_zig-macos-arm64
```

产物放到 macOS 上直接运行即可，不需要装任何依赖
（macOS 版本只依赖系统自带的 `/usr/lib/libSystem.B.dylib`，
AppKit / CoreGraphics / CoreText 都是运行时动态加载的）。

分发用的二进制做了两件事：

* `strip -x` 去掉符号表，体积更小；
* `codesign -s -` 做 **ad-hoc 签名**（Apple Silicon 上未签名的二进制会被系统直接杀掉，
  ad-hoc 签名不需要开发者证书，但别人机器上仍可能需要 `xattr -d com.apple.quarantine`）。

最低系统版本锁到 macOS 10.13（Intel）/ 11.0（Apple Silicon）。

## 目录结构

| 文件 | 说明 |
| --- | --- |
| `src/main.zig` | 平台无关逻辑：参数、35 条祝福语、爱心曲线、HSV 配色、三阶段时间轴 |
| `src/backend_x11.zig` | Linux 后端：X11 + cairo（运行时 dlopen，不需要 X11/cairo 开发包） |
| `src/backend_mac.zig` | macOS 后端：AppKit + CoreGraphics + CoreText（全部运行时 dlopen，因此可交叉编译） |
| `tests/center_test.zig` | macOS 回归测试：把文字画进位图，断言水平居中且没有被裁掉 |
| `build.zig` | 按目标平台选择后端模块并注入 |

## 实现要点

* **爱心曲线**：`x=16sin³t, y=13cos t−5cos2t−2cos3t−cos4t`，用 2000 点密集采样后按弧长等距重采样，
  按屏幕尺寸缩放，弹窗数量按周长算出来并夹在 100~150 之间。
* **配色**：HSV，`h` 随机、`s∈[0.25,0.75]`、`v∈[0.85,1]`，保证背景是明亮的浅色，文字用黑色。
* **字体**：优先行书/行楷（`STXingkai`、`华文行楷`、`Xingkai SC` …），
  逐个测量「平安喜乐」的中文宽度来判断字体是否真的有汉字字形，取第一个可用的。
* **退出**：X11 下用 `XGrabKey` 抓 Esc（抓不到会提示，可用 `SHAODJ_NO_ESC=1` 关闭），
  同时监听鼠标按键；macOS 直接接收键盘事件。
* **Objective-C 调用**：macOS 后端所有消息都走 `objc_msgSend`。
  不能直接调用 `class_getMethodImplementation` 拿到的 IMP——AppKit 内部大量使用
  `objc_direct` 方法，直接调 IMP 会跳进错误的代码并崩溃（表现为
  `-[NSImage initWithCGImage:size:]` 段错误）。
  另外 x86_64 上返回 `NSRect` 这类大结构体的方法要用 `objc_msgSend_stret`，
  用普通 `objc_msgSend` 会因为隐藏返回指针被当成 receiver 而崩溃。
* **CoreText 宽度**：居中要用 `CTLineGetTypographicBounds` 的**返回值**（就是宽度），
  不要用它的 `width` 出参——有些系统（比如 macOS 虚拟机）根本不写回这个出参，
  拿到 0 就会把文字算到窗口正中间，右半截被裁掉，看起来就是「没居中、只显示了一半」。
  `tests/center_test.zig` 就是为了盯住这一点：它把文字画进位图，
  统计墨迹包围盒，断言左右留白基本相等、且没有碰到边缘。
* **环境变量**：`SHAODJ_DEBUG=1` 打印字体探测和文字测量信息。

## 与其它版本的对比

* `../shaodj_go/`：Go 版本（Linux 已实跑验证；macOS 后端用 cgo，需要在 Mac 上或带 SDK 的环境编译）
* `../shaodj_1.py`：原始 Python 版本

Zig 版本的优点：单个静态二进制、无运行时依赖、macOS 版本可以在 Linux 上交叉编译。
