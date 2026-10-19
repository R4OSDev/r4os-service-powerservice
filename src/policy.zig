// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! External profile intent in abstract backend units. This does not predict
//! delivered frequency, boost, energy, thermal freedom or a hard clock limit.
const a = @import("r4os").abi;
pub const Error = error{ InvalidProfile, ReturnOnly, Unsupported, EfficiencyUnknown, Constrained };
pub const Capabilities = struct {
    lowest: u32,
    highest: u32,
    nominal: u32,
    efficient: u32,
    epp: bool,
    limit: u32 = 255,
    discrete: bool = false,
    current_limit: ?u32 = null,

    pub fn valid(self: Capabilities) bool {
        return self.lowest != 0 and self.lowest <= self.highest and self.highest <= self.limit and
            (self.nominal == 0 or (self.nominal >= self.lowest and self.nominal <= self.highest)) and
            (self.efficient == 0 or (self.efficient >= self.lowest and self.efficient <= self.highest));
    }
};
/// Firmware selection returns the exact owned baseline; it never synthesizes
/// a guessed firmware request from capability numbers. Caller handles it apart.
pub fn request(profile: u32, caps: Capabilities) Error!a.CpuPerformanceRequest {
    if (profile > a.power_profile_saving) return Error.InvalidProfile;
    if (profile == a.power_profile_firmware) return Error.ReturnOnly;
    if (!caps.valid()) return Error.Unsupported;
    var maximum = caps.highest;
    if (profile == a.power_profile_saving) {
        maximum = if (caps.discrete) caps.lowest else if (caps.efficient != 0) caps.efficient else if (caps.nominal != 0) caps.nominal else return Error.EfficiencyUnknown;
    }
    if (caps.current_limit) |limit| {
        // CPPC CAP2 is a current advisory constraint, not a frequency. A
        // below-range/zero constraint cannot become an invalid max0 request.
        if (limit < caps.lowest) return Error.Constrained;
        maximum = @min(maximum, limit);
    }
    return .{
        .operation = a.cpu_performance_op_apply,
        .minimum = caps.lowest,
        .maximum = maximum,
        .desired = if (caps.discrete) @min(maximum, if (profile == a.power_profile_performance) caps.highest else caps.nominal) else 0,
        .epp = if (!caps.epp) 0 else switch (profile) {
            a.power_profile_balanced => 128,
            a.power_profile_performance => 0,
            a.power_profile_saving => 255,
            else => unreachable,
        },
        .flags = if (caps.epp) a.cpu_performance_request_flag_epp else 0,
    };
}

pub fn name(profile: u32) []const u8 {
    return switch (profile) {
        a.power_profile_firmware => "firmware",
        a.power_profile_balanced => "balanced",
        a.power_profile_performance => "performance",
        a.power_profile_saving => "saving",
        else => "invalid",
    };
}
