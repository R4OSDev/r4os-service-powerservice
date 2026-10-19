// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const a = @import("r4os").abi;
pub fn validRequest(request: a.PowerProfileRequest, op: u16, info: a.PowerProfileInfo) bool {
    if (request.version != 1 or request.size != @sizeOf(a.PowerProfileRequest) or request.reserved0 != 0 or request.reserved1 != 0 or request.reserved2 != 0 or request.reserved3 != 0) return false;
    if (op < a.power_profile_op_status or op > a.power_profile_op_reload) return false;
    const passive = op == a.power_profile_op_status or op == a.power_profile_op_cpu;
    if (request.expected_service_generation != info.service_generation and !(passive and request.expected_service_generation == 0)) return false;
    if ((!passive and request.expected_revision != info.revision) or (passive and request.expected_revision != 0)) return false;
    if (op == a.power_profile_op_cpu) return request.cpu_index < info.configured_cpus and request.profile == 0 and request.flags == 0;
    if (request.cpu_index != 0) return false;
    if (op == a.power_profile_op_select) return request.profile <= a.power_profile_saving and request.flags & ~@as(u32, a.power_profile_request_flag_sticky_enable) == 0 and !(request.profile == a.power_profile_firmware and request.flags != 0);
    return request.profile == 0 and request.flags == 0;
}
