const std = @import("std");
const Dynamic = std.bit_set.Dynamic;
const Allocator = std.mem.Allocator;

pub const ClockPolicy = struct {
    allocator: Allocator,
    referenced: Dynamic,
    hand: usize = 0,

    pub fn init(allocator: Allocator, frame_count: usize) !ClockPolicy {
        return .{
            .allocator = allocator,
            .referenced = try Dynamic.initFull(allocator, frame_count),
            .hand = 0,
        };
    }

    pub fn deinit(self: *ClockPolicy) void {
        self.referenced.deinit(self.allocator);
    }

    pub fn onHit(self: *ClockPolicy, index: usize) void {
        self.referenced.set(index);
    }

    pub fn onLoad(self: *ClockPolicy, index: usize) void {
        self.referenced.set(index);
    }

    pub fn onUnpin(self: *ClockPolicy, index: usize) void {
        self.referenced.unset(index);
    }

    pub fn onRemove(self: *ClockPolicy, index: usize) void {
        self.referenced.unset(index);
    }

    pub fn pickVictim(self: *ClockPolicy) ?usize {
        const frame_count = self.referenced.bit_length;
        var scanned: usize = 0;
        while (scanned < frame_count) : (scanned += 1) {
            const index = self.hand;
            self.hand = (self.hand + 1) % frame_count;
            if (!self.referenced.isSet(index)) return index;
        }
        return null;
    }
};

const testing = std.testing;

test "clock: all frames in use returns null" {
    var policy = try ClockPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "clock: unpinned frame is returned as victim" {
    var policy = try ClockPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    policy.onUnpin(1);
    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
}

test "clock: frames in use are skipped" {
    var policy = try ClockPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    policy.onUnpin(2);
    try testing.expectEqual(@as(?usize, 2), policy.pickVictim());
    policy.onLoad(2);
    try testing.expectEqual(@as(?usize, null), policy.pickVictim());
}

test "clock: hand advances past the victim" {
    var policy = try ClockPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    policy.onUnpin(0);
    policy.onUnpin(1);
    policy.onUnpin(2);

    try testing.expectEqual(@as(?usize, 0), policy.pickVictim());
    policy.onLoad(0);
    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
}

test "clock: sweep wraps past the end of the frames" {
    var policy = try ClockPolicy.init(testing.allocator, 3);
    defer policy.deinit();

    policy.onUnpin(0);
    try testing.expectEqual(@as(?usize, 0), policy.pickVictim());
    policy.onLoad(0);

    policy.onUnpin(2);
    try testing.expectEqual(@as(?usize, 2), policy.pickVictim());
}

test "clock: onRemove makes the frame a candidate" {
    var policy = try ClockPolicy.init(testing.allocator, 2);
    defer policy.deinit();

    policy.onRemove(1);
    try testing.expectEqual(@as(?usize, 1), policy.pickVictim());
}
