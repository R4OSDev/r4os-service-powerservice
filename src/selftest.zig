// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Explicit small contract/configuration probe. It never selects a profile,
//! activates a backend, captures sensors or submits a hardware parameter write.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const config = @import("config.zig");
const protocol = @import("protocol.zig");
const timeout: r4os.app_services.Timeout = .{ .kind = a.timeout_kind_finite, .nanoseconds = 2_000_000_000 };
pub fn run(sys: r4os.r4sys.Context) i32 {
    var checks: u32 = 0;
    const valid = config.parse("\xef\xbb\xbf# settings\nR4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=balanced\n");
    if (valid.rc != 0 or valid.profile != a.power_profile_balanced) return fail(sys, "valid-config");
    checks += 1;
    for ([_][]const u8{
        "R4S_FORMAT=2\nSCHEMA=POWER\nPROFILE=firmware\n",
        "R4S_FORMAT=1\nSCHEMA=OTHER\nPROFILE=firmware\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=firmware\nPROFILE=saving\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=unknown\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=balanced\nENABLE=yes\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=balanced\nmalformed\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\nPROFILE=balanced\n\xff\n",
        "R4S_FORMAT=1\nSCHEMA=POWER\n",
    }) |bytes| {
        if (config.parse(bytes).rc == 0) return fail(sys, "bad-config");
        checks += 1;
    }
    var client = switch (r4os.power_profiles.Client.open(sys, timeout)) {
        .client => |value| value,
        .failure => return fail(sys, "open"),
    };
    const before = client.info;
    if (!r4os.power_profiles.valid(before)) return fail(sys, "status");
    checks += 1;
    const services: r4os.app_services.Services = .{ .sys = sys };
    var peer = switch (services.open("POWERSVC")) {
        .connection => |value| value,
        .failure => return fail(sys, "raw-open"),
    };
    defer _ = peer.close();
    const base: a.PowerProfileRequest = .{ .expected_service_generation = before.service_generation, .expected_revision = before.revision, .profile = a.power_profile_balanced };
    for (0..9) |case| {
        var request = base;
        switch (case) {
            0 => request.expected_service_generation ^= @as(u64, 1) << 63,
            1 => request.expected_revision ^= @as(u64, 1) << 63,
            2 => request.size -= 1,
            3 => request.version = 2,
            4 => request.reserved3 = 1,
            5 => request.flags = 4,
            6 => request.profile = 4,
            7 => request.cpu_index = 1,
            8 => {
                request.profile = 0;
                request.flags = a.power_profile_request_flag_sticky_enable;
            },
            else => unreachable,
        }
        if (protocol.validRequest(request, a.power_profile_op_select, before)) return fail(sys, "local-invalid");
        switch (peer.callTyped(a.PowerProfileRequest, a.PowerProfileInfo, a.power_profile_op_select, &request, timeout)) {
            .remote_failure => |rc| {
                if (rc != a.service_api_result_invalid) return fail(sys, "invalid-code");
            },
            else => return fail(sys, "invalid-accepted"),
        }
        checks += 1;
    }
    var completed = before;
    switch (client.status(timeout)) {
        .value => |after| {
            if (after.service_generation != before.service_generation or after.revision != before.revision or after.selected_profile != before.selected_profile or
                after.config_revision != before.config_revision or after.owned_mask != before.owned_mask or after.applied_mask != before.applied_mask) return fail(sys, "invalid-side-effect");
            completed = after;
        },
        else => return fail(sys, "after-status"),
    }
    checks += 1;
    for (0..before.configured_cpus) |cpu| switch (client.cpu(@intCast(cpu), timeout)) {
        .value => |value| {
            if (value.cpu_index != cpu or value.service_generation != before.service_generation) return fail(sys, "cpu-identity");
            if (before.selected_profile != a.power_profile_firmware and before.state == a.power_profile_state_unsupported and
                before.provider_generation != 0 and before.online_cpus == before.configured_cpus and before.last_error == 0 and
                (completed.worker_count != 0 or value.provider_generation != before.provider_generation or value.last_error != 0 or
                    value.worker_state != a.power_profile_worker_complete or value.lease != 0 or value.applied_revision != 0 or
                    value.flags & (a.power_profile_cpu_flag_owned | a.power_profile_cpu_flag_confirmed) != 0)) return fail(sys, "cpu-completion-receipt");
            checks += 1;
        },
        else => return fail(sys, "cpu-reply"),
    };
    sys.write("POWERSVC selftest PASS checks=");
    sys.printU64(checks);
    sys.println(" config/IPC/generation; no profile or hardware writes");
    return 0;
}
fn fail(sys: r4os.r4sys.Context, reason: []const u8) i32 {
    sys.write("POWERSVC selftest FAIL ");
    sys.println(reason);
    return 1;
}
