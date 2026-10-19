// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
//! Worker frames are resident until an actual handle join. The start gate
//! prevents provider calls before the exact hard CPU placement is installed.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const control = @import("controller.zig");
const backend = @import("backend.zig");
pub const Cell = struct {
    pub const Scoped = struct { view: a.PowerCpuProfileInfo, mask: u64 };
    lock: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    returns: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    handle: a.ProgramJoinHandle = .{},
    live: bool = false,
    sys: r4os.r4sys.Context = undefined,
    dev: r4os.r4dev.Context = undefined,
    initial: a.PowerCpuProfileInfo = .{},
    published: a.PowerCpuProfileInfo = .{},
    published_scope: u64 = 0,
    profile: u32 = 0,
    revision: u64 = 0,
    sticky: bool = false,
    start_error: i32 = 0,

    fn acquire(self: *Cell) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn publish(self: *Cell, view: a.PowerCpuProfileInfo) void {
        self.acquire();
        self.published = view;
        self.lock.store(false, .release);
    }
    pub fn snapshot(self: *Cell) a.PowerCpuProfileInfo {
        self.acquire();
        const value = self.published;
        self.lock.store(false, .release);
        return value;
    }
    pub fn scoped(self: *Cell) Scoped {
        self.acquire();
        const value: Scoped = .{ .view = self.published, .mask = self.published_scope };
        self.lock.store(false, .release);
        return value;
    }
    fn publishController(self: *Cell, controller: *const control.Controller) void {
        self.acquire();
        self.published = controller.view;
        self.published_scope = controller.scope_mask;
        self.lock.store(false, .release);
    }
    pub fn start(self: *Cell, sys: r4os.r4sys.Context, dev: r4os.r4dev.Context, initial: a.PowerCpuProfileInfo, profile: u32, revision: u64, sticky: bool) i32 {
        if (self.live or self.published.flags & a.power_profile_cpu_flag_owned != 0) return a.thread_error_busy;
        self.* = .{ .sys = sys, .dev = dev, .initial = initial, .published = initial, .profile = profile, .revision = revision, .sticky = sticky };
        self.published.worker_state = a.power_profile_worker_starting;
        // Kernel owner admission independently keeps64KiB resident below
        // live frames. Use the same256KiB reserve as the CPUPOWER probes.
        const rc = sys.computeWorkerCreate(entry, @intFromPtr(self), 256 * 1024, &self.handle);
        if (rc != 0) {
            self.published.last_error = rc;
            self.published.worker_state = a.power_profile_worker_absent;
            return rc;
        }
        self.live = true;
        const mask = [_]u64{@as(u64, 1) << @as(u6, @intCast(initial.cpu_index))};
        const request: a.ThreadPlacementRequest = .{};
        const placed = sys.threadPlacementSet(&self.handle, &request, &mask);
        if (placed != 0) {
            self.start_error = placed;
            self.published.last_error = placed;
            self.requestReturn();
        }
        self.ready.store(true, .release);
        return placed;
    }
    pub fn requestReturn(self: *Cell) void {
        if (!self.live) return;
        const sequence = self.returns.load(.acquire);
        // Exhaustion still closes work; an earlier return attempt remains
        // observable. A new profile must never recycle a live worker frame.
        if (sequence != std.math.maxInt(u64)) self.returns.store(sequence + 1, .release);
        self.stop.store(true, .release);
    }
    pub fn join(self: *Cell, budget: u64) bool {
        if (!self.live) return true;
        var code: i32 = 0;
        if (self.sys.threadHandleJoin(&self.handle, budget, &code) != 0) return false;
        self.live = false;
        self.handle = .{};
        var value = self.snapshot();
        value.worker_state = a.power_profile_worker_complete;
        if (value.flags & a.power_profile_cpu_flag_owned != 0) {
            // An unexpected task exit is a join receipt, not a hardware return.
            // Keep the exact provider token and frame; do not recycle it.
            value.state = a.power_profile_state_retained;
            value.applied_revision = 0;
            value.flags &= ~@as(u32, a.power_profile_cpu_flag_confirmed);
            value.flags |= a.power_profile_cpu_flag_worker_retained;
            value.last_error = if (code != 0) code else a.cpu_capabilities_error_busy;
        } else value.flags &= ~@as(u32, a.power_profile_cpu_flag_worker_retained);
        self.publish(value);
        return true;
    }
};
fn entry(arg: u64) callconv(.c) i32 {
    const cell: *Cell = @ptrFromInt(arg);
    while (!cell.ready.load(.acquire)) cell.sys.sleepTicks(1);
    var controller = control.Controller.init(cell.initial.cpu_index, cell.initial.cpu_epoch, cell.initial.service_generation);
    controller.view.last_error = cell.start_error;
    var io: backend.Io = .{ .dev = cell.dev };
    if (!cell.stop.load(.acquire) and !cell.sys.programShouldClose()) {
        var current: a.ProgramJoinHandle = .{};
        var placement: a.ThreadPlacementInfo = .{};
        const rc = cell.sys.threadCurrentHandle(&current);
        if (rc != 0 or cell.sys.threadPlacementGet(&current, &placement, &.{}) != 0 or
            placement.running_cpu != cell.initial.cpu_index or placement.request_revision != placement.applied_revision)
        {
            controller.view.last_error = a.cpu_capabilities_error_context;
        } else {
            controller.select(&io, cell.profile, cell.revision, cell.sticky);
        }
    }
    var last_return: u64 = 0;
    var close_seen = false;
    const refresh_ticks = @max(@as(u64, 1), cell.sys.ticksFromMilliseconds(500));
    var refresh_at = cell.sys.ticks() +| refresh_ticks;
    while (true) {
        const sequence = cell.returns.load(.acquire);
        const closing = cell.sys.programShouldClose();
        const stop = cell.stop.load(.acquire) or closing;
        if ((sequence != last_return or (closing and !close_seen)) and stop) {
            last_return = sequence;
            close_seen = closing;
            controller.release(&io);
        }
        if (!controller.owns()) {
            controller.view.worker_state = a.power_profile_worker_complete;
            cell.publishController(&controller);
            cell.done.store(true, .release);
            return 0;
        }
        if (stop or controller.view.state == a.power_profile_state_retained) {
            controller.view.worker_state = a.power_profile_worker_held;
            controller.view.flags |= a.power_profile_cpu_flag_worker_retained;
        } else {
            controller.view.worker_state = a.power_profile_worker_active;
            if (cell.sys.ticks() >= refresh_at) {
                _ = controller.refresh(&io);
                refresh_at = cell.sys.ticks() +| refresh_ticks;
            }
        }
        cell.publishController(&controller);
        // An explicit new return command can retry. A retained worker never
        // repeats parameter writes or discards a failed return automatically.
        cell.sys.sleepTicks(@max(@as(u64, 1), cell.sys.ticksFromMilliseconds(20)));
    }
}
