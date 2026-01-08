const std = @import("std");

const filter = @import("filter.zig");
const util = @import("util.zig");

/// scan 模块：负责扫描目录、读取文件夹名字、构建处理单元（WorkItem）。
/// 本地扫描到的文件信息。
/// - `rel_path`：相对“扫描目录”的路径（可能包含子目录）
/// - `name_only`：不含扩展名的文件名
/// - `ext`：扩展名（包含点，例如 ".mkv"）
/// - `full_path`：用于直接访问文件系统的完整路径
pub const LocalFileInfo = struct {
    rel_path: []const u8,
    name_only: []const u8,
    ext: []const u8,
    full_path: []const u8,

    /// 释放 LocalFileInfo 内部的 owned 字符串。
    pub fn deinit(self: LocalFileInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.rel_path);
        alloc.free(self.name_only);
        alloc.free(self.ext);
        alloc.free(self.full_path);
    }
};

/// 读取目录下的一级子目录名称列表。
///
/// 返回的每个字符串都由 `alloc` 分配，调用方负责释放。
pub fn readTopFolders(alloc: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(alloc);

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try out.append(alloc, try alloc.dupe(u8, entry.name));
    }

    return out.toOwnedSlice(alloc);
}

// 文件类型判断/大小写工具统一放在 io/util.zig。

/// 扫描 WorkItem 对应目录下的所有文件，并按季/系列提示进行过滤。
pub fn scanLocalFiles(
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    input_rel: []const u8,
    season_filter: ?u8,
    treat_unmarked_as_s1: bool,
    series_hint: ?[]const u8,
) !std.ArrayList(LocalFileInfo) {
    var localFiles = std.ArrayList(LocalFileInfo).empty;
    errdefer {
        for (localFiles.items) |file| file.deinit(alloc);
        localFiles.deinit(alloc);
    }

    const walkPath = std.fs.path.join(alloc, &[_][]const u8{ base_dir, input_rel }) catch null;
    defer if (walkPath) |p| alloc.free(p);

    if (walkPath) |p| {
        const dir_opt: ?std.fs.Dir = std.fs.cwd().openDir(p, .{ .iterate = true }) catch null;
        if (dir_opt) |d0| {
            var d = d0;
            defer d.close();

            const walker_opt = d.walk(alloc) catch null;
            if (walker_opt) |w0| {
                var w = w0;
                defer w.deinit();

                while (try w.next()) |entry| {
                    if (entry.kind != .file) continue;

                    const basename = entry.basename;
                    const rel_path = entry.path;

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

                    const stem = std.fs.path.stem(basename);
                    const ext = std.fs.path.extension(basename);
                    const full = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, input_rel, rel_path });

                    try localFiles.append(alloc, .{
                        .rel_path = try alloc.dupe(u8, rel_path),
                        .name_only = try alloc.dupe(u8, stem),
                        .ext = try alloc.dupe(u8, ext),
                        .full_path = full,
                    });
                }
            }
        }
    }

    return localFiles;
}

/// 一个“处理单元”。
pub const WorkItem = struct {
    key: []const u8,
    input_rel: []const u8,
    output_rel: []const u8,
    search_term: []const u8,
    season_filter: ?u8,
    treat_unmarked_as_s1: bool,
    series_hint: ?[]const u8,
};

