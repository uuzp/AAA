const std = @import("std");
const regex = @import("regex.zig");
const util = @import("util.zig");

/// filter 模块：负责“文本解析/命名推断/规则应用”。
///
/// 主要职责：
/// - 从目录名/文件名中解析季号、集号等信息
/// - 从复杂文件夹名中提取用于 Bangumi 搜索的番剧关键词
/// - 应用用户自定义规则（类正则/正则），对关键词做清洗
// 大小写无关的字符串判断统一放在 io/util.zig。

/// 将“第一季/第二季/...”这类中文序数转换为季号。
///
/// 当前只覆盖 1~10（满足大多数场景）；未匹配则返回 null。
fn chineseSeasonToInt(s: []const u8) ?u8 {
    if (std.mem.indexOf(u8, s, "第一") != null) return 1;
    if (std.mem.indexOf(u8, s, "第二") != null) return 2;
    if (std.mem.indexOf(u8, s, "第三") != null) return 3;
    if (std.mem.indexOf(u8, s, "第四") != null) return 4;
    if (std.mem.indexOf(u8, s, "第五") != null) return 5;
    if (std.mem.indexOf(u8, s, "第六") != null) return 6;
    if (std.mem.indexOf(u8, s, "第七") != null) return 7;
    if (std.mem.indexOf(u8, s, "第八") != null) return 8;
    if (std.mem.indexOf(u8, s, "第九") != null) return 9;
    if (std.mem.indexOf(u8, s, "第十") != null) return 10;
    return null;
}

/// 从文本中检测季号。
///
/// 支持：
/// - `S02` / `s2` / `S2E01` / `S02E03`
/// - `Season 2` / `season2`
/// - `第X季`（最小支持：一~十 或阿拉伯数字）
pub fn detectSeasonNumber(text: []const u8) ?u8 {
    if (text.len == 0) return null;

    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const c = text[i];
        if (c != 'S' and c != 's') continue;
        const j = i + 1;
        if (j >= text.len or !std.ascii.isDigit(text[j])) continue;
        var k = j;
        while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
        const n = std.fmt.parseInt(u8, text[j..k], 10) catch null;
        if (n) |sn| if (sn > 0) return sn;
    }

    if (std.ascii.indexOfIgnoreCase(text, "season")) |idx| {
        var j = idx + 6;
        while (j < text.len and (text[j] == ' ' or text[j] == '_' or text[j] == '-')) : (j += 1) {}
        var k = j;
        while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
        if (k > j) {
            const n = std.fmt.parseInt(u8, text[j..k], 10) catch null;
            if (n) |sn| if (sn > 0) return sn;
        }
    }

    if (std.mem.indexOf(u8, text, "季") != null) {
        if (chineseSeasonToInt(text)) |sn| return sn;
        if (std.mem.indexOf(u8, text, "第")) |p| {
            const j = p + 1;
            var k = j;
            while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
            if (k > j) {
                const n = std.fmt.parseInt(u8, text[j..k], 10) catch null;
                if (n) |sn| if (sn > 0) return sn;
            }
        }
    }

    return null;
}

/// 从“目录名”中解析季号（用于 Season 子目录拆分）。
pub fn parseSeasonFromDirName(name: []const u8) ?u8 {
    if (name.len == 0) return null;

    if ((name[0] == 'S' or name[0] == 's') and name.len >= 2) {
        var i: usize = 1;
        var end: usize = 1;
        while (i < name.len) : (i += 1) {
            if (!std.ascii.isDigit(name[i])) break;
            end = i + 1;
        }
        if (end > 1) {
            const n = std.fmt.parseInt(u8, name[1..end], 10) catch return null;
            if (n > 0) return n;
        }
    }

    if (std.ascii.indexOfIgnoreCase(name, "season")) |idx| {
        var j = idx + 6;
        while (j < name.len and name[j] == ' ') : (j += 1) {}
        var k = j;
        while (k < name.len and std.ascii.isDigit(name[k])) : (k += 1) {}
        if (k > j) {
            const n = std.fmt.parseInt(u8, name[j..k], 10) catch return null;
            if (n > 0) return n;
        }
    }

    if (std.mem.indexOf(u8, name, "季") != null) {
        if (chineseSeasonToInt(name)) |n| return n;
        if (std.mem.indexOf(u8, name, "第")) |p| {
            const j = p + 1;
            var k = j;
            while (k < name.len and std.ascii.isDigit(name[k])) : (k += 1) {}
            if (k > j) {
                const n = std.fmt.parseInt(u8, name[j..k], 10) catch return null;
                if (n > 0) return n;
            }
        }
    }

    return null;
}

