const std = @import("std");
const document_model = @import("../../models/common/document.zig");
const ident = @import("ident_utils.zig");

const UnifiedDocument = document_model.UnifiedDocument;
const Schema = document_model.Schema;

/// One Zig enum gathered from the document.
pub const EnumType = struct {
    /// Owned by the registry.
    name: []const u8,
    /// Sorted and deduplicated. The strings are borrowed from the document.
    values: []const []const u8,
};

/// Every `enum` in a document, grouped so that the same set of choices used in
/// many places becomes one Zig type.
///
/// A tag is the wire value verbatim, escaped as `@"..."` where it is not a bare
/// identifier. That is what makes the round trip free: `std.json` matches an
/// incoming string against `@tagName`, `Stringify` writes `@tagName` back out,
/// and the generated query and header writers already format an enum with
/// `@tagName`. No mapping table, and no name mangling to keep injective.
///
/// Two things are left as `[]const u8` rather than being given a type:
///
///   * a choice list containing the empty string, because `@""` is not a legal
///     Zig identifier and any tag chosen for it would have to be mapped back by
///     hand, losing exactly the property that makes the rest of this free;
///   * a choice list that is not all strings, since the wire form of a
///     non-string tag is not its name.
pub const EnumRegistry = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(EnumType),
    /// Group key to index into `types`. The keys are owned.
    index: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) EnumRegistry {
        return .{
            .allocator = allocator,
            .types = .empty,
            .index = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *EnumRegistry) void {
        for (self.types.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.values);
        }
        self.types.deinit(self.allocator);
        var it = self.index.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.index.deinit();
    }

    /// The name of the type standing for this schema's choices, or null when
    /// the schema has none or carries a list this generator will not name.
    pub fn lookup(self: *const EnumRegistry, schema: Schema) ?[]const u8 {
        const key = (groupKeyAlloc(self.allocator, schema) catch return null) orelse return null;
        defer self.allocator.free(key);
        const position = self.index.get(key) orelse return null;
        return self.types.items[position].name;
    }

    /// Write the enum declarations, in the order the registry holds them,
    /// which is sorted by group key and so does not depend on hash iteration.
    pub fn appendDeclarations(self: *const EnumRegistry, buffer: *std.ArrayList(u8)) !void {
        for (self.types.items) |entry| {
            try buffer.appendSlice(self.allocator, "pub const ");
            try buffer.appendSlice(self.allocator, entry.name);
            try buffer.appendSlice(self.allocator, " = enum {\n");
            for (entry.values) |value| {
                try buffer.appendSlice(self.allocator, "    ");
                try ident.appendIdentifier(buffer, self.allocator, value);
                try buffer.appendSlice(self.allocator, ",\n");
            }
            try buffer.appendSlice(self.allocator, "};\n\n");
        }
    }
};

/// The values of a schema this generator is willing to turn into a Zig enum.
fn namableValues(schema: Schema) ?[]const std.json.Value {
    const values = schema.enum_values orelse return null;
    if (values.len == 0) return null;
    for (values) |value| {
        switch (value) {
            // `@""` is not a legal identifier, so a list containing the empty
            // string cannot use the wire value as its tag.
            .string => |text| if (text.len == 0) return null,
            else => return null,
        }
    }
    return values;
}

/// What decides whether two schemas are the same enum.
///
/// `x-spec-enum-id` is preferred where present, because the values alone do not
/// settle it: drf-spectacular emits the same choice set with a `null` variant
/// added or not depending on whether the context is a nullable field or a
/// filter, so three spellings of one enum are common. Falling back to the
/// values themselves means a document without the extension still gets one type
/// per distinct choice list rather than one per occurrence.
fn groupKeyAlloc(allocator: std.mem.Allocator, schema: Schema) !?[]u8 {
    const values = namableValues(schema) orelse return null;
    if (schema.enum_id) |id| return try std.fmt.allocPrint(allocator, "id:{s}", .{id});

    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try key.appendSlice(allocator, "values:");
    // Sorted, so that two lists differing only in order are one group.
    const sorted = try allocator.alloc([]const u8, values.len);
    defer allocator.free(sorted);
    for (values, 0..) |value, i| sorted[i] = value.string;
    std.mem.sort([]const u8, sorted, {}, lessThanString);
    for (sorted) |value| {
        try key.appendSlice(allocator, value);
        try key.append(allocator, 0);
    }
    return try key.toOwnedSlice(allocator);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One place an enum was written, kept until every place is known so that the
/// name can be taken from how the choices are most often spelled.
const Occurrence = struct {
    /// Owned.
    key: []u8,
    /// Borrowed: the property or parameter the enum was written on.
    hint: []const u8,
    /// Borrowed.
    values: []const std.json.Value,
};

fn occurrenceLessThan(_: void, a: Occurrence, b: Occurrence) bool {
    return switch (std.mem.order(u8, a.key, b.key)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.hint, b.hint) == .lt,
    };
}

