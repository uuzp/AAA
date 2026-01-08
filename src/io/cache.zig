const std = @import("std");

const api = @import("../api.zig");
const scan = @import("scan.zig");
const util = @import("util.zig");

/// 单集缓存信息（来自 Bangumi + 本地文件匹配结果）。
///
/// `video_src/video_dst` 用于“确定性重命名”：
/// - src：目标目录内当前相对路径
/// - dst：目标目录内期望相对路径
pub const CachedEpisodeInfo = struct {
    bangumi_sort: f64,
    bangumi_name: []const u8,
    video_src: ?[]const u8,
    video_dst: ?[]const u8,
    subtitles: std.StringHashMap([]const u8),

    /// 释放本集条目中的 owned 字符串与字幕映射。
    pub fn deinit(self: *CachedEpisodeInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.bangumi_name);
        if (self.video_src) |v| alloc.free(v);
        if (self.video_dst) |v| alloc.free(v);

        var it = self.subtitles.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            alloc.free(e.value_ptr.*);
        }
        self.subtitles.deinit();
    }
};

/// 单季缓存信息。
pub const CachedSeasonInfo = struct {
    bangumi_season_id: i32,
    bangumi_season_name: []const u8,
    total_bangumi_episodes: i32,
    episodes: std.StringHashMap(CachedEpisodeInfo),

    /// 释放本季条目中的 owned 字符串与 episode 映射。
    pub fn deinit(self: *CachedSeasonInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.bangumi_season_name);

        var iter = self.episodes.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.episodes.deinit();
    }
};

/// WorkItem 的缓存映射条目。
pub const WorkItemCacheEntry = struct {
    source_rel: []const u8,
    target_rel: []const u8,
    search_term: []const u8,
    bangumi_season_id: i32,
    bangumi_season_name: []const u8,

    /// 释放 work item 映射条目中的 owned 字符串。
    pub fn deinit(self: *WorkItemCacheEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.source_rel);
        alloc.free(self.target_rel);
        alloc.free(self.search_term);
        alloc.free(self.bangumi_season_name);
    }
};

