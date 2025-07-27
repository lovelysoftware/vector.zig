const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const sift = @import("sift.zig");

/// SIMD-optimized implementation of squared Euclidean distance.
/// Asserts that the two slices are of equal length.
pub fn euclideanSquared(a: []const f32, b: []const f32) f32 {
    @setFloatMode(.optimized);
    assert(a.len == b.len);
    var sum: f32 = 0;
    var a_mut = a;
    var b_mut = b;
    if (std.simd.suggestVectorLength(f32)) |vl| {
        const rounds = a_mut.len / vl;
        for (0..rounds) |_| {
            const a_vec: @Vector(vl, f32) = a_mut[0..vl].*;
            const b_vec: @Vector(vl, f32) = b_mut[0..vl].*;
            const diff = a_vec - b_vec;
            sum += @reduce(.Add, diff * diff);
            a_mut = a_mut[vl..];
            b_mut = b_mut[vl..];
        }
    }
    for (a_mut, b_mut) |a_i, b_i| {
        const diff = a_i - b_i;
        sum += diff * diff;
    }
    return sum;
}

test "euclidean distance" {
    const dims: usize = 150;
    var a: [dims]f32 = undefined;
    var b: [dims]f32 = undefined;
    for (0..dims) |i| {
        a[i] = @floatFromInt(i);
        b[i] = @floatFromInt(i + 1);
    }
    const distance = euclideanSquared(&a, &b);
    try testing.expectApproxEqRel(
        @as(f32, @floatFromInt(dims)),
        distance,
        std.math.floatEps(f32),
    );
}

/// Simple Max-Heap implementation for maintaining a set of the top-k elements.
pub fn TopK(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            distance: f32,
            value: T,
        };

        const QueueType = std.PriorityQueue(Item, void, compareFn);

        fn compareFn(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(b.distance, a.distance);
        }

        maxq: QueueType,
        k: usize,

        /// Creates a new TopK heap that can hold up to `k` elements.
        pub fn init(gpa: std.mem.Allocator, k: usize) !Self {
            assert(k > 0);
            var maxq = QueueType.init(gpa, {});
            errdefer maxq.deinit();
            try maxq.ensureTotalCapacity(k);
            return .{ .maxq = maxq, .k = k };
        }

        pub fn deinit(self: *Self) void {
            self.maxq.deinit();
            self.* = undefined;
        }

        /// Pushes a new value to the heap, maintaining the top-k elements.
        /// Returns true if the value was added to the heap, false if it didn't change the heap.
        pub fn push(self: *Self, value: T, distance: f32) bool {
            if (self.maxq.count() < self.k) {
                self.maxq.add(.{ .value = value, .distance = distance }) catch unreachable;
                return true;
            }
            const elem = self.maxq.peek() orelse unreachable;
            if (distance < elem.distance) {
                _ = self.maxq.remove();
                self.maxq.add(.{ .value = value, .distance = distance }) catch unreachable;
                return true;
            }
            return false;
        }

        /// Removes the largest item (by distance) from the heap.
        pub fn popLargest(self: *Self) ?Item {
            return self.maxq.removeOrNull();
        }

        /// Drains the heap into a slice, ordered by distance ascending.
        pub fn drainIntoSlice(self: *Self, slice: []Item) []const Item {
            const c = self.maxq.count();
            assert(slice.len >= c);
            var r = c;
            while (r > 0) : (r -= 1) {
                slice[r - 1] = self.maxq.remove();
            }
            assert(self.maxq.count() == 0);
            return slice[0..c];
        }

        /// Same as `drainIntoSlice`, but allocates the slice using the provided allocator.
        /// Caller is responsible for deallocating the slice.
        fn drainIntoSliceAlloc(self: *Self, gpa: std.mem.Allocator) ![]Item {
            const slice = try gpa.alloc(Item, self.maxq.count());
            return self.drainIntoSlice(slice);
        }
    };
}

test "topk heap" {
    const allocator = testing.allocator;
    const HeapType = TopK(i32);
    var topk_heap = try HeapType.init(allocator, 3);
    defer topk_heap.deinit();

    _ = topk_heap.push(0, 0.5);
    _ = topk_heap.push(1, 0.4);
    _ = topk_heap.push(2, 0.6);
    _ = topk_heap.push(3, 0.3);
    _ = topk_heap.push(4, 0.7);
    _ = topk_heap.push(5, 0.2);
    _ = topk_heap.push(6, 0.8);
    _ = topk_heap.push(7, 0.1);
    _ = topk_heap.push(8, 0.9);
    _ = topk_heap.push(9, 0.0);
    _ = topk_heap.push(10, 1.0);

    const largest = topk_heap.popLargest();
    try testing.expectEqual(5, largest.?.value);

    const slice = try topk_heap.drainIntoSliceAlloc(allocator);
    defer allocator.free(slice);

    try testing.expectEqualSlices(
        HeapType.Item,
        &.{
            .{ .value = 9, .distance = 0.0 },
            .{ .value = 7, .distance = 0.1 },
        },
        slice,
    );
}

/// Performs exhaustive search on a set of vectors.
fn exhaustiveSearch(vectors: *const sift.FVecs, heap: *TopK(i32), query: []const f32) void {
    var it = vectors.iterator();
    var i: i32 = 0;
    while (it.next()) |v| : (i += 1) {
        const dist = euclideanSquared(query, v);
        _ = heap.push(i, dist);
    }
}

/// Computes the recall of a top-k heap against a ground truth set.
fn siftRecall(gpa: std.mem.Allocator, groundtruth: []const i32, topk_heap: *TopK(i32)) !f32 {
    assert(topk_heap.k <= groundtruth.len);
    var gt_set = std.AutoHashMap(i32, void).init(gpa);
    defer gt_set.deinit();
    for (groundtruth) |gt| {
        try gt_set.putNoClobber(gt, {});
    }
    var overlaps: usize = 0;
    while (topk_heap.popLargest()) |qr| {
        if (gt_set.contains(qr.value)) overlaps += 1;
    }
    return @as(f32, @floatFromInt(overlaps)) / @as(f32, @floatFromInt(gt_set.count()));
}

test "exhaustive search recall" {
    const allocator = testing.allocator;

    var queries = try sift.FVecs.loadFile("sift_data/siftsmall/siftsmall_query.fvecs");
    defer queries.deinit();

    var vectors = try sift.FVecs.loadFile("sift_data/siftsmall/siftsmall_base.fvecs");
    defer vectors.deinit();

    var groundtruth = try sift.IVecs.loadFile("sift_data/siftsmall/siftsmall_groundtruth.ivecs");
    defer groundtruth.deinit();

    const topk = blk: {
        var it = groundtruth.iterator();
        const first = it.next() orelse unreachable;
        break :blk first.len;
    };
    try testing.expectEqual(100, topk);

    const HeapType = TopK(i32);
    var topk_heap = try HeapType.init(allocator, topk);
    defer topk_heap.deinit();

    var queries_it = queries.iterator();
    var groundtruth_it = groundtruth.iterator();

    while (queries_it.next()) |q| {
        const gt = groundtruth_it.next() orelse unreachable;
        exhaustiveSearch(&vectors, &topk_heap, q);
        const recall = try siftRecall(allocator, gt, &topk_heap);
        try testing.expectApproxEqRel(1.0, recall, std.math.floatEps(f32));
    }
}