/// Gather every enum in the document into named types.
///
/// The result depends only on the document: occurrences are sorted before any
/// name is chosen, so two generators building a registry from the same document
/// -- the model generator, which writes the declarations, and the API
/// generator, which refers to them -- agree without having to share one.
pub fn build(allocator: std.mem.Allocator, document: UnifiedDocument) !EnumRegistry {
    var registry = EnumRegistry.init(allocator);
    errdefer registry.deinit();

    var occurrences: std.ArrayList(Occurrence) = .empty;
    defer {
        for (occurrences.items) |occurrence| allocator.free(occurrence.key);
        occurrences.deinit(allocator);
    }

    if (document.schemas) |schemas| {
        var it = schemas.iterator();
        while (it.next()) |entry| {
            try collect(allocator, &occurrences, entry.key_ptr.*, entry.value_ptr.*, 0);
        }
    }

    var path_it = document.paths.iterator();
    while (path_it.next()) |path_entry| {
        const item = path_entry.value_ptr.*;
        const operations = [_]?document_model.Operation{
            item.get, item.put, item.post, item.delete, item.options, item.head, item.patch,
        };
        for (operations) |maybe_operation| {
            const operation = maybe_operation orelse continue;
            try collectParameters(allocator, &occurrences, operation.parameters);
        }
        try collectParameters(allocator, &occurrences, item.parameters);
    }

    std.mem.sort(Occurrence, occurrences.items, {}, occurrenceLessThan);

    // Names already spoken for by a model, so an enum cannot shadow one.
    var taken = std.StringHashMap(void).init(allocator);
    defer taken.deinit();
    if (document.schemas) |schemas| {
        var it = schemas.iterator();
        while (it.next()) |entry| try taken.put(entry.key_ptr.*, {});
    }

    var start: usize = 0;
    while (start < occurrences.items.len) {
        var end = start;
        while (end < occurrences.items.len and
            std.mem.eql(u8, occurrences.items[end].key, occurrences.items[start].key)) : (end += 1)
        {}
        const group = occurrences.items[start..end];
        try addGroup(allocator, &registry, &taken, group);
        start = end;
    }

    return registry;
}

fn collectParameters(
    allocator: std.mem.Allocator,
    occurrences: *std.ArrayList(Occurrence),
    parameters: ?[]document_model.Parameter,
) !void {
    for (parameters orelse return) |parameter| {
        const schema = parameter.schema orelse continue;
        try collect(allocator, occurrences, parameter.name, schema, 0);
    }
}

/// Walk a schema for enums, carrying down the name the enclosing property or
/// parameter was given. `depth` stops a self-referential document from
/// recursing forever.
fn collect(
    allocator: std.mem.Allocator,
    occurrences: *std.ArrayList(Occurrence),
    hint: []const u8,
    schema: Schema,
    depth: usize,
) !void {
    if (depth > 16) return;

    if (try groupKeyAlloc(allocator, schema)) |key| {
        errdefer allocator.free(key);
        try occurrences.append(allocator, .{
            .key = key,
            .hint = hint,
            .values = schema.enum_values.?,
        });
    }

    if (schema.properties) |properties| {
        var it = properties.iterator();
        while (it.next()) |entry| {
            try collect(allocator, occurrences, entry.key_ptr.*, entry.value_ptr.*, depth + 1);
        }
    }
    // An array of choices is named for the property holding it, not for the
    // anonymous item schema.
    if (schema.items) |items| try collect(allocator, occurrences, hint, items.*, depth + 1);
    if (schema.one_of) |variants| {
        for (variants) |variant| try collect(allocator, occurrences, hint, variant, depth + 1);
    }
    if (schema.any_of) |variants| {
        for (variants) |variant| try collect(allocator, occurrences, hint, variant, depth + 1);
    }
}

