//! A basic slotted page.
//!
//! Layout inside one PAGE_SIZE buffer:
//!
//!   +---------------------------------------------------------------+
//!   | header | slot 0 | slot 1 | ... | free space | record data ... |
//!   +---------------------------------------------------------------+
//!   0        8                                   lower -> <- upper  end
//!
//! - The header stores slot_count, lower, and upper.
//! - The slot directory grows forward from the header.
//! - Records grow backward from the end of the page.
//! - `lower == upper` means the page is full.
//!
//! A slot is { offset: u16, length: u16 }. A slot with length 0 is
//! deleted. Slot indexes are stable: deleting and compacting never
//! renumbers them.

const std = @import("std");

pub const PAGE_SIZE: usize = 8192;
pub const SLOT_FORWARDED: u16 = 0xFFFF;

const HEADER_SIZE: usize = 8;

pub const Slot = struct {
    offset: u16,
    length: u16,
};

const SLOT_SIZE: usize = @sizeOf(Slot);

const SLOT_COUNT_OFFSET: usize = 0;
const LOWER_OFFSET: usize = 2;
const UPPER_OFFSET: usize = 4;

/// A nicety: the largest record that can fit in a fresh page.
pub fn maxRecordSize() usize {
    return PAGE_SIZE - HEADER_SIZE - SLOT_SIZE;
}

pub const SlottedPage = struct {
    data: *[PAGE_SIZE]u8,

    /// Wrap an existing page buffer without touching its contents.
    pub fn attach(data: *[PAGE_SIZE]u8) SlottedPage {
        return .{ .data = data };
    }

    /// Wrap a page buffer and reset it to an empty page.
    pub fn init(data: *[PAGE_SIZE]u8) SlottedPage {
        const self = attach(data);
        self.reset();
        return self;
    }

    fn reset(self: SlottedPage) void {
        @memset(self.data[0..], 0);
        self.setSlotCount(0);
        self.setLower(HEADER_SIZE);
        self.setUpper(PAGE_SIZE);
    }

    // -----------------------------------------------------------------
    // Header access
    // -----------------------------------------------------------------

    pub fn slotCount(self: SlottedPage) u16 {
        return self.readU16(SLOT_COUNT_OFFSET);
    }

    fn setSlotCount(self: SlottedPage, n: u16) void {
        self.writeU16(SLOT_COUNT_OFFSET, n);
    }

    pub fn lower(self: SlottedPage) u16 {
        return self.readU16(LOWER_OFFSET);
    }

    fn setLower(self: SlottedPage, n: u16) void {
        self.writeU16(LOWER_OFFSET, n);
    }

    pub fn upper(self: SlottedPage) u16 {
        return self.readU16(UPPER_OFFSET);
    }

    fn setUpper(self: SlottedPage, n: u16) void {
        self.writeU16(UPPER_OFFSET, n);
    }

    fn readU16(self: SlottedPage, offset: usize) u16 {
        const bytes: *const [2]u8 = @ptrCast(self.data[offset..].ptr);
        return std.mem.readInt(u16, bytes, .little);
    }

    fn writeU16(self: SlottedPage, offset: usize, value: u16) void {
        const bytes: *[2]u8 = @ptrCast(self.data[offset..].ptr);
        std.mem.writeInt(u16, bytes, value, .little);
    }

    // -----------------------------------------------------------------
    // Slots
    // -----------------------------------------------------------------

    fn slotOffset(index: u16) usize {
        return HEADER_SIZE + @as(usize, index) * SLOT_SIZE;
    }

    fn readSlotAt(data: *const [PAGE_SIZE]u8, index: u16) Slot {
        const off = slotOffset(index);
        const bytes: *const [4]u8 = @ptrCast(data[off..].ptr);
        return .{
            .offset = std.mem.readInt(u16, bytes[0..2], .little),
            .length = std.mem.readInt(u16, bytes[2..4], .little),
        };
    }

    fn getSlot(self: SlottedPage, index: u16) Slot {
        return readSlotAt(self.data, index);
    }

    fn writeSlot(self: SlottedPage, index: u16, slot: Slot) void {
        const off = slotOffset(index);
        self.writeU16(off, slot.offset);
        self.writeU16(off + 2, slot.length);
    }

    // -----------------------------------------------------------------
    // Public page operations
    // -----------------------------------------------------------------

    pub fn freeSpace(self: SlottedPage) usize {
        const lo: usize = self.lower();
        const hi: usize = self.upper();
        return if (hi >= lo) hi - lo else 0;
    }

    /// Insert a record and return its slot index.
    pub fn insert(self: SlottedPage, record: []const u8) !u16 {
        if (record.len == 0) return error.EmptyRecord;
        if (record.len > maxRecordSize()) return error.RecordTooLarge;

        const count = self.slotCount();
        const lo: usize = self.lower();
        const hi: usize = self.upper();
        const needed = record.len + SLOT_SIZE;

        if (hi < lo or hi - lo < needed) return error.PageFull;
        if (count == std.math.maxInt(u16)) return error.PageFull;

        const new_upper = hi - record.len;

        // Copy the record into the data area at the end of the page.
        @memcpy(self.data[new_upper..][0..record.len], record);

        // Write the new slot at the end of the slot directory.
        self.writeSlot(count, .{ .offset = @intCast(new_upper), .length = @intCast(record.len) });

        // Grow the slot directory and move the free-space boundary.
        self.setSlotCount(count + 1);
        self.setLower(@intCast(lo + SLOT_SIZE));
        self.setUpper(@intCast(new_upper));

        return count;
    }

    /// Read a record, or null if the slot is invalid or deleted.
    pub fn read(self: SlottedPage, index: u16) ?[]const u8 {
        if (index >= self.slotCount()) return null;

        const slot = self.getSlot(index);
        if (slot.length == 0) return null;
        if (slot.length == SLOT_FORWARDED) return self.read(slot.offset);

        return self.data[slot.offset..][0..slot.length];
    }

    /// Mark a slot deleted. The space is reclaimed by `compact`.
    pub fn remove(self: SlottedPage, index: u16) bool {
        if (index >= self.slotCount()) return false;

        const slot = self.getSlot(index);
        if (slot.length == 0) return false;

        self.writeSlot(index, .{ .offset = 0, .length = 0 });
        return true;
    }

    /// Update a record. Same-size or smaller records are overwritten in
    /// place; larger ones are written to a fresh slot and the old slot is
    /// turned into a forwarding pointer, so the caller's slot id stays valid.
    pub fn update(self: SlottedPage, index: u16, record: []const u8) !u16 {
        if (record.len == 0) return error.EmptyRecord;
        if (index >= self.slotCount()) return error.InvalidSlot;

        const slot = self.getSlot(index);
        if (slot.length == 0) return error.InvalidSlot;

        // Follow one level of forwarding before updating.
        if (slot.length == SLOT_FORWARDED) return self.update(slot.offset, record);

        if (record.len <= slot.length) {
            // Fits in place — overwrite.
            @memcpy(self.data[slot.offset..][0..record.len], record);
            self.writeSlot(index, .{ .offset = slot.offset, .length = @intCast(record.len) });
            return index;
        }

        // Doesn't fit — insert new copy and leave a forwarding pointer.
        const new_index = try self.insert(record);
        self.writeSlot(index, .{ .offset = new_index, .length = SLOT_FORWARDED });
        return index; // caller's (page_id, slot_id) stays valid
    }
    /// Re-pack live records toward the end of the page, reclaiming the
    /// space of deleted slots. Slot numbers are preserved.
    pub fn compact(self: SlottedPage) void {
        var tmp: [PAGE_SIZE]u8 = undefined;
        @memcpy(tmp[0..], self.data[0..]);

        const count = self.slotCount();
        var top: usize = PAGE_SIZE;

        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const old = readSlotAt(&tmp, i);

            if (old.length == 0) {
                self.writeSlot(i, .{ .offset = 0, .length = 0 });
                continue;
            }

            const len: usize = old.length;
            top -= len;

            @memcpy(
                self.data[top..][0..len],
                tmp[old.offset..][0..len],
            );

            self.writeSlot(i, .{ .offset = @intCast(top), .length = old.length });
        }

        self.setUpper(@intCast(top));
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "insert and read records" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const a = try page.insert("hello");
    const b = try page.insert("world");

    try testing.expectEqual(@as(u16, 0), a);
    try testing.expectEqual(@as(u16, 1), b);
    try testing.expectEqualStrings("hello", page.read(a).?);
    try testing.expectEqualStrings("world", page.read(b).?);
}

