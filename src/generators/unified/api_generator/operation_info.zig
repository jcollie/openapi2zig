const std = @import("std");
const document_types = @import("../../../models/common/document.zig");
const UnifiedDocument = document_types.UnifiedDocument;
const Operation = document_types.Operation;
const Parameter = document_types.Parameter;
const helpers = @import("helpers.zig");
const escapeZigString = helpers.escapeZigString;
const UnifiedApiGenerator = @import("../api_generator.zig").UnifiedApiGenerator;

const operation_info_type =
    \\/// What the specification says about one operation, for a program that
    \\/// has to know at run time rather than at compile time: a command line
    \\/// built over the client, say.
    \\pub const OperationInfo = struct {
    \\    method: std.http.Method,
    \\    /// The path as the specification writes it, `{name}` placeholders and all.
    \\    path: []const u8,
    \\    summary: ?[]const u8 = null,
    \\    description: ?[]const u8 = null,
    \\    deprecated: bool = false,
    \\    params: []const Param = &.{},
    \\
    \\    pub const Location = enum { path, query, header, body, form };
    \\
    \\    pub const Param = struct {
    \\        /// The name on the wire, as the specification spells it.
    \\        name: []const u8,
    \\        /// What the generated code calls it: the field of the operation's
    \\        /// parameters struct, or the argument, or `requestBody`.
    \\        field: []const u8,
    \\        location: Location,
    \\        required: bool = false,
    \\        description: ?[]const u8 = null,
    \\        /// The only values the parameter may take, when the specification
    \\        /// gives a list; empty when it does not.
    \\        allowed: []const []const u8 = &.{},
    \\    };
    \\
    \\    pub fn param(self: OperationInfo, field: []const u8) ?Param {
    \\        for (self.params) |p| {
    \\            if (std.mem.eql(u8, p.field, field)) return p;
    \\        }
    \\        return null;
    \\    }
    \\};
    \\
    \\/// One `OperationInfo` per operation, named as its function is.
    \\pub const operation_info = struct {
    \\
;

/// Declares `OperationInfo` and the `operation_info` namespace, when
/// `operation_info` was asked for. It is emitted after every operation, so the
/// names of their parameters structs' fields are already settled.
pub fn generateOperationInfo(self: *UnifiedApiGenerator, document: UnifiedDocument) !void {
    if (!self.args.operation_info) return;
    try self.buffer.appendSlice(self.allocator, operation_info_type);
    var path_iterator = document.paths.iterator();
    while (path_iterator.next()) |entry| {
        const path = entry.key_ptr.*;
        const item = entry.value_ptr.*;
        inline for (.{ "get", "post", "put", "delete", "patch", "head", "options" }) |field| {
            if (@field(item, field)) |operation| {
                try generateOne(self, comptime upper(field), path, operation);
            }
        }
    }
    try self.buffer.appendSlice(self.allocator, "};\n\n");
}

fn upper(comptime text: []const u8) []const u8 {
    comptime {
        var result: [text.len]u8 = undefined;
        for (text, 0..) |c, i| result[i] = std.ascii.toUpper(c);
        const final = result;
        return &final;
    }
}

fn generateOne(self: *UnifiedApiGenerator, comptime method: []const u8, path: []const u8, operation: Operation) !void {
    const name = self.operationNameOf(operation) orelse return;
    try self.buffer.appendSlice(self.allocator, "    pub const ");
    try self.appendIdentifier(name);
    try self.buffer.appendSlice(self.allocator, ": OperationInfo = .{\n");
    try self.buffer.appendSlice(self.allocator, "        .method = ." ++ method ++ ",\n");
    try appendStringField(self, "        ", "path", path);
    if (operation.summary) |summary| try appendStringField(self, "        ", "summary", summary);
    if (operation.description) |description| try appendStringField(self, "        ", "description", description);
    if (operation.deprecated) try self.buffer.appendSlice(self.allocator, "        .deprecated = true,\n");

    if (operation.parameters) |params| {
        try self.buffer.appendSlice(self.allocator, "        .params = &.{\n");
        for (params, 0..) |param, i| {
            try self.buffer.appendSlice(self.allocator, "            .{\n");
            try appendStringField(self, "                ", "name", param.name);
            const field = try fieldName(self, operation, method, path, param, i);
            defer self.allocator.free(field);
            try appendStringField(self, "                ", "field", field);
            try self.buffer.appendSlice(self.allocator, "                .location = .");
            try self.buffer.appendSlice(self.allocator, switch (param.location) {
                .path => "path",
                .query => "query",
                .header => "header",
                .body => "body",
                .form => "form",
            });
            try self.buffer.appendSlice(self.allocator, ",\n");
            if (param.required or param.location == .path)
                try self.buffer.appendSlice(self.allocator, "                .required = true,\n");
            if (param.description) |description| try appendStringField(self, "                ", "description", description);
            try appendAllowed(self, param);
            try self.buffer.appendSlice(self.allocator, "            },\n");
        }
        try self.buffer.appendSlice(self.allocator, "        },\n");
    }
    try self.buffer.appendSlice(self.allocator, "    };\n");
}

/// The name the generated code gives the parameter.
fn fieldName(self: *UnifiedApiGenerator, operation: Operation, method: []const u8, path: []const u8, param: Parameter, index: usize) ![]const u8 {
    if (param.location == .body) return self.allocator.dupe(u8, "requestBody");
    if (self.args.parameters_as_struct) return self.optionsFieldNameAlloc(operation, method, path, index);
    return self.allocator.dupe(u8, param.name);
}

fn appendStringField(self: *UnifiedApiGenerator, indent: []const u8, field: []const u8, value: []const u8) !void {
    const escaped = try escapeZigString(self.allocator, value);
    defer self.allocator.free(escaped);
    try self.buffer.appendSlice(self.allocator, indent);
    try self.buffer.append(self.allocator, '.');
    try self.buffer.appendSlice(self.allocator, field);
    try self.buffer.appendSlice(self.allocator, " = \"");
    try self.buffer.appendSlice(self.allocator, escaped);
    try self.buffer.appendSlice(self.allocator, "\",\n");
}

/// The parameter's allowed values, from wherever the specification put them:
/// on the parameter itself (Swagger 2.0), or in its schema or its schema's
/// items (OpenAPI 3).
fn appendAllowed(self: *UnifiedApiGenerator, param: Parameter) !void {
    const values = param.enum_values orelse if (param.schema) |schema|
        schema.enum_values orelse if (schema.items) |items| items.enum_values else null
    else
        null;
    const list = values orelse return;
    if (list.len == 0) return;
    try self.buffer.appendSlice(self.allocator, "                .allowed = &.{ ");
    var first = true;
    for (list) |value| {
        var number_buffer: [64]u8 = undefined;
        const text: []const u8 = switch (value) {
            .string => |s| s,
            .integer => |n| std.fmt.bufPrint(&number_buffer, "{d}", .{n}) catch unreachable,
            .bool => |b| if (b) "true" else "false",
            else => continue,
        };
        if (!first) try self.buffer.appendSlice(self.allocator, ", ");
        first = false;
        const escaped = try escapeZigString(self.allocator, text);
        defer self.allocator.free(escaped);
        try self.buffer.append(self.allocator, '"');
        try self.buffer.appendSlice(self.allocator, escaped);
        try self.buffer.append(self.allocator, '"');
    }
    try self.buffer.appendSlice(self.allocator, " },\n");
}