fn addGroup(
    allocator: std.mem.Allocator,
    registry: *EnumRegistry,
    taken: *std.StringHashMap(void),
    group: []const Occurrence,
) !void {
    // The union across the group, since occurrences of one enum differ by the
    // null variant drf-spectacular adds in some contexts and not others. A tag
    // that only a filter accepts is harmless on a response type; a missing one
    // would not be.
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    for (group) |occurrence| {
        for (occurrence.values) |value| {
            var seen = false;
            for (values.items) |existing| {
                if (std.mem.eql(u8, existing, value.string)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try values.append(allocator, value.string);
        }
    }
    std.mem.sort([]const u8, values.items, {}, lessThanString);

    const base = try enumNameAlloc(allocator, modalHint(group));
    defer allocator.free(base);

    var name = try allocator.dupe(u8, base);
    errdefer allocator.free(name);
    var suffix: usize = 2;
    while (taken.contains(name)) {
        allocator.free(name);
        name = try std.fmt.allocPrint(allocator, "{s}{d}", .{ base, suffix });
        suffix += 1;
    }
    try taken.put(name, {});

    const key = try allocator.dupe(u8, group[0].key);
    errdefer allocator.free(key);
    try registry.index.put(key, registry.types.items.len);
    try registry.types.append(allocator, .{
        .name = name,
        .values = try values.toOwnedSlice(allocator),
    });
}

/// The name the group is most often written under. The group is sorted by hint,
/// so equal hints are adjacent and the longest run wins; ties go to the one
/// sorting first, which keeps the choice independent of document order.
fn modalHint(group: []const Occurrence) []const u8 {
    var best: []const u8 = group[0].hint;
    var best_count: usize = 0;
    var i: usize = 0;
    while (i < group.len) {
        var j = i;
        while (j < group.len and std.mem.eql(u8, group[j].hint, group[i].hint)) : (j += 1) {}
        if (j - i > best_count) {
            best = group[i].hint;
            best_count = j - i;
        }
        i = j;
    }
    return best;
}

/// `cable_end` becomes `CableEndEnum`. The suffix keeps a choice list from
/// colliding with the model of the same name -- NetBox has both a `status`
/// field and a `Status` schema -- and matches what drf-spectacular calls these
/// when it hoists them itself.
fn enumNameAlloc(allocator: std.mem.Allocator, hint: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var upper_next = true;
    for (hint) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            upper_next = true;
            continue;
        }
        if (upper_next) {
            try out.append(allocator, std.ascii.toUpper(c));
            upper_next = false;
        } else {
            try out.append(allocator, c);
        }
    }
    if (out.items.len == 0 or !ident.isIdentStart(out.items[0])) {
        try out.insert(allocator, 0, '_');
    }
    try out.appendSlice(allocator, "Enum");
    return try out.toOwnedSlice(allocator);
}

test "an enum containing the empty string is not named" {
    const values = [_]std.json.Value{ .{ .string = "a" }, .{ .string = "" } };
    try std.testing.expect(namableValues(.{ .type = .string, .enum_values = &values }) == null);
}

test "an enum of non-strings is not named" {
    const values = [_]std.json.Value{.{ .integer = 1 }};
    try std.testing.expect(namableValues(.{ .type = .integer, .enum_values = &values }) == null);
}

test "the group key prefers x-spec-enum-id over the values" {
    const values = [_]std.json.Value{.{ .string = "a" }};
    const with_id = (try groupKeyAlloc(std.testing.allocator, .{
        .type = .string,
        .enum_values = &values,
        .enum_id = "deadbeef",
    })).?;
    defer std.testing.allocator.free(with_id);
    try std.testing.expectEqualStrings("id:deadbeef", with_id);

    const without = (try groupKeyAlloc(std.testing.allocator, .{
        .type = .string,
        .enum_values = &values,
    })).?;
    defer std.testing.allocator.free(without);
    try std.testing.expectEqualStrings("values:a\x00", without);
}

test "the group key does not depend on the order of the values" {
    const one = [_]std.json.Value{ .{ .string = "b" }, .{ .string = "a" } };
    const two = [_]std.json.Value{ .{ .string = "a" }, .{ .string = "b" } };
    const key_one = (try groupKeyAlloc(std.testing.allocator, .{ .type = .string, .enum_values = &one })).?;
    defer std.testing.allocator.free(key_one);
    const key_two = (try groupKeyAlloc(std.testing.allocator, .{ .type = .string, .enum_values = &two })).?;
    defer std.testing.allocator.free(key_two);
    try std.testing.expectEqualStrings(key_one, key_two);
}

test "enumNameAlloc capitalises and suffixes" {
    const name = try enumNameAlloc(std.testing.allocator, "cable_end");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("CableEndEnum", name);

    const digit = try enumNameAlloc(std.testing.allocator, "2fa");
    defer std.testing.allocator.free(digit);
    try std.testing.expectEqualStrings("_2faEnum", digit);
}