/// 用于判断“文件夹看起来是 S1，但 API 名称可能是续作”的情况。
///
/// 这个判定属于“从命名/文本解析推断”的职责，因此放在 filter 模块。
pub fn needVerifySeason(folder_key: []const u8, api_name: []const u8) bool {
    const folder_has_s1 = (std.ascii.indexOfIgnoreCase(folder_key, "s1") != null) or (std.ascii.indexOfIgnoreCase(folder_key, "season 1") != null);
    if (!folder_has_s1) return false;
    return (std.ascii.indexOfIgnoreCase(api_name, "w") != null) or (std.ascii.indexOfIgnoreCase(api_name, "2") != null) or (std.ascii.indexOfIgnoreCase(api_name, "ii") != null);
}

/// 一个宽松的名称匹配，用于“解析/校验”场景。
pub fn namesRoughlyMatch(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return (std.ascii.indexOfIgnoreCase(a, b) != null) or (std.ascii.indexOfIgnoreCase(b, a) != null);
}

/// 清理常见画质/编码/字幕组标签等噪音信息。
///
/// 这是一个“偏保守”的启发式清洗：目标是让搜索词更接近番剧标题。
fn cleanVideoQualityInfo(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    const quality_patterns = [_][]const u8{
        " 1080p",  " 1080P",  " 720p",   " 720P",    " 480p",   " 480P",   " 2160p",   " 4K",
        " HEVC",   " H.265",  " H265",   " AVC",     " H.264",  " H264",   " x264",    " x265",
        " 10-bit", " 10bit",  " 8-bit",  " 8bit",    "--10bit", " -10bit", " BDRip",   " BDrip",
        " WEB-DL", " WEBDL",  " BluRay", " Blu-ray", " AAC",    " FLAC",   " DTS",     " AC3",
        " CHT",    " CHS",    " GB",     " BIG5",    "[Baha]",  "[Bdrip]", "[WEB-DL]", "[BDRip]",
        " Baha",   " WEB-DL", " BDRip",  "[Fin]",    " [Fin]",  " Season", " -",
    };

    var result = try alloc.dupe(u8, input);

    for (quality_patterns) |pattern| {
        if (std.mem.indexOf(u8, result, pattern)) |idx| {
            const before = result[0..idx];
            const after_idx = idx + pattern.len;
            const after = if (after_idx < result.len) result[after_idx..] else "";
            const new_result = try std.fmt.allocPrint(alloc, "{s}{s}", .{ before, after });
            alloc.free(result);
            result = new_result;
        }
    }

    if (std.mem.indexOf(u8, result, "【")) |start_idx| {
        if (std.mem.indexOf(u8, result[start_idx..], "】")) |relative_end_idx| {
            const end_idx = start_idx + relative_end_idx + "】".len;
            const before = result[0..start_idx];
            const after = if (end_idx < result.len) result[end_idx..] else "";
            const new_result = try std.fmt.allocPrint(alloc, "{s}{s}", .{ before, after });
            alloc.free(result);
            result = new_result;
        }
    }

    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    if (trimmed.len != result.len) {
        const new_result = try alloc.dupe(u8, trimmed);
        alloc.free(result);
        result = new_result;
    }

    return result;
}

