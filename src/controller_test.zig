// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const a = @import("r4os").abi;
const t = std.testing;
const Controller = @import("controller.zig").Controller;
const b = @import("backend.zig");
const Fake = struct {
    value: b.Observation = .{ .driver_state = a.cpu_performance_state_ready, .enabled = true, .caps = .{ .lowest = 10, .highest = 200, .nominal = 150, .efficient = 40, .epp = true }, .report = .{ .cpu_index = 2, .backend = a.power_profile_backend_hwp, .cpu_epoch = 7, .provider_generation = 41, .revision = 4, .valid_mask = a.power_profile_cpu_valid_request | a.power_profile_cpu_valid_range, .minimum = 10, .maximum = 200, .observed_request = 0x1234, .baseline_request = 0x1234 } },
    inspections: u32 = 0,
    applications: u32 = 0,
    enables: u32 = 0,
    releases: u32 = 0,
    sensor_error: bool = false,
    uncertain: bool = false,
    return_error: bool = false,
    replace_on_apply: bool = false,
    cppc: bool = false,
    pub fn call(self: *Fake, kind: u32, request: a.CpuPerformanceRequest) b.Observation {
        std.debug.assert(request.cpu_index == 2 and request.epoch == 7);
        if (kind == a.power_profile_backend_hwp and self.cppc) {
            var unsupported = self.value;
            unsupported.driver_state = a.cpu_performance_state_unsupported;
            return unsupported;
        }
        self.value.report.backend = kind;
        switch (request.operation) {
            a.cpu_performance_op_inspect => {
                self.inspections += 1;
                if (self.sensor_error) return .{ .rc = a.cpu_capabilities_error_busy };
            },
            a.cpu_performance_op_apply => {
                self.applications += 1;
                std.debug.assert(request.lease == self.value.report.lease and request.expected_revision == self.value.report.revision);
                self.value.report.lease = 88;
                self.value.report.revision += 1;
                self.value.report.minimum = request.minimum;
                self.value.report.maximum = request.maximum;
                self.value.report.desired = request.desired;
                self.value.report.epp = request.epp;
                self.value.report.last_written = 0xabcdef;
                self.value.report.observed_request = if (self.uncertain) 0 else 0xabcdef;
                self.value.driver_state = if (self.uncertain) a.cpu_performance_state_uncertain else a.cpu_performance_state_owned;
                if (self.replace_on_apply) self.value.report.provider_generation += 1;
            },
            a.cpu_performance_op_enable => {
                self.enables += 1;
                std.debug.assert(request.flags == a.cpu_performance_request_flag_sticky_enable and request.lease == 0);
                self.value.enabled = true;
                self.value.driver_state = a.cpu_performance_state_ready;
                self.value.report.flags |= a.power_profile_cpu_flag_sticky_enabled;
                if (self.uncertain) {
                    self.value.report.lease = 88;
                    self.value.driver_state = a.cpu_performance_state_uncertain;
                }
            },
            a.cpu_performance_op_release => {
                self.releases += 1;
                std.debug.assert(request.lease == 88 and request.expected_revision == self.value.report.revision);
                if (self.return_error) return .{ .rc = a.cpu_capabilities_error_busy };
                self.value.report.lease = 0;
                self.value.report.observed_request = self.value.report.baseline_request;
                self.value.driver_state = a.cpu_performance_state_restored;
            },
            else => unreachable,
        }
        return self.value;
    }
};
fn controller(io: *Fake) Controller {
    var result = Controller.init(2, 7, 9001);
    result.discover(io);
    return result;
}
test "profile receipt binds local CPU epoch provider token and exact revisions; sensor-independent return restores original baseline" {
    var io: Fake = .{};
    var owner = controller(&io);
    owner.select(&io, a.power_profile_balanced, 9, false);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u64, 88), owner.view.lease);
    try t.expectEqual(@as(u64, 9), owner.view.applied_revision);
    try t.expectEqual(a.power_profile_state_applied, owner.view.state);
    io.sensor_error = true;
    const before = io.inspections;
    owner.release(&io);
    try t.expect(!owner.owns());
    try t.expectEqual(before, io.inspections);
    try t.expectEqual(@as(u32, 1), io.releases);
    try t.expectEqual(@as(u64, 0x1234), owner.view.observed_request);
    try t.expectEqual(@as(u64, 9001), owner.view.service_generation);
}
test "firmware and invalid profile never write; no implicit sticky activation" {
    var io: Fake = .{};
    var owner = controller(&io);
    owner.select(&io, a.power_profile_firmware, 2, false);
    owner.select(&io, 4, 3, true);
    io.value.enabled = false;
    io.value.driver_state = a.cpu_performance_state_disabled;
    owner.select(&io, a.power_profile_performance, 4, false);
    try t.expectEqual(@as(u32, 0), io.applications + io.enables + io.releases);
    try t.expectEqual(a.power_profile_state_disabled, owner.view.state);
}
test "explicit enable receipt remains separate and an uncertain enable is retained without a parameter write" {
    var io: Fake = .{};
    io.value.enabled = false;
    io.value.driver_state = a.cpu_performance_state_disabled;
    var owner = controller(&io);
    io.uncertain = true;
    owner.select(&io, a.power_profile_saving, 2, true);
    try t.expectEqual(@as(u32, 1), io.enables);
    try t.expectEqual(@as(u32, 0), io.applications);
    try t.expect(owner.owns());
    try t.expectEqual(a.power_profile_state_retained, owner.view.state);
    owner.release(&io);
    try t.expect(!owner.owns());
}
test "foreign control is never adopted overwritten or released by a new service generation" {
    var io: Fake = .{};
    io.value.report.lease = 99;
    var owner = controller(&io);
    owner.select(&io, a.power_profile_balanced, 2, false);
    owner.release(&io);
    try t.expect(!owner.owns());
    try t.expectEqual(@as(u64, 0), owner.view.lease);
    try t.expect(owner.view.flags & a.power_profile_cpu_flag_foreign_control != 0);
    try t.expectEqual(@as(u32, 0), io.applications + io.enables + io.releases);
}
test "failed return preserves exact token baseline and frame ownership until a real explicit acknowledgement" {
    var io: Fake = .{};
    var owner = controller(&io);
    owner.select(&io, a.power_profile_saving, 2, false);
    io.return_error = true;
    owner.release(&io);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u64, 88), owner.view.lease);
    try t.expectEqual(@as(u64, 0x1234), owner.view.baseline_request);
    try t.expectEqual(@as(u64, 0), owner.view.applied_revision);
    io.return_error = false;
    owner.release(&io);
    try t.expect(!owner.owns());
    try t.expectEqual(@as(u32, 2), io.releases);
}
test "provider replacement with an old live token quarantines without redirecting return" {
    var io: Fake = .{};
    var owner = controller(&io);
    owner.select(&io, a.power_profile_balanced, 2, false);
    io.value.report.provider_generation = 92;
    try t.expect(!owner.refresh(&io));
    owner.release(&io);
    try t.expect(owner.quarantined);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u64, 41), owner.view.provider_generation);
    try t.expectEqual(@as(u32, 0), io.releases);
}
test "binding changes before first acquisition keep the actual new operation receipt available for return" {
    var io: Fake = .{};
    var owner = controller(&io);
    io.replace_on_apply = true;
    owner.select(&io, a.power_profile_balanced, 2, false);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u64, 42), owner.view.provider_generation);
    try t.expectEqual(a.power_profile_state_retained, owner.view.state);
    try t.expectEqual(@as(u64, 0), owner.view.applied_revision);
    owner.release(&io);
    try t.expect(!owner.owns());
}
test "uncertain write cannot become an applied profile or lose its actual hardware control" {
    var io: Fake = .{};
    var owner = controller(&io);
    io.uncertain = true;
    owner.select(&io, a.power_profile_performance, 2, false);
    try t.expect(owner.owns());
    try t.expectEqual(@as(u64, 0), owner.view.applied_revision);
    try t.expectEqual(a.power_profile_state_retained, owner.view.state);
    owner.release(&io);
    try t.expect(!owner.owns());
}
test "CPPc uses the independent backend and current abstract constraint; release remains possible at exhausted revision" {
    var io: Fake = .{};
    io.cppc = true;
    io.value.caps.current_limit = 80;
    var owner = controller(&io);
    owner.select(&io, a.power_profile_performance, 2, false);
    try t.expectEqual(a.power_profile_backend_cppc, owner.view.backend);
    try t.expectEqual(@as(u32, 80), owner.view.maximum);
    io.value.report.revision = std.math.maxInt(u64);
    owner.view.revision = std.math.maxInt(u64);
    owner.release(&io);
    try t.expect(!owner.owns());
}
test "normalizers keep HWP and CPPC layouts ranges EPP and validity separate" {
    const h = b.fromHwp(.{ .cpu_index = 2, .epoch = 7, .provider_generation = 41, .highest = 200, .guaranteed = 150, .efficient = 40, .lowest = 10, .flags = a.cpu_performance_flag_epp, .valid_mask = a.cpu_performance_valid_capabilities });
    const c = b.fromCppc(.{ .cpu_index = 2, .epoch = 7, .provider_generation = 41, .highest = 190, .nominal = 140, .lowest_nonlinear = 35, .lowest = 9, .raw_capability2 = 70, .valid_mask = a.cpu_cppc_valid_range | a.cpu_cppc_valid_current_limit });
    try t.expectEqual(a.power_profile_backend_hwp, h.report.backend);
    try t.expectEqual(@as(u32, 40), h.caps.efficient);
    try t.expectEqual(a.power_profile_backend_cppc, c.report.backend);
    try t.expectEqual(@as(u32, 35), c.caps.efficient);
    try t.expectEqual(@as(?u32, 70), c.caps.current_limit);
    try t.expectEqual(@as(u32, 0), c.report.valid_mask & a.power_profile_cpu_valid_request);
}
test "unsupported transports and missing provider cannot acquire controls or fabricate profile application" {
    var io: Fake = .{};
    io.value.driver_state = a.cpu_performance_state_unsupported;
    var owner = Controller.init(2, 7, 9001);
    owner.select(&io, a.power_profile_balanced, 2, false);
    try t.expect(!owner.owns());
    try t.expectEqual(a.power_profile_backend_none, owner.view.backend);
    try t.expectEqual(@as(u64, 0), owner.view.applied_revision);
    try t.expectEqual(@as(u32, 0), io.applications + io.enables + io.releases);
    io.sensor_error = true;
    owner = Controller.init(2, 7, 9002);
    owner.select(&io, a.power_profile_saving, 2, false);
    try t.expect(!owner.owns());
    try t.expectEqual(@as(u64, 0), owner.view.applied_revision);
    try t.expectEqual(@as(u32, 0), io.applications + io.enables + io.releases);
}
