const std = @import("std");

const log = @import("log.zig");
const cache = @import("cache.zig");
const util = @import("util.zig");

pub const CachedSeasonInfo = cache.CachedSeasonInfo;
pub const CachedEpisodeInfo = cache.CachedEpisodeInfo;

/// 根据缓存中的“确定性映射”对目标目录内文件重命名。
///
/// 输入：
/// - targetPath：目标目录（已经 link/复制完成）
/// - seasonInfo：缓存中该季的映射信息（包含每集的视频/字幕 src->dst）
///
/// 行为：
/// - 只在 old 存在且 new 不存在时执行 rename（避免覆盖用户已有文件）
pub fn renameFilesBasedOnCache(alloc: std.mem.Allocator, targetPath: []const u8, seasonInfo: CachedSeasonInfo) !void {
    const cwd = std.fs.cwd();
    log.print("  [RENAME] 开始重命名，剧集数: {}\n", .{seasonInfo.episodes.count()});

    const exists = struct {
        /// 判断目标路径是否存在（用于避免 rename 覆盖）。
        fn file(cwd_: std.fs.Dir, p: []const u8) bool {
            _ = cwd_.statFile(p) catch return false;
            return true;
        }
    };

    const EpPtr = struct { sort: f64, ep: *const CachedEpisodeInfo };
    var eps: std.ArrayList(EpPtr) = .empty;
    defer eps.deinit(std.heap.page_allocator);

    var it0 = seasonInfo.episodes.iterator();
    while (it0.next()) |entry| {
        try eps.append(std.heap.page_allocator, .{ .sort = entry.value_ptr.bangumi_sort, .ep = entry.value_ptr });
    }

    std.sort.block(EpPtr, eps.items, {}, struct {
        /// 按 Bangumi sort 升序排序（保证重命名日志/执行顺序稳定）。
        fn less(_: void, a: EpPtr, b: EpPtr) bool {
            return a.sort < b.sort;
        }
    }.less);

    for (eps.items) |item| {
        const ep = item.ep.*;
        const cleanEpName = try util.sanitizeFilename(alloc, ep.bangumi_name);
        defer alloc.free(cleanEpName);

        if (ep.video_src != null and ep.video_dst != null) {
            const oldName = ep.video_src.?;
            const newName = ep.video_dst.?;
            const oldPath = try std.fs.path.join(alloc, &[_][]const u8{ targetPath, oldName });
            const newPath = try std.fs.path.join(alloc, &[_][]const u8{ targetPath, newName });
            defer alloc.free(oldPath);
            defer alloc.free(newPath);

            const old_exists = exists.file(cwd, oldPath);
            const new_exists = exists.file(cwd, newPath);
            if (old_exists and !new_exists) {
                log.print("  [RENAME] 视频: {s} -> {s}\n", .{ oldName, newName });
                cwd.rename(oldPath, newPath) catch |err| {
                    log.print("  [ERROR] 重命名失败: {}\n", .{err});
                };
            }
        }

        var sit = ep.subtitles.iterator();
        while (sit.next()) |se| {
            const oldName = se.key_ptr.*;
            const newName = se.value_ptr.*;
            const oldPath = try std.fs.path.join(alloc, &[_][]const u8{ targetPath, oldName });
            const newPath = try std.fs.path.join(alloc, &[_][]const u8{ targetPath, newName });
            defer alloc.free(oldPath);
            defer alloc.free(newPath);

            const old_exists = exists.file(cwd, oldPath);
            const new_exists = exists.file(cwd, newPath);
            if (old_exists and !new_exists) {
                log.print("  [RENAME] 字幕: {s} -> {s}\n", .{ oldName, newName });
                cwd.rename(oldPath, newPath) catch |err| {
                    log.print("  [ERROR] 重命名字幕失败: {}\n", .{err});
                };
            }
        }
    }
}