/// 从文件夹名中提取番剧关键词（用于 Bangumi 搜索）。
pub fn extractAnimeName(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (line.len == 0) return try alloc.dupe(u8, "");

    const has_rev = util.containsIgnoreCase(line, "rev");
    const target_index: usize = if (has_rev) 2 else 1;
    var result: []const u8 = line;

    if (line[0] == '[') {
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(std.heap.page_allocator);
        var it = std.mem.splitAny(u8, line, "[]");
        while (it.next()) |p| {
            if (p.len == 0) continue;
            parts.append(std.heap.page_allocator, p) catch {};
        }
        if (parts.items.len > target_index) {
            result = std.mem.trim(u8, parts.items[target_index], &std.ascii.whitespace);
        }
    } else if (std.mem.indexOfScalar(u8, line, '_')) |idx| {
        result = std.mem.trim(u8, line[0..idx], &std.ascii.whitespace);
    }

    var converted_season = false;
    var season_result: []const u8 = result;
    if (std.mem.lastIndexOf(u8, result, " S")) |space_s_idx| {
        const after_space_s = result[space_s_idx + 2 ..];
        var season_end: usize = 0;
        for (after_space_s, 0..) |c, i| {
            if (c == ' ' or c == '-') {
                season_end = i;
                break;
            }
        }
        if (season_end == 0) season_end = after_space_s.len;

        const season_part = after_space_s[0..season_end];
        if (season_part.len > 0 and season_part.len <= 3) {
            var is_season = true;
            var season_num: i32 = 0;
            for (season_part) |c| {
                if (!std.ascii.isDigit(c)) {
                    is_season = false;
                    break;
                }
            }
            if (is_season) season_num = std.fmt.parseInt(i32, season_part, 10) catch 0;

            if (is_season and season_num > 0) {
                const base = result[0..space_s_idx];
                const after_season_idx = space_s_idx + 2 + season_end;
                const remaining = if (after_season_idx < result.len) result[after_season_idx..] else "";
                season_result = try std.fmt.allocPrint(alloc, "{s} Season {d}{s}", .{ base, season_num, remaining });
                converted_season = true;
            }
        }
    }
    result = season_result;

    var cleaned_result: []const u8 = result;
    if (std.mem.lastIndexOfScalar(u8, result, '-')) |dash_idx| {
        const after_dash = std.mem.trim(u8, result[dash_idx + 1 ..], &std.ascii.whitespace);
        if (after_dash.len > 0) {
            var check_str = after_dash;
            var is_episode = false;

            if (after_dash.len > 1 and (after_dash[0] == 'E' or after_dash[0] == 'e')) {
                check_str = after_dash[1..];
            }

            if (check_str.len > 0 and check_str.len <= 6) {
                is_episode = blk: {
                    for (check_str) |c| {
                        if (!std.ascii.isDigit(c) and c != '.') break :blk false;
                    }
                    break :blk true;
                };
            }

            if (!is_episode) {
                if (std.mem.indexOfScalar(u8, after_dash, ' ')) |space_idx| {
                    const first_part = after_dash[0..space_idx];
                    if (first_part.len > 0 and first_part.len <= 4) {
                        is_episode = blk: {
                            for (first_part) |c| {
                                if (!std.ascii.isDigit(c)) break :blk false;
                            }
                            break :blk true;
                        };
                    }
                }
            }

            if (is_episode) {
                const trimmed = std.mem.trimRight(u8, result[0..dash_idx], &std.ascii.whitespace);
                if (converted_season) {
                    alloc.free(result);
                }
                cleaned_result = try alloc.dupe(u8, trimmed);
                converted_season = true;
            }
        }
    }
    result = cleaned_result;

    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(std.heap.page_allocator);
    var tok_it = std.mem.tokenizeAny(u8, result, " ");
    while (tok_it.next()) |tok| tokens.append(std.heap.page_allocator, tok) catch {};

    if (tokens.items.len > 1) {
        const last = tokens.items[tokens.items.len - 1];
        const is_ep_token = blk: {
            if (last.len == 0 or last.len > 4) break :blk false;
            var check_str = last;
            if (last[0] == 'E' or last[0] == 'e') {
                if (last.len == 1) break :blk false;
                check_str = last[1..];
            }
            for (check_str) |c| {
                if (!std.ascii.isDigit(c) and c != '.') break :blk false;
            }
            break :blk true;
        };

        if (is_ep_token) {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(alloc);
            for (tokens.items[0 .. tokens.items.len - 1], 0..) |t, i| {
                if (i > 0) try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, t);
            }
            if (converted_season) {
                alloc.free(result);
            }
            const temp_result = try buf.toOwnedSlice(alloc);
            const cleaned = try cleanVideoQualityInfo(alloc, temp_result);
            alloc.free(temp_result);
            return cleaned;
        }
    }

    const to_clean = if (converted_season) result else try alloc.dupe(u8, result);
    const cleaned = try cleanVideoQualityInfo(alloc, to_clean);
    if (!converted_season or to_clean.ptr != result.ptr) {
        alloc.free(to_clean);
    }
    return cleaned;
}

/// 从文件名中提取集号（非常简化的实现）。
///
/// 当前策略：找到 1~4 位连续数字就认为是集号。
/// 注意：可能会误判年份/分辨率等数字，这里更适合“粗筛”。
pub fn extractEpisodeNumber(filename: []const u8) ?i32 {
    // 简单实现：查找连续的数字
    var i: usize = 0;
    while (i < filename.len) : (i += 1) {
        if (std.ascii.isDigit(filename[i])) {
            var num_end = i;
            while (num_end < filename.len and std.ascii.isDigit(filename[num_end])) {
                num_end += 1;
            }
            const num_str = filename[i..num_end];
            if (num_str.len > 0 and num_str.len <= 4) {
                return std.fmt.parseInt(i32, num_str, 10) catch null;
            }
            i = num_end;
        }
    }
    return null;
}

