const std = @import("std");

const config = @import("io/config.zig");
const log = @import("io/log.zig");
const api = @import("api.zig");
const cache = @import("io/cache.zig");
const filter = @import("io/filter.zig");
const scan = @import("io/scan.zig");
const link_ops = @import("io/link.zig");
const rename_ops = @import("io/rename.zig");
const util = @import("io/util.zig");

const WorkItem = scan.WorkItem;

const yamlCacheFile = "cache/cache.yaml";

/// 默认视频/字幕扩展名列表（集中定义，避免各处重复/不一致）。
const videoExts = util.default_video_exts;
const subtitleExts = util.default_subtitle_exts;

/// 程序入口。
///
/// 只负责：解析参数、初始化日志、执行一次完整流程。
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var cfg = config.loadFromFile(alloc, "config.toml") catch |err| blk: {
        if (err == error.FileNotFound) break :blk try config.defaultConfig(alloc);
        return err;
    };
    defer config.deinit(&cfg, alloc);

    try config.applyArgsOverrides(alloc, &cfg, args);

    try log.init(alloc, cfg.debug);
    defer log.deinit();

    try runOnce(alloc, cfg);
}

// ============================================================
// 主流程编排（单文件、按阶段分区）
//
// 目标：
// - main 里直接按“模块名”调用（cache/scan/api/link/rename），符合 Zig 直白的风格
// - 不引入额外中间层文件，通过分区注释 + 小函数保持可读性
// ============================================================

/// 执行一次完整处理流程（扫描 -> API/LLM -> 更新缓存 -> 链接/重命名）。
fn runOnce(alloc: std.mem.Allocator, cfg: config.AppConfig) !void {
    // -----------------------------
    // 阶段 0：运行环境 + LLM 配置
    // -----------------------------
    api.llm.configure(.{
        .url = cfg.llm_url,
        .api_key = cfg.llm_api_key,
        .model = cfg.llm_model,
        .prompt_template = cfg.llm_prompt_template,
    });

    const cwd = std.fs.cwd();
    _ = cwd.makePath("cache") catch {};
    _ = cwd.makePath("cache/logs") catch {};

    // -----------------------------
    // 阶段 1：加载/创建 YAML 缓存
    // -----------------------------
    log.print("[INFO] 正在加载缓存...\n", .{});
    var yaml_cache = cache.loadYamlCache(alloc, yamlCacheFile) catch blk: {
        log.print("[WARN] YAML 缓存不存在或加载失败，将创建新缓存\n", .{});
        break :blk cache.YamlCache.init(alloc);
    };
    defer yaml_cache.deinit(alloc);

    // 当前运行路径写回缓存顶层（用于跨机器/换盘符时定位）
    try syncCacheRoots(alloc, cfg, &yaml_cache);
    log.print("[INFO] 缓存加载完成 (WorkItems: {} 条, Seasons: {} 条)\n", .{ yaml_cache.work_items.count(), yaml_cache.seasons.count() });

    // -----------------------------
    // 阶段 2：扫描目录 -> 构建 WorkItem 列表
    // -----------------------------
    log.print("[INFO] 正在扫描目录: {s}\n", .{cfg.base});
    const top_folders = scan.readTopFolders(alloc, cfg.base) catch &[0][]const u8{};
    defer freeStringSlice(alloc, top_folders);
    if (top_folders.len == 0) {
        log.print("[ERROR] 目录下没有找到任何文件夹: {s}\n", .{cfg.base});
        return;
    }

    const work_items = try scan.buildWorkItems(alloc, cfg.base, top_folders, cfg.filter_custom_rules);
    defer freeWorkItems(alloc, work_items);
    log.print("[INFO] 找到 {} 个处理单元（含季子目录拆分）\n", .{work_items.len});

    // -----------------------------
    // 阶段 3：批量 LLM（尽力而为，失败不影响主流程）
    // -----------------------------
    var llm_name_map = tryBatchExtractLlmNames(alloc, work_items);
    defer deinitLlmNameMap(alloc, &llm_name_map);

    // -----------------------------
    // 阶段 4：逐个 WorkItem（API/episodes/local scan/cache 更新）
    // -----------------------------
    log.print("\n[INFO] 开始处理文件夹...\n", .{});
    for (work_items, 0..) |wi, idx| {
        log.print("\n[{}/{}] 处理: {s}\n", .{ idx + 1, work_items.len, wi.key });
        try processOneWorkItem(alloc, cfg, wi, &yaml_cache, &llm_name_map);
    }

    // -----------------------------
    // 阶段 5：写回缓存 + 链接/重命名输出
    // -----------------------------
    try cache.saveYamlCache(yamlCacheFile, &yaml_cache);
    _ = cwd.makePath(cfg.anime) catch {};
    for (work_items) |wi| {
        try linkAndRenameForWorkItem(alloc, cfg, wi, &yaml_cache);
    }
}

