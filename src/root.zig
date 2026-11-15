//! db-internals
//!
//! Code for the "Database Internals" article series. Each numbered directory
//! under src/ is one post, in reading order, and its name matches the draft in
//! src/articles/.
//!
//! The numbers are append-only: a post added later always gets the next
//! number, because published posts link to pinned commits that point at these
//! paths.

pub const buffer_manager = struct {
    pub const slotted_page = @import("01-buffer-manager/slotted_page.zig");
    pub const disk_manager = @import("01-buffer-manager/disk_manager.zig");
    pub const frame = @import("01-buffer-manager/frame.zig");
    pub const manager = @import("01-buffer-manager/buffer_manager.zig");
};

test {
    // `zig build test` only runs the `test` blocks reachable from this file.
    // Referencing every implementation file explicitly is what makes the
    // whole suite run — a plain `pub const` above is not enough, because
    // unused declarations are never analyzed.
    _ = @import("01-buffer-manager/slotted_page.zig");
    _ = @import("01-buffer-manager/disk_manager.zig");
    _ = @import("01-buffer-manager/frame.zig");
    _ = @import("01-buffer-manager/buffer_manager.zig");
    _ = @import("01-buffer-manager/policies/clock_policy.zig");
    _ = @import("01-buffer-manager/policies/lru_policy.zig");
}
