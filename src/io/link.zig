const std = @import("std");

const filter = @import("filter.zig");
const util = @import("util.zig");

/// link 模块：负责在输入和输出文件夹里创建硬链接（失败回退复制），以及目录合并。
///
/// 设计目的：
/// - 输出目录尽量使用硬链接，节省空间
/// - 硬链接失败（例如权限/文件系统不支持）时回退到复制
// 文件类型判断/大小写工具统一放在 io/util.zig。

/// 在目标目录下创建与源目录等结构的硬链接（仅处理视频/字幕）。
///
/// - 目录会被递归创建
/// - 每个文件：优先硬链接，失败时回退到复制
pub fn createDirectoryHardLink(alloc: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    var source_dir = try std.fs.cwd().openDir(source, .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(alloc);
    defer walker.deinit();

    var fs_cwd = std.fs.cwd();
    try fs_cwd.makePath(target);

    while (try walker.next()) |entry| {
        const rel = entry.path;
        const tgt_rel = try std.fs.path.join(alloc, &[_][]const u8{ target, rel });
        defer alloc.free(tgt_rel);

        if (entry.kind == .directory) {
            try fs_cwd.makePath(tgt_rel);
            continue;
        }

        const basename = entry.basename;
        if (!util.isVideoFile(basename) and !util.isSubtitleFile(basename)) continue;

        if (std.fs.path.dirname(tgt_rel)) |dirp| try fs_cwd.makePath(dirp);

        const src_abs = try std.fs.path.join(alloc, &[_][]const u8{ source, rel });
        defer alloc.free(src_abs);
        const tgt_abs = try alloc.dupe(u8, tgt_rel);
        defer alloc.free(tgt_abs);

        linkFileAbsolute(alloc, src_abs, tgt_abs) catch {
            try std.fs.copyFileAbsolute(src_abs, tgt_abs, .{});
        };
    }
}

/// 创建硬链接目录结构（带过滤）。
///
/// 过滤规则：
/// - series_hint：文件名必须包含该子串（忽略大小写）
/// - season_filter：只保留匹配季号的文件；若文件不含季号，可用 treat_unmarked_as_s1 放行 S1
pub fn createDirectoryHardLinkFiltered(
    alloc: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
    season_filter: ?u8,
    treat_unmarked_as_s1: bool,
    series_hint: ?[]const u8,
) !void {
    var source_dir = try std.fs.cwd().openDir(source, .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(alloc);
    defer walker.deinit();

    var fs_cwd = std.fs.cwd();
    try fs_cwd.makePath(target);

    while (try walker.next()) |entry| {
        const rel = entry.path;
        const tgt_rel = try std.fs.path.join(alloc, &[_][]const u8{ target, rel });
        defer alloc.free(tgt_rel);

        if (entry.kind == .directory) {
            try fs_cwd.makePath(tgt_rel);
            continue;
        }

        const basename = entry.basename;
        if (!util.isVideoFile(basename) and !util.isSubtitleFile(basename)) continue;

        if (series_hint) |hint| {
            if (std.ascii.indexOfIgnoreCase(basename, hint) == null) continue;
        }

        if (season_filter) |sn| {
            const sn_opt = filter.detectSeasonNumber(basename);
            if (sn_opt == null) {
                if (!(treat_unmarked_as_s1 and sn == 1)) continue;
            } else if (sn_opt.? != sn) {
                continue;
            }
        }

        if (std.fs.path.dirname(tgt_rel)) |dirp| try fs_cwd.makePath(dirp);

        const src_abs = try std.fs.path.join(alloc, &[_][]const u8{ source, rel });
        defer alloc.free(src_abs);
        const tgt_abs = try alloc.dupe(u8, tgt_rel);
        defer alloc.free(tgt_abs);

        linkFileAbsolute(alloc, src_abs, tgt_abs) catch {
            try std.fs.copyFileAbsolute(src_abs, tgt_abs, .{});
        };
    }
}

/// 合并目录：将 `src_dir_path` 下的文件覆盖移动到 `dst_dir_path`。
///
/// 主要用于目录重命名冲突时的兜底：
/// - 先尝试 rename
/// - 失败则 merge 覆盖移动
pub fn mergeDirectoryOverwrite(cwd: std.fs.Dir, alloc: std.mem.Allocator, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    _ = alloc;
    _ = cwd.makePath(dst_dir_path) catch {};

    const src_opt = cwd.openDir(src_dir_path, .{ .iterate = true }) catch null;
    if (src_opt == null) return;
    var src_dir = src_opt.?;
    defer src_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const src_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ src_dir_path, entry.name });
        defer std.heap.page_allocator.free(src_path);
        const dst_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dst_dir_path, entry.name });
        defer std.heap.page_allocator.free(dst_path);

        cwd.deleteFile(dst_path) catch {};
        cwd.rename(src_path, dst_path) catch {};
    }

    cwd.deleteDir(src_dir_path) catch {};
}

/// 创建硬链接（绝对路径）。
///
/// Windows：使用 MoveFileExW + MOVEFILE_CREATE_HARDLINK。
/// 其他平台：使用 std.posix.link。
fn linkFileAbsolute(alloc: std.mem.Allocator, src_abs: []const u8, tgt_abs: []const u8) !void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const k32 = std.os.windows.kernel32;
        const src_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, src_abs);
        defer alloc.free(src_w);
        const tgt_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, tgt_abs);
        defer alloc.free(tgt_w);

        if (k32.MoveFileExW(src_w.ptr, tgt_w.ptr, w.MOVEFILE_CREATE_HARDLINK) == 0) {
            return error.OperationUnsupported;
        }
        return;
    }

    try std.posix.link(src_abs, tgt_abs);
}