// ============================================================
// 工具函数：基础内存/结构释放
// ============================================================

/// 将本次运行的输入/输出根目录写回 YAML 缓存头部。
///
/// 目的：让 cache.yaml 自带来源/目标根路径，便于跨机器/换盘符时定位。
fn syncCacheRoots(alloc: std.mem.Allocator, cfg: config.AppConfig, yaml_cache: *cache.YamlCache) !void {
    if (yaml_cache.source_root.len > 0) alloc.free(yaml_cache.source_root);
    if (yaml_cache.target_root.len > 0) alloc.free(yaml_cache.target_root);
    yaml_cache.source_root = try alloc.dupe(u8, cfg.base);
    yaml_cache.target_root = try alloc.dupe(u8, cfg.anime);
}

/// 释放 `[]const []const u8`：先 free 每个字符串，再 free 容器。
fn freeStringSlice(alloc: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| alloc.free(s);
    alloc.free(items);
}

/// 释放 WorkItem 列表中每个条目的字符串字段。
fn freeWorkItems(alloc: std.mem.Allocator, work_items: []WorkItem) void {
    for (work_items) |wi| {
        alloc.free(wi.key);
        alloc.free(wi.input_rel);
        alloc.free(wi.output_rel);
        alloc.free(wi.search_term);
        if (wi.series_hint) |h| alloc.free(h);
    }
    alloc.free(work_items);
}

// ============================================================
// 阶段 3：LLM 批量（best-effort）
// ============================================================

/// 批量把 WorkItem key 交给 LLM 提取番剧名。
///
/// 失败时返回空 map（不中断主流程）。
fn tryBatchExtractLlmNames(alloc: std.mem.Allocator, work_items: []const WorkItem) std.StringHashMap([]const u8) {
    var llm_keys = std.ArrayList([]const u8).empty;
    defer llm_keys.deinit(alloc);

    for (work_items) |wi| {
        llm_keys.append(alloc, wi.key) catch {};
    }

    log.print("[INFO] 正在批量请求 LLM 提取番剧名...\n", .{});
    const map = api.llm.extractAnimeNamesWithLLM(alloc, llm_keys.items) catch blk: {
        log.print("[WARN] 批量 LLM 提取失败，将仅使用规则/API 路径\n", .{});
        break :blk std.StringHashMap([]const u8).init(alloc);
    };
    log.print("[INFO] LLM 批量提取完成：{} 条\n", .{map.count()});
    return map;
}

/// 释放 LLM 批量返回的 HashMap（key/value 都由 alloc 分配）。
fn deinitLlmNameMap(alloc: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.*);
    }
    map.deinit();
}

// ============================================================
// 阶段 4：Bangumi/episodes 解析 + cache 更新
// ============================================================

