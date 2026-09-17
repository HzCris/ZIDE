const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("sdl-backend");
const c = Backend.c;
const build_options = @import("build_options");
const t = std.testing;

fn quad(x: f32, y: f32, color: dvui.Color.PMA) [4]dvui.Vertex {
    return .{
        .{ .pos = .{ .x = x, .y = y }, .col = color, .uv = .{ 0, 0 } },
        .{ .pos = .{ .x = x + 16, .y = y }, .col = color, .uv = .{ 1, 0 } },
        .{ .pos = .{ .x = x + 16, .y = y + 16 }, .col = color, .uv = .{ 1, 1 } },
        .{ .pos = .{ .x = x, .y = y + 16 }, .col = color, .uv = .{ 0, 1 } },
    };
}

fn expectPixel(surface: *c.SDL_Surface, x: c_int, y: c_int, expected: [4]u8) !void {
    var actual: [4]u8 = undefined;
    try t.expect(c.SDL_ReadSurfacePixel(surface, x, y, &actual[0], &actual[1], &actual[2], &actual[3]));
    for (actual, expected) |got, want| {
        if (@abs(@as(i16, got) - @as(i16, want)) > 2) {
            std.debug.print("pixel ({d}, {d}): expected {any}, got {any}\n", .{ x, y, expected, actual });
            return error.TestExpectedEqual;
        }
    }
}

test "GUI software pixels: translucent atlas, fills and triangle blending" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 128, .h = 32 },
        .title = "ZIDE software pixels",
        .hidden = true,
        .vsync = false,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    backend.arena = t.allocator;
    const target = try backend.textureCreateTarget(.{ .width = 128, .height = 32 });
    defer backend.textureDestroyTarget(target);
    try backend.renderTarget(target);
    try t.expect(c.SDL_SetRenderDrawColor(backend.renderer, 40, 50, 60, 255));
    try t.expect(c.SDL_RenderClear(backend.renderer));

    // White glyph coverage: transparent, half covered, fully covered.
    const atlas_pixels = [_]u8{ 0, 0, 0, 0, 128, 128, 128, 128, 255, 255, 255, 255, 255, 255, 255, 255 };
    const atlas = try backend.textureCreate(&atlas_pixels, .{ .width = 2, .height = 2, .interpolation = .nearest });
    defer backend.textureDestroy(atlas);
    const tint: dvui.Color.PMA = .fromColor(.{ .r = 100, .g = 100, .b = 120, .a = 180 });
    const indices = [_]dvui.Vertex.Index{ 0, 2, 1, 0, 3, 2 };
    try backend.drawClippedTriangles(atlas, &quad(4, 4, tint), &indices, null);
    try backend.drawClippedTriangles(null, &quad(28, 4, tint), &indices, null);
    // A real triangle must blend too, including textured antialiasing fringes.
    try backend.drawClippedTriangles(atlas, &quad(52, 4, tint), indices[0..3], null);
    const solid: dvui.Color.PMA = .fromColor(.{ .r = 100, .g = 100, .b = 120 });
    try backend.drawClippedTriangles(null, &quad(76, 4, solid), indices[0..3], null);
    try backend.drawClippedTriangles(null, &quad(100, 4, solid), &indices, null);
    const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(surface);
    try expectPixel(surface, 6, 6, .{ 40, 50, 60, 255 });
    try expectPixel(surface, 18, 6, .{ 60, 67, 80, 255 });
    try expectPixel(surface, 6, 18, .{ 81, 84, 101, 255 });
    try expectPixel(surface, 30, 6, .{ 81, 84, 101, 255 });
    try expectPixel(surface, 66, 6, .{ 60, 67, 80, 255 });
    try expectPixel(surface, 90, 6, .{ 100, 100, 120, 255 });
    try expectPixel(surface, 78, 18, .{ 40, 50, 60, 255 });
    try expectPixel(surface, 102, 18, .{ 100, 100, 120, 255 });
}

