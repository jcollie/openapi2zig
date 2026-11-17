const std = @import("std");

pub fn createTestAllocator() std.heap.DebugAllocator(.{}) {
    return std.heap.DebugAllocator(.{}){};
}

/// Wraps an allocator so that memory is never resized in place: every
/// `resize` or `remap` that would change a block's size is refused, and the
/// caller falls back to allocating a new block and copying.
///
/// `std.testing.checkAllAllocationFailures` needs the number of allocations to
/// be the same on every run. Whether a backing allocator can grow a block in
/// place depends on what happens to sit after it, so a growing buffer costs one
/// allocation on one run and none on the next, and the check reports
/// `error.NondeterministicMemoryUsage`. Refusing growth makes the count a
/// function of the code under test alone.
pub const NoGrowAllocator = struct {
    backing: std.mem.Allocator,

    pub fn allocator(self: *NoGrowAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoGrowAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    // Shrinking is refused too. Whether the backing allocator can shrink in
    // place depends on where the memory happens to lie, and a refused shrink
    // is answered with a fresh allocation, so passing shrinks through made
    // the number of allocations differ from run to run once an output grew
    // large enough -- which `checkAllAllocationFailures` reports as
    // nondeterministic memory use.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        _ = .{ ctx, alignment, ra };
        return new_len == memory.len;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        _ = .{ ctx, alignment, ra };
        return if (new_len == memory.len) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoGrowAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};