/// 更新 `yaml_cache.work_items`：写入来源/目标/查询词与最终 Bangumi 结果。
fn upsertWorkItemCacheEntry(
    alloc: std.mem.Allocator,
    yaml_cache: *cache.YamlCache,
    wi: WorkItem,
    bangumi_id: i32,
    bangumi_name: []const u8,
) !void {
    if (yaml_cache.work_items.getPtr(wi.key)) |old| {
        old.deinit(alloc);
        old.* = .{
            .source_rel = try alloc.dupe(u8, wi.input_rel),
            .target_rel = try alloc.dupe(u8, wi.output_rel),
            .search_term = try alloc.dupe(u8, wi.search_term),
            .bangumi_season_id = bangumi_id,
            .bangumi_season_name = try alloc.dupe(u8, bangumi_name),
        };
        return;
    }

    const key = try alloc.dupe(u8, wi.key);
    try yaml_cache.work_items.put(key, .{
        .source_rel = try alloc.dupe(u8, wi.input_rel),
        .target_rel = try alloc.dupe(u8, wi.output_rel),
        .search_term = try alloc.dupe(u8, wi.search_term),
        .bangumi_season_id = bangumi_id,
        .bangumi_season_name = try alloc.dupe(u8, bangumi_name),
    });
}

/// 从 WorkItem 缓存条目构造一个 `api.Season`。
///
/// 注意：这里会为 name/platform 分配内存，调用方必须 `api.deinitSeason`。
fn seasonFromCacheEntry(alloc: std.mem.Allocator, entry: cache.WorkItemCacheEntry) !api.Season {
    return .{
        .id = entry.bangumi_season_id,
        .name = try alloc.dupe(u8, entry.bangumi_season_name),
        .platform = try alloc.dupe(u8, "Unknown"),
        .eps = 0,
        .score = 0.0,
    };
}

/// 根据 WorkItem 获取最终应使用的 Season（优先缓存，其次 API，再用 LLM 回退/校验）。
///
/// - 若返回非空，Season 内部字符串由 alloc 分配，调用方必须 `api.deinitSeason`。
/// - 会在确定最终 Season 后写回 `yaml_cache.work_items`。
fn resolveSeasonForWorkItem(
    alloc: std.mem.Allocator,
    cfg: config.AppConfig,
    wi: WorkItem,
    yaml_cache: *cache.YamlCache,
    llm_name_map: *std.StringHashMap([]const u8),
) !?api.Season {
    if (yaml_cache.work_items.get(wi.key)) |entry| {
        log.print("  [CACHE] 从 YAML 缓存获取: ID={}, 名称={s}\n", .{ entry.bangumi_season_id, entry.bangumi_season_name });
        return try seasonFromCacheEntry(alloc, entry);
    }

    log.print("  [INFO] 查询关键词: {s}\n", .{wi.search_term});
    if (wi.search_term.len == 0) {
        log.print("  [WARN] 无法提取动画名称，跳过: {s}\n", .{wi.key});
        return null;
    }

    log.print("  [INFO] 正在调用 Bangumi API 查询: {s}\n", .{wi.search_term});
    const season_from_api = api.getSeason(alloc, wi.search_term, cfg.use_cn) catch |err| blk: {
        log.print("  [WARN] Bangumi API 调用失败: {s}\n", .{@errorName(err)});
        break :blk null;
    };

    if (season_from_api) |s| {
        log.print("  [SUCCESS] API 返回: ID={}, 名称={s}\n", .{ s.id, s.name });

        if (filter.needVerifySeason(wi.key, s.name)) {
            log.print("  [VERIFY] API结果可能不匹配，使用LLM验证...\n", .{});
            if (llm_name_map.get(wi.key)) |llm_name| {
                log.print("  [LLM] LLM提取: {s}，与API对比: {s}\n", .{ llm_name, s.name });

                if (!filter.namesRoughlyMatch(s.name, llm_name)) {
                    log.print("  [LLM] LLM与API不一致，使用LLM重新查询...\n", .{});
                    const season_from_llm = api.getSeason(alloc, llm_name, cfg.use_cn) catch |err| blk_llm: {
                        log.print("  [WARN] Bangumi API (LLM关键字) 调用失败: {s}\n", .{@errorName(err)});
                        break :blk_llm null;
                    };
                    if (season_from_llm) |ls| {
                        log.print("  [LLM] 采用LLM结果: ID={}, 名称={s}\n", .{ ls.id, ls.name });
                        api.deinitSeason(alloc, s);
                        try upsertWorkItemCacheEntry(alloc, yaml_cache, wi, ls.id, ls.name);
                        return ls;
                    }
                }
            } else {
                log.print("  [VERIFY] LLM提取失败，保留API结果\n", .{});
            }
        }

        try upsertWorkItemCacheEntry(alloc, yaml_cache, wi, s.id, s.name);
        return s;
    }

    log.print("  [WARN] 规则/API 提取失败，尝试使用 LLM 提取番剧名称...\n", .{});
    if (llm_name_map.get(wi.key)) |llm_name| {
        log.print("  [LLM] LLM 提取成功，重新调用 Bangumi API 查询: {s}\n", .{llm_name});
        const season_from_llm = api.getSeason(alloc, llm_name, cfg.use_cn) catch |err| blk2: {
            log.print("  [WARN] Bangumi API (LLM关键字) 调用失败: {s}\n", .{@errorName(err)});
            break :blk2 null;
        };
        if (season_from_llm) |ls| {
            log.print("  [SUCCESS] LLM 辅助成功！API 返回: ID={}, 名称={s}\n", .{ ls.id, ls.name });
            try upsertWorkItemCacheEntry(alloc, yaml_cache, wi, ls.id, ls.name);
            return ls;
        }
        log.print("  [ERROR] LLM 辅助后 API 仍未返回结果，跳过: {s}\n", .{wi.key});
        return null;
    }

    log.print("  [ERROR] LLM 提取失败，跳过: {s}\n", .{wi.key});
    return null;
}

