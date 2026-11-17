//! The types every generated client relies on, shared by the single-file
//! preamble and the separate runtime module of `--multiple-files`, so that
//! the two cannot drift apart.

pub const runtime_types =
    \\pub fn Owned(comptime T: type) type {
    \\    return struct {
    \\        allocator: std.mem.Allocator,
    \\        body: []u8,
    \\        parsed: std.json.Parsed(T),
    \\        /// The response's headers, in the order they were received.
    \\        headers: []const std.http.Header = &.{},
    \\        header_storage: []u8 = &.{},
    \\
    \\        pub fn deinit(self: *@This()) void {
    \\            self.parsed.deinit();
    \\            self.allocator.free(self.body);
    \\            self.allocator.free(self.headers);
    \\            self.allocator.free(self.header_storage);
    \\        }
    \\
    \\        /// The first header called `name`, compared without regard to case.
    \\        pub fn header(self: *const @This(), name: []const u8) ?[]const u8 {
    \\            return findHeader(self.headers, name);
    \\        }
    \\
    \\        pub fn value(self: *@This()) *T {
    \\            return &self.parsed.value;
    \\        }
    \\    };
    \\}
    \\
    \\pub const RawResponse = struct {
    \\    allocator: std.mem.Allocator,
    \\    status: std.http.Status,
    \\    body: []u8,
    \\    /// The response's headers, in the order they were received.
    \\    headers: []const std.http.Header = &.{},
    \\    header_storage: []u8 = &.{},
    \\
    \\    pub fn deinit(self: *@This()) void {
    \\        self.allocator.free(self.body);
    \\        self.allocator.free(self.headers);
    \\        self.allocator.free(self.header_storage);
    \\    }
    \\
    \\    /// The first header called `name`, compared without regard to case.
    \\    pub fn header(self: *const @This(), name: []const u8) ?[]const u8 {
    \\        return findHeader(self.headers, name);
    \\    }
    \\};
    \\
    \\pub fn findHeader(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    \\    for (headers) |h| {
    \\        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    \\    }
    \\    return null;
    \\}
    \\
    \\/// A file sent as one part of a `multipart/form-data` request.
    \\pub const FormFile = struct {
    \\    /// The name the part says the file has.
    \\    filename: []const u8,
    \\    /// `application/octet-stream` when left out.
    \\    content_type: ?[]const u8 = null,
    \\    bytes: []const u8,
    \\};
    \\
    \\/// A `multipart/form-data` body, gathered a field at a time. The fields are
    \\/// borrowed until `finish`, which chooses a boundary that none of them
    \\/// contains and writes the body out.
    \\pub const Multipart = struct {
    \\    parts: std.ArrayList(Part) = .empty,
    \\
    \\    const Part = struct {
    \\        name: []const u8,
    \\        value: []const u8,
    \\        filename: ?[]const u8 = null,
    \\        content_type: ?[]const u8 = null,
    \\        /// The value, when `add` had to format it.
    \\        owned: bool = false,
    \\    };
    \\
    \\    pub const Body = struct {
    \\        body: []u8,
    \\        /// `multipart/form-data; boundary=...`, for the request's header.
    \\        content_type: []u8,
    \\
    \\        pub fn deinit(self: Body, allocator: std.mem.Allocator) void {
    \\            allocator.free(self.body);
    \\            allocator.free(self.content_type);
    \\        }
    \\    };
    \\
    \\    pub fn deinit(self: *Multipart, allocator: std.mem.Allocator) void {
    \\        for (self.parts.items) |part| {
    \\            if (part.owned) allocator.free(part.value);
    \\        }
    \\        self.parts.deinit(allocator);
    \\    }
    \\
    \\    /// Adds a field: a `FormFile`, a string, a number, a boolean or an enum,
    \\    /// or a slice of them as one part each.
    \\    pub fn add(self: *Multipart, allocator: std.mem.Allocator, name: []const u8, value: anytype) !void {
    \\        const T = @TypeOf(value);
    \\        if (T == FormFile) {
    \\            return self.parts.append(allocator, .{
    \\                .name = name,
    \\                .value = value.bytes,
    \\                .filename = value.filename,
    \\                .content_type = value.content_type orelse "application/octet-stream",
    \\            });
    \\        }
    \\        switch (@typeInfo(T)) {
    \\            .pointer => |ptr| {
    \\                if (ptr.size == .slice and ptr.child == u8) return self.parts.append(allocator, .{ .name = name, .value = value });
    \\                if (ptr.size == .slice) {
    \\                    for (value) |element| try self.add(allocator, name, element);
    \\                    return;
    \\                }
    \\                @compileError("a form field cannot hold a " ++ @typeName(T));
    \\            },
    \\            .@"enum" => return self.parts.append(allocator, .{ .name = name, .value = @tagName(value) }),
    \\            .int, .comptime_int, .float, .comptime_float, .bool => {
    \\                const text = try std.fmt.allocPrint(allocator, "{}", .{value});
    \\                errdefer allocator.free(text);
    \\                return self.parts.append(allocator, .{ .name = name, .value = text, .owned = true });
    \\            },
    \\            else => @compileError("a form field cannot hold a " ++ @typeName(T)),
    \\        }
    \\    }
    \\
    \\    pub fn finish(self: *const Multipart, allocator: std.mem.Allocator, io: std.Io) !Body {
    \\        var boundary: [32]u8 = undefined;
    \\        choose: while (true) {
    \\            var random: [16]u8 = undefined;
    \\            io.random(&random);
    \\            boundary = std.fmt.bytesToHex(random, .lower);
    \\            for (self.parts.items) |part| {
    \\                if (std.mem.indexOf(u8, part.value, &boundary) != null) continue :choose;
    \\            }
    \\            break;
    \\        }
    \\
    \\        var out: std.Io.Writer.Allocating = .init(allocator);
    \\        errdefer out.deinit();
    \\        const w = &out.writer;
    \\        for (self.parts.items) |part| {
    \\            try w.print("--{s}\r\nContent-Disposition: form-data; name=\"", .{&boundary});
    \\            try writeFormName(w, part.name);
    \\            try w.writeByte('"');
    \\            if (part.filename) |filename| {
    \\                try w.writeAll("; filename=\"");
    \\                try writeFormName(w, filename);
    \\                try w.writeByte('"');
    \\            }
    \\            try w.writeAll("\r\n");
    \\            if (part.content_type) |content_type| try w.print("Content-Type: {s}\r\n", .{content_type});
    \\            try w.writeAll("\r\n");
    \\            try w.writeAll(part.value);
    \\            try w.writeAll("\r\n");
    \\        }
    \\        try w.print("--{s}--\r\n", .{&boundary});
    \\
    \\        const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{&boundary});
    \\        errdefer allocator.free(content_type);
    \\        return .{ .body = try out.toOwnedSlice(), .content_type = content_type };
    \\    }
    \\
    \\    /// A name or filename inside the quotes of a Content-Disposition, with
    \\    /// the three bytes that cannot appear there percent-encoded, as browsers
    \\    /// encode them.
    \\    fn writeFormName(w: *std.Io.Writer, text: []const u8) !void {
    \\        for (text) |c| switch (c) {
    \\            '"' => try w.writeAll("%22"),
    \\            '\r' => try w.writeAll("%0D"),
    \\            '\n' => try w.writeAll("%0A"),
    \\            else => try w.writeByte(c),
    \\        };
    \\    }
    \\};
    \\
    \\pub const ParseErrorResponse = struct {
    \\    raw: RawResponse,
    \\    error_name: []const u8,
    \\};
    \\
    \\pub fn ApiResult(comptime T: type) type {
    \\    return union(enum) {
    \\        ok: Owned(T),
    \\        api_error: RawResponse,
    \\        parse_error: ParseErrorResponse,
    \\
    \\        pub fn deinit(self: *@This()) void {
    \\            switch (self.*) {
    \\                .ok => |*value| value.deinit(),
    \\                .api_error => |*value| value.deinit(),
    \\                .parse_error => |*value| value.raw.deinit(),
    \\            }
    \\        }
    \\    };
    \\}
    \\
;
