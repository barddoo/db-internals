const std = @import("std");
const page_mod = @import("slotted_page.zig");
const disk_mod = @import("disk_manager.zig");

const RwLock = std.Io.RwLock;

pub const PAGE_SIZE = page_mod.PAGE_SIZE;
pub const SlottedPage = page_mod.SlottedPage;
pub const PageId = disk_mod.PageId;

pub const Frame = struct {
    data: [PAGE_SIZE]u8 = undefined,
    page_id: ?PageId = null,
    pin_count: std.atomic.Value(u32) = .init(0),
    dirty: bool = false,
    rwlatch: RwLock = .init,

    pub fn slottedPage(self: *Frame) SlottedPage {
        return SlottedPage.attach(&self.data);
    }
};