/// YAML 缓存根对象。
pub const YamlCache = struct {
    /// cache.yaml 的 schema 版本。
    ///
    /// 规则：
    /// - 读取时若版本高于当前实现支持的版本，返回 UnsupportedCacheVersion
    /// - 写回时总是写入当前版本
    version: u32,
    source_root: []const u8,
    target_root: []const u8,
    work_items: std.StringHashMap(WorkItemCacheEntry),
    seasons: std.StringHashMap(CachedSeasonInfo),

    /// 创建空的 YAML cache 容器。
    pub fn init(alloc: std.mem.Allocator) YamlCache {
        return .{
            .version = current_cache_version,
            .source_root = &[_]u8{},
            .target_root = &[_]u8{},
            .work_items = std.StringHashMap(WorkItemCacheEntry).init(alloc),
            .seasons = std.StringHashMap(CachedSeasonInfo).init(alloc),
        };
    }

    /// 释放 YAML cache 内所有 owned 字符串与集合。
    pub fn deinit(self: *YamlCache, alloc: std.mem.Allocator) void {
        if (self.source_root.len > 0) alloc.free(self.source_root);
        if (self.target_root.len > 0) alloc.free(self.target_root);

        var wi_it = self.work_items.iterator();
        while (wi_it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.work_items.deinit();

        var s_it = self.seasons.iterator();
        while (s_it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.seasons.deinit();
    }
};

/// 当前代码支持写出的 cache.yaml schema 版本。
///
/// v2：修复 episodes 解析逻辑后，旧缓存可能混入特典(type=1)导致 E01/E02 名称被覆盖；
///     主流程会对旧版本缓存优先刷新 episodes 并写回新版本。
const current_cache_version: u32 = 2;

const matcher = struct {
    pub const LocalFileInfo = scan.LocalFileInfo;

    // 文件名清洗统一使用 io/util.zig 的 sanitizeFilename。

    pub const EpisodeMatch = struct {
        video: ?LocalFileInfo,
        subs: []LocalFileInfo,
    };

    pub const MatchResult = struct {
        matched: std.AutoHashMap(u64, EpisodeMatch),
        used: std.AutoHashMap(usize, void),

        /// 释放匹配结果中的临时分配（key、subs slice、hashmap）。
        pub fn deinit(self: *MatchResult, alloc: std.mem.Allocator) void {
            var iter = self.matched.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.subs.len > 0) {
                    alloc.free(entry.value_ptr.subs);
                }
            }
            self.matched.deinit();
            self.used.deinit();
        }
    };

    /// 将 episode.sort 映射为可稳定哈希/比较的 key。
    ///
    /// 说明：直接用 float 作为 hash key 容易遇到 NaN/-0 等边界；这里用 bitcast 的 u64 做精确键。
    fn sortKey(sort: f64) u64 {
        return @bitCast(sort);
    }

    /// 将字符串按“数字段/非数字段”切分，用于自然排序（e.g. 2 < 10）。
    pub fn splitAlphaNumeric(alloc: std.mem.Allocator, s: []const u8) ![][]const u8 {
        if (s.len == 0) return &[_][]const u8{};
        var parts = std.ArrayList([]const u8).empty;
        errdefer parts.deinit(alloc);

        var start: usize = 0;
        var is_digit = std.ascii.isDigit(s[0]);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const d = std.ascii.isDigit(s[i]);
            if (d != is_digit) {
                try parts.append(alloc, s[start..i]);
                start = i;
                is_digit = d;
            }
        }
        if (start < s.len) try parts.append(alloc, s[start..]);
        return parts.toOwnedSlice(alloc);
    }

    /// 对本地文件做自然排序比较：先按 name_only 的数字段，再按扩展名。
    pub fn naturalCompare(a: LocalFileInfo, b: LocalFileInfo) i32 {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const lowerA = util.asciiLowerCopy(alloc, a.name_only) catch return 0;
        const lowerB = util.asciiLowerCopy(alloc, b.name_only) catch return 0;

        const partsA = splitAlphaNumeric(alloc, lowerA) catch return 0;
        const partsB = splitAlphaNumeric(alloc, lowerB) catch return 0;

        const min_len = @min(partsA.len, partsB.len);
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            const pa = partsA[i];
            const pb = partsB[i];
            const pa_num = std.fmt.parseInt(i32, pa, 10) catch null;
            const pb_num = std.fmt.parseInt(i32, pb, 10) catch null;
            if (pa_num != null and pb_num != null) {
                if (pa_num.? < pb_num.?) return -1;
                if (pa_num.? > pb_num.?) return 1;
            } else {
                const cmp = std.mem.order(u8, pa, pb);
                if (cmp == .lt) return -1;
                if (cmp == .gt) return 1;
            }
        }

        if (partsA.len < partsB.len) return -1;
        if (partsA.len > partsB.len) return 1;

        const lowerExtA = util.asciiLowerCopy(alloc, a.ext) catch return 0;
        const lowerExtB = util.asciiLowerCopy(alloc, b.ext) catch return 0;
        const ext_cmp = std.mem.order(u8, lowerExtA, lowerExtB);
        return switch (ext_cmp) {
            .lt => -1,
            .gt => 1,
            else => 0,
        };
    }

    /// `std.sort` 使用的 lessThan 适配器。
    fn naturalLessThan(_: void, a: LocalFileInfo, b: LocalFileInfo) bool {
        return naturalCompare(a, b) < 0;
    }

    /// ASCII 忽略大小写的全量替换（返回 owned slice）。
    fn replaceCaseInsensitiveAll(alloc: std.mem.Allocator, input: []const u8, token: []const u8, replacement: []const u8) ![]u8 {
        var lower_in = try util.asciiLowerCopy(alloc, input);
        defer alloc.free(lower_in);
        const lower_tok = try util.asciiLowerCopy(alloc, token);
        defer alloc.free(lower_tok);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);

        var i: usize = 0;
        while (i < input.len) {
            if (i + token.len <= input.len and std.mem.eql(u8, lower_in[i .. i + token.len], lower_tok)) {
                try out.appendSlice(alloc, replacement);
                i += token.len;
            } else {
                try out.append(alloc, input[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// 清理文件名中的常见编码/清晰度/来源 token，并统一分隔符为 '.'。
    pub fn getCleanedBaseName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        var buf = try alloc.dupe(u8, name);
        const tokens = [_][]const u8{ "1080p", "720p", "2160p", "4k", "x265", "h265", "x264", "h264", "avc", "hevc", "flac", "aac", "ac3", "dts", "opus", "bdrip", "bluray", "web-dl", "webrip", "hdtv" };
        for (tokens) |tok| {
            const tmp = try replaceCaseInsensitiveAll(alloc, buf, tok, "");
            alloc.free(buf);
            buf = tmp;
        }

        const buf_to_free = buf;
        defer alloc.free(buf_to_free);

        while (true) {
            if (buf.len == 0) break;
            const last_dash = std.mem.lastIndexOfScalar(u8, buf, '-') orelse break;
            if (last_dash + 1 < buf.len and std.ascii.isAlphanumeric(buf[last_dash + 1])) {
                buf = buf[0..last_dash];
            } else break;
        }
        while (true) {
            if (buf.len == 0) break;
            const last_us = std.mem.lastIndexOfScalar(u8, buf, '_') orelse break;
            if (last_us + 1 < buf.len and std.ascii.isAlphanumeric(buf[last_us + 1])) {
                buf = buf[0..last_us];
            } else break;
        }

        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);
        var last_is_sep = false;
        for (buf) |c| {
            const is_sep = c == ' ' or c == '.' or c == '_' or c == '-';
            if (is_sep) {
                if (!last_is_sep) try out.append(alloc, '.');
                last_is_sep = true;
            } else {
                try out.append(alloc, c);
                last_is_sep = false;
            }
        }

        while (out.items.len > 0 and out.items[0] == '.') {
            const items = try out.toOwnedSlice(alloc);
            defer alloc.free(items);
            try out.appendSlice(alloc, items[1..]);
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == '.') _ = out.pop();
        return out.toOwnedSlice(alloc);
    }

    /// 从文件名中尽量移除“集号/季集标记”，用于做字幕/视频的粗匹配。
    pub fn getBaseNameWithoutEpisode(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        var temp = std.ArrayList(u8).empty;
        defer temp.deinit(alloc);

        var depth: usize = 0;
        for (name) |c| {
            if (c == '[' or c == '(' or c == '{') {
                depth += 1;
                continue;
            }
            if ((c == ']' or c == ')' or c == '}') and depth > 0) {
                depth -= 1;
                continue;
            }
            if (depth == 0) try temp.append(alloc, c);
        }

        const buf = try getCleanedBaseName(alloc, temp.items);
        defer alloc.free(buf);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);

        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            if ((buf[i] == 'S' or buf[i] == 's') and i + 3 < buf.len and std.ascii.isDigit(buf[i + 1])) {
                while (i < buf.len and buf[i] != 'E' and buf[i] != 'e') i += 1;
                while (i < buf.len and std.ascii.isDigit(buf[i])) i += 1;
                continue;
            }
            if ((buf[i] == 'E' or buf[i] == 'e') and i + 1 < buf.len and std.ascii.isDigit(buf[i + 1])) {
                while (i < buf.len and std.ascii.isDigit(buf[i])) i += 1;
                continue;
            }
            if (std.ascii.isDigit(buf[i])) {
                while (i < buf.len and std.ascii.isDigit(buf[i])) i += 1;
                continue;
            }
            try out.append(alloc, buf[i]);
        }

        const cleaned = try getCleanedBaseName(alloc, out.items);
        return cleaned;
    }

    /// 计算字幕文件相对视频 base 的“后缀部分”（保留语言/版本等信息）。
    pub fn getSubtitleSuffix(sub_filename: []const u8, video_base: []const u8) []const u8 {
        if (std.mem.startsWith(u8, sub_filename, video_base)) {
            const boundary_ok = sub_filename.len == video_base.len or sub_filename[video_base.len] == '.';
            if (boundary_ok) return sub_filename[video_base.len..];
        }

        const last_dot = std.mem.lastIndexOfScalar(u8, sub_filename, '.') orelse return "";
        if (last_dot == 0) return sub_filename[last_dot..];

        var i: isize = @as(isize, @intCast(last_dot)) - 1;
        while (i >= 0) : (i -= 1) {
            if (sub_filename[@intCast(i)] == '.') return sub_filename[@intCast(i)..];
        }
        return sub_filename[last_dot..];
    }

    /// 从文件名里抽取“可能的集号”（支持 SxxEyy/第xx话/Ep12/纯数字等）。
    pub fn extractEpisodeNumber(name: []const u8) ?f64 {
        if (name.len == 0) return null;

        const is_noise_number = struct {
            /// 过滤常见“噪声数字”（分辨率/编码号等），避免误识别为集号。
            fn run(n: i32) bool {
                return n == 1920 or n == 1080 or n == 720 or n == 2160 or n == 480 or n == 1440 or n == 1280 or n == 265 or n == 264 or n == 420;
            }
        };

        const parseDigits = struct {
            /// 从 start 起解析连续数字，返回值与结束位置；失败返回 null。
            fn run(s: []const u8, start: usize) ?struct { val: i32, end: usize } {
                if (start >= s.len or !std.ascii.isDigit(s[start])) return null;
                var i: usize = start;
                while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
                const v = std.fmt.parseInt(i32, s[start..i], 10) catch return null;
                return .{ .val = v, .end = i };
            }
        };

        var i: usize = 0;
        while (i + 3 < name.len) : (i += 1) {
            const c = name[i];
            if (c != 'S' and c != 's') continue;
            const sdigits = parseDigits.run(name, i + 1) orelse continue;
            const j = sdigits.end;
            if (j >= name.len) continue;
            if (name[j] != 'E' and name[j] != 'e') continue;
            const edigits = parseDigits.run(name, j + 1) orelse continue;
            if (edigits.val > 0 and edigits.val <= 500 and !is_noise_number.run(edigits.val)) return @floatFromInt(edigits.val);
        }

        if (std.mem.indexOf(u8, name, "第")) |p| {
            const d = parseDigits.run(name, p + "第".len);
            if (d) |dd| {
                if (dd.end < name.len and (std.mem.startsWith(u8, name[dd.end..], "话") or std.mem.startsWith(u8, name[dd.end..], "話") or std.mem.startsWith(u8, name[dd.end..], "集") or std.mem.startsWith(u8, name[dd.end..], "回"))) {
                    if (dd.val > 0 and dd.val <= 500 and !is_noise_number.run(dd.val)) return @floatFromInt(dd.val);
                }
            }
        }

        i = 0;
        while (i + 1 < name.len) : (i += 1) {
            const c = name[i];
            if (c == 'E' or c == 'e') {
                const d = parseDigits.run(name, i + 1) orelse continue;
                if (d.val > 0 and d.val <= 500 and !is_noise_number.run(d.val)) return @floatFromInt(d.val);
            }
            if ((c == 'P' or c == 'p') and i > 0 and (name[i - 1] == 'E' or name[i - 1] == 'e')) {
                const d = parseDigits.run(name, i + 1) orelse continue;
                if (d.val > 0 and d.val <= 500 and !is_noise_number.run(d.val)) return @floatFromInt(d.val);
            }
        }

        var it = std.mem.tokenizeAny(u8, name, " []-_.(){}");
        while (it.next()) |tok| {
            if (tok.len == 0) continue;
            var num_tok = tok;
            if (num_tok.len > 2 and (num_tok[0] == 'E' or num_tok[0] == 'e') and std.ascii.isDigit(num_tok[1])) {
                num_tok = num_tok[1..];
            } else if (num_tok.len > 3 and (num_tok[0] == 'S' or num_tok[0] == 's') and (num_tok[1] == 'P' or num_tok[1] == 'p') and std.ascii.isDigit(num_tok[2])) {
                // 支持 SP01 / sp1 之类的特典集号。
                num_tok = num_tok[2..];
            }
            const val = std.fmt.parseFloat(f64, num_tok) catch continue;
            if (val == 0) continue;
            const iv: i32 = @intFromFloat(val);
            if (iv <= 0 or iv > 500) continue;
            if (is_noise_number.run(iv)) continue;
            return val;
        }

        return null;
    }

    /// 把 Bangumi 的 sort 格式化成「前缀 + 数字」：如 E01 / SP01。
    ///
    /// - prefix：建议使用 "E"（正片）或 "SP"（特典）
    /// - 位数由 total 推断
    pub fn formatEpisodeNumberWithPrefix(sort: f64, total: i32, prefix: []const u8, alloc: std.mem.Allocator) ![]u8 {
        const sort_int: i32 = @intFromFloat(sort);
        const sort_int_f: f64 = @floatFromInt(sort_int);
        const has_frac = @abs(sort - sort_int_f) >= 0.0001;

        var digits: usize = 1;
        if (total >= 10000) digits = 5 else if (total >= 1000) digits = 4 else if (total >= 100) digits = 3 else if (total >= 10) digits = 2;

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);

        try buf.appendSlice(alloc, prefix);
        const num_text = std.fmt.allocPrint(alloc, "{d}", .{sort_int}) catch return error.OutOfMemory;
        defer alloc.free(num_text);

        const need_zero = if (digits > num_text.len) digits - num_text.len else 0;
        var zi: usize = 0;
        while (zi < need_zero) : (zi += 1) try buf.append(alloc, '0');
        try buf.appendSlice(alloc, num_text);

        if (has_frac) try buf.print(alloc, "{d}", .{sort - sort_int_f});
        return buf.toOwnedSlice(alloc);
    }

    /// 正片默认使用 E 前缀。
    pub fn formatEpisodeNumber(sort: f64, total: i32, alloc: std.mem.Allocator) ![]u8 {
        return formatEpisodeNumberWithPrefix(sort, total, "E", alloc);
    }

    /// 两个字符串的粗相似度分数（0~1，近似 LCS 思路的线性扫描）。
    pub fn similarityScore(a: []const u8, b: []const u8) f64 {
        if (a.len == 0 or b.len == 0) return 0;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const la = util.asciiLowerCopy(alloc, a) catch return 0;
        const lb = util.asciiLowerCopy(alloc, b) catch return 0;

        var i: usize = 0;
        var j: usize = 0;
        var lcs: usize = 0;
        while (i < la.len and j < lb.len) {
            if (la[i] == lb[j]) {
                lcs += 1;
                i += 1;
                j += 1;
            } else if (la.len - i > lb.len - j) {
                i += 1;
            } else {
                j += 1;
            }
        }

        const num: f64 = @floatFromInt(lcs);
        const denom: f64 = @floatFromInt(std.math.max(la.len, lb.len));
        return num / denom;
    }

    /// 字幕名是否“看起来属于”该视频（基于 similarityScore 的阈值判断）。
    pub fn matchSubtitleToVideo(video: []const u8, sub: []const u8) bool {
        return similarityScore(video, sub) > 0.7;
    }

    /// 判断扩展名是否属于视频集合（忽略大小写，兼容复合后缀）。
    fn isVideoExt(ext: []const u8, video_exts: []const []const u8) bool {
        return util.isExtInListIgnoreAsciiCase(ext, video_exts);
    }

    /// 判断扩展名是否属于字幕集合（忽略大小写，兼容复合后缀）。
    fn isSubtitleExt(ext: []const u8, subtitle_exts: []const []const u8) bool {
        return util.isExtInListIgnoreAsciiCase(ext, subtitle_exts);
    }

    /// 将本地文件（视频/字幕）与 Bangumi episodes 尽量匹配。
    ///
    /// 策略：优先根据文件名抽取的集号进行确定匹配；未匹配到的文件留给后续兜底分配。
    pub fn matchFilesToEpisodes(
        alloc: std.mem.Allocator,
        episodes: []api.Episode,
        localFiles: []LocalFileInfo,
        videoExts: []const []const u8,
        subtitleExts: []const []const u8,
    ) !MatchResult {
        var matched = std.AutoHashMap(u64, EpisodeMatch).init(alloc);
        var used = std.AutoHashMap(usize, void).init(alloc);

        for (episodes) |ep| {
            const key = sortKey(ep.sort);
            if (matched.contains(key)) continue;
            try matched.put(key, .{ .video = null, .subs = &[_]LocalFileInfo{} });
        }

        for (episodes) |ep| {
            const ep_int: i64 = @intFromFloat(ep.sort);
            const ep_int_f: f64 = @floatFromInt(ep_int);
            if (@abs(ep.sort - ep_int_f) < 0.001 and ep.sort >= 1.0) {
                const ep_num = ep.sort;
                const ep_key = sortKey(ep_num);

                for (localFiles, 0..) |f, idx| {
                    if (used.contains(idx)) continue;
                    const epOpt = extractEpisodeNumber(f.name_only);
                    if (epOpt) |num| {
                        if (@abs(num - ep_num) < 0.001) {
                            if (isVideoExt(f.ext, videoExts)) {
                                if (matched.getPtr(ep_key)) |m| {
                                    if (m.video == null) {
                                        m.video = f;
                                        try used.put(idx, {});
                                    }
                                }
                            } else if (isSubtitleExt(f.ext, subtitleExts)) {
                                if (matched.getPtr(ep_key)) |m| {
                                    var list = std.ArrayList(LocalFileInfo).empty;
                                    if (m.subs.len > 0) {
                                        try list.appendSlice(alloc, m.subs);
                                        alloc.free(m.subs);
                                    }
                                    try list.append(alloc, f);
                                    m.subs = try list.toOwnedSlice(alloc);
                                    try used.put(idx, {});
                                }
                            }
                        }
                    }
                }
            }
        }

        for (episodes) |ep| {
            const ep_num = ep.sort;
            const ep_key = sortKey(ep_num);

            const ep_num_int: i64 = @intFromFloat(ep_num);
            const ep_num_int_f: f64 = @floatFromInt(ep_num_int);
            if (@abs(ep_num - ep_num_int_f) >= 0.001 or ep_num == 0.0) {
                for (localFiles, 0..) |f, idx| {
                    if (used.contains(idx)) continue;
                    const epOpt = extractEpisodeNumber(f.name_only);
                    if (epOpt) |num| {
                        if (@abs(num - ep_num) < 0.001) {
                            if (isVideoExt(f.ext, videoExts)) {
                                if (matched.getPtr(ep_key)) |m| {
                                    if (m.video == null) {
                                        m.video = f;
                                        try used.put(idx, {});
                                    }
                                }
                            } else if (isSubtitleExt(f.ext, subtitleExts)) {
                                if (matched.getPtr(ep_key)) |m| {
                                    var list = std.ArrayList(LocalFileInfo).empty;
                                    if (m.subs.len > 0) {
                                        try list.appendSlice(alloc, m.subs);
                                        alloc.free(m.subs);
                                    }
                                    try list.append(alloc, f);
                                    m.subs = try list.toOwnedSlice(alloc);
                                    try used.put(idx, {});
                                }
                            }
                        }
                    }
                }
            }
        }

        return .{ .matched = matched, .used = used };
    }

    /// 对剩余未匹配文件做“顺序兜底分配”：按自然排序把视频/字幕依次分配给 episode。
    fn assignRemainingFiles(
        alloc: std.mem.Allocator,
        matched: *std.AutoHashMap(u64, EpisodeMatch),
        used: *std.AutoHashMap(usize, void),
        remainingVideos: []LocalFileInfo,
        remainingSubs: []LocalFileInfo,
        episodes: []api.Episode,
    ) !void {
        var videoIdx: usize = 0;
        var subIdx: usize = 0;

        const eps = try alloc.dupe(api.Episode, episodes);
        defer alloc.free(eps);

        std.sort.block(api.Episode, eps, {}, struct {
            /// 对 episode 的 sort 做一个分组排序：
            /// - >= 1 的正序号优先
            /// - (0,1) 的特典/小数 sort 其次
            /// - <= 0 的放最后
            fn less(_: void, a: api.Episode, b: api.Episode) bool {
                const group = struct {
                    /// 将 sort 映射到排序分组。
                    fn g(x: f64) u8 {
                        if (x >= 1.0) return 0;
                        if (x > 0.0) return 1;
                        return 2;
                    }
                };
                const ga = group.g(a.sort);
                const gb = group.g(b.sort);
                if (ga != gb) return ga < gb;
                return a.sort < b.sort;
            }
        }.less);

        for (eps) |ep| {
            const ep_key = sortKey(ep.sort);

            if (matched.getPtr(ep_key)) |m| {
                if (m.video == null and videoIdx < remainingVideos.len) {
                    m.video = remainingVideos[videoIdx];
                    try used.put(videoIdx, {});
                    videoIdx += 1;
                }
                if (m.subs.len == 0 and subIdx < remainingSubs.len) {
                    var list = std.ArrayList(LocalFileInfo).empty;
                    defer list.deinit(alloc);
                    try list.append(alloc, remainingSubs[subIdx]);
                    m.subs = try list.toOwnedSlice(alloc);
                    try used.put(subIdx, {});
                    subIdx += 1;
                }
            }
        }
    }

    /// 把 episode->(video/subs) 的匹配结果转成最终要写入 YAML cache 的结构。
    fn buildEpisodeCache(
        alloc: std.mem.Allocator,
        matched: *std.AutoHashMap(u64, EpisodeMatch),
        episodes: []api.Episode,
        total: i32,
        prefix: []const u8,
    ) !std.StringHashMap(CachedEpisodeInfo) {
        var result = std.StringHashMap(CachedEpisodeInfo).init(alloc);

        for (episodes) |ep| {
            const key = try formatEpisodeNumberWithPrefix(ep.sort, total, prefix, alloc);
            const ep_key = sortKey(ep.sort);

            const cleanEpName = try util.sanitizeFilename(alloc, ep.name);
            defer alloc.free(cleanEpName);
            const newBaseName = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ key, cleanEpName });
            defer alloc.free(newBaseName);

            var video_src: ?[]const u8 = null;
            var video_dst: ?[]const u8 = null;
            var subtitles = std.StringHashMap([]const u8).init(alloc);
            errdefer {
                if (video_src) |v| alloc.free(v);
                if (video_dst) |v| alloc.free(v);
                var it = subtitles.iterator();
                while (it.next()) |e| {
                    alloc.free(e.key_ptr.*);
                    alloc.free(e.value_ptr.*);
                }
                subtitles.deinit();
            }

            var video_stem: []const u8 = "";
            if (matched.get(ep_key)) |m| {
                if (m.video) |v| {
                    video_stem = v.name_only;
                    video_src = try alloc.dupe(u8, v.rel_path);

                    const dst_file = try std.fmt.allocPrint(alloc, "{s}{s}", .{ newBaseName, v.ext });
                    defer alloc.free(dst_file);
                    if (std.fs.path.dirname(v.rel_path)) |dirp| {
                        video_dst = try std.fs.path.join(alloc, &[_][]const u8{ dirp, dst_file });
                    } else {
                        video_dst = try alloc.dupe(u8, dst_file);
                    }
                } else if (m.subs.len > 0) {
                    video_stem = m.subs[0].name_only;
                }

                for (m.subs) |s| {
                    const src_sub = try alloc.dupe(u8, s.rel_path);

                    const sub_base = std.fs.path.basename(s.rel_path);
                    const suffix = getSubtitleSuffix(sub_base, if (video_stem.len > 0) video_stem else s.name_only);

                    const dst_file = try std.fmt.allocPrint(alloc, "{s}{s}", .{ newBaseName, suffix });
                    defer alloc.free(dst_file);
                    const dst_sub = if (std.fs.path.dirname(s.rel_path)) |dirp|
                        try std.fs.path.join(alloc, &[_][]const u8{ dirp, dst_file })
                    else
                        try alloc.dupe(u8, dst_file);

                    subtitles.put(src_sub, dst_sub) catch {
                        alloc.free(src_sub);
                        alloc.free(dst_sub);
                    };
                }
            }

            if (result.getPtr(key)) |old_entry| {
                alloc.free(key);
                old_entry.deinit(alloc);
                old_entry.* = .{
                    .bangumi_sort = ep.sort,
                    .bangumi_name = try alloc.dupe(u8, ep.name),
                    .video_src = video_src,
                    .video_dst = video_dst,
                    .subtitles = subtitles,
                };
            } else {
                try result.put(key, .{
                    .bangumi_sort = ep.sort,
                    .bangumi_name = try alloc.dupe(u8, ep.name),
                    .video_src = video_src,
                    .video_dst = video_dst,
                    .subtitles = subtitles,
                });
            }
        }

        return result;
    }

    /// 从本地扫描文件构建 episodes cache：匹配 + 兜底分配 + 生成 dst 相对路径。
    pub fn buildEpisodeCacheFromLocalFiles(
        alloc: std.mem.Allocator,
        episodes: []api.Episode,
        localFiles: []LocalFileInfo,
        videoExts: []const []const u8,
        subtitleExts: []const []const u8,
        total: i32,
    ) !std.StringHashMap(CachedEpisodeInfo) {
        var matched_used = try matchFilesToEpisodes(alloc, episodes, localFiles, videoExts, subtitleExts);
        defer matched_used.deinit(alloc);

        var remainingVideos = std.ArrayList(LocalFileInfo).empty;
        defer remainingVideos.deinit(alloc);
        var remainingSubs = std.ArrayList(LocalFileInfo).empty;
        defer remainingSubs.deinit(alloc);

        for (localFiles, 0..) |f, idx| {
            if (matched_used.used.contains(idx)) continue;
            if (isVideoExt(f.ext, videoExts)) {
                try remainingVideos.append(alloc, f);
            } else if (isSubtitleExt(f.ext, subtitleExts)) {
                try remainingSubs.append(alloc, f);
            }
        }

        std.sort.block(LocalFileInfo, remainingVideos.items, {}, naturalLessThan);
        std.sort.block(LocalFileInfo, remainingSubs.items, {}, naturalLessThan);

        try assignRemainingFiles(alloc, &matched_used.matched, &matched_used.used, remainingVideos.items, remainingSubs.items, episodes);

        return try buildEpisodeCache(alloc, &matched_used.matched, episodes, total, "E");
    }

    /// 与 buildEpisodeCacheFromLocalFiles 相同，但允许自定义前缀（如 "SP"）。
    fn buildEpisodeCacheFromLocalFilesWithPrefix(
        alloc: std.mem.Allocator,
        episodes: []api.Episode,
        localFiles: []LocalFileInfo,
        videoExts: []const []const u8,
        subtitleExts: []const []const u8,
        total: i32,
        prefix: []const u8,
    ) !std.StringHashMap(CachedEpisodeInfo) {
        var matched_used = try matchFilesToEpisodes(alloc, episodes, localFiles, videoExts, subtitleExts);
        defer matched_used.deinit(alloc);

        var remainingVideos = std.ArrayList(LocalFileInfo).empty;
        defer remainingVideos.deinit(alloc);
        var remainingSubs = std.ArrayList(LocalFileInfo).empty;
        defer remainingSubs.deinit(alloc);

        for (localFiles, 0..) |f, idx| {
            if (matched_used.used.contains(idx)) continue;
            if (isVideoExt(f.ext, videoExts)) {
                try remainingVideos.append(alloc, f);
            } else if (isSubtitleExt(f.ext, subtitleExts)) {
                try remainingSubs.append(alloc, f);
            }
        }

        std.sort.block(LocalFileInfo, remainingVideos.items, {}, naturalLessThan);
        std.sort.block(LocalFileInfo, remainingSubs.items, {}, naturalLessThan);

        try assignRemainingFiles(alloc, &matched_used.matched, &matched_used.used, remainingVideos.items, remainingSubs.items, episodes);

        return try buildEpisodeCache(alloc, &matched_used.matched, episodes, total, prefix);
    }
};

