const std = @import("std");
const a = @import("r4os").abi;
const valid = @import("protocol.zig").validRequest;
test "IPC validates complete fixed records and full generation/revision before any work" {
    const info: a.PowerProfileInfo = .{ .service_generation = 0x12345678_abcdef12, .revision = 0x98765432_abcd1234, .configured_cpus = 4 };
    const base: a.PowerProfileRequest = .{ .profile = a.power_profile_balanced, .expected_service_generation = info.service_generation, .expected_revision = info.revision };
    try std.testing.expect(valid(base, a.power_profile_op_select, info));
    for (0..12) |case| {
        var request = base;
        switch (case) {
            0 => request.expected_service_generation ^= @as(u64, 1) << 63,
            1 => request.expected_revision ^= @as(u64, 1) << 63,
            2 => request.version += 1,
            3 => request.size -= 1,
            4 => request.reserved0 = 1,
            5 => request.reserved1 = 1,
            6 => request.reserved2 = 1,
            7 => request.reserved3 = 1,
            8 => request.profile = 4,
            9 => request.flags = 4,
            10 => request.cpu_index = 1,
            11 => request.expected_service_generation = 0,
            else => unreachable,
        }
        try std.testing.expect(!valid(request, a.power_profile_op_select, info));
    }
}
test "initial passive reads are independent of mutation revisions; enable consent is selection-only" {
    const info: a.PowerProfileInfo = .{ .service_generation = 7, .revision = 99, .configured_cpus = 4 };
    try std.testing.expect(valid(.{}, a.power_profile_op_status, info));
    try std.testing.expect(valid(.{ .cpu_index = 3 }, a.power_profile_op_cpu, info));
    try std.testing.expect(!valid(.{ .cpu_index = 4 }, a.power_profile_op_cpu, info));
    try std.testing.expect(!valid(.{ .expected_service_generation = 8 }, a.power_profile_op_status, info));
    try std.testing.expect(!valid(.{ .expected_revision = 1 }, a.power_profile_op_status, info));
    for ([_]u16{ a.power_profile_op_status, a.power_profile_op_quiesce, a.power_profile_op_resume, a.power_profile_op_reload }) |op|
        try std.testing.expect(!valid(.{ .expected_service_generation = 7, .expected_revision = if (op == a.power_profile_op_status) 0 else 99, .flags = a.power_profile_request_flag_sticky_enable }, op, info));
    try std.testing.expect(!valid(.{ .expected_service_generation = 7, .expected_revision = 99, .flags = a.power_profile_request_flag_sticky_enable }, a.power_profile_op_select, info));
    try std.testing.expect(!valid(.{}, 0, info));
    try std.testing.expect(!valid(.{}, 7, info));
}
