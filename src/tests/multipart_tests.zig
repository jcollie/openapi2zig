const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const cli = @import("../cli.zig");
const SwaggerConverter = @import("../generators/converters/swagger_converter.zig").SwaggerConverter;
const UnifiedApiGenerator = @import("../generators/unified/api_generator.zig").UnifiedApiGenerator;

// Forgejo's three uploads: a file field, and on releases a plain field too.
const spec =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Uploads", "version": "1.0.0" },
    \\  "paths": {
    \\    "/releases/{id}/assets": {
    \\      "post": {
    \\        "operationId": "createReleaseAttachment",
    \\        "consumes": ["multipart/form-data", "application/octet-stream"],
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "type": "integer" },
    \\          { "name": "name", "in": "query", "type": "string" },
    \\          { "name": "attachment", "in": "formData", "type": "file" },
    \\          { "name": "external_url", "in": "formData", "type": "string" }
    \\        ],
    \\        "responses": { "201": { "description": "ok" } }
    \\      }
    \\    },
    \\    "/issues/{index}/assets": {
    \\      "post": {
    \\        "operationId": "createIssueAttachment",
    \\        "consumes": ["multipart/form-data"],
    \\        "parameters": [
    \\          { "name": "index", "in": "path", "required": true, "type": "integer" },
    \\          { "name": "attachment", "in": "formData", "required": true, "type": "file" }
    \\        ],
    \\        "responses": { "201": { "description": "ok" } }
    \\      }
    \\    }
    \\  }
    \\}
;

fn generate(allocator: std.mem.Allocator, args: cli.CliArgs) ![]const u8 {
    var parsed = try models.SwaggerDocument.parseFromJson(allocator, spec);
    defer parsed.deinit(allocator);
    var converter = SwaggerConverter.init(allocator);
    var unified = try converter.convert(parsed);
    defer unified.deinit(allocator);
    var generator = UnifiedApiGenerator.init(allocator, args);
    defer generator.deinit();
    return generator.generate(unified);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

test "a file field is a FormFile, and form fields go out as multipart" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const code = try generate(allocator, .{ .input_path = "fixture.json", .parameters_as_struct = true });
    defer allocator.free(code);

    try expectContains(code, "attachment: FormFile,");
    try expectContains(code, "attachment: ?FormFile = null,");
    try expectContains(code, "external_url: ?[]const u8 = null,");
    // Nothing set aside as unused: every field reaches the body.
    try testing.expect(std.mem.indexOf(u8, code, "_ = options.attachment;") == null);
    try expectContains(code, "    try multipart.add(allocator, \"attachment\", options.attachment);\n");
    try expectContains(code, "    if (options.external_url) |value| try multipart.add(allocator, \"external_url\", value);\n");
    try expectContains(code, "const form = try multipart.finish(allocator, client.io);");
    try expectContains(code, "uri_buf.written(), payload, form.content_type");
    try testing.expect(std.mem.indexOf(u8, code, "TODO(#53-followup)") == null);
}

test "form fields are arguments too when params are not a struct" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const code = try generate(allocator, .{ .input_path = "fixture.json" });
    defer allocator.free(code);

    try expectContains(code, "attachment: ?FormFile, external_url: ?[]const u8");
    try expectContains(code, "if (attachment) |value| try multipart.add(allocator, \"attachment\", value);");
}
