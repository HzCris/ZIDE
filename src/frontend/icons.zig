//! The GUI's icons, free of attribution: the SVGs in `src/icons/svg` are the
//! CFPB Design System icons (a US government work, released to the public
//! domain worldwide under CC0), and `src/icons/svg/zide` holds the shapes
//! that pack lacks, drawn for ZIDE to its proportions. DVUI draws TinyVG,
//! so an icon is converted the first time it is drawn and kept for the rest
//! of the process; an icon that fails to convert is reported once and its
//! callers draw without it. The TUI has its own glyphs.
const std = @import("std");
const build_options = @import("build_options");
const dvui = if (build_options.has_gui) @import("dvui") else struct {};

/// Named by shape, not by use: one shape serves several buttons.
pub const Icon = enum {
    check,
    warning,
    book,
    diff,
    go_to_file,
    refresh,
    pin,
    pin_off,
    chevron_up,
    chevron_down,
    chevron_right,
    arrow_up,
    add,
    remove,
    new_file,
    collapse_all,
    filter,
    play,
    stop,
    pause,
    continue_run,
    step_over,
    step_into,
    step_out,
    list,
    lines,
    equal,
    breakpoint,
    terminal,
    gear,
    close,

    fn svg(self: Icon) []const u8 {
        return switch (self) {
            .check => @embedFile("../icons/svg/approved.svg"),
            .warning => @embedFile("../icons/svg/warning.svg"),
            .book => @embedFile("../icons/svg/book.svg"),
            .diff => @embedFile("../icons/svg/zide/diff.svg"),
            .go_to_file => @embedFile("../icons/svg/external-link.svg"),
            .refresh => @embedFile("../icons/svg/zide/refresh.svg"),
            .pin => @embedFile("../icons/svg/zide/pin.svg"),
            .pin_off => @embedFile("../icons/svg/zide/pin-off.svg"),
            .chevron_up => @embedFile("../icons/svg/up.svg"),
            .chevron_down => @embedFile("../icons/svg/down.svg"),
            .chevron_right => @embedFile("../icons/svg/right.svg"),
            .arrow_up => @embedFile("../icons/svg/arrow-up.svg"),
            .add => @embedFile("../icons/svg/plus.svg"),
            .remove => @embedFile("../icons/svg/minus.svg"),
            .new_file => @embedFile("../icons/svg/plus.svg"),
            .collapse_all => @embedFile("../icons/svg/minus.svg"),
            .filter => @embedFile("../icons/svg/filter.svg"),
            .play => @embedFile("../icons/svg/play.svg"),
            .stop => @embedFile("../icons/svg/zide/stop.svg"),
            .pause => @embedFile("../icons/svg/zide/pause.svg"),
            .continue_run => @embedFile("../icons/svg/zide/continue.svg"),
            .step_over => @embedFile("../icons/svg/zide/step-over.svg"),
            .step_into => @embedFile("../icons/svg/zide/step-into.svg"),
            .step_out => @embedFile("../icons/svg/zide/step-out.svg"),
            .list => @embedFile("../icons/svg/list.svg"),
            .lines => @embedFile("../icons/svg/menu.svg"),
            .equal => @embedFile("../icons/svg/equal.svg"),
            .breakpoint => @embedFile("../icons/svg/zide/breakpoint.svg"),
            .terminal => @embedFile("../icons/svg/zide/terminal.svg"),
            .gear => @embedFile("../icons/svg/settings.svg"),
            .close => @embedFile("../icons/svg/x.svg"),
        };
    }
};

var cache: std.EnumArray(Icon, ?[]const u8) = .initFill(null);
var failed: std.EnumArray(Icon, bool) = .initFill(false);
const allocator = std.heap.page_allocator;

/// The icon as TinyVG bytes, converted on first use; null when the SVG did
/// not convert (reported once).
pub fn tvg(icon: Icon) ?[]const u8 {
    if (cache.get(icon)) |bytes| return bytes;
    if (failed.get(icon)) return null;
    const bytes = dvui.svgToTvg(allocator, icon.svg()) catch |err| {
        failed.set(icon, true);
        std.log.warn("icon {s} did not convert: {s}", .{ @tagName(icon), @errorName(err) });
        return null;
    };
    cache.set(icon, bytes);
    return bytes;
}

/// Frees the converted icons (tests; the process end otherwise).
pub fn deinit() void {
    for (std.enums.values(Icon)) |icon| {
        if (cache.get(icon)) |bytes| allocator.free(bytes);
        cache.set(icon, null);
        failed.set(icon, false);
    }
}

/// A button with the icon before its label — a plain button when the icon
/// is unavailable. (DVUI's own icon-and-label button leaves no gap between
/// the two.)
pub fn button(src: std.builtin.SourceLocation, icon: Icon, label: []const u8, opts: dvui.Options) bool {
    const bytes = tvg(icon) orelse return dvui.button(src, label, .{}, opts);
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, opts);
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();
    const inner = opts.strip().override(bw.style()).override(.{ .gravity_y = 0.5 });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        dvui.icon(@src(), @tagName(icon), bytes, .{}, inner.override(.{ .margin = .{ .w = 6 } }));
        dvui.labelNoFmt(@src(), label, .{}, inner);
    }
    const click = bw.clicked();
    bw.drawFocus();
    return click;
}

/// The icon as a widget, tinted with the text color of `opts` (nothing
/// when unavailable).
pub fn draw(src: std.builtin.SourceLocation, icon: Icon, opts: dvui.Options) void {
    const bytes = tvg(icon) orelse return;
    dvui.icon(src, @tagName(icon), bytes, .{}, opts);
}

test "GUI icons: every icon of the set converts to TinyVG and is cached" {
    if (!build_options.has_gui) return error.SkipZigTest;
    var ui = try dvui.testing.init(.{});
    defer ui.deinit();
    defer deinit();
    for (std.enums.values(Icon)) |icon| {
        const bytes = tvg(icon) orelse return error.IconDidNotConvert;
        try std.testing.expect(bytes.len > 0);
        try std.testing.expect(tvg(icon).?.ptr == bytes.ptr);
    }
}
