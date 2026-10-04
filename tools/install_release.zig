//! Installs a built executable outside the build's install prefix: into the
//! prefix when one was given with `--prefix`, and otherwise into
//! `$INSTALL_DIR`, or `~/.local/bin` when that is not set.
//!
//! Usage: install_release <executable> <install prefix> <build.zig>
//!
//! The prefix counts as given when it is anything other than `zig-out` beside
//! `build.zig`, which is where `zig build` installs by default.
//!
//! The environment is read here rather than in build.zig because the build
//! configuration is cached, and a value read while configuring would go stale
//! without anything noticing.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const source = args.next() orelse return usage();
    const install_prefix = args.next() orelse return usage();
    const build_zig = args.next() orelse return usage();
    const build_root = std.fs.path.dirname(build_zig) orelse ".";
    const default_prefix = try std.fs.path.join(arena, &.{ build_root, "zig-out" });

    const dest_dir = try installDir(arena, init.environ_map, install_prefix, default_prefix);
    const dest_name = std.fs.path.basename(source);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest_dir);
    var dest = try cwd.openDir(io, dest_dir, .{});
    defer dest.close(io);
    _ = try cwd.updateFile(io, source, dest, dest_name, .{});

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("installed {s} to {s}\n", .{ dest_name, dest_dir });
    try stdout.interface.flush();
}

fn installDir(
    arena: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    install_prefix: []const u8,
    default_prefix: []const u8,
) ![]const u8 {
    if (!std.mem.eql(u8, install_prefix, default_prefix)) return install_prefix;

    if (environ.get("INSTALL_DIR")) |dir| {
        if (dir.len > 0) return dir;
    }
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |name| {
        if (environ.get(name)) |home| {
            if (home.len > 0) return std.fs.path.join(arena, &.{ home, ".local", "bin" });
        }
    }

    std.log.err("unable to determine install directory: set HOME, USERPROFILE, or INSTALL_DIR", .{});
    return error.NoInstallDir;
}

fn usage() error{InvalidArguments} {
    std.log.err("usage: install_release <executable> <install prefix> <build.zig>", .{});
    return error.InvalidArguments;
}
