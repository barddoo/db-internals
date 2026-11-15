//! A buffer manager with two levels of latching.
//!
//! Frame bookkeeping:
//!
//!   page_id     which disk page is loaded here (null = free frame)
//!   pin_count   how many callers are using it; > 0 means "do not evict"
//!   dirty       the page has changed and must be written back
//!   rwlatch     per-frame read/write latch (std.Io.RwLock)
//!
//! Latch rule: never wait for the pool latch while holding a frame latch.
//! The checked methods do not nest the two. They pin the frame under the
//! pool latch, release it, then take the frame latch. drop() releases the
//! frame latch before it unpins.
//!
//!   pool latch (Mutex)   page table, replacement policy state, pin counts
//!   frame latch (RwLock) frame.data: many readers or one writer
//!
//! checkedReadPage / checkedWritePage are the safe API. They return a guard
//! that releases the frame latch and unpins on drop(). fetch/unpin remain
//! available as the raw single-threaded API used internally and by newPage.
//!
//! Disk I/O happens while the pool latch is held. A production pool would
//! release it during I/O and re-acquire after, requiring a per-frame
//! "loading" state and condition variable.

const std = @import("std");
const page_mod = @import("slotted_page.zig");
const disk_mod = @import("disk_manager.zig");
const frame_mod = @import("frame.zig");
const ClockPolicy = @import("policies/clock_policy.zig").ClockPolicy;

pub const DefaultPolicy = ClockPolicy;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Mutex = Io.Mutex;
const RwLock = Io.RwLock;

pub const PAGE_SIZE = page_mod.PAGE_SIZE;
pub const PageId = disk_mod.PageId;
pub const SlottedPage = page_mod.SlottedPage;
pub const FileDisk = disk_mod.FileDisk;

pub const Frame = frame_mod.Frame;

pub const NewPage = struct {
    id: PageId,
    frame: *Frame,
};

