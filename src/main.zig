// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const a = r4os.abi;
const config = @import("config.zig");
const workers = @import("workers.zig");
const name = "POWERSVC";
const State = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    endpoint: u32 = 0,
    info: a.PowerProfileInfo = .{},
    quiesced: bool = false,
    cells: [64]workers.Cell = [_]workers.Cell{.{}} ** 64,

    fn collect(self: *State) void {
        var capacity: a.CpuCapacity = .{};
        if (self.sys.cpuCapacity(&capacity) == 0) self.info.online_cpus = capacity.available_cpus;
        self.info.owned_mask = 0;
        self.info.applied_mask = 0;
        self.info.pending_mask = 0;
        self.info.supported_mask = 0;
        self.info.worker_count = 0;
        self.info.sticky_count = 0;
        self.info.backend_cpus = 0;
        self.info.last_error = 0;
        self.info.last_cpu = a.cpu_power_cpu_none;
        self.info.flags = if (self.info.config_error == 0) a.power_profile_flag_config_valid else 0;
        var provider: a.CpuPowerInfo = .{};
        var boot_cpu: a.CpuCapabilitiesInfo = .{};
        if (self.dev.cpuCapabilities(0, &boot_cpu) == 0 and self.dev.cpuPowerInfo(0, boot_cpu.epoch, &provider) == 0 and provider.provider_generation != 0) {
            self.info.provider_generation = provider.provider_generation;
            self.info.flags |= a.power_profile_flag_provider;
        } else self.info.provider_generation = 0;
        for (self.cells[0..self.info.configured_cpus], 0..) |*cell, cpu| {
            if (cell.live and cell.done.load(.acquire)) _ = cell.join(0);
            const snapshot = cell.scoped();
            const value = snapshot.view;
            var cap: a.CpuCapabilitiesInfo = .{};
            const online = self.dev.cpuCapabilities(@intCast(cpu), &cap) == 0 and cap.flags & a.cpu_capabilities_flag_schedulable != 0;
            const bit = @as(u64, 1) << @as(u6, @intCast(cpu));
            const scope = if (value.backend >= a.power_profile_backend_acpi_cppc and snapshot.mask != 0) snapshot.mask else bit;
            if (cell.live) self.info.worker_count += 1;
            if (value.flags & a.power_profile_cpu_flag_owned != 0) self.info.owned_mask |= scope;
            if (value.flags & a.power_profile_cpu_flag_confirmed != 0 and value.applied_revision == self.info.revision) self.info.applied_mask |= scope;
            if ((cell.live and (self.quiesced or value.worker_state == a.power_profile_worker_held or value.worker_state == a.power_profile_worker_starting)) or
                ((self.quiesced or value.state == a.power_profile_state_retained) and value.flags & a.power_profile_cpu_flag_owned != 0)) self.info.pending_mask |= scope;
            if (online and value.backend != a.power_profile_backend_none and (value.valid_mask & a.power_profile_cpu_valid_range != 0 or value.state == a.power_profile_state_disabled)) {
                self.info.supported_mask |= scope;
            }
            if (value.flags & a.power_profile_cpu_flag_sticky_enabled != 0) self.info.sticky_count += 1;
            if (value.last_error != 0) {
                self.info.last_error = value.last_error;
                self.info.last_cpu = @intCast(cpu);
            }
        }
        self.info.backend_cpus = @popCount(self.info.supported_mask);
        if (self.info.sticky_count != 0) self.info.flags |= a.power_profile_flag_sticky_enabled;
        self.info.applied_revision = 0;
        if (self.info.pending_mask != 0) {
            self.info.flags |= a.power_profile_flag_pending_return;
            self.info.state = a.power_profile_state_retained;
        } else if (self.quiesced) {
            self.info.flags |= a.power_profile_flag_quiesced;
            self.info.state = a.power_profile_state_quiesced;
        } else if (self.info.selected_profile == a.power_profile_firmware) {
            self.info.state = a.power_profile_state_firmware;
        } else if (self.info.applied_mask != 0 and @popCount(self.info.applied_mask) == self.info.online_cpus) {
            self.info.flags |= a.power_profile_flag_applied_complete;
            self.info.applied_revision = self.info.revision;
            self.info.state = a.power_profile_state_applied;
        } else self.info.state = if (self.info.applied_mask != 0) a.power_profile_state_partial else if (self.info.backend_cpus != 0) a.power_profile_state_disabled else a.power_profile_state_unsupported;
    }
    fn returnWorkers(self: *State, budget: u64) bool {
        self.quiesced = true;
        for (self.cells[0..self.info.configured_cpus]) |*cell| cell.requestReturn();
        const start = self.sys.ticks();
        for (self.cells[0..self.info.configured_cpus]) |*cell| {
            const elapsed = self.sys.ticks() -| start;
            _ = cell.join(budget -| elapsed);
        }
        self.collect();
        return self.info.worker_count == 0 and self.info.owned_mask == 0 and self.info.pending_mask == 0;
    }
    fn startWorkers(self: *State, sticky: bool) void {
        self.collect();
        if (self.info.worker_count != 0 or self.info.owned_mask != 0 or self.info.pending_mask != 0) return;
        self.quiesced = false;
        for (self.cells[0..self.info.configured_cpus], 0..) |*cell, cpu| {
            var cap: a.CpuCapabilitiesInfo = .{};
            const online = self.dev.cpuCapabilities(@intCast(cpu), &cap) == 0 and cap.flags & a.cpu_capabilities_flag_schedulable != 0;
            const initial: a.PowerCpuProfileInfo = .{ .cpu_index = @intCast(cpu), .cpu_epoch = cap.epoch, .service_generation = self.info.service_generation, .profile = self.info.selected_profile, .state = if (self.info.selected_profile == a.power_profile_firmware) a.power_profile_state_firmware else a.power_profile_state_unsupported };
            if (!online or self.info.selected_profile == a.power_profile_firmware) {
                cell.published = initial;
                continue;
            }
            _ = cell.start(self.sys, self.dev, initial, self.info.selected_profile, self.info.revision, sticky);
        }
        const deadline = self.sys.ticks() +| self.sys.ticksFromMilliseconds(1500);
        while (true) {
            var starting = false;
            for (self.cells[0..self.info.configured_cpus]) |*cell| if (cell.live and cell.snapshot().worker_state == a.power_profile_worker_starting) {
                starting = true;
                break;
            };
            if (!starting or self.sys.ticks() >= deadline or self.sys.programShouldClose()) break;
            self.sys.sleepTicks(1);
        }
        self.collect();
    }
};
var storage: State = undefined;