/// 获取番剧的 episodes 列表：优先使用缓存（若存在），否则请求 Bangumi。
///
/// - 若命中缓存，会把 `used_cached_eps` 置为 true。
fn loadEpisodeList(
    alloc: std.mem.Allocator,
    cfg: config.AppConfig,
    yaml_cache: *cache.YamlCache,
    season_id: i32,
    used_cached_eps: *bool,
) !std.ArrayList(api.Episode) {
    var episode_list = std.ArrayList(api.Episode).empty;
    errdefer api.deinitEpisodeList(alloc, &episode_list);

    var season_id_buf: [32]u8 = undefined;
    const season_id_str = try std.fmt.bufPrint(&season_id_buf, "{d}", .{season_id});

    // 兼容旧版本 cache：优先拉取最新 episodes（避免旧缓存混入特典导致 E01/E02 名称错误）。
    // 如果网络/接口失败，再回退使用缓存。
    const prefer_refresh = yaml_cache.version < 2;

    const eps_opt = api.getEpisodes(alloc, season_id, cfg.use_cn) catch |err| blk_api: {
        if (!prefer_refresh) return err;
        log.print("  [WARN] Bangumi episodes 刷新失败，将回退缓存: {s}\n", .{@errorName(err)});
        break :blk_api null;
    };
    if (eps_opt) |eps| {
        episode_list = eps;
        return episode_list;
    }

    if (yaml_cache.seasons.get(season_id_str)) |cached| {
        if (cached.episodes.count() > 0) {
            var it = cached.episodes.iterator();
            while (it.next()) |ep_entry| {
                const epv = ep_entry.value_ptr.*;
                try episode_list.append(alloc, .{ .sort = epv.bangumi_sort, .name = try alloc.dupe(u8, epv.bangumi_name) });
            }
            std.sort.block(api.Episode, episode_list.items, {}, struct {
                /// 按 sort 升序排序，保证缓存回放的 episode 列表稳定。
                fn less(_: void, a: api.Episode, b: api.Episode) bool {
                    return a.sort < b.sort;
                }
            }.less);
            used_cached_eps.* = true;
            return episode_list;
        }
    }

    log.print("Failed episodes {d}\n", .{season_id});
    return error.EpisodesNotFound;
}

