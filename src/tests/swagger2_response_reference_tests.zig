const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const cli = @import("../cli.zig");
const SwaggerConverter = @import("../generators/converters/swagger_converter.zig").SwaggerConverter;
const common = @import("../models/common/document.zig");
const UnifiedApiGenerator = @import("../generators/unified/api_generator.zig").UnifiedApiGenerator;

// Swagger 2.0 lets an operation name a shared response instead of spelling one
// out, and real specifications lean on it heavily: Forgejo writes every one of
// its 467 successful responses as a `$ref` into the global table.
const spec_with_response_refs =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Refs", "version": "1.0.0" },
    \\  "basePath": "/api/v1",
    \\  "paths": {
    \\    "/version": {
    \\      "get": {
    \\        "operationId": "getVersion",
    \\        "responses": { "200": { "$ref": "#/responses/ServerVersion" } }
    \\      }
    \\    },
    \\    "/users": {
    \\      "get": {
    \\        "operationId": "listUsers",
    \\        "responses": { "200": { "$ref": "#/responses/UserList" } }
    \\      }
    \\    },
    \\    "/users/{name}": {
    \\      "delete": {
    \\        "operationId": "deleteUser",
    \\        "parameters": [
    \\          { "name": "name", "in": "path", "required": true, "type": "string" }
    \\        ],
    \\        "responses": { "204": { "$ref": "#/responses/empty" } }
    \\      }
    \\    }
    \\  },
    \\  "responses": {
    \\    "ServerVersion": {
    \\      "description": "ServerVersion",
    \\      "schema": { "$ref": "#/definitions/ServerVersion" }
    \\    },
    \\    "UserList": {
    \\      "description": "UserList",
    \\      "schema": { "type": "array", "items": { "$ref": "#/definitions/User" } }
    \\    },
    \\    "empty": { "description": "APIEmpty is an empty response" }
    \\  },
    \\  "definitions": {
    \\    "ServerVersion": {
    \\      "type": "object",
    \\      "properties": { "version": { "type": "string" } }
    \\    },
    \\    "User": {
    \\      "type": "object",
    \\      "properties": { "login": { "type": "string" } }
    \\    }
    \\  }
    \\}
;

// A response that references another response. The specification permits it,
// and resolution has to keep following the chain to reach the schema.
const spec_with_response_ref_chain =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Refs", "version": "1.0.0" },
    \\  "paths": {
    \\    "/version": {
    \\      "get": {
    \\        "operationId": "getVersion",
    \\        "responses": { "200": { "$ref": "#/responses/VersionAlias" } }
    \\      }
    \\    }
    \\  },
    \\  "responses": {
    \\    "VersionAlias": { "description": "", "$ref": "#/responses/ServerVersion" },
    \\    "ServerVersion": {
    \\      "description": "ServerVersion",
    \\      "schema": { "$ref": "#/definitions/ServerVersion" }
    \\    }
    \\  },
    \\  "definitions": {
    \\    "ServerVersion": {
    \\      "type": "object",
    \\      "properties": { "version": { "type": "string" } }
    \\    }
    \\  }
    \\}
;

// Two malformed documents: one naming a response that is not in the table, one
// whose responses reference each other in a circle. Neither should stop the
// rest of the document from generating, and neither should hang.
const spec_with_dangling_response_ref =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Refs", "version": "1.0.0" },
    \\  "paths": {
    \\    "/version": {
    \\      "get": {
    \\        "operationId": "getVersion",
    \\        "responses": { "200": { "$ref": "#/responses/Missing" } }
    \\      }
    \\    }
    \\  },
    \\  "responses": {
    \\    "Present": { "description": "Present" }
    \\  }
    \\}
;

const spec_with_cyclic_response_refs =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Refs", "version": "1.0.0" },
    \\  "paths": {
    \\    "/version": {
    \\      "get": {
    \\        "operationId": "getVersion",
    \\        "responses": { "200": { "$ref": "#/responses/A" } }
    \\      }
    \\    }
    \\  },
    \\  "responses": {
    \\    "A": { "description": "", "$ref": "#/responses/B" },
    \\    "B": { "description": "", "$ref": "#/responses/A" }
    \\  }
    \\}
;

// Forgejo declares both an `ActionRun` definition and an `ActionRun` operation.
// Emitted into one file they are two declarations of the same name.
const spec_with_operation_named_after_a_definition =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Collide", "version": "1.0.0" },
    \\  "paths": {
    \\    "/runs/{id}": {
    \\      "get": {
    \\        "operationId": "ActionRun",
    \\        "parameters": [
    \\          { "name": "id", "in": "path", "required": true, "type": "string" }
    \\        ],
    \\        "responses": { "200": { "$ref": "#/responses/ActionRun" } }
    \\      }
    \\    }
    \\  },
    \\  "responses": {
    \\    "ActionRun": {
    \\      "description": "ActionRun",
    \\      "schema": { "$ref": "#/definitions/ActionRun" }
    \\    }
    \\  },
    \\  "definitions": {
    \\    "ActionRun": {
    \\      "type": "object",
    \\      "properties": { "id": { "type": "integer", "format": "int64" } }
    \\    }
    \\  }
    \\}
