const std = @import("std");
const test_utils = @import("test_utils.zig");
const models = @import("../models.zig");
const OpenApiConverter = @import("../generators/converters/openapi_converter.zig").OpenApiConverter;
const UnifiedModelGenerator = @import("../generators/unified/model_generator.zig").UnifiedModelGenerator;

// A component schema that is nothing but a `$ref` to another. Singlewire
// InformaCast's schema is full of them -- 31 of its 615 components are written
// this way, a name for a "merged" definition next door -- and the names are
// used by properties and responses throughout. Emitting nothing for such a
// component leaves the generated file naming a type it never declares, which
// cost that client 214 compile errors.
const spec_with_aliases =
    \\{
    \\  "openapi": "3.0.3",
    \\  "info": { "title": "Aliases", "version": "1.0.0" },
    \\  "paths": {},
    \\  "components": {
    \\    "schemas": {
    \\      "Base": {
    \\        "type": "object",
    \\        "properties": { "id": { "type": "integer" } }
    \\      },
    \\      "_thing.response": { "$ref": "#/components/schemas/Base" },
    \\      "_thing.wrapped": { "allOf": [ { "$ref": "#/components/schemas/Base" } ] },
    \\      "SelfNaming": { "$ref": "#/components/schemas/SelfNaming" },
    \\      "Holder": {
    \\        "type": "object",
    \\        "properties": {
    \\          "response": { "$ref": "#/components/schemas/_thing.response" },
    \\          "wrapped": { "$ref": "#/components/schemas/_thing.wrapped" }
    \\        }
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

test "a component that is only a reference is declared as an alias" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateModels(allocator, spec_with_aliases);
    defer allocator.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, "pub const @\"_thing.response\" = Base;") != null);

    // The same holds for the one-member `allOf` that OpenAPI 3.0 forces on
    // anyone wanting to hang a keyword off a reference, which the converter
    // resolves to the reference it wraps.
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const @\"_thing.wrapped\" = Base;") != null);

    // And the names stay usable by whatever refers to them.
    try std.testing.expect(std.mem.indexOf(u8, code, "    response: ?@\"_thing.response\" = null,") != null);
}

test "a component naming itself emits nothing" {
    var gpa = test_utils.createTestAllocator();
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const code = try generateModels(allocator, spec_with_aliases);
    defer allocator.free(code);

    // `pub const SelfNaming = SelfNaming;` does not compile, so the alias is
    // skipped rather than emitted circularly.
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const SelfNaming = SelfNaming;") == null);
}