/// 为“单次重命名”构造一个临时的 CachedSeasonInfo（不写入 YAML cache）。
///
/// 主要用于特典/附加内容目录：
/// - episodes：从 Bangumi 拉取（例如 type=1）
/// - local_files：扫描该目录下的视频/字幕
/// - prefix：输出编号前缀（建议 "SP"）
pub fn buildTempSeasonInfoForRename(
    alloc: std.mem.Allocator,
    season_id: i32,
    season_name: []const u8,
    episodes: api.EpisodeList,
    local_files: []scan.LocalFileInfo,
    videoExts: []const []const u8,
    subtitleExts: []const []const u8,
    prefix: []const u8,
) !CachedSeasonInfo {
    const eps_cache = try matcher.buildEpisodeCacheFromLocalFilesWithPrefix(
        alloc,
        episodes.items,
        local_files,
        videoExts,
        subtitleExts,
        @intCast(episodes.items.len),
        prefix,
    );

    return .{
        .bangumi_season_id = season_id,
        .bangumi_season_name = try alloc.dupe(u8, season_name),
        .total_bangumi_episodes = @intCast(episodes.items.len),
        .episodes = eps_cache,
    };
}

const yaml = struct {
    /// 生成 YAML 双引号字符串（对反斜杠、引号和换行做转义）。
    fn quoted(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);

        try out.append(alloc, '"');
        for (s) |c| {
            switch (c) {
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '"' => try out.appendSlice(alloc, "\\\""),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\r' => try out.appendSlice(alloc, "\\r"),
                '\t' => try out.appendSlice(alloc, "\\t"),
                else => try out.append(alloc, c),
            }
        }
        try out.append(alloc, '"');
        return out.toOwnedSlice(alloc);
    }

    /// 解析 YAML 双引号字符串（支持常见转义）。
    fn unquote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') {
            return try alloc.dupe(u8, std.mem.trim(u8, s, &std.ascii.whitespace));
        }

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        var i: usize = 1;
        while (i + 1 < s.len) : (i += 1) {
            const c = s[i];
            if (c != '\\') {
                try out.append(alloc, c);
                continue;
            }
            if (i + 1 >= s.len - 1) break;
            const n = s[i + 1];
            switch (n) {
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                '\\' => try out.append(alloc, '\\'),
                '"' => try out.append(alloc, '"'),
                else => try out.append(alloc, n),
            }
            i += 1;
        }

        return out.toOwnedSlice(alloc);
    }

    /// 写入 n 个空格缩进。
    fn indent(writer: anytype, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try writer.writeByte(' ');
    }
};

