//! Buffer manager + slotted page demo, backed by a real file.
//!
//! The demo truncates `buffer_manager.db`, creates more pages than there
//! are frames, writes records, lets the buffer manager evict and reload
//! them, then deletes and compacts a record. The final state is flushed
//! to the file.

const std = @import("std");
const bm_mod = @import("buffer_manager.zig");

const PageId = bm_mod.PageId;
const FileDisk = bm_mod.FileDisk;
const BufferManager = bm_mod.BufferManager(FileDisk, bm_mod.DefaultPolicy);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const path = "buffer_manager.db";

    var disk = try FileDisk.open(
        allocator,
        io,
        std.Io.Dir.cwd(),
        path,
        .{ .truncate = true },
    );
    defer disk.close();

    var bm = try BufferManager.init(allocator, io, &disk, 3);
    defer bm.deinit();

    std.debug.print("=== buffer manager demo (file: {s}) ===\n", .{path});

    const page_count = 5;
    var ids: [page_count]PageId = undefined;

    for (&ids, 0..) |*id, i| {
        const np = try bm.newPage();
        id.* = np.id;

        const slotted = np.frame.slottedPage();

        var first_buf: [64]u8 = undefined;
        var second_buf: [64]u8 = undefined;
        const first = try std.fmt.bufPrint(&first_buf, "page-{d}-first", .{i});
        const second = try std.fmt.bufPrint(&second_buf, "page-{d}-second", .{i});

        _ = try slotted.insert(first);
        _ = try slotted.insert(second);

        bm.unpin(np.id, true);
    }

    std.debug.print(
        "created {d} pages with {d} frames\n",
        .{ page_count, bm.frameCount() },
    );

    // Read every page. Some of these will have been evicted and must be
    // reloaded from the file.
    for (ids, 0..) |id, i| {
        const frame = try bm.fetch(id);
        const slotted = frame.slottedPage();

        const first = slotted.read(0) orelse "<missing>";
        const second = slotted.read(1) orelse "<missing>";

        std.debug.print(
            "page {d}: [{s}] [{s}] free={d}\n",
            .{ i, first, second, slotted.freeSpace() },
        );

        bm.unpin(id, false);
    }

    // Delete a record and compact page 0.
    const frame0 = try bm.fetch(ids[0]);
    const page0 = frame0.slottedPage();

    const temp = try page0.insert("temporary-record");
    const before = page0.freeSpace();

    _ = page0.remove(temp);
    page0.compact();

    const after = page0.freeSpace();

    std.debug.print(
        "page 0 delete+compact: free {d} -> {d}, slot 0 = {s}\n",
        .{ before, after, page0.read(0).? },
    );

    bm.unpin(ids[0], true);

    // Flush the final state to the file.
    try bm.flushAll();

    std.debug.print(
        "disk pages={d}, frames={d}, resident={d}, file bytes={d}\n",
        .{
            disk.pageCount(),
            bm.frameCount(),
            bm.residentCount(),
            disk.pageCount() * @as(u64, bm_mod.PAGE_SIZE),
        },
    );
}
