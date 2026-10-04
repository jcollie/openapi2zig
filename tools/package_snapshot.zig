//! Copies the files that make up the openapi2zig package into a directory of
//! their own, so that `examples/package_consumer` can be built against the
//! package as a dependent would see it rather than against the working tree.
//!
//! Usage: package_snapshot <output directory>
//!
//! Run from the repository root. The file list comes from `git ls-files`, so
//! untracked files are included unless ignored, and nothing ignored is.

const std = @import("std");

const package_paths = [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "src",
    "resources",
    "tools",
    "openapi",
    "generated",
    "vendor/zig-yaml",
    "LICENSE",
    "README.md",
    "examples/package_consumer",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const output_dir = args.next() orelse {
        std.log.err("usage: package_snapshot <output directory>", .{});
        return error.InvalidArguments;
    };

    const argv = [_][]const u8{ "git", "ls-files", "--cached", "--others", "--exclude-standard", "--" } ++ package_paths;
    const result = try std.process.run(arena, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("git ls-files exited with code {d}: {s}", .{ code, result.stderr });
            return error.GitFailed;
        },
        else => {
            std.log.err("git ls-files terminated abnormally: {s}", .{result.stderr});
            return error.GitFailed;
        },
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, output_dir);
    var out = try cwd.createDirPathOpen(io, output_dir, .{});
    defer out.close(io);

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const repo_path = std.mem.trimEnd(u8, line, "\r");
        if (repo_path.len == 0) continue;
        if (std.fs.path.dirname(repo_path)) |dir| try out.createDirPath(io, dir);
        try cwd.copyFile(repo_path, out, repo_path, io, .{});
    }
}