test "remove marks a slot deleted" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const a = try page.insert("hello");
    const b = try page.insert("world");

    try testing.expect(page.remove(a));
    try testing.expect(page.read(a) == null);
    try testing.expectEqualStrings("world", page.read(b).?);

    // Removing twice returns false.
    try testing.expect(!page.remove(a));
}

test "update shrinks a record in place" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const slot = try page.insert("hello");
    _ = try page.update(slot, "hi");
    try testing.expectEqualStrings("hi", page.read(slot).?);

    // Growing past the original size forwards the slot instead of failing.
    _ = try page.update(slot, "hello again");
    try testing.expectEqualStrings("hello again", page.read(slot).?);
}

test "compact reclaims deleted space and keeps slot ids" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const a = try page.insert("aaaa");
    const b = try page.insert("bbbb");
    const c = try page.insert("cccc");

    _ = page.remove(b);
    const before = page.freeSpace();

    page.compact();
    const after = page.freeSpace();

    try testing.expect(after > before);
    try testing.expectEqualStrings("aaaa", page.read(a).?);
    try testing.expect(page.read(b) == null);
    try testing.expectEqualStrings("cccc", page.read(c).?);
    try testing.expectEqual(@as(u16, 3), page.slotCount());
}

test "update forwarded slot does not chain" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const slot = try page.insert("hi");
    _ = try page.update(slot, "hello"); // grows: slot 0 -> slot 1
    _ = try page.update(slot, "world"); // updates target in place, no new slot
    try testing.expectEqualStrings("world", page.read(slot).?);
    try testing.expectEqual(@as(u16, 2), page.slotCount()); // still only 2 slots
}

test "update growing record forwards slot and read follows" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    const slot = try page.insert("hi");
    // "hello" is longer than "hi" — triggers a forwarding pointer.
    _ = try page.update(slot, "hello");
    try testing.expectEqualStrings("hello", page.read(slot).?);

    // The original slot id is still valid.
    try testing.expectEqual(@as(u16, 0), slot);
}

test "record too large is rejected" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    var big: [PAGE_SIZE]u8 = @splat(0);
    try testing.expectError(error.RecordTooLarge, page.insert(big[0..]));
}

test "page fills up" {
    var data: [PAGE_SIZE]u8 = undefined;
    const page = SlottedPage.init(&data);

    var filled = false;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = page.insert("0123456789abcdef") catch |err| {
            try testing.expectEqual(error.PageFull, err);
            filled = true;
            break;
        };
    }

    try testing.expect(filled);
    try testing.expect(page.freeSpace() < 20);
}
