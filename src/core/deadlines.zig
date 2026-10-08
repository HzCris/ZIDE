const std = @import("std");

/// Main-thread deadlines shared by frontends; no busy polling or timer thread.
pub const Deadlines = struct {
    next_auto: i128 = 0,
    next_poll: i128 = 0,
    auto_interval: u32 = 0,
    next_service: ?i128 = null,
    /// Work was left queued on purpose (the per-tick LSP message cap): the
    /// next wait returns 0 so the loop runs again at once instead of
    /// sleeping until input or the next poll. Consumed by `waitMicros`.
    run_again: bool = false,
    const poll_ns = 1500 * std.time.ns_per_ms;

    pub fn tick(self: *Deadlines, editor: anytype, now: i128) void {
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
