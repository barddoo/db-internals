//! Page-oriented backing store.
//!
//! FileDisk exposes five operations:
//!
//!   allocatePage() -> PageId
//!   deletePage(id)
//!   readPage(id, *[PAGE_SIZE]u8)
//!   writePage(id, *const [PAGE_SIZE]u8)
//!   pageCount() -> PageId
//!
//! An in-memory free list lets deleted page ids be reused by the next
//! allocatePage instead of always extending the file. The free list is
//! not persisted; orphaned pages after a crash are a known limitation.
//!
//! Direct I/O (FileOpenOptions.direct = true) bypasses the OS page cache.
//! On macOS this uses F_NOCACHE; on Linux F_SETFL + O_DIRECT.
//! Callers must pass buffers aligned to 4096 bytes — in BufferManager this is
//! NOT guaranteed: `Frame` is `PAGE_SIZE` bytes of data plus inline
//! bookkeeping, so `Frame.data` is only naturally aligned. The demo and the
//! buffer-manager tests therefore use `.direct = false`; the flag is exercised
//! at the FileDisk level, where the test buffers are explicitly `align(4096)`.

const std = @import("std");
const builtin = @import("builtin");
const page = @import("slotted_page.zig");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;

pub const PageId = u64;
pub const PAGE_SIZE = page.PAGE_SIZE;

pub const FileOpenOptions = struct {
    /// Truncate an existing file and start with zero pages.
    truncate: bool = false,
    /// Bypass the OS page cache. The database buffer pool is the only cache.
    /// Requires 4096-byte-aligned buffers on every read/write.
    direct: bool = false,
};

/// A disk backed by a real file. Pages are stored at `id * PAGE_SIZE`.
pub const FileDisk = struct {
    allocator: Allocator,
    io: Io,
    file: File,
    page_count: PageId = 0,
    free_pages: std.ArrayListUnmanaged(PageId) = .empty,

    pub fn open(
        allocator: Allocator,
        io: Io,
        dir: Dir,
        path: []const u8,
        options: FileOpenOptions,
    ) !FileDisk {
        const file = try dir.createFile(io, path, .{
            .read = true,
            .truncate = options.truncate,
        });
        errdefer file.close(io);

        if (options.direct) try applyDirectIo(file.handle);

        const stat = try file.stat(io);
        const count: PageId = @intCast(stat.size / @as(u64, PAGE_SIZE));

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .page_count = count,
        };
    }

    pub fn close(self: *FileDisk) void {
        // Free list is not persisted; orphaned pages survive only until reopen.
        self.free_pages.deinit(self.allocator);
        self.file.close(self.io);
    }

    /// Allocate a zero-filled page, reusing a freed id if one is available.
    pub fn allocatePage(self: *FileDisk) !PageId {
        if (self.free_pages.items.len > 0) {
            const id = self.free_pages.pop().?;
            const zero: [PAGE_SIZE]u8 = @splat(0);
            const offset = id * @as(u64, PAGE_SIZE);
            try self.file.writePositionalAll(self.io, zero[0..], offset);
            return id;
        }

        const id = self.page_count;
        const zero: [PAGE_SIZE]u8 = @splat(0);
        const offset = id * @as(u64, PAGE_SIZE);

        try self.file.writePositionalAll(self.io, zero[0..], offset);

        self.page_count += 1;
        return id;
    }

    /// Mark a page as free so its id can be reused by the next allocatePage.
    pub fn deletePage(self: *FileDisk, id: PageId) !void {
        if (id >= self.page_count) return error.InvalidPage;
        try self.free_pages.append(self.allocator, id);
    }

    pub fn readPage(self: *FileDisk, id: PageId, dest: *[PAGE_SIZE]u8) !void {
        if (id >= self.page_count) return error.InvalidPage;

        const offset = id * @as(u64, PAGE_SIZE);
        const n = try self.file.readPositionalAll(self.io, dest[0..], offset);

        // A short read means the file ended early; the rest is zero.
        if (n < PAGE_SIZE) @memset(dest[n..], 0);
    }

    pub fn writePage(self: *FileDisk, id: PageId, src: *const [PAGE_SIZE]u8) !void {
        if (id >= self.page_count) return error.InvalidPage;

        const offset = id * @as(u64, PAGE_SIZE);
        try self.file.writePositionalAll(self.io, src[0..], offset);
    }

    pub fn pageCount(self: *const FileDisk) PageId {
        return self.page_count;
    }
};

/// Set the OS cache-bypass flag on an already-open fd.
/// macOS: F_NOCACHE disables the unified buffer cache for this fd.
/// Linux: O_DIRECT is added to the open flags via F_SETFL.
fn applyDirectIo(fd: File.Handle) !void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // F_NOCACHE = 48 on Darwin; arg 1 means "don't cache".
            if (std.c.fcntl(fd, std.c.F.NOCACHE, @as(c_int, 1)) == -1)
                return error.Unexpected;
        },
        .linux => {
            // Read current flags then OR in O_DIRECT.
            const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            if (flags == -1) return error.Unexpected;
            // Build the new flags with DIRECT set.
            const current: std.c.O = @bitCast(@as(u32, @intCast(flags)));
            const updated: std.c.O = .{
                .ACCMODE = current.ACCMODE,
                .CREAT = current.CREAT,
                .EXCL = current.EXCL,
                .NOCTTY = current.NOCTTY,
                .TRUNC = current.TRUNC,
                .APPEND = current.APPEND,
                .NONBLOCK = current.NONBLOCK,
                .DSYNC = current.DSYNC,
                .DIRECT = true,
                .LARGEFILE = current.LARGEFILE,
                .DIRECTORY = current.DIRECTORY,
                .NOFOLLOW = current.NOFOLLOW,
                .NOATIME = current.NOATIME,
                .CLOEXEC = current.CLOEXEC,
                .SYNC = current.SYNC,
            };
            if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(updated))) == -1)
                return error.Unexpected;
        },
        else => return error.DirectIoNotSupported,
    }
}

test "file disk stores pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "pages.db",
        .{ .truncate = true },
    );
    defer disk.close();

    const a = try disk.allocatePage();
    const b = try disk.allocatePage();
    try std.testing.expectEqual(@as(PageId, 0), a);
    try std.testing.expectEqual(@as(PageId, 1), b);

    var page_a: [PAGE_SIZE]u8 = @splat(0);
    page_a[0] = 42;
    try disk.writePage(a, &page_a);

    var read_back: [PAGE_SIZE]u8 = @splat(0);
    try disk.readPage(b, &read_back);
    try std.testing.expectEqual(@as(u8, 0), read_back[0]);

    try disk.readPage(a, &read_back);
    try std.testing.expectEqual(@as(u8, 42), read_back[0]);

    try std.testing.expectError(error.InvalidPage, disk.readPage(99, &read_back));
}

test "direct io open and read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "direct.db",
        .{ .truncate = true, .direct = true },
    );
    defer disk.close();

    const id = try disk.allocatePage();
    var buf: [PAGE_SIZE]u8 align(4096) = @splat(0);
    buf[0] = 0xAB;
    try disk.writePage(id, &buf);

    var got: [PAGE_SIZE]u8 align(4096) = @splat(0);
    try disk.readPage(id, &got);
    try std.testing.expectEqual(@as(u8, 0xAB), got[0]);
}
