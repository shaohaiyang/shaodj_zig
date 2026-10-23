const std = @import("std");

/// Zig 构建脚本入口：决定用什么后端、编译哪些程序、注册哪些命令。
///
/// 用 `zig build` 编译，用 `zig build run` 运行，用 `zig build test` 跑测试。
pub fn build(b: *std.Build) void {
    // 目标平台和优化级别都可以从命令行传入：
    //   zig build -Dtarget=x86_64-linux-gnu
    //   zig build -Doptimize=ReleaseSafe
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 图形后端按目标平台选择：macOS 用 AppKit，其余用 X11。
    const backend_src = switch (target.result.os.tag) {
        .macos => b.path("src/backend_mac.zig"),
        else => b.path("src/backend_x11.zig"),
    };

    // 把后端做成一个模块，主程序通过 @import("backend") 使用它。
    // 这样主程序不需要知道自己是跑在 macOS 还是 Linux 上。
    const backend_mod = b.addModule("backend", .{
        .root_source_file = backend_src,
        .target = target,
        .optimize = optimize,
    });

    // 主程序：平台无关的业务逻辑。
    const exe = b.addExecutable(.{
        .name = "shaodj_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("backend", backend_mod);

    b.installArtifact(exe);

    // `zig build run`：先安装，再运行编译出来的程序。
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "运行程序");
    run_step.dependOn(&run_cmd.step);

    // macOS 专用回归测试：文字必须水平居中、不能被裁掉。
    // 其它平台没有对应的测试程序，所以不注册 test 命令。
    if (target.result.os.tag == .macos) {
        const test_exe = b.addExecutable(.{
            .name = "center_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/center_test.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_tests = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "运行测试");
        test_step.dependOn(&run_tests.step);
    }
}