pub fn BufferManager(comptime Disk: type, comptime Policy: type) type {
    comptime {
        for (.{ "allocatePage", "deletePage", "readPage", "writePage", "pageCount" }) |name| {
            if (!@hasDecl(Disk, name)) @compileError("Disk is missing " ++ name);
        }
        for (.{ "init", "deinit", "onHit", "onLoad", "onUnpin", "onRemove", "pickVictim" }) |name| {
            if (!@hasDecl(Policy, name)) @compileError("Policy is missing " ++ name);
        }
    }
    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        disk: *Disk,
        frames: []Frame,
        page_table: std.AutoHashMapUnmanaged(PageId, *Frame),
        latch: Mutex = .init,
        policy: Policy,

        // -----------------------------------------------------------------
        // Guards
        // -----------------------------------------------------------------

        pub const ReadPageGuard = struct {
            bm: *Self,
            frame: *Frame,

            pub fn slottedPage(self: ReadPageGuard) SlottedPage {
                return SlottedPage.attach(@constCast(&self.frame.data));
            }

            /// Release the shared frame latch and unpin the page.
            pub fn drop(self: *ReadPageGuard) void {
                const page_id = self.frame.page_id.?;
                self.frame.rwlatch.unlockShared(self.bm.io);
                self.bm.unpin(page_id, false);
            }
        };

        pub const WritePageGuard = struct {
            bm: *Self,
            frame: *Frame,

            pub fn slottedPage(self: WritePageGuard) SlottedPage {
                return SlottedPage.attach(&self.frame.data);
            }

            /// Release the exclusive frame latch, mark dirty, and unpin the page.
            pub fn drop(self: *WritePageGuard) void {
                const page_id = self.frame.page_id.?;
                self.frame.rwlatch.unlock(self.bm.io);
                self.bm.unpin(page_id, true);
            }
        };

        // -----------------------------------------------------------------
        // Lifecycle
        // -----------------------------------------------------------------

        pub fn init(
            allocator: Allocator,
            io: Io,
            disk: *Disk,
            frame_count: usize,
        ) !Self {
            if (frame_count == 0) return error.InvalidFrameCount;

            const frames = try allocator.alloc(Frame, frame_count);
            errdefer allocator.free(frames);

            for (frames) |*frame| frame.* = .{};

            const policy = try Policy.init(allocator, frame_count);
            errdefer policy.deinit();

            return .{
                .io = io,
                .allocator = allocator,
                .disk = disk,
                .frames = frames,
                .page_table = .empty,
                .policy = policy,
            };
        }

        pub fn deinit(self: *Self) void {
            self.flushAll() catch {};
            self.policy.deinit();
            self.page_table.deinit(self.allocator);
            self.allocator.free(self.frames);
        }

        // -----------------------------------------------------------------
        // Public API
        // -----------------------------------------------------------------

        /// Allocate a page on disk, load it into a pinned frame, and
        /// initialize it as an empty slotted page. Caller must unpin.
        pub fn newPage(self: *Self) !NewPage {
            try self.latch.lock(self.io);
            defer self.latch.unlock(self.io);

            const id = try self.disk.allocatePage();
            const frame = try self.fetchLocked(id);
            _ = SlottedPage.init(&frame.data);
            return .{ .id = id, .frame = frame };
        }

        /// Remove a page from the pool and mark its id as reusable on disk.
        /// Returns error.PagePinned if any caller still holds the page.
        /// The dirty flag is discarded — the page is gone, there is nothing to flush.
        pub fn deletePage(self: *Self, page_id: PageId) !void {
            try self.latch.lock(self.io);
            defer self.latch.unlock(self.io);

            if (self.page_table.get(page_id)) |frame| {
                if (frame.pin_count.load(.monotonic) > 0) return error.PagePinned;
                self.policy.onRemove(self.frameIndex(frame));
                _ = self.page_table.remove(page_id);
                frame.page_id = null;
                frame.dirty = false;
            }
            try self.disk.deletePage(page_id);
        }

        /// Pin a page, loading it from disk if needed. Caller must unpin.
        /// Does not acquire the frame latch — use checkedReadPage/checkedWritePage
        /// when concurrent access to frame.data is needed.
        pub fn fetch(self: *Self, page_id: PageId) !*Frame {
            try self.latch.lock(self.io);
            defer self.latch.unlock(self.io);
            return self.fetchLocked(page_id);
        }

        /// Release a pin. Pass dirty=true if the page was modified.
        pub fn unpin(self: *Self, page_id: PageId, dirty: bool) void {
            while (!self.latch.tryLock()) {}
            defer self.latch.unlock(self.io);

            const frame = self.page_table.get(page_id) orelse return;
            if (frame.pin_count.load(.monotonic) == 0) return;

            _ = frame.pin_count.fetchSub(1, .monotonic);
            if (dirty) frame.dirty = true;

            if (frame.pin_count.load(.monotonic) == 0) self.policy.onUnpin(self.frameIndex(frame));
        }

        /// Pin a page and acquire a shared (read) frame latch.
        /// Multiple threads may hold a ReadPageGuard on the same page concurrently.
        /// Call guard.drop() when done.
        pub fn checkedReadPage(self: *Self, page_id: PageId) !ReadPageGuard {
            const frame = blk: {
                try self.latch.lock(self.io);
                defer self.latch.unlock(self.io);
                break :blk try self.fetchLocked(page_id);
            };
            try frame.rwlatch.lockShared(self.io);
            return .{ .bm = self, .frame = frame };
        }

        /// Pin a page and acquire an exclusive (write) frame latch.
        /// No other reader or writer may access the page until guard.drop().
        pub fn checkedWritePage(self: *Self, page_id: PageId) !WritePageGuard {
            const frame = blk: {
                try self.latch.lock(self.io);
                defer self.latch.unlock(self.io);
                break :blk try self.fetchLocked(page_id);
            };
            try frame.rwlatch.lock(self.io);
            return .{ .bm = self, .frame = frame };
        }

        /// Write a dirty resident page back to disk.
        pub fn flushPage(self: *Self, page_id: PageId) !void {
            try self.latch.lock(self.io);
            defer self.latch.unlock(self.io);

            const frame = self.page_table.get(page_id) orelse return;
            if (frame.dirty) {
                try self.disk.writePage(page_id, &frame.data);
                frame.dirty = false;
            }
        }

        /// Write every dirty resident page back to disk.
        pub fn flushAll(self: *Self) !void {
            for (self.frames) |*frame| {
                if (frame.page_id) |id| {
                    if (frame.dirty) {
                        try self.disk.writePage(id, &frame.data);
                        frame.dirty = false;
                    }
                }
            }
        }

        pub fn frameCount(self: *const Self) usize {
            return self.frames.len;
        }

        pub fn residentCount(self: *const Self) usize {
            return self.page_table.count();
        }

        // -----------------------------------------------------------------
        // Internals — called with the pool latch already held
        // -----------------------------------------------------------------

        fn fetchLocked(self: *Self, page_id: PageId) !*Frame {
            if (self.page_table.get(page_id)) |frame| {
                self.policy.onHit(self.frameIndex(frame));
                _ = frame.pin_count.fetchAdd(1, .monotonic);
                return frame;
            }

            const frame = try self.pickFrame();

            if (frame.page_id) |old_id| {
                if (frame.dirty) try self.disk.writePage(old_id, &frame.data);
                _ = self.page_table.remove(old_id);
            }

            try self.disk.readPage(page_id, &frame.data);

            frame.page_id = page_id;
            frame.pin_count.store(1, .monotonic);
            frame.dirty = false;

            self.page_table.put(self.allocator, page_id, frame) catch |err| {
                frame.page_id = null;
                frame.pin_count.store(0, .monotonic);
                frame.dirty = false;
                return err;
            };

            self.policy.onLoad(self.frameIndex(frame));
            return frame;
        }

        fn pickFrame(self: *Self) !*Frame {
            for (self.frames) |*frame| {
                if (frame.page_id == null) return frame;
            }
            const index = self.policy.pickVictim() orelse return error.BufferFull;
            return &self.frames[index];
        }

        fn frameIndex(self: *Self, frame: *Frame) usize {
            return @divExact(@intFromPtr(frame) - @intFromPtr(self.frames.ptr), @sizeOf(Frame));
        }
    };
}

