const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const SwaggerConverter = @import("../generators/converters/swagger_converter.zig").SwaggerConverter;
const UnifiedApiGenerator = @import("../generators/unified/api_generator.zig").UnifiedApiGenerator;

// Swagger 2.0 gives a non-body array parameter its element type in `items`,
// on the parameter itself rather than in a schema. Forgejo has ten of them:
// `status-types` on its notification listings, `labels` on its pull request
// listing, and others.
const spec_with_array_parameters =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Arrays", "version": "1.0.0" },
    \\  "paths": {
    \\    "/notifications": {
    \\      "get": {
    \\        "operationId": "notifyGetList",
    \\        "parameters": [
    \\          { "name": "status-types", "in": "query", "type": "array",
    \\            "items": { "type": "string" }, "collectionFormat": "multi" },
    \\          { "name": "labels", "in": "query", "type": "array",
    \\            "items": { "type": "integer", "format": "int64" }, "collectionFormat": "multi" },
    \\          { "name": "matrix", "in": "query", "type": "array",
    \\            "items": { "type": "array", "items": { "type": "boolean" } } }
    \\        ],
    \\        "responses": { "204": { "description": "empty" } }
    \\      }
    \\    }
    \\  }
    \\}
;

fn generate(allocator: std.mem.Allocator, parameters_as_struct: bool) ![]const u8 {
    var parsed = try models.SwaggerDocument.parseFromJson(allocator, spec_with_array_parameters);
    defer parsed.deinit(allocator);
    var converter = SwaggerConverter.init(allocator);
    var unified = try converter.convert(parsed);
    defer unified.deinit(allocator);

    var generator = UnifiedApiGenerator.init(allocator, .{
        .input_path = "fixture.json",
        .parameters_as_struct = parameters_as_struct,
    });
    defer generator.deinit();
    return generator.generate(unified);
}

test "an array parameter is a slice of its items' type" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, true);
    defer allocator.free(code);

    try testing.expect(std.mem.indexOf(u8, code, "@\"status-types\": ?[]const []const u8 = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "labels: ?[]const i64 = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "matrix: ?[]const []const bool = null,") != null);
    try testing.expect(std.mem.indexOf(u8, code, "std.json.Value = null,") == null);
}

test "an array parameter is typed by its items as a plain argument too" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generate(allocator, false);
    defer allocator.free(code);

    try testing.expect(std.mem.indexOf(u8, code, "labels: ?[]const i64") != null);
    try testing.expect(std.mem.indexOf(u8, code, "[]const std.json.Value") == null);
}
