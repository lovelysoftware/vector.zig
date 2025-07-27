const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const vector = @import("vector");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

// Helper type for keeping track of the top-k elements.
const TopKHeap = vector.distance.TopK(i64);

comptime {
    if (builtin.target.os.tag != .macos) {
        @compileError("imessage example only works on macOS");
    }
}

// Want info logs to show up on Release builds too (not default behavior).
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
};

// Terminal escape codes
const clear_screen = "\x1b[2J";
const move_to_top = "\x1b[H";
const clear_line = "\x1b[K";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const next_line = "\x1b[E";

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    // Shamelessly stolen from the Zig compiler's main.zig.
    // Use the c_allocator if available, otherwise use a debug allocator.
    const gpa, const is_debug = gpa: {
        if (builtin.link_libc) {
            if (@alignOf(std.c.max_align_t) < @max(@alignOf(i128), std.atomic.cache_line)) {
                break :gpa .{ std.heap.c_allocator, false };
            }
            break :gpa .{ std.heap.raw_c_allocator, false };
        }
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // TODO allow user to pass in argument for maximum number of messages to index
    // TODO also allow configurable topk for queries

    // If the user compiled the code in debug mode, warn them.
    switch (builtin.mode) {
        .Debug => {
            std.log.warn("debug mode is enabled", .{});
            std.log.warn("passing -Doptimize=ReleaseFast is recommended for this example", .{});
        },
        else => {},
    }

    const sqlite_path = try dbPath(gpa);
    std.log.info("opening imessage database at {s}", .{sqlite_path});

    // Open the SQLite database regardless of whether the index exists.
    // We'll use it to a) create the index if it doesn't exist, or b) lookup
    // messages by ID when printing search results.
    const db = try openDB(sqlite_path);
    defer closeDB(db);
    std.log.info("successfully opened imessage database", .{});

    var embedder = try Embedder.init(gpa);
    defer embedder.deinit(gpa);

    const index_path = "imessage_index";
    var index = Index.loadFromFilePath(index_path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            std.log.info("no index found, creating new one", .{});
            var messages = try MessagesIterator.init(db);
            defer messages.deinit();
            break :blk try Index.createFromMessages(&messages, &embedder, index_path, .exhaustive);
        },
        else => return err,
    };
    defer index.deinit();
    std.log.info("index loaded (kind: {s})", .{index.kind()});

    const topk = 10; // Number of results to return
    var topk_heap = try TopKHeap.init(gpa, topk);
    defer topk_heap.deinit();

    const results_buffer = try gpa.alloc(TopKHeap.Item, topk);
    defer gpa.free(results_buffer);

    // For looking up message text by ID.
    var message_lookup = try MessageLookup.init(gpa, db);
    defer message_lookup.deinit();

    var stdin = std.io.getStdIn();
    var stdout = std.io.getStdOut();

    // Enter raw mode to read input.
    const original_termios = try setRawMode(stdin.handle);
    defer std.posix.tcsetattr(stdin.handle, .NOW, original_termios) catch {};

    try stdout.writeAll(hide_cursor);
    defer stdout.writeAll(show_cursor) catch {};

    var query_buf: [256]u8 = undefined;
    var query_len: usize = 0;
    while (true) {
        try std.fmt.format(
            stdout.writer(),
            "{s}{s}Search: {s}{s}\n",
            .{ clear_screen, move_to_top, query_buf[0..query_len], clear_line },
        );

        if (query_len > 0) {
            const query = query_buf[0..query_len];
            var timer = std.time.Timer.start() catch unreachable;

            const embedding = try embedder.embedText(query);
            const embedding_took_ns = timer.lap();

            index.searchTopK(&topk_heap, embedding);
            const search_took_ns = timer.lap();

            const results = topk_heap.drainIntoSlice(results_buffer);
            try std.fmt.format(
                stdout.writer(),
                "{s}Found {} results (embed took {}, search took {})",
                .{ next_line, results.len, std.fmt.fmtDuration(embedding_took_ns), std.fmt.fmtDuration(search_took_ns) },
            );
            for (results) |result| {
                const text = (try message_lookup.lookup(result.value)) orelse "unknown";
                try std.fmt.format(
                    stdout.writer(),
                    "{s}  {} (dist={d:.3}): {s}",
                    .{ next_line, result.value, result.distance, text[0..@min(80, text.len)] },
                );
            }
        }

        var char: [1]u8 = undefined;
        _ = try stdin.read(&char);

        switch (char[0]) {
            27 => break, // ESC key
            127, 8 => { // Backspace
                if (query_len > 0) query_len -= 1;
            },
            '\r', '\n' => {}, // Ignore enter
            32...126 => { // Printable characters
                if (query_len < query_buf.len - 1) {
                    query_buf[query_len] = char[0];
                    query_len += 1;
                }
            },
            else => {}, // Ignore other control characters
        }
    }

    try stdout.writeAll(clear_screen ++ move_to_top ++ show_cursor);
}