/// 将内存中的 YamlCache 序列化并写入到 path（覆盖写）。
pub fn saveYamlCache(path: []const u8, cache: *YamlCache) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);
    const wr = &w.interface;

    const src_q = try yaml.quoted(std.heap.page_allocator, cache.source_root);
    defer std.heap.page_allocator.free(src_q);
    const dst_q = try yaml.quoted(std.heap.page_allocator, cache.target_root);
    defer std.heap.page_allocator.free(dst_q);

    // 写回时固定输出当前版本，确保 cache.yaml 可自描述、可迁移。
    cache.version = current_cache_version;
    try wr.print("version: {d}\n", .{cache.version});
    try wr.print("source_root: {s}\n", .{src_q});
    try wr.print("target_root: {s}\n", .{dst_q});

    const lessStr = struct {
        /// 按字典序对字符串 key 排序（用于让 YAML 输出稳定、便于 diff）。
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    };

    try wr.print("work_items:\n", .{});
    var wi_keys: std.ArrayList([]const u8) = .empty;
    defer wi_keys.deinit(std.heap.page_allocator);
    var wi_it0 = cache.work_items.iterator();
    while (wi_it0.next()) |e| try wi_keys.append(std.heap.page_allocator, e.key_ptr.*);
    std.sort.block([]const u8, wi_keys.items, {}, lessStr.less);
    for (wi_keys.items) |k| {
        const entry = cache.work_items.get(k) orelse continue;
        const key_q = try yaml.quoted(std.heap.page_allocator, k);
        defer std.heap.page_allocator.free(key_q);
        try yaml.indent(wr, 2);
        try wr.print("{s}:\n", .{key_q});

        const srel_q = try yaml.quoted(std.heap.page_allocator, entry.source_rel);
        defer std.heap.page_allocator.free(srel_q);
        const trel_q = try yaml.quoted(std.heap.page_allocator, entry.target_rel);
        defer std.heap.page_allocator.free(trel_q);
        const term_q = try yaml.quoted(std.heap.page_allocator, entry.search_term);
        defer std.heap.page_allocator.free(term_q);
        const sname_q = try yaml.quoted(std.heap.page_allocator, entry.bangumi_season_name);
        defer std.heap.page_allocator.free(sname_q);

        try yaml.indent(wr, 4);
        try wr.print("source_rel: {s}\n", .{srel_q});
        try yaml.indent(wr, 4);
        try wr.print("target_rel: {s}\n", .{trel_q});
        try yaml.indent(wr, 4);
        try wr.print("search_term: {s}\n", .{term_q});
        try yaml.indent(wr, 4);
        try wr.print("bangumi_season_id: {d}\n", .{entry.bangumi_season_id});
        try yaml.indent(wr, 4);
        try wr.print("bangumi_season_name: {s}\n", .{sname_q});
    }

    try wr.print("seasons:\n", .{});
    var s_keys: std.ArrayList([]const u8) = .empty;
    defer s_keys.deinit(std.heap.page_allocator);
    var s_it0 = cache.seasons.iterator();
    while (s_it0.next()) |e| try s_keys.append(std.heap.page_allocator, e.key_ptr.*);
    std.sort.block([]const u8, s_keys.items, {}, lessStr.less);
    for (s_keys.items) |k| {
        const s = cache.seasons.get(k) orelse continue;
        const kq = try yaml.quoted(std.heap.page_allocator, k);
        defer std.heap.page_allocator.free(kq);
        try yaml.indent(wr, 2);
        try wr.print("{s}:\n", .{kq});

        const name_q = try yaml.quoted(std.heap.page_allocator, s.bangumi_season_name);
        defer std.heap.page_allocator.free(name_q);

        try yaml.indent(wr, 4);
        try wr.print("bangumi_season_id: {d}\n", .{s.bangumi_season_id});
        try yaml.indent(wr, 4);
        try wr.print("bangumi_season_name: {s}\n", .{name_q});
        try yaml.indent(wr, 4);
        try wr.print("total_bangumi_episodes: {d}\n", .{s.total_bangumi_episodes});

        try yaml.indent(wr, 4);
        try wr.print("episodes:\n", .{});

        var ep_keys: std.ArrayList([]const u8) = .empty;
        defer ep_keys.deinit(std.heap.page_allocator);
        var ep_it0 = s.episodes.iterator();
        while (ep_it0.next()) |e| try ep_keys.append(std.heap.page_allocator, e.key_ptr.*);
        std.sort.block([]const u8, ep_keys.items, {}, lessStr.less);

        for (ep_keys.items) |ek| {
            const ep = s.episodes.get(ek) orelse continue;
            const ekq = try yaml.quoted(std.heap.page_allocator, ek);
            defer std.heap.page_allocator.free(ekq);
            try yaml.indent(wr, 6);
            try wr.print("{s}:\n", .{ekq});

            const epname_q = try yaml.quoted(std.heap.page_allocator, ep.bangumi_name);
            defer std.heap.page_allocator.free(epname_q);
            try yaml.indent(wr, 8);
            try wr.print("bangumi_sort: {d}\n", .{ep.bangumi_sort});
            try yaml.indent(wr, 8);
            try wr.print("bangumi_name: {s}\n", .{epname_q});

            if (ep.video_src) |v| {
                const vq = try yaml.quoted(std.heap.page_allocator, v);
                defer std.heap.page_allocator.free(vq);
                try yaml.indent(wr, 8);
                try wr.print("video_src: {s}\n", .{vq});
            }
            if (ep.video_dst) |v| {
                const vq = try yaml.quoted(std.heap.page_allocator, v);
                defer std.heap.page_allocator.free(vq);
                try yaml.indent(wr, 8);
                try wr.print("video_dst: {s}\n", .{vq});
            }

            try yaml.indent(wr, 8);
            try wr.print("subtitles:\n", .{});

            var sub_keys: std.ArrayList([]const u8) = .empty;
            defer sub_keys.deinit(std.heap.page_allocator);
            var sub_it = ep.subtitles.iterator();
            while (sub_it.next()) |e| try sub_keys.append(std.heap.page_allocator, e.key_ptr.*);
            std.sort.block([]const u8, sub_keys.items, {}, lessStr.less);
            for (sub_keys.items) |sk| {
                const v = ep.subtitles.get(sk) orelse continue;
                const skq = try yaml.quoted(std.heap.page_allocator, sk);
                defer std.heap.page_allocator.free(skq);
                const vq = try yaml.quoted(std.heap.page_allocator, v);
                defer std.heap.page_allocator.free(vq);
                try yaml.indent(wr, 10);
                try wr.print("{s}: {s}\n", .{ skq, vq });
            }
        }
    }

    try wr.flush();
}