/// 处理单个 WorkItem：
/// - resolve season（cache/API/LLM）
/// - load episodes（cache/API）
/// - 扫描本地文件
/// - 更新 YAML cache（seasons/episodes/files）
fn processOneWorkItem(
    alloc: std.mem.Allocator,
    cfg: config.AppConfig,
    wi: WorkItem,
    yaml_cache: *cache.YamlCache,
    llm_name_map: *std.StringHashMap([]const u8),
) !void {
    var used_cached_eps: bool = false;

    const season_opt = try resolveSeasonForWorkItem(alloc, cfg, wi, yaml_cache, llm_name_map);
    if (season_opt == null) return;
    const season = season_opt.?;
    defer api.deinitSeason(alloc, season);

    var episode_list = try loadEpisodeList(alloc, cfg, yaml_cache, season.id, &used_cached_eps);
    defer api.deinitEpisodeList(alloc, &episode_list);

    var local_files = try scan.scanLocalFiles(
        alloc,
        cfg.base,
        wi.input_rel,
        wi.season_filter,
        wi.treat_unmarked_as_s1,
        wi.series_hint,
    );
    defer {
        for (local_files.items) |f| f.deinit(alloc);
        local_files.deinit(alloc);
    }

    if (used_cached_eps and episode_list.items.len <= 1 and local_files.items.len > 1) {
        const eps_opt = api.getEpisodes(alloc, season.id, cfg.use_cn) catch |err| blk: {
            log.print("  [WARN] 刷新 Bangumi episodes 失败: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (eps_opt) |fresh| {
            api.deinitEpisodeList(alloc, &episode_list);
            episode_list = fresh;
            used_cached_eps = false;
        }
    }

    try cache.updateCache(alloc, &yaml_cache.seasons, season, episode_list, local_files.items, videoExts[0..], subtitleExts[0..]);
}

// ============================================================
// 阶段 5：link + rename 输出
// ============================================================

/// 基于 yaml_cache 的结果，把源目录硬链接到目标目录，并按缓存规则重命名。
fn linkAndRenameForWorkItem(
    alloc: std.mem.Allocator,
    cfg: config.AppConfig,
    wi: WorkItem,
    yaml_cache: *cache.YamlCache,
) !void {
    const source_dir = try std.fs.path.join(alloc, &[_][]const u8{ cfg.base, wi.input_rel });
    defer alloc.free(source_dir);
    const target_dir = try std.fs.path.join(alloc, &[_][]const u8{ cfg.anime, wi.output_rel });
    defer alloc.free(target_dir);

    std.fs.cwd().deleteTree(target_dir) catch |e| {
        log.print("  [WARN] 清理旧输出目录失败: {s} ({s})\n", .{ target_dir, @errorName(e) });
    };

    link_ops.createDirectoryHardLinkFiltered(alloc, source_dir, target_dir, wi.season_filter, wi.treat_unmarked_as_s1, wi.series_hint) catch |e| {
        log.print("link error {s}: {s}\n", .{ wi.key, @errorName(e) });
        return;
    };

    const wi_entry = yaml_cache.work_items.get(wi.key) orelse return;
    var id_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{wi_entry.bangumi_season_id});
    const info = yaml_cache.seasons.get(id_str) orelse return;

    rename_ops.renameFilesBasedOnCache(alloc, target_dir, info) catch |err| {
        log.print("  [WARN] 重命名文件失败: {}\n", .{err});
    };

    const desired_name = try util.sanitizeFilename(alloc, info.bangumi_season_name);
    defer alloc.free(desired_name);

    const original_name = std.fs.path.basename(wi.output_rel);
    var final_target_dir: []const u8 = target_dir;
    var final_target_dir_owned: ?[]u8 = null;
    defer if (final_target_dir_owned) |p| alloc.free(p);
    if (!std.mem.eql(u8, original_name, desired_name)) {
        const new_path = try std.fs.path.join(alloc, &[_][]const u8{ cfg.anime, desired_name });
        final_target_dir_owned = new_path;
        final_target_dir = new_path;

        std.fs.cwd().rename(target_dir, new_path) catch {
            std.fs.cwd().deleteTree(new_path) catch |e| {
                log.print("  [WARN] 删除已存在目标目录失败: {s} ({s})\n", .{ new_path, @errorName(e) });
            };
            std.fs.cwd().rename(target_dir, new_path) catch {
                link_ops.mergeDirectoryOverwrite(std.fs.cwd(), alloc, target_dir, new_path) catch {};
            };
        };
    }

    // 特典/附加内容：在输出番剧目录下创建同名子目录，并按 type=1 重命名。
    if (cfg.special_folders.len > 0) {
        handleSpecialFolders(alloc, cfg, wi, source_dir, final_target_dir, wi_entry.bangumi_season_id) catch |e| {
            log.print("  [WARN] 处理特典目录失败: {s}\n", .{@errorName(e)});
        };
    }

    if (std.fs.path.dirname(wi.output_rel)) |parent_rel| {
        if (parent_rel.len > 0) {
            const parent_abs = std.fs.path.join(alloc, &[_][]const u8{ cfg.anime, parent_rel }) catch null;
            if (parent_abs) |p| {
                defer alloc.free(p);
                std.fs.cwd().deleteDir(p) catch {};
            }
        }
    }
}

