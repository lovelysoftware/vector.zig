const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

/// A set of vectors, MMAP'ed from disk.
/// Supports the SIFT file format. For more information,
/// see: http://corpus-texmex.irisa.fr/.
fn Vectors(comptime datatype: enum { float, int }) type {
    return struct {
        const Self = @This();

        file: std.fs.File,
        contents: []align(std.heap.page_size_min) u8,

        fn loadFile(path: []const u8) !Self {
            const ext = std.fs.path.extension(path);
            if (!std.mem.eql(u8, expectedFileExt(), ext)) {
                return error.UnexpectedFileExtension;
            }

            const f = try std.fs.cwd().openFile(path, .{});
            errdefer f.close();

            const stat = try f.stat();
            const ptr = try std.posix.mmap(
                null,
                @intCast(stat.size),
                std.posix.PROT.READ, // Read-only access
                .{ .TYPE = .SHARED },
                f.handle,
                0,
            );
            errdefer std.posix.munmap(ptr);

            return .{
                .file = f,
                .contents = ptr,
            };
        }

        fn deinit(self: *Self) void {
            std.posix.munmap(self.contents);
            self.file.close();
            self.* = undefined;
        }

        fn expectedFileExt() []const u8 {
            return switch (datatype) {
                .float => ".fvecs",
                .int => ".ivecs",
            };
        }

        fn iterator(self: *const Self) Iterator {
            return .{
                .vectors = self,
                .offset = 0,
            };
        }

        const Iterator = struct {
            vectors: *const Self,
            offset: usize,

            fn next(self: *Iterator) ?vectorType() {
                const contents = self.vectors.contents;
                if (self.offset >= contents.len) {
                    return null;
                }

                const dims = @as(usize, @intCast(decodeInt(
                    contents[self.offset .. self.offset + 4],
                )));
                self.offset += 4;

                const vector_num_bytes = 4 * dims;
                const vector_end = self.offset + vector_num_bytes;
                const vector_bytes = contents[self.offset..vector_end];
                const vector = switch (datatype) {
                    .float => @as([]const f32, @alignCast(
                        std.mem.bytesAsSlice(f32, vector_bytes),
                    )),
                    .int => @as([]const i32, @alignCast(
                        std.mem.bytesAsSlice(i32, vector_bytes),
                    )),
                };
                self.offset += vector_num_bytes;

                return vector;
            }

            fn vectorType() type {
                return switch (datatype) {
                    .float => []const f32,
                    .int => []const i32,
                };
            }

            fn decodeInt(bytes: []const u8) i32 {
                assert(bytes.len == 4);
                const arr = @as(*const [4]u8, @ptrCast(bytes.ptr));
                return std.mem.readInt(i32, arr, .little);
            }
        };
    };
}

/// Helper type for parsing .fvecs files.
const FVecs = Vectors(.float);

/// Helper type for parsing .ivecs files.
const IVecs = Vectors(.int);

test "load .fvecs file" {
    const path = "sift_data/siftsmall/siftsmall_base.fvecs";
    var vectors = try FVecs.loadFile(path);
    defer vectors.deinit();

    var iter = vectors.iterator();
    var n: usize = 0;
    var dims: ?usize = null;
    while (iter.next()) |vector| {
        if (dims) |d| {
            try testing.expectEqual(d, vector.len);
        } else {
            dims = vector.len;
        }
        n += 1;
    }
    try testing.expectEqual(128, dims.?);
    try testing.expectEqual(10_000, n);
}

test "load .ivecs file" {
    const path = "sift_data/siftsmall/siftsmall_groundtruth.ivecs";
    var vectors = try IVecs.loadFile(path);
    defer vectors.deinit();

    var iter = vectors.iterator();
    var n: usize = 0;
    var dims: ?usize = null;
    while (iter.next()) |vector| {
        if (dims) |d| {
            try testing.expectEqual(d, vector.len);
        } else {
            dims = vector.len;
        }
        n += 1;
    }
    try testing.expectEqual(100, dims.?);
    try testing.expectEqual(100, n);
}