/// 从 path 读取并解析 YAML cache。
///
/// - 文件不存在时返回空 cache（不报错）
/// - 返回的所有字符串与集合均使用 alloc 分配，需调用 `YamlCache.deinit`
pub fn loadYamlCache(alloc: std.mem.Allocator, path: []const u8) !YamlCache {
    var cache = YamlCache.init(alloc);
    errdefer cache.deinit(alloc);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return cache;
        return err;
    };
    defer file.close();

    const data = try file.readToEndAlloc(alloc, 1 << 22);
    defer alloc.free(data);
    if (data.len == 0) return cache;

    var mode: enum { root, work_items, seasons, season_entry, episode_entry, subtitles } = .root;
    var current_wi_key: ?[]u8 = null;
    var current_season_key: ?[]u8 = null;
    var current_ep_key: ?[]u8 = null;

    var current_season: ?CachedSeasonInfo = null;
    var current_episode: ?CachedEpisodeInfo = null;

    const commitEpisode = struct {
        /// 提交一集到当前 season；失败则负责释放 key/entry，避免泄漏。
        fn run(alloc_: std.mem.Allocator, season: *CachedSeasonInfo, ep_key: []u8, ep: *CachedEpisodeInfo) void {
            season.episodes.put(ep_key, ep.*) catch {
                alloc_.free(ep_key);
                ep.deinit(alloc_);
            };
        }
    };
    const commitSeason = struct {
        /// 提交一季到 seasons map；失败则负责释放 key/entry，避免泄漏。
        fn run(alloc_: std.mem.Allocator, seasons: *std.StringHashMap(CachedSeasonInfo), skey: []u8, s: *CachedSeasonInfo) void {
            seasons.put(skey, s.*) catch {
                alloc_.free(skey);
                s.deinit(alloc_);
            };
        }
    };

    // work_items 的 key 只用于“定位 map 条目”，并不作为 map 的 owned key；解析完成后必须释放。
    defer if (current_wi_key) |k| alloc.free(k);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line0 = std.mem.trimRight(u8, raw_line, "\r");
        const line = std.mem.trim(u8, line0, &std.ascii.whitespace);
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const indent = line0.len - std.mem.trimLeft(u8, line0, &std.ascii.whitespace).len;

        if (indent == 0) {
            if (current_episode) |*ep| {
                if (current_ep_key) |k| {
                    if (current_season) |*s| commitEpisode.run(alloc, s, k, ep);
                }
                current_episode = null;
                current_ep_key = null;
            }
            if (current_season) |*s| {
                if (current_season_key) |k| commitSeason.run(alloc, &cache.seasons, k, s);
                current_season = null;
                current_season_key = null;
            }
            mode = .root;

            if (std.mem.eql(u8, line, "work_items:")) {
                mode = .work_items;
                continue;
            }
            if (std.mem.eql(u8, line, "seasons:")) {
                mode = .seasons;
                continue;
            }
            if (std.mem.startsWith(u8, line, "source_root:")) {
                const v = std.mem.trim(u8, line["source_root:".len..], &std.ascii.whitespace);
                cache.source_root = try yaml.unquote(alloc, v);
                continue;
            }
            if (std.mem.startsWith(u8, line, "target_root:")) {
                const v = std.mem.trim(u8, line["target_root:".len..], &std.ascii.whitespace);
                cache.target_root = try yaml.unquote(alloc, v);
                continue;
            }
            if (std.mem.startsWith(u8, line, "version:")) {
                const v = std.mem.trim(u8, line["version:".len..], &std.ascii.whitespace);
                const parsed = std.fmt.parseInt(u32, v, 10) catch return error.InvalidCacheVersion;
                if (parsed > current_cache_version) return error.UnsupportedCacheVersion;
                cache.version = if (parsed == 0) current_cache_version else parsed;
                continue;
            }
            continue;
        }

        if (mode == .work_items) {
            if (indent == 2 and std.mem.endsWith(u8, line, ":")) {
                if (current_wi_key) |k| {
                    alloc.free(k);
                    current_wi_key = null;
                }
                const key_txt = std.mem.trim(u8, line[0 .. line.len - 1], &std.ascii.whitespace);
                current_wi_key = try yaml.unquote(alloc, key_txt);

                const key_owned = try alloc.dupe(u8, current_wi_key.?);
                const empty = WorkItemCacheEntry{
                    .source_rel = try alloc.dupe(u8, ""),
                    .target_rel = try alloc.dupe(u8, ""),
                    .search_term = try alloc.dupe(u8, ""),
                    .bangumi_season_id = 0,
                    .bangumi_season_name = try alloc.dupe(u8, ""),
                };

                if (cache.work_items.getPtr(key_owned)) |old| {
                    old.deinit(alloc);
                    alloc.free(key_owned);
                    old.* = empty;
                } else {
                    cache.work_items.put(key_owned, empty) catch {
                        alloc.free(key_owned);
                        var tmp = empty;
                        tmp.deinit(alloc);
                    };
                }
                continue;
            }
            if (indent == 4 and current_wi_key != null) {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const k = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                const v_raw = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
                const wi = cache.work_items.getPtr(current_wi_key.?) orelse continue;
                if (std.mem.eql(u8, k, "source_rel")) {
                    alloc.free(wi.source_rel);
                    wi.source_rel = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "target_rel")) {
                    alloc.free(wi.target_rel);
                    wi.target_rel = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "search_term")) {
                    alloc.free(wi.search_term);
                    wi.search_term = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "bangumi_season_id")) {
                    wi.bangumi_season_id = std.fmt.parseInt(i32, v_raw, 10) catch wi.bangumi_season_id;
                } else if (std.mem.eql(u8, k, "bangumi_season_name")) {
                    alloc.free(wi.bangumi_season_name);
                    wi.bangumi_season_name = try yaml.unquote(alloc, v_raw);
                }
                continue;
            }
        }

        if (mode == .seasons or mode == .season_entry or mode == .episode_entry or mode == .subtitles) {
            if (indent == 2 and std.mem.endsWith(u8, line, ":")) {
                if (current_episode) |*ep| {
                    if (current_ep_key) |k| {
                        if (current_season) |*s| commitEpisode.run(alloc, s, k, ep);
                    }
                    current_episode = null;
                    current_ep_key = null;
                }
                if (current_season) |*s| {
                    if (current_season_key) |k| commitSeason.run(alloc, &cache.seasons, k, s);
                    current_season = null;
                    current_season_key = null;
                }

                const season_key_txt = std.mem.trim(u8, line[0 .. line.len - 1], &std.ascii.whitespace);
                const season_key = try yaml.unquote(alloc, season_key_txt);
                current_season_key = season_key;
                current_season = CachedSeasonInfo{
                    .bangumi_season_id = 0,
                    .bangumi_season_name = try alloc.dupe(u8, ""),
                    .total_bangumi_episodes = 0,
                    .episodes = std.StringHashMap(CachedEpisodeInfo).init(alloc),
                };
                mode = .season_entry;
                continue;
            }

            if (mode == .season_entry and indent == 4 and current_season != null) {
                if (std.mem.eql(u8, line, "episodes:")) {
                    mode = .episode_entry;
                    continue;
                }
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const k = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                const v_raw = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
                var s = &current_season.?;
                if (std.mem.eql(u8, k, "bangumi_season_id")) {
                    s.bangumi_season_id = std.fmt.parseInt(i32, v_raw, 10) catch s.bangumi_season_id;
                } else if (std.mem.eql(u8, k, "bangumi_season_name")) {
                    alloc.free(s.bangumi_season_name);
                    s.bangumi_season_name = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "total_bangumi_episodes")) {
                    s.total_bangumi_episodes = std.fmt.parseInt(i32, v_raw, 10) catch s.total_bangumi_episodes;
                }
                continue;
            }

            if (mode == .episode_entry and indent == 6 and std.mem.endsWith(u8, line, ":")) {
                if (current_episode) |*ep| {
                    if (current_ep_key) |k| {
                        if (current_season) |*s| commitEpisode.run(alloc, s, k, ep);
                    }
                    current_episode = null;
                    current_ep_key = null;
                }
                const ep_key_txt = std.mem.trim(u8, line[0 .. line.len - 1], &std.ascii.whitespace);
                current_ep_key = try yaml.unquote(alloc, ep_key_txt);
                current_episode = CachedEpisodeInfo{
                    .bangumi_sort = 0,
                    .bangumi_name = try alloc.dupe(u8, ""),
                    .video_src = null,
                    .video_dst = null,
                    .subtitles = std.StringHashMap([]const u8).init(alloc),
                };
                mode = .episode_entry;
                continue;
            }

            if (current_episode != null and indent == 8) {
                if (std.mem.eql(u8, line, "subtitles:")) {
                    mode = .subtitles;
                    continue;
                }
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const k = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                const v_raw = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
                var ep = &current_episode.?;
                if (std.mem.eql(u8, k, "bangumi_sort")) {
                    ep.bangumi_sort = std.fmt.parseFloat(f64, v_raw) catch ep.bangumi_sort;
                } else if (std.mem.eql(u8, k, "bangumi_name")) {
                    alloc.free(ep.bangumi_name);
                    ep.bangumi_name = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "video_src")) {
                    if (ep.video_src) |p| alloc.free(p);
                    ep.video_src = try yaml.unquote(alloc, v_raw);
                } else if (std.mem.eql(u8, k, "video_dst")) {
                    if (ep.video_dst) |p| alloc.free(p);
                    ep.video_dst = try yaml.unquote(alloc, v_raw);
                }
                continue;
            }

            if (mode == .subtitles and current_episode != null and indent == 10) {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const k_raw = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
                const v_raw = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
                const k = try yaml.unquote(alloc, k_raw);
                const v = try yaml.unquote(alloc, v_raw);
                current_episode.?.subtitles.put(k, v) catch {
                    alloc.free(k);
                    alloc.free(v);
                };
                continue;
            }
        }
    }

    if (current_episode) |*ep| {
        if (current_ep_key) |k| {
            if (current_season) |*s| commitEpisode.run(alloc, s, k, ep);
        }
        current_episode = null;
        current_ep_key = null;
    }
    if (current_season) |*s| {
        if (current_season_key) |k| commitSeason.run(alloc, &cache.seasons, k, s);
        current_season = null;
        current_season_key = null;
    }

    return cache;
}

