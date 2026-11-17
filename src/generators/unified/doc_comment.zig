const std = @import("std");

/// Writes `text` as a doc comment, one `///` line per line of it, each
/// preceded by `indent`. Descriptions arrive from the specification as
/// Markdown, so their tabs become spaces (Zig rejects a tab in a comment), and
/// a line left blank stays a bare `///` to keep paragraphs apart.
pub fn append(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: []const u8, text: []const u8) !void {
    const trimmed_text = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed_text.len == 0) return;
    var lines = std.mem.splitScalar(u8, trimmed_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        try buffer.appendSlice(allocator, indent);
        if (line.len == 0) {
            try buffer.appendSlice(allocator, "///\n");
            continue;
        }
        try buffer.appendSlice(allocator, "/// ");
        for (line) |c| try buffer.append(allocator, if (c == '\t') ' ' else c);
        try buffer.append(allocator, '\n');
    }
}

test append {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    try append(&buffer, std.testing.allocator, "    ", "First line.\r\n\n\tIndented  \n");
    try std.testing.expectEqualStrings(
        \\    /// First line.
        \\    ///
        \\    ///  Indented
        \\
    , buffer.items);

    buffer.clearRetainingCapacity();
    try append(&buffer, std.testing.allocator, "", "  \n ");
    try std.testing.expectEqualStrings("", buffer.items);
}
