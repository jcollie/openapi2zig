const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const OpenApiConverter = @import("../generators/converters/openapi_converter.zig").OpenApiConverter;
const UnifiedModelGenerator = @import("../generators/unified/model_generator.zig").UnifiedModelGenerator;

// A definition with a field of its own type. Forgejo's `Repository` has a
// `parent` that is another `Repository`, and generated as a plain field it is
// a struct that contains itself, which Zig rejects outright.
const spec_with_self_reference =
    \\{
    \\  "openapi": "3.0.0",
    \\  "info": { "title": "Recursion", "version": "1.0.0" },
    \\  "paths": {},
    \\  "components": {
    \\    "schemas": {
    \\      "Repository": {
    \\        "type": "object",
    \\        "properties": {
    \\          "name": { "type": "string" },
    \\          "parent": { "$ref": "#/components/schemas/Repository" },
    \\          "forks": {
    \\            "type": "array",
    \\            "items": { "$ref": "#/components/schemas/Repository" }
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

// The cycle is longer than one hop: a category holds a directory, which holds
// the category back. Either field would do to break it; the one reached first
// takes the pointer.
const spec_with_indirect_cycle =
    \\{
    \\  "openapi": "3.0.0",
    \\  "info": { "title": "Recursion", "version": "1.0.0" },
    \\  "paths": {},
    \\  "components": {
    \\    "schemas": {
    \\      "Category": {
    \\        "type": "object",
    \\        "properties": {
    \\          "directory": { "$ref": "#/components/schemas/Directory" }
    \\        }
    \\      },
    \\      "Directory": {
    \\        "type": "object",
    \\        "properties": {
    \\          "category": { "$ref": "#/components/schemas/Category" }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

// Two definitions referring to a third. Nothing here is recursive, and adding
// indirection to these would only make them harder to use.
const spec_without_recursion =
    \\{
    \\  "openapi": "3.0.0",
    \\  "info": { "title": "Recursion", "version": "1.0.0" },
    \\  "paths": {},
    \\  "components": {
    \\    "schemas": {
    \\      "Issue": {
    \\        "type": "object",
    \\        "properties": {
    \\          "user": { "$ref": "#/components/schemas/User" },
    \\          "assignee": { "$ref": "#/components/schemas/User" }
    \\        }
    \\      },
    \\      "User": {
    \\        "type": "object",
    \\        "properties": { "login": { "type": "string" } }
    \\      }
    \\    }
    \\  }
    \\}
;

fn generateModels(allocator: std.mem.Allocator, spec: []const u8) ![]const u8 {
    var parsed = try models.OpenApiDocument.parseFromJson(allocator, spec);
    defer parsed.deinit(allocator);
    var converter = OpenApiConverter.init(allocator);
    var unified = try converter.convert(parsed);
    defer unified.deinit(allocator);

    var generator = UnifiedModelGenerator.init(allocator);
    defer generator.deinit();
    return generator.generate(unified);
}

test "a field of the type it is declared in is generated behind a pointer" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateModels(allocator, spec_with_self_reference);
    defer allocator.free(code);

    try testing.expect(std.mem.indexOf(u8, code, "parent: ?*const Repository = null,") != null);
    // A slice already holds its elements out of line, so an array of the same
    // type needs no pointer and should not grow one.
    try testing.expect(std.mem.indexOf(u8, code, "forks: ?[]const Repository = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "name: ?[]const u8 = null,") != null);
}

test "a cycle through another definition is broken too" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateModels(allocator, spec_with_indirect_cycle);
    defer allocator.free(code);

    // Whichever way round the two are emitted, at least one of the two fields
    // has to be a pointer or neither struct has a size.
    const category_indirect = std.mem.indexOf(u8, code, "directory: ?*const Directory = null,") != null;
    const directory_indirect = std.mem.indexOf(u8, code, "category: ?*const Category = null,") != null;
    try testing.expect(category_indirect or directory_indirect);
}

test "definitions that are not recursive keep their fields by value" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateModels(allocator, spec_without_recursion);
    defer allocator.free(code);

    try testing.expect(std.mem.indexOf(u8, code, "user: ?User = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "assignee: ?User = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "*const") == null);
}
