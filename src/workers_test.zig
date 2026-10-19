const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Cell = @import("workers.zig").Cell;
var table: a.R4XStartR4Sys = .{};
var raw: a.R4XStartContext = .{};
var bundle: r4os.program.Bundle = .{ .raw = &raw };
var timeout = true;
var calls: u32 = 0;
var captured_entry: ?a.ThreadEntryFn = null;
var captured_arg: u64 = 0;
fn create(entry: a.ThreadEntryFn, arg: u64, reserve: u64, flags: u32, out: *a.ProgramJoinHandle) callconv(.c) i32 {
    std.debug.assert(reserve == 256 * 1024 and flags == a.thread_create_flag_compute_worker);
    captured_entry = entry;
    captured_arg = arg;
    out.* = .{ .thread_id = 19, .thread_generation = 0x12345678_abcd4321 };
    return 0;
}
fn placement(_: *const a.ProgramJoinHandle, _: *const a.ThreadPlacementRequest, cpus: ?[*]const u64, count: u32) callconv(.c) i32 {
    std.debug.assert(count == 1 and cpus.?[0] == 4);
    return a.thread_error_busy;
}
fn join(handle: *const a.ProgramJoinHandle, budget: u64, out: *i32) callconv(.c) i32 {
    std.debug.assert(handle.thread_id == 19 and handle.thread_generation == 0x12345678_abcd4321 and budget == 7);
    calls += 1;
    if (timeout) return a.thread_error_timeout;
    out.* = 0;
    return 0;
}
fn context() r4os.r4sys.Context {
    table = .{};
    table.thread_handle_join = @intFromPtr(&join);
    bundle = .{ .raw = &raw, .sys = &table };
    return r4os.r4sys.Context.init(&bundle);
}
test "join timeout retains exact task handle and published hardware state; only actual join consumes the handle" {
    var cell: Cell = .{ .sys = context(), .live = true, .handle = .{ .thread_id = 19, .thread_generation = 0x12345678_abcd4321 }, .published = .{ .cpu_index = 2, .cpu_epoch = 7, .service_generation = 99 } };
    timeout = true;
    calls = 0;
    const before = cell.handle;
    try std.testing.expect(!cell.join(7));
    try std.testing.expect(cell.live);
    try std.testing.expectEqualDeep(before, cell.handle);
    cell.requestReturn();
    try std.testing.expect(cell.stop.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), cell.returns.load(.acquire));
    timeout = false;
    try std.testing.expect(cell.join(7));
    try std.testing.expect(!cell.live);
    try std.testing.expectEqual(@as(u32, 0), cell.handle.thread_id);
    try std.testing.expectEqual(@as(u32, 2), calls);
}
test "joined unexpected worker exit cannot erase or recycle a live hardware token" {
    var cell: Cell = .{ .sys = context(), .live = true, .handle = .{ .thread_id = 19, .thread_generation = 0x12345678_abcd4321 }, .published = .{ .cpu_index = 2, .cpu_epoch = 7, .provider_generation = 41, .lease = 88, .revision = 5, .applied_revision = 2, .flags = a.power_profile_cpu_flag_owned | a.power_profile_cpu_flag_confirmed } };
    timeout = false;
    try std.testing.expect(cell.join(7));
    const value = cell.snapshot();
    try std.testing.expectEqual(@as(u64, 88), value.lease);
    try std.testing.expectEqual(@as(u64, 41), value.provider_generation);
    try std.testing.expectEqual(a.power_profile_state_retained, value.state);
    try std.testing.expectEqual(@as(u64, 0), value.applied_revision);
    try std.testing.expect(value.flags & a.power_profile_cpu_flag_worker_retained != 0);
    try std.testing.expectEqual(a.thread_error_busy, cell.start(cell.sys, undefined, .{}, 1, 2, false));
}
test "failed hard placement survives the real worker entry stop gate without provider calls and still requires actual join" {
    const sys = context();
    table.thread_create_handle = @intFromPtr(&create);
    table.thread_placement_set = @intFromPtr(&placement);
    var cell: Cell = .{};
    try std.testing.expectEqual(a.thread_error_busy, cell.start(sys, r4os.r4dev.Context.init(&bundle), .{ .cpu_index = 2, .cpu_epoch = 7, .service_generation = 99 }, 1, 2, false));
    try std.testing.expect(cell.live and cell.ready.load(.acquire) and cell.stop.load(.acquire));
    try std.testing.expectEqual(@as(i32, 0), captured_entry.?(captured_arg));
    const view = cell.snapshot();
    try std.testing.expectEqual(a.thread_error_busy, view.last_error);
    try std.testing.expectEqual(@as(u64, 0), view.lease);
    try std.testing.expectEqual(@as(u64, 0), view.provider_generation);
    try std.testing.expect(cell.live and cell.done.load(.acquire));
    timeout = false;
    try std.testing.expect(cell.join(7));
    try std.testing.expect(!cell.live);
}
