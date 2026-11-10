//! The main service Task owns this reusable wait set. Readiness is only a
//! reason to retry the exact join; hardware return remains the Cell's receipt.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const checked = r4os.time_contract.checked;
const Cell = @import("workers.zig").Cell;
pub const Waiter = struct {
    set: ?r4os.wait_set.Set = null,
    registrations: [64]u64 = @splat(0),
    handles: [64]a.ProgramJoinHandle = @splat(.{}),

    pub fn wait(self: *Waiter, sys: *const r4os.r4sys.Context, cells: []Cell, ticks: u64) i32 {
        if (cells.len > self.registrations.len) return a.thread_error_invalid;
        const actual = sys.base.generation2 orelse return a.err_no_group;
        const sample = sys.base.clockSampleChecked() catch |err| return r4os.rpc_budget.code(err);
        const timeout: a.R4Timeout = if (ticks == 0) .{} else if (ticks == a.io_wait_forever) .{ .kind = a.timeout_kind_forever } else .{
            .kind = a.timeout_kind_finite,
            .nanoseconds = checked.scaleCeil(ticks, 1_000_000_000, sample.identity.tick_hz) catch |err| return r4os.rpc_budget.code(err),
        };
        var budget = checked.DeadlineBudget.init(sample, timeout) catch |err| return r4os.rpc_budget.code(err);
        while (true) {
            var live: usize = 0;
            for (cells, 0..) |*cell, index| {
                if (cell.live) _ = cell.join(0);
                const changed = !cell.live or !std.meta.eql(cell.handle, self.handles[index]);
                if (changed and self.registrations[index] != 0) {
                    const rc = self.set.?.remove(self.registrations[index]);
                    if (rc != 0 and rc != a.waitset_error_stale) return rc;
                    self.registrations[index] = 0;
                    self.handles[index] = .{};
                }
                if (cell.live) live += 1;
            }
            if (live == 0) return 0;
            const now = sys.base.clockSampleChecked() catch |err| return r4os.rpc_budget.code(err);
            const remaining = budget.remaining(now) catch |err| return r4os.rpc_budget.code(err);
            if (remaining.kind == 0) return a.thread_error_timeout;
            if (self.set == null) {
                var set: r4os.wait_set.Set = undefined;
                const rc = r4os.wait_set.Set.init(actual, a.waitset_max_sources, &set);
                if (rc != 0) return rc;
                self.set = set;
            }
            var enrolled_count: u32 = 0;
            for (self.registrations) |registration| if (registration != 0) {
                enrolled_count += 1;
            };
            for (cells, 0..) |*cell, index| {
                if (!cell.live or self.registrations[index] != 0) continue;
                // One native set has32 sources. Poll all64 exact Cells on
                // every wake and refill this window; this is not a CPU cap.
                if (enrolled_count == a.waitset_max_sources) break;
                var source: a.WaitSource = .{};
                const prepared = r4os.wait_set.prepare(actual, r4os.wait_set.thread(cell.handle, index), &source);
                if (prepared != 0) {
                    if (cell.join(0)) continue;
                    return prepared;
                }
                var registration: u64 = 0;
                const enrolled = self.set.?.enroll(source, &registration);
                if (enrolled != 0) {
                    if (cell.join(0)) continue;
                    return enrolled;
                }
                self.handles[index] = cell.handle;
                self.registrations[index] = registration;
                enrolled_count += 1;
            }
            var still_live = false;
            for (cells) |cell| still_live = still_live or cell.live;
            if (!still_live) continue;
            var events: [a.waitset_max_sources]a.WaitSetEvent = undefined;
            var batch: a.WaitSetBatch = .{};
            const limit = r4os.wait_set.deadline(budget) catch |err| return r4os.rpc_budget.code(err);
            const waited = self.set.?.wait(limit, &events, &batch);
            if (waited < 0) return waited;
            // No event grants permission to release a Cell or hardware lease.
        }
    }
    pub fn close(self: *Waiter) i32 {
        if (self.set) |*set| {
            const rc = set.close();
            if (set.handle != 0) return rc;
            self.set = null;
            self.registrations = @splat(0);
            self.handles = @splat(.{});
        }
        return 0;
    }
};
