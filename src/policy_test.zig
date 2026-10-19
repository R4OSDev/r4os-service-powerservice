// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const a = @import("r4os").abi;
const policy = @import("policy.zig");
const t = std.testing;
test {
    _ = @import("controller_test.zig");
    _ = @import("protocol_test.zig");
    _ = @import("workers_test.zig");
    _ = @import("firmware_test.zig");
}
test "three profile intents use bounded abstract values and autonomous desired" {
    const caps: policy.Capabilities = .{ .lowest = 10, .highest = 200, .nominal = 150, .efficient = 40, .epp = true };
    for ([_]struct { profile: u32, maximum: u32, epp: u32 }{
        .{ .profile = a.power_profile_balanced, .maximum = 200, .epp = 128 },
        .{ .profile = a.power_profile_performance, .maximum = 200, .epp = 0 },
        .{ .profile = a.power_profile_saving, .maximum = 40, .epp = 255 },
    }) |example| {
        const request = try policy.request(example.profile, caps);
        try t.expectEqual(@as(u32, 10), request.minimum);
        try t.expectEqual(example.maximum, request.maximum);
        try t.expectEqual(example.epp, request.epp);
        try t.expectEqual(@as(u32, 0), request.desired);
        try t.expectEqual(a.cpu_performance_request_flag_epp, request.flags);
        try t.expectEqual(@as(u64, 0), request.lease);
        try t.expectEqual(@as(u64, 0), request.expected_revision);
    }
}
test "firmware return never invents raw baseline; invalid and unknown ranges refuse" {
    const caps: policy.Capabilities = .{ .lowest = 10, .highest = 200, .nominal = 150, .efficient = 40, .epp = true };
    try t.expectError(error.ReturnOnly, policy.request(a.power_profile_firmware, caps));
    try t.expectError(error.InvalidProfile, policy.request(4, caps));
    for ([_]policy.Capabilities{
        .{ .lowest = 0, .highest = 200, .nominal = 150, .efficient = 40, .epp = true },
        .{ .lowest = 10, .highest = 256, .nominal = 150, .efficient = 40, .epp = true },
        .{ .lowest = 201, .highest = 200, .nominal = 150, .efficient = 40, .epp = true },
        .{ .lowest = 10, .highest = 200, .nominal = 201, .efficient = 40, .epp = true },
    }) |bad| try t.expectError(error.Unsupported, policy.request(a.power_profile_performance, bad));
}
test "optional EPP remains untouched and savings does not fabricate an unknown efficiency threshold" {
    const caps: policy.Capabilities = .{ .lowest = 10, .highest = 200, .nominal = 150, .efficient = 0, .epp = false };
    const value = try policy.request(a.power_profile_saving, caps);
    try t.expectEqual(@as(u32, 150), value.maximum);
    try t.expectEqual(@as(u32, 0), value.flags);
    try t.expectEqual(@as(u32, 0), value.epp);
    try t.expectError(error.EfficiencyUnknown, policy.request(a.power_profile_saving, .{ .lowest = 10, .highest = 200, .nominal = 0, .efficient = 0, .epp = false }));
}
test "current CPPc constraint cannot be turned into an invalid bound or MHz" {
    var caps: policy.Capabilities = .{ .lowest = 10, .highest = 200, .nominal = 150, .efficient = 40, .epp = true, .current_limit = 110 };
    try t.expectEqual(@as(u32, 110), (try policy.request(a.power_profile_performance, caps)).maximum);
    try t.expectEqual(@as(u32, 40), (try policy.request(a.power_profile_saving, caps)).maximum);
    caps.current_limit = 0;
    try t.expectError(error.Constrained, policy.request(a.power_profile_balanced, caps));
    caps.current_limit = 9;
    try t.expectError(error.Constrained, policy.request(a.power_profile_balanced, caps));
}
