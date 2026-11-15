//! When the main loop has to wake up without input: auto-save, the polls for
//! files changed on disk, a status message that is due to settle. One struct
//! of deadlines on the main thread, and no timer thread.
const std = @import("std");

/// Main-thread deadlines shared by frontends; no busy polling or timer thread.
pub const Deadlines = struct {
    next_auto: i128 = 0,
    next_poll: i128 = 0,
    auto_interval: u32 = 0,
    next_service: ?i128 = null,
    /// When the status bar's highlighted message settles (Editor.statusView):
    /// the bar must be drawn again then, input or not.
    next_status: ?i128 = null,
    /// Work was left queued on purpose (the per-tick LSP message cap): the
    /// next wait returns 0 so the loop runs again at once instead of
    /// sleeping until input or the next poll. Consumed by `waitMicros`.
    run_again: bool = false,
    const poll_ns = 1500 * std.time.ns_per_ms;

    pub fn tick(self: *Deadlines, editor: anytype, now: i128) void {
        // Reached: this frame redraws the bar. Dropped here, not only by the
        // painter, so a frame without a status bar cannot spin on it.
        if (self.next_status) |status| if (now >= status) {
            self.next_status = null;
        };
        const interval = if (editor.auto_save) @max(1, editor.auto_save_interval_ms) else 0;
        if (interval != self.auto_interval) {
            self.auto_interval = interval;
            self.next_auto = now + @as(i128, interval) * std.time.ns_per_ms;
        }
        if (interval != 0 and now >= self.next_auto) {
            self.next_auto = now + @as(i128, interval) * std.time.ns_per_ms;
            if (editor.hasUnsavedChanges()) _ = editor.autoSaveAll();
        }
        if (now >= self.next_poll) {
            self.next_poll = now + poll_ns;
            editor.pollExternalChanges();
        }
    }

    pub fn waitMicros(self: *Deadlines, now: i128) u32 {
        if (self.run_again) {
            self.run_again = false;
            return 0;
        }
        var next = self.next_poll;
        if (self.auto_interval != 0) next = @min(next, self.next_auto);
        if (self.next_service) |service| next = @min(next, service);
        if (self.next_status) |status| next = @min(next, status);
        return @intCast(@min(std.math.maxInt(u32), @max(0, @divFloor(next - now + 999, 1000))));
    }
};

test "idle deadlines save without input and leave time to sleep" {
    const Fake = struct {
        auto_save: bool = true,
        auto_save_interval_ms: u32 = 500,
        saves: usize = 0,
        polls: usize = 0,
        pub fn hasUnsavedChanges(_: *@This()) bool {
            return true;
        }
        pub fn autoSaveAll(self: *@This()) usize {
            self.saves += 1;
            return 1;
        }
        pub fn pollExternalChanges(self: *@This()) void {
            self.polls += 1;
        }
    };
    var editor: Fake = .{};
    var deadlines: Deadlines = .{};
    deadlines.tick(&editor, 0);
    try std.testing.expectEqual(@as(u32, 500_000), deadlines.waitMicros(0));
    deadlines.tick(&editor, 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), editor.saves);
    deadlines.tick(&editor, 1500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 2), editor.polls);
    try std.testing.expect(deadlines.waitMicros(1500 * std.time.ns_per_ms) > 0);
    // Work left queued skips exactly one sleep.
    deadlines.run_again = true;
    try std.testing.expectEqual(@as(u32, 0), deadlines.waitMicros(1500 * std.time.ns_per_ms));
    try std.testing.expect(deadlines.waitMicros(1500 * std.time.ns_per_ms) > 0);
}

test "the status deadline shortens the wait and is dropped once reached" {
    const Fake = struct {
        auto_save: bool = false,
        auto_save_interval_ms: u32 = 5000,
        pub fn hasUnsavedChanges(_: *@This()) bool {
            return false;
        }
        pub fn autoSaveAll(_: *@This()) usize {
            return 0;
        }
        pub fn pollExternalChanges(_: *@This()) void {}
    };
    var editor: Fake = .{};
    var deadlines: Deadlines = .{};
    const ms = std.time.ns_per_ms;
    deadlines.tick(&editor, 0);
    try std.testing.expectEqual(@as(u32, 1_500_000), deadlines.waitMicros(0));
    deadlines.next_status = 400 * ms;
    try std.testing.expectEqual(@as(u32, 400_000), deadlines.waitMicros(0));
    try std.testing.expectEqual(@as(u32, 100_000), deadlines.waitMicros(300 * ms));
    // Not reached yet: kept. Reached: this frame redraws, the deadline goes.
    deadlines.tick(&editor, 399 * ms);
    try std.testing.expect(deadlines.next_status != null);
    deadlines.tick(&editor, 400 * ms);
    try std.testing.expectEqual(@as(?i128, null), deadlines.next_status);
    try std.testing.expectEqual(@as(u32, 1_100_000), deadlines.waitMicros(400 * ms));
}