pub fn r4_app_main(app: *r4os.App) i32 {
    if (!r4std.init(app.startContext())) return a.err_no_group;
    const sys = app.system();
    const args = std.mem.trim(u8, std.mem.span(sys.argsRaw()), " \t\r\n");
    if (std.ascii.eqlIgnoreCase(args, "/SELFTEST")) return @import("selftest.zig").run(sys);
    if (args.len != 0 and !std.ascii.eqlIgnoreCase(args, "/RUN")) return a.service_api_result_invalid;
    const dev = app.devicesLowLevel() orelse return a.err_no_group;
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != 0 or capacity.configured_cpus == 0 or capacity.configured_cpus > 64) return a.service_api_result_invalid;
    const id = std.math.cast(u32, app.startContext().instance_id) orelse return a.service_api_result_invalid;
    var own: a.ProgramProcessHandle = .{};
    if (sys.programOpenHandle(id, &own) != 0 or own.generation == 0) return a.service_api_result_invalid;
    storage = .{ .sys = sys, .dev = dev, .info = .{ .service_generation = own.generation, .service_instance_id = id, .revision = 1, .configured_cpus = capacity.configured_cpus, .online_cpus = capacity.available_cpus, .config_revision = 1 } };
    const state = &storage;
    const loaded = config.load(&sys);
    state.info.config_error = loaded.rc;
    state.info.selected_profile = loaded.profile;
    var endpoint: a.ServiceInfo = .{};
    var attempts: u32 = 0;
    while (attempts < 100 and !sys.programShouldClose()) : (attempts += 1) {
        if (sys.serviceEndpointRegister(name, 0, &endpoint) == 0 and endpoint.handle != 0) break;
        sys.sleepTicks(1);
    }
    if (endpoint.handle == 0) return a.service_api_result_no_endpoint;
    state.endpoint = endpoint.handle;
    state.startWorkers(false);
    var loop = r4os.ServiceLoop.init(sys, endpoint.handle, .{});
    var result: i32 = 0;
    while (true) {
        state.collect();
        const deadline: ?u64 = if (state.info.worker_count != 0) sys.ticks() +| sys.ticksFromMilliseconds(500) else null;
        switch (loop.wait(deadline)) {
            .requests => |pending| {
                const rc = loop.drain(pending, handleRequest, .{state});
                if (rc < 0) {
                    result = rc;
                    break;
                }
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |rc| {
                result = rc;
                break;
            },
        }
    }
    _ = sys.serviceEndpointUnregister(endpoint.handle);
    // Stop is real process exit only after same-CPU hardware return and join.
    // Failure keeps the original service instance and all worker storage alive.
    _ = state.returnWorkers(sys.ticksFromMilliseconds(2000));
    while (state.info.worker_count != 0 or state.info.owned_mask != 0 or state.info.pending_mask != 0) {
        state.collect();
        sys.sleepTicks(@max(@as(u64, 1), sys.ticksFromMilliseconds(50)));
    }
    loop.report(name);
    sys.println("POWERSVC stopped: own CPU requests returned and workers joined");
    return result;
}
fn reply(state: *State, request_id: u32, code: i32, bytes: []const u8) i32 {
    return r4os.app_services.replyIfPending(state.sys, state.endpoint, request_id, code, bytes);
}
fn handleRequest(state: *State) i32 {
    var header: a.ServiceMessageHeader = .{};
    var bytes: [a.service_api_max_payload]u8 = undefined;
    const count = state.sys.serviceEndpointRecv(state.endpoint, &header, &bytes);
    if (count < 0) return count;
    if (count == 0 and header.magic != a.service_api_magic) return 0;
    var request: a.PowerProfileRequest = .{};
    if (count != @sizeOf(a.PowerProfileRequest)) return reply(state, header.request_id, a.service_api_result_invalid, "");
    @memcpy(std.mem.asBytes(&request), bytes[0..@sizeOf(a.PowerProfileRequest)]);
    if (!@import("protocol.zig").validRequest(request, header.op, state.info)) return reply(state, header.request_id, a.service_api_result_invalid, "");
    if (header.op == a.power_profile_op_cpu) {
        state.collect();
        const view = state.cells[request.cpu_index].snapshot();
        return reply(state, header.request_id, 0, std.mem.asBytes(&view));
    }
    if (header.op != a.power_profile_op_status) {
        if (state.info.revision == std.math.maxInt(u64) and header.op != a.power_profile_op_quiesce) return reply(state, header.request_id, a.service_api_result_invalid, "");
        var profile = state.info.selected_profile;
        if (header.op == a.power_profile_op_reload) {
            const loaded = config.load(&state.sys);
            state.info.config_error = loaded.rc;
            if (loaded.rc != 0) {
                state.collect();
                return reply(state, header.request_id, 0, std.mem.asBytes(&state.info));
            }
            profile = loaded.profile;
        } else if (header.op == a.power_profile_op_select) {
            const rc = config.save(&state.sys, request.profile);
            state.info.config_error = rc;
            if (rc < 0) {
                state.collect();
                return reply(state, header.request_id, 0, std.mem.asBytes(&state.info));
            }
            profile = request.profile;
        }
        if (state.info.revision != std.math.maxInt(u64)) state.info.revision += 1;
        state.info.selected_profile = profile;
        if (header.op == a.power_profile_op_select or header.op == a.power_profile_op_reload) state.info.config_revision +|= 1;
        const returned = state.returnWorkers(state.sys.ticksFromMilliseconds(1500));
        if (header.op != a.power_profile_op_quiesce and returned) state.startWorkers(request.flags & a.power_profile_request_flag_sticky_enable != 0);
    }
    state.collect();
    return reply(state, header.request_id, 0, std.mem.asBytes(&state.info));
}