test "GUI software atlas: normalized glyph coordinates preserve every source pixel" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 64, .h = 32 },
        .title = "ZIDE atlas sampling",
        .hidden = true,
        .vsync = false,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    backend.arena = t.allocator;
    const target = try backend.textureCreateTarget(.{ .width = 64, .height = 32 });
    defer backend.textureDestroyTarget(target);
    try backend.renderTarget(target);
    const indices = [_]dvui.Vertex.Index{ 0, 2, 1, 0, 3, 2 };
    // Font atlases are not necessarily powers of two. A round trip through
    // normalized UVs can put a pixel edge just below its original integer.
    for ([_]u32{ 97, 101, 139 }) |atlas_width| {
        const atlas_height = 61;
        const pixels = try t.allocator.alloc(u8, atlas_width * atlas_height * 4);
        defer t.allocator.free(pixels);
        for (0..atlas_height) |y| {
            for (0..atlas_width) |x| {
                const offset = (y * atlas_width + x) * 4;
                @memcpy(pixels[offset..][0..4], &[_]u8{ @intCast((x * 17) % 256), @intCast((y * 19) % 256), 120, 255 });
            }
        }
        const texture = try backend.textureCreate(pixels.ptr, .{ .width = atlas_width, .height = atlas_height, .interpolation = .nearest });
        defer backend.textureDestroy(texture);
        for ([_]f32{ 1, 1.25, 17, 17.625, 37, 61 }) |source_x| {
            const source: c.SDL_FRect = .{ .x = source_x, .y = 17, .w = 9, .h = 11 };
            const reference: c.SDL_FRect = .{ .x = 32, .y = 4, .w = source.w, .h = source.h };
            var vertices = quad(4, 4, .white);
            const atlas_w: f32 = @floatFromInt(atlas_width);
            const u = source.x / atlas_w;
            const v = source.y / atlas_height;
            vertices[0].uv = .{ u, v };
            vertices[1].uv = .{ u + source.w / atlas_w, v };
            vertices[2].uv = .{ vertices[1].uv[0], v + source.h / atlas_height };
            vertices[3].uv = .{ u, vertices[2].uv[1] };
            vertices[1].pos.x = 4 + source.w;
            vertices[2].pos = .{ .x = 4 + source.w, .y = 4 + source.h };
            vertices[3].pos.y = 4 + source.h;
            try t.expect(c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255));
            try t.expect(c.SDL_RenderClear(backend.renderer));
            try backend.drawClippedTriangles(texture, &vertices, &indices, null);
            try t.expect(c.SDL_RenderTexture(backend.renderer, @ptrCast(@alignCast(texture.ptr)), &source, &reference));
            const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
            defer c.SDL_DestroySurface(surface);
            for (0..11) |y| {
                for (0..9) |x| {
                    var expected: [4]u8 = undefined;
                    try t.expect(c.SDL_ReadSurfacePixel(surface, @intCast(32 + x), @intCast(4 + y), &expected[0], &expected[1], &expected[2], &expected[3]));
                    try expectPixel(surface, @intCast(4 + x), @intCast(4 + y), expected);
                }
            }
        }
    }
}

test "GUI software letters: S and P match integer atlas blits at every font size" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 1024, .h = 112 },
        .title = "ZIDE letter spacing",
        .hidden = true,
        .vsync = false,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, backend.backend(), .{});
    defer window.deinit();
    try window.addFont("spacing_test", @embedFile("bundled_mono_font"), null);
    try window.begin(0);
    {
        const target = try backend.textureCreateTarget(.{ .width = 1024, .height = 112 });
        defer backend.textureDestroyTarget(target);
        const previous = dvui.renderTarget(.{ .texture = target, .offset = .{} });
        defer _ = dvui.renderTarget(previous);
        const texts = [_][]const u8{
            "SP PS SSP PPS SSS PPP sps psps",
            "// or press Ctrl+P to browse every command by name.",
            "// Shortcuts below are the defaults; rebind any of them in",
        };
        for ([_]f32{ 10, 12, 14, 16, 20 }) |size| {
            const font = dvui.Font.find(.{ .family = "spacing_test", .size = size });
            const entry = try window.fonts.getOrCreate(t.allocator, font);
            const atlas = try entry.getTextureAtlas(t.allocator, backend.backend());
            const atlas_w: f32 = @floatFromInt(atlas.width);
            const atlas_h: f32 = @floatFromInt(atlas.height);
            for (texts, 0..) |text, text_index| {
                try t.expect(c.SDL_SetRenderDrawColor(backend.renderer, 40, 40, 48, 255));
                try t.expect(c.SDL_RenderClear(backend.renderer));
                try dvui.renderText(.{
                    .font = font,
                    .text = text,
                    .rs = .{ .r = .{ .x = 4, .y = 4, .w = 1020, .h = 52 }, .s = 1 },
                    .color = .white,
                    .kerning = false,
                });
                // Reference: bitmap-sized blits at the font's integer bearings
                // and advances, without normalized UV geometry conversion.
                var pen: f32 = 4;
                for (text) |letter| {
                    const glyph = try entry.glyphInfoGetOrReplacement(t.allocator, letter);
                    if (glyph.w > 0) {
                        const source: c.SDL_FRect = .{ .x = @round(glyph.uv[0] * atlas_w), .y = @round(glyph.uv[1] * atlas_h), .w = glyph.w, .h = glyph.h };
                        const dest: c.SDL_FRect = .{ .x = pen + glyph.leftBearing, .y = 60 + entry.ascent - glyph.topBearing, .w = glyph.w, .h = glyph.h };
                        try t.expect(c.SDL_RenderTexture(backend.renderer, @ptrCast(@alignCast(atlas.ptr)), &source, &dest));
                    }
                    pen += @round(glyph.advance);
                }
                const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
                defer c.SDL_DestroySurface(surface);
                const rgba: *c.SDL_Surface = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse return error.ReadPixels;
                defer c.SDL_DestroySurface(rgba);
                const pixels: [*]const u8 = @ptrCast(rgba.pixels);
                const pitch: usize = @intCast(rgba.pitch);
                for (0..56) |row| {
                    const actual = pixels[row * pitch ..][0 .. 1024 * 4];
                    const expected = pixels[(row + 56) * pitch ..][0 .. 1024 * 4];
                    if (!std.mem.eql(u8, expected, actual)) {
                        std.debug.print("glyph spacing mismatch at font size {d}, row {d}: {s}\n", .{ size, row, text });
                        return error.TestExpectedEqual;
                    }
                }
                if (size == 12 and text_index == 2 and c.SDL_getenv("ZIDE_SOFTWARE_PROFILE") != null) {
                    try std.Io.Dir.cwd().createDirPath(t.io, ".zig-cache");
                    try t.expect(c.SDL_SavePNG(surface, ".zig-cache/software-font-spacing.png"));
                }
            }
        }
    }
    _ = try window.end(.{});
}