/// 用一季的 Bangumi 数据 + 本地扫描结果更新 seasons_cache。
///
/// 行为：
/// - 构建该季的 episodes 映射（含 video_src/video_dst/subtitles）
/// - 若该 season 已存在则释放旧数据并覆盖
pub fn updateCache(
    alloc: std.mem.Allocator,
    seasons_cache: *std.StringHashMap(CachedSeasonInfo),
    season: api.Season,
    episodes: api.EpisodeList,
    localFiles: []scan.LocalFileInfo,
    videoExts: []const []const u8,
    subtitleExts: []const []const u8,
) !void {
    const eps_cache = try matcher.buildEpisodeCacheFromLocalFiles(alloc, episodes.items, localFiles, videoExts, subtitleExts, @intCast(episodes.items.len));

    // 优化：查找时不分配 key；仅在首次插入该 season 时 dupe。
    var key_buf: [32]u8 = undefined;
    const key_slice = try std.fmt.bufPrint(&key_buf, "{d}", .{season.id});

    if (seasons_cache.getPtr(key_slice)) |old_entry| {
        old_entry.deinit(alloc);
        old_entry.* = .{
            .bangumi_season_id = season.id,
            .bangumi_season_name = try alloc.dupe(u8, season.name),
            .total_bangumi_episodes = @intCast(episodes.items.len),
            .episodes = eps_cache,
        };
    } else {
        const key_owned = try alloc.dupe(u8, key_slice);
        try seasons_cache.put(key_owned, .{
            .bangumi_season_id = season.id,
            .bangumi_season_name = try alloc.dupe(u8, season.name),
            .total_bangumi_episodes = @intCast(episodes.items.len),
            .episodes = eps_cache,
        });
    }
}