/// 根据扫描到的顶层目录列表，构建 WorkItem 列表。
///
/// 构建策略：
/// 1) 若检测到明确的季子目录（例如 "Season 2" / "S02"），则每个季目录单独生成一个 WorkItem。
/// 2) 否则尝试从文件名/路径中推断多季（例如同一目录下出现 S01/S02/S03）。
pub fn buildWorkItems(
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    top_folders: []const []const u8,
    custom_rules: []const []const u8,
) ![]WorkItem {
    var out = std.ArrayList(WorkItem).empty;
    errdefer {
        for (out.items) |it| {
            alloc.free(it.key);
            alloc.free(it.input_rel);
            alloc.free(it.output_rel);
            alloc.free(it.search_term);
            if (it.series_hint) |h| alloc.free(h);
        }
        out.deinit(alloc);
    }

    // 从任意文本中标记出现过的季号（形如 S1/S02/...）。
    const markSeasonsFromText = struct {
        /// 扫描 text，找出形如 Sxx 的季号并记录到 found。
        fn run(text: []const u8, found: *[33]bool, found_count: *usize) void {
            var i: usize = 0;
            while (i + 1 < text.len) : (i += 1) {
                const c = text[i];
                if (c != 'S' and c != 's') continue;
                if (i + 1 >= text.len or !std.ascii.isDigit(text[i + 1])) continue;
                var k = i + 1;
                while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
                const n = std.fmt.parseInt(u8, text[i + 1 .. k], 10) catch 0;
                if (n > 0 and n < found.len and !found[n]) {
                    found[n] = true;
                    found_count.* += 1;
                }
            }
        }
    };

    for (top_folders) |folder| {
        const abs_folder = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, folder });
        defer alloc.free(abs_folder);

        var season_dirs = std.ArrayList(struct { name: []const u8, season: u8 }).empty;
        defer {
            for (season_dirs.items) |sd| alloc.free(sd.name);
            season_dirs.deinit(alloc);
        }

        const dir_opt: ?std.fs.Dir = std.fs.cwd().openDir(abs_folder, .{ .iterate = true }) catch null;
        if (dir_opt) |d0| {
            var d = d0;
            defer d.close();
            var it = d.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (filter.parseSeasonFromDirName(entry.name)) |sn| {
                    try season_dirs.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .season = sn });
                }
            }
        }

        if (season_dirs.items.len > 0) {
            const base_name0 = try filter.extractAnimeName(alloc, folder);
            defer alloc.free(base_name0);
            const base_name = try filter.applyCustomRules(alloc, base_name0, custom_rules);
            defer alloc.free(base_name);

            for (season_dirs.items) |sd| {
                const rel = try std.fs.path.join(alloc, &[_][]const u8{ folder, sd.name });
                const key = try alloc.dupe(u8, rel);
                const input_rel = try alloc.dupe(u8, rel);
                const output_rel = try alloc.dupe(u8, rel);
                alloc.free(rel);

                const term = if (sd.season <= 1)
                    try alloc.dupe(u8, base_name)
                else
                    try std.fmt.allocPrint(alloc, "{s} Season {d}", .{ base_name, sd.season });

                try out.append(alloc, .{
                    .key = key,
                    .input_rel = input_rel,
                    .output_rel = output_rel,
                    .search_term = term,
                    .season_filter = null,
                    .treat_unmarked_as_s1 = false,
                    .series_hint = null,
                });
            }
        } else {
            var found: [33]bool = .{false} ** 33;
            var found_count: usize = 0;

            const dir_opt2: ?std.fs.Dir = std.fs.cwd().openDir(abs_folder, .{ .iterate = true }) catch null;
            if (dir_opt2) |d0| {
                var d = d0;
                defer d.close();

                const walker_opt = d.walk(alloc) catch null;
                if (walker_opt) |w0| {
                    var w = w0;
                    defer w.deinit();
                    var seen: usize = 0;
                    while (seen < 600) : (seen += 1) {
                        const next = w.next() catch null;
                        if (next == null) break;
                        const entry = next.?;
                        if (entry.kind != .file) continue;
                        const bn = entry.basename;
                        if (!util.isVideoFile(bn) and !util.isSubtitleFile(bn)) continue;
                        if (filter.detectSeasonNumber(bn)) |sn| {
                            if (sn < found.len and !found[sn]) {
                                found[sn] = true;
                                found_count += 1;
                            }
                        }
                        if (found_count >= 3) break;
                    }
                }
            }

            const base_name0 = try filter.extractAnimeName(alloc, folder);
            defer alloc.free(base_name0);
            const base_name = try filter.applyCustomRules(alloc, base_name0, custom_rules);
            defer alloc.free(base_name);

            markSeasonsFromText.run(folder, &found, &found_count);

            if (found_count >= 2) {
                const hint = try alloc.dupe(u8, base_name);
                var sn: u8 = 1;
                while (sn < found.len) : (sn += 1) {
                    if (!found[sn]) continue;

                    const key = try std.fmt.allocPrint(alloc, "{s}::S{d}", .{ folder, sn });
                    const input_rel = try alloc.dupe(u8, folder);

                    const season_dir_name = try std.fmt.allocPrint(alloc, "Season {d}", .{sn});
                    defer alloc.free(season_dir_name);

                    const output_rel = try std.fs.path.join(alloc, &[_][]const u8{ folder, season_dir_name });

                    const term = if (sn <= 1)
                        try alloc.dupe(u8, base_name)
                    else
                        try std.fmt.allocPrint(alloc, "{s} Season {d}", .{ base_name, sn });

                    try out.append(alloc, .{
                        .key = key,
                        .input_rel = input_rel,
                        .output_rel = output_rel,
                        .search_term = term,
                        .season_filter = sn,
                        .treat_unmarked_as_s1 = sn == 1,
                        .series_hint = try alloc.dupe(u8, hint),
                    });
                }
                alloc.free(hint);
            } else {
                const key = try alloc.dupe(u8, folder);
                const input_rel = try alloc.dupe(u8, folder);
                const output_rel = try alloc.dupe(u8, folder);
                const term = try alloc.dupe(u8, base_name);

                try out.append(alloc, .{
                    .key = key,
                    .input_rel = input_rel,
                    .output_rel = output_rel,
                    .search_term = term,
                    .season_filter = null,
                    .treat_unmarked_as_s1 = false,
                    .series_hint = null,
                });
            }
        }
    }

    return out.toOwnedSlice(alloc);
}