/// 处理用户配置的“特典文件夹名列表”：
/// - 若源目录内存在同名子目录，则硬链接到输出番剧目录下
/// - 使用 Bangumi episodes(type=1) 在该子目录内执行重命名（默认前缀 SP）
fn handleSpecialFolders(
    alloc: std.mem.Allocator,
    cfg: config.AppConfig,
    wi: WorkItem,
    source_dir: []const u8,
    target_anime_dir: []const u8,
    season_id: i32,
) !void {
    // 先探测是否存在任何一个特典目录；没有就直接返回，避免无谓 API 请求。
    if (!scan.anyNamedSubfolderExists(alloc, source_dir, cfg.special_folders)) return;

    const eps_opt = api.getEpisodesByType(alloc, season_id, cfg.use_cn, 1) catch |err| {
        log.print("  [WARN] Bangumi 特典 episodes 获取失败，跳过特典重命名: {s}\n", .{@errorName(err)});
        return;
    };
    if (eps_opt == null) return;
    var special_eps = eps_opt.?;
    defer api.deinitEpisodeList(alloc, &special_eps);
    if (special_eps.items.len == 0) return;

    for (cfg.special_folders) |folder_name| {
        const src_special = try std.fs.path.join(alloc, &[_][]const u8{ source_dir, folder_name });
        defer alloc.free(src_special);

        // 源目录不存在则跳过。
        if (std.fs.cwd().openDir(src_special, .{ .iterate = true }) catch null) |dir_val| {
            var d = dir_val;
            d.close();
        } else {
            continue;
        }

        const tgt_special = try std.fs.path.join(alloc, &[_][]const u8{ target_anime_dir, folder_name });
        defer alloc.free(tgt_special);

        std.fs.cwd().deleteTree(tgt_special) catch {};
        link_ops.createDirectoryHardLink(alloc, src_special, tgt_special) catch |e| {
            log.print("  [WARN] 特典硬链接失败({s}): {s}\n", .{ folder_name, @errorName(e) });
            continue;
        };

        // 扫描该特典目录本地文件，并仅保留“看起来像特别篇/SP”的条目参与映射与重命名。
        var sp_only = try scan.scanLikelySpecialEpisodeFilesInSubfolder(
            alloc,
            cfg.base,
            wi.input_rel,
            folder_name,
            wi.series_hint,
        );
        defer {
            for (sp_only.items) |f| f.deinit(alloc);
            sp_only.deinit(alloc);
        }
        if (sp_only.items.len == 0) continue;

        var temp = try cache.buildTempSeasonInfoForRename(
            alloc,
            season_id,
            folder_name,
            special_eps,
            sp_only.items,
            videoExts[0..],
            subtitleExts[0..],
            "SP",
        );
        defer temp.deinit(alloc);

        rename_ops.renameFilesBasedOnCache(alloc, tgt_special, temp) catch |e| {
            log.print("  [WARN] 特典重命名失败({s}): {s}\n", .{ folder_name, @errorName(e) });
        };
    }
}
