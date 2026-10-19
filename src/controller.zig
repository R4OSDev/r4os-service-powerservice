// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! A worker owns this controller on one hard-admitted CPU. Only a direct
//! successful operation receipt may create ownership; inspection never does.
const a = @import("r4os").abi;
const backend = @import("backend.zig");
const policy = @import("policy.zig");
pub const Controller = struct {
    view: a.PowerCpuProfileInfo,
    driver_state: u32 = a.cpu_performance_state_unsupported,
    caps: policy.Capabilities = .{ .lowest = 0, .highest = 0, .nominal = 0, .efficient = 0, .epp = false },
    enabled: bool = false,
    quarantined: bool = false,

    pub fn init(cpu: u32, epoch: u64, generation: u64) Controller {
        return .{ .view = .{ .cpu_index = cpu, .cpu_epoch = epoch, .service_generation = generation, .state = a.power_profile_state_unsupported } };
    }
    pub fn owns(self: *const Controller) bool {
        return self.view.flags & a.power_profile_cpu_flag_owned != 0;
    }
    fn fail(self: *Controller, rc: i32, retain: bool) void {
        self.view.last_error = rc;
        self.view.flags &= ~@as(u32, a.power_profile_cpu_flag_confirmed);
        self.view.applied_revision = 0;
        self.view.state = if (retain or self.owns()) a.power_profile_state_retained else a.power_profile_state_unsupported;
    }
    fn identity(self: *const Controller, value: backend.Observation) bool {
        return value.report.cpu_index == self.view.cpu_index and value.report.cpu_epoch == self.view.cpu_epoch and
            value.report.backend == self.view.backend and value.report.provider_generation != 0 and
            (self.view.provider_generation == 0 or value.report.provider_generation == self.view.provider_generation);
    }
    fn accept(self: *Controller, value: backend.Observation, ownership_receipt: bool) bool {
        if (value.rc != 0) {
            self.fail(value.rc, false);
            return false;
        }
        if (!self.owns() and ownership_receipt and value.report.lease != 0 and
            value.report.cpu_index == self.view.cpu_index and value.report.cpu_epoch == self.view.cpu_epoch and
            value.report.backend == self.view.backend and value.report.provider_generation != 0 and !self.identity(value))
        {
            // A binding may change before the first acquisition. Preserve the
            // direct receipt of our new control so it can be returned; never
            // attach an old token to a new provider, or claim this was applied.
            self.install(value);
            self.fail(a.cpu_capabilities_error_epoch, true);
            return false;
        }
        if (!self.identity(value) or (self.owns() and
            (value.report.lease != self.view.lease or value.report.revision < self.view.revision)))
        {
            self.quarantined = self.owns();
            self.fail(a.cpu_capabilities_error_epoch, true);
            return false;
        }
        if (!self.owns() and value.report.lease != 0 and !ownership_receipt) {
            self.view.flags |= a.power_profile_cpu_flag_foreign_control;
            self.fail(a.cpu_capabilities_error_busy, true);
            return false;
        }
        self.install(value);
        return true;
    }
    fn install(self: *Controller, value: backend.Observation) void {
        const profile = self.view.profile;
        const generation = self.view.service_generation;
        const applied = self.view.applied_revision;
        const worker = self.view.worker_state;
        self.view = value.report;
        self.view.profile = profile;
        self.view.service_generation = generation;
        self.view.applied_revision = applied;
        self.view.worker_state = worker;
        if (value.report.lease != 0) self.view.flags |= a.power_profile_cpu_flag_owned;
        self.driver_state = value.driver_state;
        self.enabled = value.enabled;
        self.caps = value.caps;
    }
    fn request(self: *const Controller, operation: u32) a.CpuPerformanceRequest {
        return .{ .cpu_index = self.view.cpu_index, .epoch = self.view.cpu_epoch, .operation = operation, .lease = if (operation == a.cpu_performance_op_inspect or operation == a.cpu_performance_op_enable) 0 else self.view.lease, .expected_revision = if (operation == a.cpu_performance_op_inspect or operation == a.cpu_performance_op_enable) 0 else self.view.revision };
    }
    pub fn discover(self: *Controller, io: anytype) void {
        if (self.owns() or self.quarantined) return;
        self.view.provider_generation = 0;
        self.view.flags = 0;
        self.view.backend = a.power_profile_backend_hwp;
        var value = io.call(self.view.backend, self.request(a.cpu_performance_op_inspect));
        if (value.rc == 0 and value.driver_state == a.cpu_performance_state_unsupported) {
            self.view.backend = a.power_profile_backend_cppc;
            value = io.call(self.view.backend, self.request(a.cpu_performance_op_inspect));
        }
        if (!self.accept(value, false)) return;
        self.view.state = if (self.driver_state == a.cpu_performance_state_disabled) a.power_profile_state_disabled else a.power_profile_state_unsupported;
        if (self.driver_state == a.cpu_performance_state_unsupported) self.view.backend = a.power_profile_backend_none;
    }
    pub fn refresh(self: *Controller, io: anytype) bool {
        if (self.quarantined or self.view.backend == a.power_profile_backend_none) return false;
        const applied = self.view.applied_revision;
        if (!self.accept(io.call(self.view.backend, self.request(a.cpu_performance_op_inspect)), false)) return false;
        if (self.owns()) {
            if (self.driver_state != a.cpu_performance_state_owned or self.view.valid_mask & a.power_profile_cpu_valid_request == 0 or
                self.view.observed_request != self.view.last_written)
            {
                self.fail(a.cpu_capabilities_error_busy, true);
                return false;
            }
            self.view.flags |= a.power_profile_cpu_flag_confirmed;
            self.view.state = a.power_profile_state_applied;
            self.view.applied_revision = applied;
        }
        return true;
    }
    pub fn select(self: *Controller, io: anytype, profile: u32, revision: u64, sticky: bool) void {
        if (profile > a.power_profile_saving or revision == 0 or (profile == a.power_profile_firmware and sticky)) {
            self.fail(a.cpu_capabilities_error_invalid, false);
            return;
        }
        self.view.profile = profile;
        self.view.applied_revision = 0;
        if (profile == a.power_profile_firmware) {
            self.release(io);
            return;
        }
        if (self.quarantined) {
            self.fail(a.cpu_capabilities_error_epoch, true);
            return;
        }
        if (self.view.backend == a.power_profile_backend_none) self.discover(io);
        if (self.view.backend == a.power_profile_backend_none or self.view.flags & a.power_profile_cpu_flag_foreign_control != 0) return;
        if (!self.refresh(io)) return;
        if (!self.enabled and sticky and self.driver_state == a.cpu_performance_state_disabled) {
            var enable = self.request(a.cpu_performance_op_enable);
            enable.flags = a.cpu_performance_request_flag_sticky_enable;
            if (!self.accept(io.call(self.view.backend, enable), true)) return;
            if (self.owns()) {
                self.fail(a.cpu_capabilities_error_busy, true);
                return;
            }
            if (!self.refresh(io)) return;
        }
        if (!self.enabled) {
            self.view.state = a.power_profile_state_disabled;
            return;
        }
        var operation = policy.request(profile, self.caps) catch {
            self.fail(a.cpu_capabilities_error_unsupported, false);
            return;
        };
        operation.cpu_index = self.view.cpu_index;
        operation.epoch = self.view.cpu_epoch;
        operation.lease = self.view.lease;
        operation.expected_revision = self.view.revision;
        if (!self.accept(io.call(self.view.backend, operation), true)) return;
        if (!self.owns() or self.driver_state != a.cpu_performance_state_owned or self.view.valid_mask & a.power_profile_cpu_valid_request == 0 or
            self.view.minimum != operation.minimum or self.view.maximum != operation.maximum or self.view.desired != operation.desired or
            (operation.flags & a.cpu_performance_request_flag_epp != 0 and self.view.epp != operation.epp) or self.view.observed_request != self.view.last_written)
        {
            self.fail(a.cpu_capabilities_error_busy, self.owns());
            return;
        }
        self.view.flags |= a.power_profile_cpu_flag_confirmed;
        self.view.state = a.power_profile_state_applied;
        self.view.applied_revision = revision;
    }
    pub fn release(self: *Controller, io: anytype) void {
        self.view.applied_revision = 0;
        self.view.flags &= ~@as(u32, a.power_profile_cpu_flag_confirmed);
        if (!self.owns()) {
            if (self.view.flags & a.power_profile_cpu_flag_foreign_control == 0) self.view.state = a.power_profile_state_firmware;
            return;
        }
        if (self.quarantined) {
            self.fail(a.cpu_capabilities_error_epoch, true);
            return;
        }
        // No preceding sensor refresh: CPUPOWER owns sensor-independent return.
        const value = io.call(self.view.backend, self.request(a.cpu_performance_op_release));
        if (value.rc != 0 or !self.identity(value) or value.report.lease != 0 or
            value.driver_state == a.cpu_performance_state_uncertain or value.driver_state == a.cpu_performance_state_conflict)
        {
            self.fail(if (value.rc != 0) value.rc else a.cpu_capabilities_error_busy, true);
            return;
        }
        const generation = self.view.service_generation;
        const profile = self.view.profile;
        self.view = value.report;
        self.view.service_generation = generation;
        self.view.profile = profile;
        self.view.state = a.power_profile_state_firmware;
        self.view.flags &= ~@as(u32, a.power_profile_cpu_flag_owned | a.power_profile_cpu_flag_confirmed);
        self.driver_state = value.driver_state;
    }
};
