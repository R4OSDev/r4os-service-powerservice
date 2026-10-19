// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const a = @import("r4os").abi;
const b = @import("backend.zig");
const policy = @import("policy.zig");
const Controller = @import("controller.zig").Controller;
const t = std.testing;
test "PSS profiles select declared nonzero ranks while CPPC keeps abstract autonomous requests" {
    const caps: policy.Capabilities = .{ .lowest = 1, .highest = 3, .nominal = 3, .efficient = 0, .epp = false, .limit = 32, .discrete = true };
    const saving = try policy.request(a.power_profile_saving, caps);
    try t.expectEqual(@as(u32, 1), saving.desired);
    try t.expectEqual(@as(u32, 1), saving.maximum);
    try t.expectEqual(@as(u32, 0), saving.flags);
    const performance = try policy.request(a.power_profile_performance, caps);
    try t.expectEqual(@as(u32, 3), performance.desired);
    const cppc = try policy.request(a.power_profile_balanced, .{ .lowest = 100, .highest = 1000, .nominal = 800, .efficient = 200, .epp = true, .limit = 65535 });
    try t.expectEqual(@as(u32, 0), cppc.desired);
    try t.expectEqual(@as(u32, 1000), cppc.maximum);
}
test "firmware normalization distinguishes discrete ranks and preserves complete domain plus uncertain original receipt" {
    const value = b.fromFirmware(.{ .cpu_index = 2, .epoch = 7, .backend = a.cpu_firmware_backend_pss, .provider_generation = 41, .firmware_generation = 17, .state = a.cpu_performance_state_uncertain, .lease = 88, .revision = 4, .domain_mask = 12, .lowest = 1, .highest = 3, .nominal = 3, .baseline_request = 0x1234, .last_written = 0x5678, .observed_request = 0, .last_error = -8, .valid_mask = a.cpu_firmware_valid_range });
    try t.expectEqual(@as(u64, 12), value.scope_mask);
    try t.expectEqual(@as(u64, 88), value.report.lease);
    try t.expectEqual(a.power_profile_backend_acpi_pss, value.report.backend);
    try t.expect(value.caps.discrete);
    try t.expectEqual(@as(u64, 0x1234), value.firmware.?.baseline_request);
    try t.expectEqual(@as(u64, 0), value.report.baseline_request);
    try t.expectEqual(@as(u64, 0), value.report.last_written);
    try t.expectEqual(@as(u64, 0), value.report.observed_request);
    try t.expectEqual(@as(u32, 0), value.report.minimum | value.report.maximum | value.report.desired | value.report.epp | value.report.nominal);
    try t.expectEqual(@as(u32, 0), value.report.valid_mask & (a.power_profile_cpu_valid_request | a.power_profile_cpu_valid_epp));
    try t.expectEqual(@as(i32, -8), value.report.last_error);
}
const Peer = struct {
    inspections: u32 = 0,
    applications: u32 = 0,
    returns: u32 = 0,
    invalidated: bool = false,
    replace_on_apply: bool = false,
    raw: a.CpuFirmwareInfo = .{ .cpu_index = 2, .epoch = 7, .backend = a.cpu_firmware_backend_pss, .provider_generation = 41, .firmware_generation = 17, .state = a.cpu_performance_state_ready, .domain_mask = 12, .lowest = 1, .highest = 3, .nominal = 3, .baseline_request = 111, .observed_request = 111, .valid_mask = a.cpu_firmware_valid_range | a.cpu_firmware_valid_request },
    pub fn call(self: *Peer, kind: u32, request: a.CpuPerformanceRequest) b.Observation {
        if (kind < a.power_profile_backend_acpi_cppc) return .{ .report = .{ .cpu_index = 2, .cpu_epoch = 7, .provider_generation = 41, .backend = kind } };
        switch (request.operation) {
            a.cpu_performance_op_inspect => {
                self.inspections += 1;
                if (self.invalidated) {
                    var raw = self.raw;
                    raw.state = a.cpu_performance_state_uncertain;
                    raw.valid_mask = 0;
                    raw.last_error = -7;
                    return b.fromFirmware(raw);
                }
            },
            a.cpu_performance_op_apply => {
                self.applications += 1;
                self.raw.lease = 88;
                self.raw.revision += 1;
                self.raw.state = a.cpu_performance_state_owned;
                self.raw.minimum = request.minimum;
                self.raw.maximum = request.maximum;
                self.raw.desired = request.desired;
                self.raw.last_written = 222;
                self.raw.observed_request = 222;
                if (self.replace_on_apply) self.raw.firmware_generation += 1;
            },
            a.cpu_performance_op_release => {
                self.returns += 1;
                std.debug.assert(request.lease == 88 and request.expected_revision == self.raw.revision);
                self.raw.lease = 0;
                self.raw.state = a.cpu_performance_state_restored;
                self.raw.observed_request = 111;
            },
            else => unreachable,
        }
        return b.fromFirmware(self.raw);
    }
};
test "firmware domain profile falls back only after unsupported direct providers and survives catalogue withdrawal until exact return" {
    var peer: Peer = .{};
    var owner = Controller.init(2, 7, 9001);
    owner.select(&peer, a.power_profile_saving, 9, false);
    try t.expect(owner.owns());
    try t.expectEqual(a.power_profile_backend_acpi_pss, owner.view.backend);
    try t.expectEqual(@as(u64, 12), owner.scope_mask);
    try t.expectEqual(@as(u64, 9), owner.view.applied_revision);
    peer.invalidated = true;
    try t.expect(!owner.refresh(&peer));
    try t.expect(owner.owns());
    try t.expect(!owner.quarantined);
    const inspections = peer.inspections;
    owner.release(&peer);
    try t.expect(!owner.owns());
    try t.expectEqual(inspections, peer.inspections);
    try t.expectEqual(@as(u32, 1), peer.applications);
    try t.expectEqual(@as(u32, 1), peer.returns);
}
test "a new firmware generation before first acquisition preserves its actual new token for return" {
    var peer: Peer = .{ .replace_on_apply = true };
    var owner = Controller.init(2, 7, 9001);
    owner.select(&peer, a.power_profile_saving, 9, false);
    try t.expect(owner.owns());
    try t.expectEqual(a.power_profile_state_retained, owner.view.state);
    try t.expectEqual(@as(u64, 18), owner.firmware.?.firmware_generation);
    try t.expectEqual(@as(u64, 0), owner.view.baseline_request);
    owner.release(&peer);
    try t.expect(!owner.owns());
    try t.expectEqual(@as(u32, 1), peer.returns);
}
test "an owned firmware generation substitution quarantines the old token without calling the new provider" {
    var peer: Peer = .{};
    var owner = Controller.init(2, 7, 9001);
    owner.select(&peer, a.power_profile_saving, 9, false);
    try t.expect(owner.owns());
    peer.raw.firmware_generation += 1;
    try t.expect(!owner.refresh(&peer));
    try t.expect(owner.quarantined);
    try t.expectEqual(@as(u64, 17), owner.firmware.?.firmware_generation);
    owner.release(&peer);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u32, 0), peer.returns);
}
