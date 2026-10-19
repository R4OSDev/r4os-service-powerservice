const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries_dep = b.dependencyFromBuildZig(libraries_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{ .zig_module_roots = &.{libraries_dep.namedLazyPath("r4std_zig_binding")} });
    const host = sdk.createR4osModule(b.graph.host, .Debug);
    const fixture = b.createModule(.{ .root_source_file = b.path("src/policy_test.zig"), .target = b.graph.host, .optimize = .Debug });
    fixture.addImport("r4os", host);
    b.step("test", "Check actual profile policy and control receipts with simulated providers, no host CPU probes").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = fixture })).step);
}
