.PHONY: all linux macos macos-arm run clean

ZIG ?= zig
STRIP ?= strip
CODESIGN ?= codesign

all: linux

# Linux (X11 + cairo)
linux:
	$(ZIG) build -Doptimize=ReleaseSafe

# macOS Intel (x86_64) —— 在 Linux 上也能交叉编译
# 最低系统版本锁到 10.13，这样在老一些的 macOS 上也能直接运行
macos:
	$(ZIG) build -Dtarget=x86_64-macos.10.13 -Doptimize=ReleaseSafe
	cp zig-out/bin/shaodj_zig shaodj_zig-macos-x86_64
	$(STRIP) -x shaodj_zig-macos-x86_64
	-$(CODESIGN) -s - shaodj_zig-macos-x86_64
	@file shaodj_zig-macos-x86_64

# macOS Apple Silicon (arm64)
macos-arm:
	$(ZIG) build -Dtarget=aarch64-macos.11.0 -Doptimize=ReleaseSafe
	cp zig-out/bin/shaodj_zig shaodj_zig-macos-arm64
	$(STRIP) -x shaodj_zig-macos-arm64
	-$(CODESIGN) -s - shaodj_zig-macos-arm64
	@file shaodj_zig-macos-arm64

run:
	$(ZIG) build run

clean:
	rm -rf zig-out .zig-cache shaodj_zig-macos-x86_64 shaodj_zig-macos-arm64
