//! ZIDE fixes for the pinned SDL 3.4.4 software renderer. Generate private
//! source copies in the build cache; never modify the shared dependency cache.
//! Recheck these patches when updating SDL. A changed source fails explicitly.
const std = @import("std");
var patched_modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;

// Recover integer texel edges after the float UV round trip. Leave genuinely
// fractional edges alone; changing all source coordinates to nearest would
// alter deliberate texture crops. The tolerance covers normalization, adding
// a glyph's normalized width, and conversion back to atlas pixels.
const texture_edge_helper =
    \\#include "SDL_internal.h"
    \\#ifdef SDL_VIDEO_RENDER_SW
    \\static SDL_INLINE float ZIDE_SoftwareTextureEdge(float uv, float size)
    \\{
    \\    const float edge = uv * size;
    \\    const float integral = SDL_roundf(edge);
    \\    return SDL_fabsf(edge - integral) <= 4.0f * SDL_FLT_EPSILON * size ? integral : edge;
    \\}
    \\#endif
;

pub fn apply(b: *std.Build, dependency: *std.Build.Dependency) void {
    const module = dependency.artifact("SDL3").root_module;
    const entry = patched_modules.getOrPut(b.allocator, module) catch @panic("OOM");
    if (entry.found_existing) return;
    const generated = b.addWriteFiles();
    const paths = [_][]const u8{ "src/render/SDL_render.c", "src/render/software/SDL_triangle.c", "src/render/software/SDL_render_sw.c" };
    var replacements: [paths.len]std.Build.LazyPath = undefined;
    for (paths, &replacements) |path, *replacement| {
        const original = std.Io.Dir.cwd().readFileAlloc(b.graph.io, dependency.path(path).getPath(b), b.allocator, .limited(1024 * 1024)) catch
            @panic("Cannot read SDL software renderer source");
        var source = replace(b, original, "\r\n", "\n", null);
        if (std.mem.endsWith(u8, path, "/SDL_render.c")) {
            source = replace(b, source, "#include \"SDL_internal.h\"", texture_edge_helper, 1);
            // Geometry's colors and UVs can have different strides. Reading a
            // packed PMA color as a float UV rejects glyph quads at random.
            inline for (.{ "A", "B", "C", "C2" }) |vertex| {
                source = replace(b, source, "uv + " ++ vertex ++ " * color_stride", "uv + " ++ vertex ++ " * uv_stride", 1);
            }
            source = replace(b, source, "if (is_quad && uv)", "if (is_quad && texture)", 1);
            // Recover both origin and extent. Truncating 8.999998 to 8 loses
            // a glyph column. Normalize the extent independently so an
            // intentional fractional origin cannot reintroduce that error.
            source = replace(b, source, "uv0_[0] * texw", "ZIDE_SoftwareTextureEdge(uv0_[0], texw)", 1);
            source = replace(b, source, "uv0_[1] * texh", "ZIDE_SoftwareTextureEdge(uv0_[1], texh)", 1);
            source = replace(b, source, "uv1_[0] * texw - s.x", "ZIDE_SoftwareTextureEdge(uv1_[0] - uv0_[0], texw)", 1);
            source = replace(b, source, "uv1_[1] * texh - s.y", "ZIDE_SoftwareTextureEdge(uv1_[1] - uv0_[1], texh)", 1);
            // The rectangle optimization must use the caller's blend mode.
            source = replace(b, source, "SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);\n                SDL_SetRenderDrawColorFloat(renderer, col0_->r", "SDL_SetRenderDrawBlendMode(renderer, (col0_->a == 1.0f && (blendMode == SDL_BLENDMODE_BLEND || blendMode == SDL_BLENDMODE_BLEND_PREMULTIPLIED)) ? SDL_BLENDMODE_NONE : blendMode);\n                SDL_SetRenderDrawColorFloat(renderer, col0_->r", 1);
        } else if (std.mem.endsWith(u8, path, "/SDL_render_sw.c")) {
            source = replace(b, source, "#include \"SDL_internal.h\"", texture_edge_helper, 1);
            // Rotated text and other non-rectangular geometry use this path.
            source = replace(b, source, "uv_[0] * texture->w", "ZIDE_SoftwareTextureEdge(uv_[0], (float)texture->w)", 1);
            source = replace(b, source, "uv_[1] * texture->h", "ZIDE_SoftwareTextureEdge(uv_[1], (float)texture->h)", 1);
        } else {
            // Opaque flat triangles can write directly to the destination.
            // SDL otherwise allocates and blends a temporary surface the size
            // of every triangle's bounding box, even for solid backgrounds.
            source = replace(b, source, "    is_uniform = COLOR_EQ(c0, c1) && COLOR_EQ(c1, c2);\n\n    // Flat triangle",
                \\    is_uniform = COLOR_EQ(c0, c1) && COLOR_EQ(c1, c2);
                \\
                \\    if (is_uniform && c0.a == 255 &&
                \\        (blend == SDL_BLENDMODE_BLEND || blend == SDL_BLENDMODE_BLEND_PREMULTIPLIED)) {
                \\        blend = SDL_BLENDMODE_NONE;
                \\    }
                \\
                \\    // Flat triangle
            , 1);
            // Textured triangles must read the destination and composite PMA,
            // as the software rectangle blitter already does. Otherwise they
            // overwrite it with transparent black around the glyph strokes.
            source = replace(b, source, "(SDL_COPY_BLEND | SDL_COPY_ADD | SDL_COPY_MOD | SDL_COPY_MUL)", "SDL_COPY_BLEND_MASK", 2);
            source = replace(b, source, "        case SDL_COPY_ADD:\n", "        case SDL_COPY_ADD:\n        case SDL_COPY_ADD_PREMULTIPLIED:\n", 1);
            source = replace(b, source, "        case SDL_COPY_BLEND:\n",
                \\        case SDL_COPY_BLEND_PREMULTIPLIED:
                \\            dstR = SDL_min(srcR + ((255 - srcA) * dstR) / 255, 255);
                \\            dstG = SDL_min(srcG + ((255 - srcA) * dstG) / 255, 255);
                \\            dstB = SDL_min(srcB + ((255 - srcA) * dstB) / 255, 255);
                \\            dstA = SDL_min(srcA + ((255 - srcA) * dstA) / 255, 255);
                \\            break;
                \\        case SDL_COPY_BLEND:
                \\
            , 1);
        }
        replacement.* = generated.add(path, b.fmt("/* ZIDE software renderer fixes; see tools/sdl_software_patch.zig. */\n{s}", .{source}));
        // Preserve quoted includes relative to each original source directory.
        module.addIncludePath(dependency.path(std.fs.path.dirname(path).?));
    }

    var found: [paths.len]bool = @splat(false);
    // Snapshot this list: addCSourceFile can reallocate module.link_objects.
    const objects = b.allocator.dupe(std.Build.Module.LinkObject, module.link_objects.items) catch @panic("OOM");
    for (objects) |object| switch (object) {
        .c_source_files => |sources| {
            var kept: std.ArrayList([]const u8) = .empty;
            for (sources.files) |file| {
                var patched = false;
                for (paths, replacements, &found) |path, replacement, *seen| {
                    if (!std.mem.eql(u8, file, path)) continue;
                    if (seen.*) @panic("Duplicate SDL software source");
                    seen.* = true;
                    module.addCSourceFile(.{ .file = replacement, .flags = sources.flags, .language = sources.language });
                    patched = true;
                }
                if (!patched) kept.append(b.allocator, file) catch @panic("OOM");
            }
            sources.files = kept.toOwnedSlice(b.allocator) catch @panic("OOM");
        },
        else => {},
    };
    for (found) |seen| if (!seen) @panic("SDL source layout changed; review tools/sdl_software_patch.zig");
}

fn replace(b: *std.Build, source: []const u8, needle: []const u8, replacement: []const u8, expected: ?usize) []const u8 {
    if (expected) |count| {
        if (std.mem.count(u8, source, needle) != count)
            std.debug.panic("SDL source changed; review software patch for: {s}", .{needle});
    }
    return std.mem.replaceOwned(u8, b.allocator, source, needle, replacement) catch @panic("OOM");
}
