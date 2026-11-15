const std = @import("std");

const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

pub const LruPolicy = struct {
    const Entry = struct {
        node: DoublyLinkedList.Node = .{},
        index: usize,
    };

    allocator: Allocator,
    entries: []Entry,
    list: DoublyLinkedList = .{},

    pub fn init(allocator: Allocator, frame_count: usize) !LruPolicy {
        const entries = try allocator.alloc(Entry, frame_count);
        for (entries, 0..) |*entry, i| entry.* = .{ .index = i };
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *LruPolicy) void {
        self.allocator.free(self.entries);
    }

    pub fn onHit(self: *LruPolicy, index: usize) void {
        self.unlink(&self.entries[index].node);
    }

    pub fn onLoad(self: *LruPolicy, index: usize) void {
        self.unlink(&self.entries[index].node);
    }

    pub fn onUnpin(self: *LruPolicy, index: usize) void {
        const node = &self.entries[index].node;
        self.unlink(node);
        self.list.prepend(node);
    }

    pub fn onRemove(self: *LruPolicy, index: usize) void {
        self.unlink(&self.entries[index].node);
    }

    pub fn pickVictim(self: *LruPolicy) ?usize {
        const node = self.list.pop() orelse return null;
        node.* = .{};
        const entry: *Entry = @fieldParentPtr("node", node);
        return entry.index;
    }

    fn contains(self: *LruPolicy, node: *DoublyLinkedList.Node) bool {
        return self.list.first == node or node.prev != null or node.next != null;
    }

    fn unlink(self: *LruPolicy, node: *DoublyLinkedList.Node) void {
        if (!self.contains(node)) return;
        self.list.remove(node);
        node.* = .{};
    }
};

const testing = std.testing;

test "lru: empty policy returns null" {
    var policy = try LruPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "lru: evicts in unpin order, oldest first" {
    var policy = try LruPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    policy.onLoad(0);
    policy.onLoad(1);
    policy.onLoad(2);
    policy.onUnpin(0);
    policy.onUnpin(1);
    policy.onUnpin(2);

    try testing.expectEqual(@as(?usize, 0), policy.pickVictim());
    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
    try testing.expectEqual(@as(?usize, 2), policy.pickVictim());
    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "lru: hit removes frame from candidates" {
    var policy = try LruPolicy.init(testing.allocator, 2);
    defer policy.deinit();

    policy.onLoad(0);
    policy.onLoad(1);
    policy.onUnpin(0);
    policy.onUnpin(1);
    policy.onHit(0);

    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "lru: unpinning again moves frame to most recent" {
    var policy = try LruPolicy.init(testing.allocator, 2);
    defer policy.deinit();

    policy.onUnpin(0);
    policy.onUnpin(1);
    policy.onUnpin(0);

    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
    try testing.expectEqual(@as(?usize, 0), policy.pickVictim());
}

test "lru: onRemove drops frame from candidates" {
    var policy = try LruPolicy.init(testing.allocator, 2);
    defer policy.deinit();

    policy.onUnpin(0);
    policy.onUnpin(1);
    policy.onRemove(0);

    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "lru: double unpin does not corrupt the list" {
    var policy = try LruPolicy.init(testing.allocator, 2);
    defer policy.deinit();

    policy.onUnpin(0);
    policy.onUnpin(0);

    try testing.expectEqual(@as(?usize, 0), policy.pickVictim());
    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}