// TODO better understand the options here, lot of claude noise
fn setRawMode(handle: std.posix.fd_t) !std.posix.termios {
    const original = try std.posix.tcgetattr(handle);
    var termios = original;
    // Input flags - disable preprocessing
    termios.iflag.BRKINT = false; // No break signal
    termios.iflag.ICRNL = false; // No CR to NL translation
    termios.iflag.INPCK = false; // No parity check
    termios.iflag.ISTRIP = false; // Don't strip 8th bit
    termios.iflag.IXON = false; // No XON/XOFF flow control

    // Output flags - raw output
    termios.oflag.OPOST = false; // No output processing

    // Control flags - 8 bit chars
    termios.cflag.CSIZE = .CS8; // 8-bit characters
    termios.cflag.PARENB = false; // No parity

    // Local flags - disable canonical mode and echo
    termios.lflag.ECHO = false; // No echo
    termios.lflag.ECHONL = false; // No echo newline
    termios.lflag.ICANON = false; // No canonical mode
    termios.lflag.IEXTEN = false; // No extended processing
    termios.lflag.ISIG = false; // No signal chars
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(handle, .NOW, termios);
    return original;
}

// An index of vectors, and their IDs.
// TODO move more of this into the vector library.
const Index = struct {
    file: std.fs.File,
    contents: []align(std.heap.page_size_min) u8,
    impl: Impl,

    // Load the index from a file. Will return error.FileNotFound if the file does not exist.
    fn loadFromFilePath(path: []const u8) !Index {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();
        return try loadFromFile(file, null); // Don't know size yet, need stat.
    }

    /// Loads the index from a file, taking ownership of said file.
    /// On deinit, the file will be closed and the memory unmapped.
    fn loadFromFile(file: std.fs.File, knownSize: ?u64) !Index {
        const file_size: u64 = if (knownSize) |s| s else blk: {
            const stat = try file.stat();
            break :blk stat.size;
        };
        const ptr = try std.posix.mmap(
            null,
            @intCast(file_size),
            std.posix.PROT.READ, // Read-only access
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(ptr);

        const impl: Impl = blk: {
            const impl_num = readInt(u32, ptr[0..4]);
            break :blk @enumFromInt(impl_num);
        };
        switch (impl) {
            .exhaustive => {},
            else => return error.UnexpectedIndexImpl,
        }

        return .{
            .file = file,
            .contents = ptr,
            .impl = impl,
        };
    }

    // Creates a new index from a given iMessage iterator.
    fn createFromMessages(
        messages: *MessagesIterator,
        embedder: *Embedder,
        path: []const u8,
        impl: Impl,
    ) !Index {
        return switch (impl) {
            .exhaustive => createExhaustiveIndex(messages, embedder, path),
            else => return error.UnexpectedIndexImpl,
        };
    }

    // Creates a new exhaustive index from a set of messages.
    fn createExhaustiveIndex(
        messages: *MessagesIterator,
        embedder: *Embedder,
        path: []const u8,
    ) !Index {
        const f = try std.fs.cwd().createFile(path, .{});
        errdefer {
            f.close();
            std.fs.cwd().deleteFile(path) catch |err| {
                std.log.err(
                    "failed to delete partially created index file (path={s}): {}",
                    .{ path, err },
                );
            };
        }
        var buffered_writer = std.io.bufferedWriter(f.writer()); // Lot of tiny writes
        const writer = buffered_writer.writer();

        std.log.info("creating exhaustive index... (this might take a while)", .{});

        // For logging, keep track of how long this takes.
        var start = std.time.Timer.start() catch unreachable;

        var file_size: u64 = 0;

        // Write the implementation type at the start of the file.
        // Not needed now, but useful for future extensibility.
        try writeInt(u32, writer, @intFromEnum(Impl.exhaustive));
        file_size += @sizeOf(u32);

        // Not the best way to lay this file out, but makes things simple.
        // We'll write a `<rowid><embedding>` pair for each message.
        // TODO multi-threading for faster index builds
        var count: u64 = 0;
        while (try messages.next()) |msg| {
            const embedding = embedder.embedText(msg.text) catch {
                std.log.warn("embedding failed for message '{s}', skipping", .{msg.text});
                continue;
            };
            try writeInt(i64, writer, msg.id);
            try writeFloats(writer, embedding);
            count += 1;
            file_size += @sizeOf(i64) + @sizeOf(f32) * embedding.len;
            if (count % 10_000 == 0) {
                std.log.info("embedded {d} messages so far...", .{count});
            }
        }

        // We're finished; flush everything.
        try buffered_writer.flush();
        try f.sync();

        const took_ns = start.read();
        std.log.info(
            "created exhaustive index with {d} messages in {s}, wrote {}",
            .{
                count,
                std.fmt.fmtDuration(took_ns),
                std.fmt.fmtIntSizeBin(file_size),
            },
        );

        // TODO can we MMAP without closing + re-opening the file?
        // Can use loadFromFile directly?
        f.close();
        return try loadFromFilePath(path);
    }

    // Writes an integer to the writer in little-endian format.
    fn writeInt(comptime T: type, writer: anytype, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try writer.writeAll(&buf);
    }

    // Reads an integer from a slice in little-endian format.
    fn readInt(comptime T: type, slice: []const u8) T {
        assert(slice.len >= @sizeOf(T));
        const arr = @as(*const [@sizeOf(T)]u8, @ptrCast(slice.ptr));
        return std.mem.readInt(T, arr, .little);
    }

    // Writes a series of floats to the writer.
    fn writeFloats(writer: anytype, floats: []const f32) !void {
        const bytes = std.mem.sliceAsBytes(floats);
        try writer.writeAll(bytes);
    }

    // Reads a series of floats from a slice.
    fn readFloats(slice: []const u8) []const f32 {
        assert(slice.len % @sizeOf(f32) == 0);
        return @alignCast(std.mem.bytesAsSlice(f32, slice));
    }

    // Deinitialize the index, freeing any resources.
    fn deinit(self: *Index) void {
        std.posix.munmap(self.contents);
        self.file.close();
        self.* = undefined;
    }

    // Returns the kind of index this is.
    fn kind(self: *const Index) []const u8 {
        return switch (self.impl) {
            .exhaustive => "exhaustive",
            else => unreachable,
        };
    }

    // Search for the top-k closest vectors to a given vector.
    fn searchTopK(
        self: *const Index,
        topk_heap: *TopKHeap,
        query_vector: []const f32,
    ) void {
        const dims = query_vector.len;
        switch (self.impl) {
            .exhaustive => {
                var remaining = self.contents[@sizeOf(u32)..];
                while (remaining.len > 0) {
                    const id = readInt(i64, remaining[0..@sizeOf(i64)]);
                    remaining = remaining[@sizeOf(i64)..];

                    const vec = readFloats(remaining[0 .. dims * @sizeOf(f32)]);
                    remaining = @alignCast(remaining[dims * @sizeOf(f32) ..]);

                    const dist = vector.distance.euclideanSquared(query_vector, vec);
                    _ = topk_heap.push(id, dist);
                }
            },
            else => unreachable,
        }
    }

    // Stored at the start of the index file.
    const Impl = enum(u32) {
        exhaustive = 0xbcb30196, // sha1sum of "exhaustive",
        _,
    };
};

// An iterator for iterating over messages in the iMessage database.
const MessagesIterator = struct {
    stmt: ?*sqlite.sqlite3_stmt,

    fn init(db: ?*sqlite.sqlite3) !MessagesIterator {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.sqlite3_prepare_v2(db, query, query.len + 1, &stmt, null);
        if (rc != sqlite.SQLITE_OK) {
            std.log.err("sqlite error preparing statement: {s}", .{sqlite.sqlite3_errstr(rc)});
            return error.PrepareStatement;
        }
        return .{ .stmt = stmt };
    }

    fn deinit(self: *MessagesIterator) void {
        const rc = sqlite.sqlite3_finalize(self.stmt);
        if (rc != sqlite.SQLITE_OK) {
            std.log.warn("sqlite error finalizing statement: {s}", .{sqlite.sqlite3_errstr(rc)});
        }
        self.* = undefined;
    }

    const Message = struct {
        id: i64,
        text: []const u8,
    };

    // Returns the next message in the iterator, or null if there are no more messages.
    fn next(self: *MessagesIterator) !?Message {
        while (true) {
            const rc = sqlite.sqlite3_step(self.stmt);
            switch (rc) {
                sqlite.SQLITE_ROW => {},
                sqlite.SQLITE_DONE => return null,
                else => {
                    std.log.err("sqlite error stepping statement: {s}", .{sqlite.sqlite3_errstr(rc)});
                    return error.StepStatement;
                },
            }
            const text = sqlite.sqlite3_column_text(self.stmt, 1) orelse continue;
            return .{
                .id = sqlite.sqlite3_column_int64(self.stmt, 0),
                .text = std.mem.span(text),
            };
        }
    }

    const query =
        \\ SELECT
        \\     m.rowid AS id,
        \\     m.text AS text
        \\ FROM message as m;
    ;
};

// Helper type for looking up message text by ID.
const MessageLookup = struct {
    stmt: ?*sqlite.sqlite3_stmt,
    buffer: std.ArrayList(u8),

    fn init(gpa: std.mem.Allocator, db: ?*sqlite.sqlite3) !MessageLookup {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.sqlite3_prepare_v2(db, message_lookup_query, message_lookup_query.len + 1, &stmt, null);
        if (rc != sqlite.SQLITE_OK) {
            std.log.err("sqlite error preparing lookup statement: {s}", .{sqlite.sqlite3_errstr(rc)});
            return error.PrepareStatement;
        }
        return .{ .stmt = stmt, .buffer = std.ArrayList(u8).init(gpa) };
    }

    fn deinit(self: *MessageLookup) void {
        const rc = sqlite.sqlite3_finalize(self.stmt);
        if (rc != sqlite.SQLITE_OK) {
            std.log.warn("sqlite error finalizing lookup statement: {s}", .{sqlite.sqlite3_errstr(rc)});
        }
        self.buffer.deinit();
        self.* = undefined;
    }

    // Looks up a message by ID, returning the text if found.
    fn lookup(self: *MessageLookup, id: i64) !?[]const u8 {
        var rc = sqlite.sqlite3_bind_int64(self.stmt, 1, id);
        if (rc != sqlite.SQLITE_OK) {
            std.log.err("sqlite error binding ID: {s}", .{sqlite.sqlite3_errstr(rc)});
            return error.BindParameter;
        }

        rc = sqlite.sqlite3_step(self.stmt);
        if (rc != sqlite.SQLITE_ROW) {
            std.log.err("sqlite error stepping statement: {s}", .{sqlite.sqlite3_errstr(rc)});
            return error.StepStatement;
        }

        const text = sqlite.sqlite3_column_text(self.stmt, 0);
        if (text == null) return null;

        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(std.mem.span(text));

        rc = sqlite.sqlite3_reset(self.stmt);
        if (rc != sqlite.SQLITE_OK) {
            std.log.err("sqlite error resetting statement: {s}", .{sqlite.sqlite3_errstr(rc)});
            return error.ResetStatement;
        }

        return self.buffer.items;
    }

    const message_lookup_query =
        \\ SELECT
        \\     m.text AS text
        \\ FROM message as m
        \\ WHERE m.rowid = ?;
    ;
};

/// Opens the SQLite database file for iMessage.
fn openDB(path: [:0]const u8) !?*sqlite.sqlite3 {
    var db_inst: ?*sqlite.sqlite3 = null;
    const rc = sqlite.sqlite3_open(path, &db_inst);
    if (rc != sqlite.SQLITE_OK) {
        if (rc == sqlite.SQLITE_CANTOPEN) {
            std.log.err("got sqlite SQLITE_CANTOPEN error", .{});
            std.log.err("likely missing full-disk access permissions", .{});
            std.log.err("Privacy & Security -> Full Disk Access -> Enable for your terminal", .{});
        }
        std.log.err(
            "sqlite error opening database at path {s}: {s}",
            .{ path, sqlite.sqlite3_errstr(rc) },
        );
        return error.SQLiteError;
    }
    return db_inst;
}

// Closes the SQLite database connection.
fn closeDB(db: ?*sqlite.sqlite3) void {
    const rc = sqlite.sqlite3_close(db);
    if (rc != sqlite.SQLITE_OK) {
        std.log.warn(
            "sqlite error closing database: {s}",
            .{sqlite.sqlite3_errstr(rc)},
        );
    }
}

/// Returns the path to the iMessage database on macOS.
/// This is typically located at "/Users/<username>/Library/Messages/chat.db".
fn dbPath(gpa: std.mem.Allocator) ![:0]const u8 {
    const uid = getuid();
    const username = user_from_uid(uid, 1) orelse {
        return error.UserNotFound;
    };
    return try std.fs.path.joinZ(
        gpa,
        &.{ "/Users", std.mem.span(username), "Library", "Messages", "chat.db" },
    );
}

// Some C functions for getting the current user ID and username.
extern "c" fn getuid() std.posix.uid_t;
extern "c" fn user_from_uid(uid: std.posix.uid_t, noname: c_int) ?[*:0]const u8;

// For calling Natural Language APIs.
// TODO might be able to do this w/o objc? But this is easy.
const objc = @import("objc");

/// Helper type for embedding text using the Natural Language framework.
const Embedder = struct {
    embed: objc.Object,
    buffer: []f32,

    fn init(gpa: std.mem.Allocator) !Embedder {
        const lang = try CFString.createWithBytes("en", .utf8, false);
        defer lang.release();

        const class = objc.getClass("NLEmbedding").?;
        const embed = class.msgSend(
            objc.Object,
            objc.sel("sentenceEmbeddingForLanguage:"),
            .{lang},
        );

        const dims = @as(usize, @intCast(embed.getProperty(c_int, "dimension")));
        return .{
            .embed = embed,
            .buffer = try gpa.alloc(f32, dims),
        };
    }

    fn deinit(self: *Embedder, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
        self.* = undefined;
    }

    // TODO re-use the CFString rather than re-allocating it each time
    // would maybe give a decent speedup for large embedding jobs
    fn embedText(self: *Embedder, text: []const u8) ![]const f32 {
        const str = try CFString.createWithBytes(text, .utf8, false);
        defer str.release();

        const res = self.embed.msgSend(
            bool,
            objc.sel("getVector:forString:"),
            .{ self.buffer.ptr, str },
        );
        if (!res) {
            return error.EmbeddingFailed;
        }

        return self.buffer;
    }
};

// Need to bring in foundation for the string type.
const foundation = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

// Wrapper around Foundation's CFString type.
// Credit: Mitchell Hashimoto (Ghostty) for the original implementation.
const CFString = opaque {
    fn createWithBytes(
        bs: []const u8,
        encoding: CFStringEncoding,
        external: bool,
    ) std.mem.Allocator.Error!*CFString {
        return @as(?*CFString, @ptrFromInt(@intFromPtr(foundation.CFStringCreateWithBytes(
            null,
            bs.ptr,
            @intCast(bs.len),
            @intFromEnum(encoding),
            @intFromBool(external),
        )))) orelse std.mem.Allocator.Error.OutOfMemory;
    }

    fn release(self: *CFString) void {
        foundation.CFRelease(self);
    }

    fn getLength(self: *CFString) usize {
        return @intCast(foundation.CFStringGetLength(@ptrCast(self)));
    }
};

// https://developer.apple.com/documentation/corefoundation/cfstringencoding?language=objc
const CFStringEncoding = enum(u32) {
    invalid = 0xffffffff,
    mac_roman = 0,
    windows_latin1 = 0x0500,
    iso_latin1 = 0x0201,
    nextstep_latin = 0x0B01,
    ascii = 0x0600,
    unicode = 0x0100,
    utf8 = 0x08000100,
    non_lossy_ascii = 0x0BFF,
    utf16_be = 0x10000100,
    utf16_le = 0x14000100,
    utf32 = 0x0c000100,
    utf32_be = 0x18000100,
    utf32_le = 0x1c000100,
};
