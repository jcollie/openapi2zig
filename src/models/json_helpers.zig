const std = @import("std");
const json = std.json;

pub fn optionalFloat(value: ?json.Value) ?f64 {
    const val = value orelse return null;
    return switch (val) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Copy a JSON scalar so it outlives the parse tree it came from. Only the two
/// variants that borrow need copying; the rest are plain values, and the
/// container variants never reach this because a schema's `enum` is a list of
/// scalars.
pub fn cloneScalar(allocator: std.mem.Allocator, value: json.Value) !json.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        else => value,
    };
}

pub fn deinitScalar(allocator: std.mem.Allocator, value: json.Value) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .number_string => |text| allocator.free(text),
        else => {},
    }
}

test "cloneScalar copies the bytes of a string" {
    const original = "choice";
    var buffer: [6]u8 = "choice".*;
    const cloned = try cloneScalar(std.testing.allocator, .{ .string = &buffer });
    defer deinitScalar(std.testing.allocator, cloned);
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings(original, cloned.string);
}
