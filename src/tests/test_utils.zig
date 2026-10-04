const std = @import("std");

pub fn createTestAllocator() std.heap.DebugAllocator(.{}) {
    return std.heap.DebugAllocator(.{}){};
}

/// Wraps an allocator so that memory is never grown in place: every `resize`
/// or `remap` that would make a block larger is refused, and the caller falls
/// back to allocating a new block and copying.
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

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *NoGrowAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) return false;
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *NoGrowAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoGrowAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};
