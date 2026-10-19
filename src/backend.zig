// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! The service uses only CPUPOWER's typed transport, never raw registers.
const r4os = @import("r4os");
const a = r4os.abi;
const policy = @import("policy.zig");
pub const Observation = struct {
    rc: i32 = 0,
    report: a.PowerCpuProfileInfo = .{},
    driver_state: u32 = a.cpu_performance_state_unsupported,
    enabled: bool = false,
    scope_mask: u64 = 0,
    firmware: ?a.CpuFirmwareInfo = null,
    caps: policy.Capabilities = .{ .lowest = 0, .highest = 0, .nominal = 0, .efficient = 0, .epp = false },
};
pub const Io = struct {
    dev: r4os.r4dev.Context,
    pub fn call(self: *Io, backend: u32, request: a.CpuPerformanceRequest) Observation {
        if (backend == a.power_profile_backend_hwp) {
            var raw: a.CpuPerformanceInfo = .{};
            const rc = self.dev.cpuPerformance(&request, &raw);
            if (rc != 0) return .{ .rc = rc };
            if (raw.version != 1 or raw.size != @sizeOf(a.CpuPerformanceInfo) or raw.cpu_index != request.cpu_index or
                raw.epoch != request.epoch or raw.provider_generation == 0) return .{ .rc = a.cpu_capabilities_error_invalid };
            return fromHwp(raw);
        }
        if (backend == a.power_profile_backend_cppc) {
            var raw: a.CpuCppcInfo = .{};
            const rc = self.dev.cpuCppc(&request, &raw);
            if (rc != 0) return .{ .rc = rc };
            if (raw.version != 1 or raw.size != @sizeOf(a.CpuCppcInfo) or raw.cpu_index != request.cpu_index or
                raw.epoch != request.epoch or raw.provider_generation == 0) return .{ .rc = a.cpu_capabilities_error_invalid };
            return fromCppc(raw);
        }
        if (backend == a.power_profile_backend_acpi_cppc or backend == a.power_profile_backend_acpi_pss) {
            var raw: a.CpuFirmwareInfo = .{};
            const rc = self.dev.cpuFirmwarePerformance(&request, &raw);
            if (rc != 0) return .{ .rc = rc };
            if (raw.version != 1 or raw.size != @sizeOf(a.CpuFirmwareInfo) or raw.cpu_index != request.cpu_index or raw.epoch != request.epoch or
                raw.provider_generation == 0 or raw.firmware_generation == 0 or raw.backend > a.cpu_firmware_backend_pss or
                (raw.valid_mask & a.cpu_firmware_valid_domain != 0 and (raw.domain_mask == 0 or raw.domain_mask & (@as(u64, 1) << @as(u6, @intCast(raw.cpu_index))) == 0))) return .{ .rc = a.cpu_capabilities_error_invalid };
            return fromFirmware(raw);
        }
        return .{ .rc = a.cpu_capabilities_error_unsupported };
    }
};
pub fn fromFirmware(raw: a.CpuFirmwareInfo) Observation {
    const pss = raw.backend == a.cpu_firmware_backend_pss;
    return .{
        .driver_state = raw.state,
        .enabled = raw.state == a.cpu_performance_state_ready or raw.state == a.cpu_performance_state_owned,
        .scope_mask = raw.domain_mask,
        .firmware = raw,
        .caps = .{ .lowest = raw.lowest, .highest = raw.highest, .nominal = raw.nominal, .efficient = raw.efficient, .epp = raw.flags & a.cpu_performance_flag_epp != 0, .limit = if (pss) 32 else 65535, .discrete = pss },
        // The fixed common record's request words mean actual raw HWP/CPPC
        // registers. Firmware fingerprints and compound requests belong only
        // to their independent record; never relabel them as those raw words.
        .report = .{ .cpu_index = raw.cpu_index, .backend = if (pss) a.power_profile_backend_acpi_pss else a.power_profile_backend_acpi_cppc, .cpu_epoch = raw.epoch, .provider_generation = raw.provider_generation, .lease = raw.lease, .revision = raw.revision, .captured_ns = raw.captured_ns, .lowest = raw.lowest, .highest = raw.highest, .efficient = if (pss) 0 else raw.efficient, .nominal = if (pss) 0 else raw.nominal, .last_error = raw.last_error, .valid_mask = (if (raw.valid_mask & a.cpu_firmware_valid_range != 0) @as(u32, a.power_profile_cpu_valid_range) else 0) |
            (if (raw.valid_mask & a.cpu_firmware_valid_time != 0) @as(u32, a.power_profile_cpu_valid_time) else 0) },
    };
}
fn flags(raw: u32) u32 {
    return if (raw & a.cpu_performance_flag_sticky_enabled != 0) a.power_profile_cpu_flag_sticky_enabled else 0;
}
pub fn fromHwp(raw: a.CpuPerformanceInfo) Observation {
    return .{
        .driver_state = raw.state,
        .enabled = raw.raw_enable == 1 and raw.valid_mask & a.cpu_performance_valid_enable != 0,
        .caps = .{ .lowest = raw.lowest, .highest = raw.highest, .nominal = raw.guaranteed, .efficient = raw.efficient, .epp = raw.flags & a.cpu_performance_flag_epp != 0 },
        .report = .{ .cpu_index = raw.cpu_index, .backend = a.power_profile_backend_hwp, .flags = flags(raw.flags), .cpu_epoch = raw.epoch, .provider_generation = raw.provider_generation, .lease = raw.lease, .revision = raw.revision, .captured_ns = raw.captured_ns, .minimum = raw.minimum, .maximum = raw.maximum, .desired = raw.desired, .epp = raw.epp, .lowest = raw.lowest, .highest = raw.highest, .efficient = raw.efficient, .nominal = raw.guaranteed, .baseline_request = raw.baseline_request, .last_written = raw.last_written, .observed_request = raw.raw_request, .last_error = raw.last_error, .valid_mask = (if (raw.valid_mask & a.cpu_performance_valid_request != 0) @as(u32, a.power_profile_cpu_valid_request) else 0) |
            (if (raw.valid_mask & a.cpu_performance_valid_capabilities != 0) @as(u32, a.power_profile_cpu_valid_range) else 0) |
            (if (raw.valid_mask & a.cpu_performance_valid_time != 0) @as(u32, a.power_profile_cpu_valid_time) else 0) |
            (if (raw.flags & a.cpu_performance_flag_epp != 0) @as(u32, a.power_profile_cpu_valid_epp) else 0) },
    };
}
pub fn fromCppc(raw: a.CpuCppcInfo) Observation {
    return .{
        .driver_state = raw.state,
        .enabled = raw.raw_enable == 1 and raw.valid_mask & a.cpu_cppc_valid_enable != 0,
        .caps = .{ .lowest = raw.lowest, .highest = raw.highest, .nominal = raw.nominal, .efficient = raw.lowest_nonlinear, .epp = raw.flags & a.cpu_performance_flag_epp != 0, .current_limit = if (raw.valid_mask & a.cpu_cppc_valid_current_limit != 0) @intCast(raw.raw_capability2) else null },
        .report = .{ .cpu_index = raw.cpu_index, .backend = a.power_profile_backend_cppc, .flags = flags(raw.flags), .cpu_epoch = raw.epoch, .provider_generation = raw.provider_generation, .lease = raw.lease, .revision = raw.revision, .captured_ns = raw.captured_ns, .minimum = raw.minimum, .maximum = raw.maximum, .desired = raw.desired, .epp = raw.epp, .lowest = raw.lowest, .highest = raw.highest, .efficient = raw.lowest_nonlinear, .nominal = raw.nominal, .baseline_request = raw.baseline_request, .last_written = raw.last_written, .observed_request = raw.raw_request, .last_error = raw.last_error, .valid_mask = (if (raw.valid_mask & a.cpu_cppc_valid_request != 0) @as(u32, a.power_profile_cpu_valid_request) else 0) |
            (if (raw.valid_mask & a.cpu_cppc_valid_range != 0) @as(u32, a.power_profile_cpu_valid_range) else 0) |
            (if (raw.valid_mask & a.cpu_cppc_valid_time != 0) @as(u32, a.power_profile_cpu_valid_time) else 0) |
            (if (raw.flags & a.cpu_performance_flag_epp != 0) @as(u32, a.power_profile_cpu_valid_epp) else 0) },
    };
}