const testing = std.testing;

test "fetch and unpin a new page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "fetch.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    const np = try bm.newPage();
    const slotted = np.frame.slottedPage();
    const slot = try slotted.insert("hello");
    try testing.expectEqual(@as(u16, 0), slot);

    bm.unpin(np.id, true);
    try testing.expectEqual(@as(usize, 1), bm.residentCount());
}

test "eviction flushes dirty pages and reloads them from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "evict.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    var ids: [3]PageId = undefined;
    for (&ids, 0..) |*id, i| {
        const np = try bm.newPage();
        id.* = np.id;

        const slotted = np.frame.slottedPage();
        const value = [_]u8{@as(u8, @intCast(i + 1))};
        _ = try slotted.insert(&value);

        bm.unpin(np.id, true);
    }

    try testing.expectEqual(@as(usize, 2), bm.residentCount());

    const frame = try bm.fetch(ids[0]);
    const slotted = frame.slottedPage();
    try testing.expectEqualSlices(u8, &[_]u8{1}, slotted.read(0).?);

    bm.unpin(ids[0], false);
}

test "all frames pinned returns BufferFull" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "pinned.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 1);
    defer bm.deinit();

    const first = try bm.newPage();
    try testing.expectError(error.BufferFull, bm.newPage());
    bm.unpin(first.id, false);
}

test "deletePage evicts frame and allows id reuse" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "delete.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    const np = try bm.newPage();
    const id = np.id;
    bm.unpin(id, false);

    try bm.deletePage(id);
    try testing.expectEqual(@as(usize, 0), bm.residentCount());

    const np2 = try bm.newPage();
    try testing.expectEqual(id, np2.id);
    bm.unpin(np2.id, false);
}

test "deletePage pinned page returns error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "delete-pinned.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    const np = try bm.newPage();
    try testing.expectError(error.PagePinned, bm.deletePage(np.id));
    bm.unpin(np.id, false);
}

test "checkedReadPage returns readable guard" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "read-guard.db",
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    const np = try bm.newPage();
    _ = try np.frame.slottedPage().insert("hello");
    bm.unpin(np.id, true);

    var guard = try bm.checkedReadPage(np.id);
    defer guard.drop();
    try testing.expectEqualStrings("hello", guard.slottedPage().read(0).?);
}

test "checkedWritePage returns writable guard" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try FileDisk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "write-guard.db",
        .{ .truncate = true },
    );
    defer disk.close();
    var bm = try BufferManager(FileDisk, DefaultPolicy).init(testing.allocator, testing.io, &disk, 2);
    defer bm.deinit();

    const np = try bm.newPage();
    _ = try np.frame.slottedPage().insert("hello");
    bm.unpin(np.id, true);

    {
        var guard = try bm.checkedWritePage(np.id);
        _ = try guard.slottedPage().insert("world");
        guard.drop();
    }

    var rguard = try bm.checkedReadPage(np.id);
    defer rguard.drop();
    try testing.expectEqualStrings("hello", rguard.slottedPage().read(0).?);
    try testing.expectEqualStrings("world", rguard.slottedPage().read(1).?);
}

test "file-backed buffer manager persists across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const path = "bm.db";

    {
        var disk = try FileDisk.open(
            testing.allocator,
            testing.io,
            tmp.dir,
            path,
            .{ .truncate = true },
        );
        defer disk.close();

        var bm = try BufferManager(FileDisk, DefaultPolicy).init(allocator, testing.io, &disk, 2);
        defer bm.deinit();

        const np = try bm.newPage();
        _ = try np.frame.slottedPage().insert("persisted");
        bm.unpin(np.id, true);
    }

    {
        var disk = try FileDisk.open(
            testing.allocator,
            testing.io,
            tmp.dir,
            path,
            .{ .truncate = false },
        );
        defer disk.close();

        var bm = try BufferManager(FileDisk, DefaultPolicy).init(allocator, testing.io, &disk, 2);
        defer bm.deinit();

        const frame = try bm.fetch(0);
        try testing.expectEqualStrings("persisted", frame.slottedPage().read(0).?);
        bm.unpin(0, false);
    }
}
