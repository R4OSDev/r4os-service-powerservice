// Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const r4std = @import("r4std");
const r4os = @import("r4os");
const policy = @import("policy.zig");
const a = r4os.abi;
pub const path = "C:\\R4OS\\CONFIG\\POWER.R4S";
pub const Loaded = struct { profile: u32 = a.power_profile_firmware, rc: i32 = 0 };
pub fn parse(bytes: []const u8) Loaded {
    _ = r4std.settings.parseDocumentText(bytes) catch return .{ .rc = a.service_api_result_invalid };
    const document = r4std.settings.Document.init(bytes);
    if (!document.hasSupportedFormat() or !std.mem.eql(u8, document.schemaName() orelse "", "POWER")) return .{ .rc = a.service_api_result_invalid };
    var seen: u8 = 0;
    var profile: ?u32 = null;
    const text = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = r4std.settings.trim(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const entry = r4std.settings.parseLine(line) orelse return .{ .rc = a.service_api_result_invalid };
        const index: u3 = if (r4std.settings.equalsKey(entry.key, "R4S_FORMAT")) 0 else if (r4std.settings.equalsKey(entry.key, "SCHEMA")) 1 else if (r4std.settings.equalsKey(entry.key, "PROFILE")) 2 else return .{ .rc = a.service_api_result_invalid };
        const bit = @as(u8, 1) << index;
        if (seen & bit != 0) return .{ .rc = a.service_api_result_invalid };
        seen |= bit;
        if (index == 2) {
            for (0..4) |candidate| if (std.ascii.eqlIgnoreCase(entry.value, policy.name(@intCast(candidate)))) {
                profile = @intCast(candidate);
                break;
            };
        }
    }
    if (seen != 7 or profile == null) return .{ .rc = a.service_api_result_invalid };
    return .{ .profile = profile.? };
}
pub fn load(sys: *const r4os.r4sys.Context) Loaded {
    const recovered = r4std.config.recoverDocumentSave(sys, path);
    if (recovered < 0 or r4std.config.hasDocumentSaveLeftovers(sys, path)) return .{ .rc = if (recovered < 0) recovered else a.service_api_result_invalid };
    var bytes: [1024]u8 = undefined;
    const count = sys.fileRead(path, &bytes);
    if (count <= 0 or count >= bytes.len) return .{ .rc = a.service_api_result_invalid };
    return parse(bytes[0..@intCast(count)]);
}
pub fn save(sys: *const r4os.r4sys.Context, profile: u32) i32 {
    if (profile > a.power_profile_saving) return a.service_api_result_invalid;
    var bytes: [256]u8 = undefined;
    var writer = r4std.settings.Writer.init(&bytes);
    writer.writeHeader("POWER");
    writer.writePair("PROFILE", policy.name(profile));
    if (!writer.ok()) return a.service_api_result_invalid;
    const result = r4std.config.saveDocument(sys, path, writer.bytes());
    // R4STD also returns positive created/recovered success receipts.
    return if (r4std.config.ok(result)) 0 else result;
}