/// 扫描 WorkItem 下某个子目录，并仅保留“看起来像特别篇/SP”的文件。
///
/// 适用场景：例如“映像特典”目录里混有 OP/ED/PV/MENU/CM 等素材，
/// 这些文件名常带数字（如 "ED 1"）会被误识别成集号，导致覆盖 SP01/02。
///
/// 返回的 ArrayList 内每个 `LocalFileInfo` 都是 owned，调用方负责逐个 deinit。
pub fn scanLikelySpecialEpisodeFilesInSubfolder(
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    wi_input_rel: []const u8,
    folder_name: []const u8,
    series_hint: ?[]const u8,
) !std.ArrayList(LocalFileInfo) {
    const rel_special = try std.fs.path.join(alloc, &[_][]const u8{ wi_input_rel, folder_name });
    defer alloc.free(rel_special);

    var files = try scanLocalFiles(
        alloc,
        base_dir,
        rel_special,
        null,
        false,
        series_hint,
    );
    errdefer {
        for (files.items) |f| f.deinit(alloc);
        files.deinit(alloc);
    }

    var i: usize = 0;
    while (i < files.items.len) {
        if (!isLikelySpecialEpisodeName(files.items[i].name_only)) {
            files.items[i].deinit(alloc);
            _ = files.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    return files;
}

/// 检测某个目录下是否存在任意一个指定的子目录名。
///
/// 用途：在处理“特典目录”前先快速判断是否有必要继续（避免无谓 API 请求）。
pub fn anyNamedSubfolderExists(
    alloc: std.mem.Allocator,
    parent_dir: []const u8,
    folder_names: []const []const u8,
) bool {
    for (folder_names) |folder_name| {
        const child = std.fs.path.join(alloc, &[_][]const u8{ parent_dir, folder_name }) catch continue;
        defer alloc.free(child);

        if (std.fs.cwd().openDir(child, .{ .iterate = true })) |dir_val| {
            var d = dir_val;
            d.close();
            return true;
        } else |_| {}
    }
    return false;
}

/// 判断一个文件名（不含扩展名）是否“像是”特别篇/特典正片条目。
///
/// 目标：只命中真正的特别篇(例如 特别篇1/2、SP01)，避免 OP/ED/PV/MENU/CM 等素材误伤。
fn isLikelySpecialEpisodeName(name_only: []const u8) bool {
    if (name_only.len == 0) return false;

    // 明确关键词：特别篇/特別篇
    if (util.containsIgnoreCase(name_only, "特别篇") or util.containsIgnoreCase(name_only, "特別篇")) return true;

    // SPxx：允许大小写。
    // 用简单规则避免把 "...S1..." 之类误判：必须包含 "SP" 连在一起且后面跟数字。
    if (util.containsIgnoreCase(name_only, "SP")) {
        var i: usize = 0;
        while (i + 2 < name_only.len) : (i += 1) {
            const c0 = name_only[i];
            const c1 = name_only[i + 1];
            if (!((c0 == 'S' or c0 == 's') and (c1 == 'P' or c1 == 'p'))) continue;
            if (std.ascii.isDigit(name_only[i + 2])) return true;
        }
    }

    return false;
}
