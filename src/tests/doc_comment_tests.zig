const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const cli = @import("../cli.zig");
const SwaggerConverter = @import("../generators/converters/swagger_converter.zig").SwaggerConverter;
const UnifiedApiGenerator = @import("../generators/unified/api_generator.zig").UnifiedApiGenerator;
const UnifiedModelGenerator = @import("../generators/unified/model_generator.zig").UnifiedModelGenerator;

const spec =
    \\{
    \\  "swagger": "2.0",
    \\  "info": { "title": "Docs", "version": "1.0.0" },
    \\  "paths": {
    \\    "/repos/{owner}/issues": {
    \\      "get": {
    \\        "operationId": "issueListIssues",
    \\        "summary": "List a repository's issues",
    \\        "description": "Open ones first.\n\n\tThen the rest.",
    \\        "parameters": [
    \\          { "name": "owner", "in": "path", "required": true, "type": "string",
    \\            "description": "owner of the repo" },
    \\          { "name": "state", "in": "query", "type": "string",
    \\            "enum": ["closed", "open", "all"], "description": "whether issue is open or closed" },
    \\          { "name": "subject-type", "in": "query", "type": "array",
    \\            "items": { "type": "string", "enum": ["issue", "pull"] }, "collectionFormat": "multi" }
    \\        ],
    \\        "responses": { "200": { "description": "ok", "schema": { "$ref": "#/definitions/Issue" } } }
    \\      },
    \\      "post": {
    \\        "operationId": "issueCreateIssue",
    \\        "deprecated": true,
    \\        "parameters": [
    \\          { "name": "owner", "in": "path", "required": true, "type": "string" },
    \\          { "name": "body", "in": "body", "schema": { "$ref": "#/definitions/Issue" } }
    \\        ],
    \\        "responses": { "201": { "description": "ok", "schema": { "$ref": "#/definitions/Issue" } } }
    \\      }
    \\    }
    \\  },
    \\  "definitions": {
    \\    "Issue": {
    \\      "description": "Issue represents an issue in a repository",
    \\      "type": "object",
    \\      "properties": { "title": { "type": "string", "description": "The \"title\"" } }
    \\    }
    \\  }
    \\}
;

const Generated = struct {
    models: []const u8,
    client: []const u8,

    fn deinit(self: Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.models);
        allocator.free(self.client);
    }
};

fn generate(allocator: std.mem.Allocator, args: cli.CliArgs) !Generated {
    var parsed = try models.SwaggerDocument.parseFromJson(allocator, spec);
    defer parsed.deinit(allocator);
    var converter = SwaggerConverter.init(allocator);
    var unified = try converter.convert(parsed);
    defer unified.deinit(allocator);

    var model_generator = UnifiedModelGenerator.init(allocator);
    defer model_generator.deinit();
    model_generator.doc_comments = args.doc_comments;
    const model_code = try model_generator.generate(unified);
    errdefer allocator.free(model_code);

    var api_generator = UnifiedApiGenerator.init(allocator, args);
    defer api_generator.deinit();
    return .{ .models = model_code, .client = try api_generator.generate(unified) };
}

const full: cli.CliArgs = .{
    .input_path = "fixture.json",
    .parameters_as_struct = true,
    .params_suffix = "Params",
    .doc_comments = true,
    .operation_info = true,
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\n", .{needle});
        return error.TestExpectedContains;
    }
}

test "an operation's summary, description and request become its doc comment" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const g = try generate(allocator, full);
    defer g.deinit(allocator);

    try expectContains(g.client,
        \\/// List a repository's issues
        \\///
        \\/// Open ones first.
        \\///
        \\///  Then the rest.
        \\///
        \\/// `GET /repos/{owner}/issues`
        \\pub fn issueListIssues(
    );
    try expectContains(g.client, "/// `POST /repos/{owner}/issues`\n///\n/// Deprecated.\npub fn issueCreateIssue(");
    try expectContains(g.client, "/// `issueListIssues`, handing back the response as it came");
    try expectContains(g.client, "/// `issueListIssues`, telling a successful response apart");
    try testing.expect(std.mem.indexOf(u8, g.client, "// Summary:") == null);
}

test "a parameter's description becomes its field's doc comment" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const g = try generate(allocator, full);
    defer g.deinit(allocator);

    try expectContains(g.client,
        \\/// The path, query and header values `issueListIssues` is called with.
        \\pub const issueListIssuesParams = struct {
        \\    /// owner of the repo
        \\    owner: []const u8,
        \\    /// whether issue is open or closed
        \\    state: ?[]const u8 = null,
    );
}

test "a model's description and its fields' become doc comments" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const g = try generate(allocator, full);
    defer g.deinit(allocator);

    try expectContains(g.models, "/// Issue represents an issue in a repository\npub const Issue = struct {\n    /// The \"title\"\n    title: ?[]const u8 = null,");
}

test "without doc comments, the output keeps its plain comments" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = full;
    args.doc_comments = false;
    args.operation_info = false;
    const g = try generate(allocator, args);
    defer g.deinit(allocator);

    try expectContains(g.client, "// Summary:\n// List a repository's issues\n");
    // The runtime preamble has doc comments of its own; none of the
    // specification's text is carried into one.
    try testing.expect(std.mem.indexOf(u8, g.client, "/// List a repository's issues") == null);
    try testing.expect(std.mem.indexOf(u8, g.client, "/// owner of the repo") == null);
    try testing.expect(std.mem.indexOf(u8, g.models, "///") == null);
    try testing.expect(std.mem.indexOf(u8, g.client, "operation_info") == null);
}

test "operation info gives each operation's method, path and parameters" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    const g = try generate(allocator, full);
    defer g.deinit(allocator);

    try expectContains(g.client, "pub const OperationInfo = struct {");
    try expectContains(g.client,
        \\    pub const issueListIssues: OperationInfo = .{
        \\        .method = .GET,
        \\        .path = "/repos/{owner}/issues",
        \\        .summary = "List a repository's issues",
        \\        .description = "Open ones first.\n\n\tThen the rest.",
        \\        .params = &.{
        \\            .{
        \\                .name = "owner",
        \\                .field = "owner",
        \\                .location = .path,
        \\                .required = true,
        \\                .description = "owner of the repo",
        \\            },
        \\            .{
        \\                .name = "state",
        \\                .field = "state",
        \\                .location = .query,
        \\                .description = "whether issue is open or closed",
        \\                .allowed = &.{ "closed", "open", "all" },
        \\            },
        \\            .{
        \\                .name = "subject-type",
        \\                .field = "subject-type",
        \\                .location = .query,
        \\                .allowed = &.{ "issue", "pull" },
        \\            },
        \\        },
        \\    };
    );
    try expectContains(g.client, ".name = \"body\",\n                .field = \"requestBody\",\n                .location = .body,");
    try expectContains(g.client, "        .deprecated = true,\n");
}