;

/// A converted document and the parsed one it borrows its strings from. The
/// unified document holds references into the Swagger document rather than
/// copies, so the two have to be freed together and in this order.
const Converted = struct {
    parsed: models.SwaggerDocument,
    unified: common.UnifiedDocument,

    fn deinit(self: *Converted, allocator: std.mem.Allocator) void {
        self.unified.deinit(allocator);
        self.parsed.deinit(allocator);
    }
};

fn convert(allocator: std.mem.Allocator, spec: []const u8) !Converted {
    var parsed = try models.SwaggerDocument.parseFromJson(allocator, spec);
    errdefer parsed.deinit(allocator);
    var converter = SwaggerConverter.init(allocator);
    return .{ .parsed = parsed, .unified = try converter.convert(parsed) };
}

fn generateClient(allocator: std.mem.Allocator, spec: []const u8, args: cli.CliArgs) ![]const u8 {
    var converted = try convert(allocator, spec);
    defer converted.deinit(allocator);

    var generator = UnifiedApiGenerator.init(allocator, args);
    defer generator.deinit();
    return generator.generate(converted.unified);
}

test "global response references resolve to the referenced response" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var converted = try convert(allocator, spec_with_response_refs);
    defer converted.deinit(allocator);
    const unified = converted.unified;

    // An unresolved $ref used to leave an empty response behind, which made
    // every one of these operations generate as `!void`.
    const version = unified.paths.get("/version").?.get.?.responses.get("200").?;
    try testing.expectEqualStrings("ServerVersion", version.description);
    try testing.expectEqualStrings("#/definitions/ServerVersion", version.schema.?.ref.?);

    const users = unified.paths.get("/users").?.get.?.responses.get("200").?;
    try testing.expectEqual(common.SchemaType.array, users.schema.?.type.?);
    try testing.expectEqualStrings("#/definitions/User", users.schema.?.items.?.ref.?);

    // A referenced response that genuinely carries no schema stays schemaless.
    const deleted = unified.paths.get("/users/{name}").?.delete.?.responses.get("204").?;
    try testing.expectEqualStrings("APIEmpty is an empty response", deleted.description);
    try testing.expect(deleted.schema == null);
}

test "referenced responses give operations their return types" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateClient(allocator, spec_with_response_refs, .{ .input_path = "fixture.json" });
    defer allocator.free(code);

    try testing.expect(std.mem.indexOf(u8, code, "pub fn getVersion(client: *Client) !Owned(ServerVersion) {") != null);
    // The element type of an array response has to survive too, or the caller
    // gets []const std.json.Value and has to parse the response a second time.
    try testing.expect(std.mem.indexOf(u8, code, "pub fn listUsers(client: *Client) !Owned([]const User) {") != null);
    // 204 with no schema is still void.
    try testing.expect(std.mem.indexOf(u8, code, "pub fn deleteUser(client: *Client, name: []const u8) !void {") != null);
}

test "a chain of response references resolves to the response at its end" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var converted = try convert(allocator, spec_with_response_ref_chain);
    defer converted.deinit(allocator);
    const unified = converted.unified;

    const version = unified.paths.get("/version").?.get.?.responses.get("200").?;
    try testing.expectEqualStrings("ServerVersion", version.description);
    try testing.expectEqualStrings("#/definitions/ServerVersion", version.schema.?.ref.?);
}

test "a response reference with no target leaves the operation without a schema" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var converted = try convert(allocator, spec_with_dangling_response_ref);
    defer converted.deinit(allocator);
    const unified = converted.unified;

    const version = unified.paths.get("/version").?.get.?.responses.get("200").?;
    try testing.expect(version.schema == null);
}

test "responses referencing each other in a circle terminate" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var converted = try convert(allocator, spec_with_cyclic_response_refs);
    defer converted.deinit(allocator);
    const unified = converted.unified;

    const version = unified.paths.get("/version").?.get.?.responses.get("200").?;
    try testing.expect(version.schema == null);
}

test "an operation named after a definition moves aside" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateClient(allocator, spec_with_operation_named_after_a_definition, .{ .input_path = "fixture.json" });
    defer allocator.free(code);

    // The model keeps the name -- it is what the return type still names --
    // and the operation takes the underscore, the same way two operations that
    // camel case onto one name are separated.
    try testing.expect(std.mem.indexOf(u8, code, "pub fn ActionRun(client: *Client") == null);
    try testing.expect(std.mem.indexOf(u8, code, "pub fn ActionRun_(client: *Client, id: []const u8) !Owned(ActionRun) {") != null);
}