/// 清理名称，移除常见的字幕组标签、分辨率等信息（简化版）。
///
/// 主要用于对展示名/搜索名做二次去噪。
pub fn cleanAnimeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();

    // 移除方括号内容 [XXX]
    var in_bracket = false;
    for (name) |c| {
        if (c == '[') {
            in_bracket = true;
            continue;
        }
        if (c == ']') {
            in_bracket = false;
            continue;
        }
        if (!in_bracket) {
            try result.append(c);
        }
    }

    // 移除常见分辨率标记
    const cleaned = try result.toOwnedSlice();
    defer alloc.free(cleaned);

    const patterns = [_][]const u8{
        "1080p", "720p",   "2160p",  "4K",
        "x264",  "x265",   "HEVC",   "AVC",
        "BDRip", "WEBRip", "BluRay",
    };

    var final = std.ArrayList(u8).init(alloc);
    defer final.deinit();
    try final.appendSlice(cleaned);

    for (patterns) |pattern| {
        if (std.ascii.indexOfIgnoreCase(final.items, pattern)) |idx| {
            const before = final.items[0..idx];
            const after_start = idx + pattern.len;
            const after = if (after_start < final.items.len) final.items[after_start..] else "";

            final.clearRetainingCapacity();
            try final.appendSlice(before);
            try final.appendSlice(after);
        }
    }

    const trimmed = std.mem.trim(u8, final.items, &std.ascii.whitespace);
    return try alloc.dupe(u8, trimmed);
}

/// 应用自定义规则（从 config 读取）。
///
/// 规则语义：
/// - 优先按正则做“全局替换为空”
/// - 若正则编译失败，则回退到“忽略大小写的字面量删除”
pub fn applyCustomRules(alloc: std.mem.Allocator, name: []const u8, rules: []const []const u8) ![]const u8 {
    var result = try alloc.dupe(u8, name);
    errdefer alloc.free(result);

    for (rules) |rule_raw| {
        const rule_trimmed = std.mem.trim(u8, rule_raw, &std.ascii.whitespace);
        if (rule_trimmed.len == 0) continue;

        // 正则：全局替换为空
        var re = regex.Regex.init(alloc, rule_trimmed) catch {
            // 正则编译失败时，回退到字面量删除（忽略大小写）
            const fallback = try removeAllIgnoreCase(alloc, result, rule_trimmed);
            alloc.free(result);
            result = fallback;
            continue;
        };
        defer re.deinit(alloc);

        const replaced = try re.replaceAll(alloc, result, "");
        alloc.free(result);
        result = replaced;
    }

    const trimmed = std.mem.trim(u8, result, &std.ascii.whitespace);
    if (trimmed.len == result.len) return result;
    const out = try alloc.dupe(u8, trimmed);
    alloc.free(result);
    return out;
}

/// 从 input 中删除所有 needle（忽略大小写），返回新字符串。
fn removeAllIgnoreCase(alloc: std.mem.Allocator, input: []const u8, needle: []const u8) ![]u8 {
    if (needle.len == 0) return try alloc.dupe(u8, input);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        if (std.ascii.indexOfIgnoreCase(input[i..], needle)) |rel| {
            const idx = i + rel;
            try buf.appendSlice(alloc, input[i..idx]);
            i = idx + needle.len;
        } else {
            try buf.appendSlice(alloc, input[i..]);
            break;
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// 删除 input 中所有“prefix..suffix（含 suffix）”的最短片段。
///
/// 典型用途：移除成对包裹的标签，如 "[xxx]"、"(xxx)" 等。
fn removeBetweenMin(alloc: std.mem.Allocator, input: []const u8, prefix: []const u8, suffix: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < input.len) {
        const rel_start = std.mem.indexOf(u8, input[i..], prefix) orelse {
            try buf.appendSlice(alloc, input[i..]);
            break;
        };
        const start_idx = i + rel_start;
        const after_prefix = start_idx + prefix.len;
        const rel_end = std.mem.indexOf(u8, input[after_prefix..], suffix) orelse {
            // 找不到 suffix：剩余全部保留
            try buf.appendSlice(alloc, input[i..]);
            break;
        };
        const end_idx = after_prefix + rel_end + suffix.len;

        // 追加 prefix 之前的内容，跳过 prefix..suffix
        try buf.appendSlice(alloc, input[i..start_idx]);
        i = end_idx;
    }

    return buf.toOwnedSlice(alloc);
}
