const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const gc = @cImport({
    @cInclude("gc.h");
});

/// Returns the Allocator used for APIs in Zig
pub fn allocator() Allocator {
    // Initialize libgc
    if (gc.GC_is_init_called() == 0) {
        gc.GC_init();
    }

    return Allocator{
        .ptr = undefined,
        .vtable = &gc_allocator_vtable,
    };
}

/// Returns the current heap size of used memory.
pub fn getHeapSize() u64 {
    return gc.GC_get_heap_size();
}

/// Disable garbage collection.
pub fn disable() void {
    gc.GC_disable();
}

/// Enables garbage collection. GC is enabled by default so this is
/// only useful if you called disable earlier.
pub fn enable() void {
    gc.GC_enable();
}

// Performs a full, stop-the-world garbage collection. With leak detection
// enabled this will output any leaks as well.
pub fn collect() void {
    gc.GC_gcollect();
}

/// Perform some garbage collection. Returns zero when work is done.
pub fn collectLittle() u8 {
    return @intCast(u8, gc.GC_collect_a_little());
}

/// Enables leak-finding mode. See the libgc docs for more details.
pub fn setFindLeak(v: bool) void {
    return gc.GC_set_find_leak(@boolToInt(v));
}

// TODO(mitchellh): there are so many more functions to add here
// from gc.h, just add em as they're useful.

/// GcAllocator is an implementation of std.mem.Allocator that uses
/// libgc under the covers. This means that all memory allocated with
/// this allocated doesn't need to be explicitly freed (but can be).
///
/// The GC is a singleton that is globally shared. Multiple GcAllocators
/// do not allocate separate pages of memory; they share the same underlying
/// pages.
///
// NOTE(mitchellh): this is basically just a copy of the standard CAllocator
// since libgc has a malloc/free-style interface. There are very slight differences
// due to API differences but overall the same.
pub const GcAllocator = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: u29,
        len_align: u29,
        return_address: usize,
    ) error{OutOfMemory}![]u8 {
        _ = return_address;
        assert(len > 0);
        assert(std.math.isPowerOfTwo(alignment));

        var ptr = alignedAlloc(len, alignment) orelse return error.OutOfMemory;
        if (len_align == 0) {
            return ptr[0..len];
        }

        const full_len = init: {
            const s = alignedAllocSize(ptr);
            assert(s >= len);
            break :init s;
        };

        return ptr[0..mem.alignBackwardAnyAlign(full_len, len_align)];
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        buf_align: u29,
        new_len: usize,
        len_align: u29,
        return_address: usize,
    ) ?usize {
        _ = buf_align;
        _ = return_address;
        if (new_len <= buf.len) {
            return mem.alignAllocLen(buf.len, new_len, len_align);
        }

        const full_len = alignedAllocSize(buf.ptr);
        if (new_len <= full_len) {
            return mem.alignAllocLen(full_len, new_len, len_align);
        }

        return null;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        buf_align: u29,
        return_address: usize,
    ) void {
        _ = buf_align;
        _ = return_address;
        alignedFree(buf.ptr);
    }

    fn getHeader(ptr: [*]u8) *[*]u8 {
        return @intToPtr(*[*]u8, @ptrToInt(ptr) - @sizeOf(usize));
    }

    fn alignedAlloc(len: usize, alignment: usize) ?[*]u8 {
        // Thin wrapper around regular malloc, overallocate to account for
        // alignment padding and store the orignal malloc()'ed pointer before
        // the aligned address.
        var unaligned_ptr = @ptrCast([*]u8, gc.GC_malloc(len + alignment - 1 + @sizeOf(usize)) orelse return null);
        const unaligned_addr = @ptrToInt(unaligned_ptr);
        const aligned_addr = mem.alignForward(unaligned_addr + @sizeOf(usize), alignment);
        var aligned_ptr = unaligned_ptr + (aligned_addr - unaligned_addr);
        getHeader(aligned_ptr).* = unaligned_ptr;

        return aligned_ptr;
    }

    fn alignedFree(ptr: [*]u8) void {
        const unaligned_ptr = getHeader(ptr).*;
        gc.GC_free(unaligned_ptr);
    }

    fn alignedAllocSize(ptr: [*]u8) usize {
        const unaligned_ptr = getHeader(ptr).*;
        const delta = @ptrToInt(ptr) - @ptrToInt(unaligned_ptr);
        return gc.GC_size(unaligned_ptr) - delta;
    }
};

const gc_allocator_vtable = Allocator.VTable{
    .alloc = GcAllocator.alloc,
    .resize = GcAllocator.resize,
    .free = GcAllocator.free,
};

test "GcAllocator" {
    const alloc = allocator();

    try std.heap.testAllocator(alloc);
    try std.heap.testAllocatorAligned(alloc);
    try std.heap.testAllocatorLargeAlignment(alloc);
    try std.heap.testAllocatorAlignedShrink(alloc);
}

test "heap size" {
    // No garbage so should be 0
    try testing.expect(collectLittle() == 0);

    // Force a collection should work
    collect();

    try testing.expect(getHeapSize() > 0);
}
