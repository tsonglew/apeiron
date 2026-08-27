const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 静态库：harness 核心（宿主 link；WASM 演示同样 build 成这个库）
    const lib = b.addLibrary(.{
        .name = "apeiron",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // zig test：所有模块的单测入口（root.zig 里 re-export 各模块）
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // wasm-demo：教程网页交互演示（浏览器里真实运行 harness 核心）
    const wasm = b.addExecutable(.{
        .name = "apeiron-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.export_memory = true;
    wasm.rdynamic = true; // 保留 export fn（否则 wasm-ld 会剥离未引用代码）
    b.installArtifact(wasm);
    const wasm_step = b.step("wasm-demo", "Build browser demo wasm (zig-out/bin/apeiron-demo.wasm)");
    wasm_step.dependOn(b.getInstallStep());
}
