const std = @import("std");
const openapi2zig = @import("../lib.zig");
const test_utils = @import("test_utils.zig");

// `--enums` turns a schema's choice list into a Zig enum whose tags are the
// wire values verbatim. The fixture carries the cases that decide the design:
// one enum written twice under the same `x-spec-enum-id` with a different null
// variant each time, a list containing the empty string, a list of integers,
// and values that are not bare identifiers.

fn generate(allocator: std.mem.Allocator, enums: bool) ![]const u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "openapi/v3.0/enums.json",
        allocator,
        .unlimited,
    );
    defer allocator.free(contents);

    var document = try openapi2zig.parseToUnified(allocator, contents);
    defer document.deinit(allocator);

    return try openapi2zig.generateCode(allocator, std.testing.io, document, .{
        .input_path = "openapi/v3.0/enums.json",
        .parameters_as_struct = true,
        .generate_enums = enums,
        .resource_wrappers = .none,
    });
}

test "a choice list becomes an enum whose tags are the wire values" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, true);
    defer allocator.free(code);

    // The union of both spellings of the id, so the tag a filter needs is
    // present on the type a response uses. `null` is a keyword and escapes.
    try std.testing.expect(std.mem.indexOf(u8, code,
        \\pub const PriorityEnum = enum {
        \\    inactive,
        \\    @"null",
        \\    primary,
        \\    secondary,
        \\    tertiary,
        \\};
    ) != null);

    try std.testing.expect(std.mem.indexOf(u8, code, "    priority: ?PriorityEnum = null,") != null);
}

test "values that are not bare identifiers are escaped, not mangled" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, true);
    defer allocator.free(code);

    // Escaping rather than mangling is what lets @tagName be the wire value,
    // which is how the JSON and query round trips come out free.
    try std.testing.expect(std.mem.indexOf(u8, code, "@\"1.6tbase-cr8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "@\"1 (2412 MHz)\"") != null);
}

test "a second enum under the same name gets a distinct type" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, true);
    defer allocator.free(code);

    // Two different ids both written as `priority`; the names cannot collide.
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const PriorityEnum2 = enum {") != null);
}

test "lists that cannot use their values as tags stay strings" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, true);
    defer allocator.free(code);

    // `@""` is not a legal identifier, so a list containing the empty string
    // is left alone rather than given a tag that would need mapping back.
    try std.testing.expect(std.mem.indexOf(u8, code, "    blankable: ?[]const u8 = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "BlankableEnum") == null);

    // A non-string list cannot use its values as tag names either.
    try std.testing.expect(std.mem.indexOf(u8, code, "    weight: ?i64 = null,") != null);
}

test "without the flag nothing changes" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, false);
    defer allocator.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, " = enum {") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "    priority: ?[]const u8 = null,") != null);
}