test "GUI software glyphs: clipped translucent text at fractional scale and rotation" {
    if (!build_options.has_gui or build_options.has_gpu) return error.SkipZigTest;
    var backend = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 160, .h = 64 },
        .title = "ZIDE software glyphs",
        .hidden = true,
        .vsync = false,
        .renderer_driver = "software",
    });
    defer backend.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, backend.backend(), .{});
    defer window.deinit();
    try window.begin(0);
    {
        const target = try backend.textureCreateTarget(.{ .width = 160, .height = 64 });
        defer backend.textureDestroyTarget(target);
        const previous = dvui.renderTarget(.{ .texture = target, .offset = .{} });
        defer _ = dvui.renderTarget(previous);
        const previous_clip = dvui.clipGet();
        defer dvui.clipSet(previous_clip);
        dvui.clipSet(.{ .x = 12, .y = 8, .w = 112, .h = 40 });
        for ([_]f32{ 1, 1.25, 2 }) |scale| {
            for ([_]f32{ 0, 0.15 }) |rotation| {
                for ([_]u8{ 0, 180, 255 }) |alpha| {
                    try t.expect(c.SDL_SetRenderDrawColor(backend.renderer, 40, 50, 60, 255));
                    try t.expect(c.SDL_RenderClear(backend.renderer));
                    try dvui.renderText(.{
                        .font = dvui.Font.theme(.body).withSize(16),
                        .text = "Current: Software café 界",
                        .rs = .{ .r = .{ .x = 4, .y = 4, .w = 400, .h = 60 }, .s = scale },
                        .color = .{ .r = 100, .g = 100, .b = 120, .a = alpha },
                        .rotation = rotation,
                    });
                    const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse return error.ReadPixels;
                    defer c.SDL_DestroySurface(surface);
                    var changed: usize = 0;
                    for (0..64) |y| {
                        for (0..160) |x| {
                            var pixel: [4]u8 = undefined;
                            try t.expect(c.SDL_ReadSurfacePixel(surface, @intCast(x), @intCast(y), &pixel[0], &pixel[1], &pixel[2], &pixel[3]));
                            // Light text over a dark opaque background must never
                            // introduce black pixels or punch holes in its alpha.
                            try t.expect(pixel[0] >= 39 and pixel[1] >= 49 and pixel[2] >= 59 and pixel[3] == 255);
                            const differs = !std.mem.eql(u8, &pixel, &.{ 40, 50, 60, 255 });
                            if (x < 12 or x >= 124 or y < 8 or y >= 48 or alpha == 0) {
                                try t.expect(!differs);
                            } else if (differs) changed += 1;
                        }
                    }
                    if (alpha != 0) try t.expect(changed > 40);
                }
            }
        }
    }
    _ = try window.end(.{});
}
