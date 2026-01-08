const std = @import("std");
const log = @import("io/log.zig");

/// 统一 API 模块入口：
/// - 本文件：Bangumi API + LLM API
///
/// 约定：业务侧只依赖 `api.llm.*`；LLM 的 URL / key / model / prompt 由上层（通常是 io.config）注入。
pub const llm = struct {
    const OpenRouter = struct {
        pub const api_url = "https://openrouter.ai/api/v1/chat/completions";
        pub const api_key_env = "OPENROUTER_API_KEY";
        pub const default_model = "arcee-ai/trinity-mini:free";
    };

    pub const Options = struct {
        url: ?[]const u8 = null,
        api_key: ?[]const u8 = null,
        model: ?[]const u8 = null,
        prompt_template: ?[]const u8 = null,
    };

    var g_url: ?[]const u8 = null;
    var g_api_key: ?[]const u8 = null;
    var g_model: ?[]const u8 = null;
    var g_prompt_template: ?[]const u8 = null;

    /// 注入/覆盖 LLM 配置。
    ///
    /// 说明：这里不做 owned copy，只保存上层提供的 slice（由上层管理生命周期）。
    pub fn configure(opts: Options) void {
        if (opts.url) |v| g_url = v;
        if (opts.api_key) |v| g_api_key = v;
        if (opts.model) |v| g_model = v;
        if (opts.prompt_template) |v| g_prompt_template = v;
    }

    /// 从 OpenAI-style chat completion JSON 响应里提取 message.content。
    fn chatCompletionContent(alloc: std.mem.Allocator, response: []const u8) !?[]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch return null;
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const choices_v = root_obj.get("choices") orelse return null;
        const choices = switch (choices_v) {
            .array => |a| a,
            else => return null,
        };
        if (choices.items.len == 0) return null;

        const c0 = choices.items[0];
        const c0_obj = switch (c0) {
            .object => |o| o,
            else => return null,
        };
        const msg_v = c0_obj.get("message") orelse return null;
        const msg_obj = switch (msg_v) {
            .object => |o| o,
            else => return null,
        };
        const content_v = msg_obj.get("content") orelse return null;
        const content = switch (content_v) {
            .string => |s| s,
            else => return null,
        };
        return try alloc.dupe(u8, content);
    }

    /// 去掉 Markdown ``` 代码块包裹（LLM 有时会把 JSON 放在代码块里）。
    fn stripCodeFences(input: []const u8) []const u8 {
        var s = std.mem.trim(u8, input, &std.ascii.whitespace);
        if (!std.mem.startsWith(u8, s, "```")) return s;

        const first_nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
        s = s[first_nl + 1 ..];

        if (std.mem.lastIndexOf(u8, s, "```")) |idx| {
            s = s[0..idx];
        }
        return std.mem.trim(u8, s, &std.ascii.whitespace);
    }

    /// 发送一次 LLM 请求并返回原始响应 body。
    ///
    /// - 若未显式配置 key，会回退读取环境变量 OPENROUTER_API_KEY
    /// - 返回值为 owned slice，调用方负责 free
    pub fn req_llm(alloc: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        const url = g_url orelse OpenRouter.api_url;
        const model = g_model orelse OpenRouter.default_model;

        var api_key_buf: ?[]u8 = null;
        defer if (api_key_buf) |b| alloc.free(b);

        const api_key: []const u8 = blk: {
            if (g_api_key) |k| {
                if (k.len > 0) break :blk k;
            }
            const owned = std.process.getEnvVarOwned(alloc, OpenRouter.api_key_env) catch |err| {
                log.print("[LLM] 未设置 API key（环境变量 {s}），跳过 LLM（{s}）\n", .{ OpenRouter.api_key_env, @errorName(err) });
                return error.MissingApiKey;
            };
            api_key_buf = owned;
            break :blk owned;
        };

        const auth_header_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
        defer alloc.free(auth_header_value);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header_value },
        };

        var body_writer = std.Io.Writer.Allocating.init(alloc);
        defer body_writer.deinit();
        var jw = std.json.Stringify{ .writer = &body_writer.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(model);
        try jw.objectField("messages");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("user");
        try jw.objectField("content");
        try jw.write(prompt);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
        const body = try body_writer.toOwnedSlice();
        defer alloc.free(body);

        var client = std.http.Client{ .allocator = alloc };
        defer client.deinit();

        var response_writer = std.Io.Writer.Allocating.init(alloc);
        defer response_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &headers,
            .response_writer = &response_writer.writer,
        }) catch |err| {
            log.print("[LLM] API 请求失败: {}\n", .{err});
            return err;
        };

        if (result.status != .ok) {
            const resp = response_writer.toOwnedSlice() catch "";
            defer if (resp.len > 0) alloc.free(resp);
            if (resp.len > 0) {
                const preview_len: usize = @min(resp.len, 400);
                log.print("[LLM] API 返回非成功状态: {}，响应前{}字节: {s}\n", .{ result.status, preview_len, resp[0..preview_len] });
            } else {
                log.print("[LLM] API 返回非成功状态: {}（无响应体）\n", .{result.status});
            }
            return error.ApiError;
        }

        return try response_writer.toOwnedSlice();
    }

    /// 从 LLM 响应 body 中提取“番剧名称”字符串。
    ///
    /// 返回 owned slice；若无法提取则返回 null。
    pub fn extractAnimeNameFromResponse(alloc: std.mem.Allocator, response: []const u8) !?[]const u8 {
        const content_opt = try chatCompletionContent(alloc, response);
        if (content_opt == null) return null;
        const content_owned = content_opt.?;
        defer alloc.free(content_owned);

        const content = stripCodeFences(content_owned);
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(trimmed, "null")) return null;
        return try alloc.dupe(u8, trimmed);
    }

    /// 单个文件夹名 -> 让 LLM 提取番剧名称（尽力而为）。
    pub fn extractAnimeNameWithLLM(alloc: std.mem.Allocator, folder_name: []const u8) !?[]const u8 {
        log.print("[LLM] 尝试使用 LLM 提取番剧名称...\n", .{});

        const prompt = try buildSinglePrompt(alloc, folder_name);
        defer alloc.free(prompt);

        const response = req_llm(alloc, prompt) catch |err| {
            log.print("[LLM] LLM 请求失败: {}\n", .{err});
            return null;
        };
        defer alloc.free(response);

        const anime_name = extractAnimeNameFromResponse(alloc, response) catch |err| {
            log.print("[LLM] 解析 LLM 响应失败: {}\n", .{err});
            return null;
        };

        if (anime_name) |name| {
            log.print("[LLM] LLM 提取到的番剧名称: {s}\n", .{name});
        } else {
            log.print("[LLM] LLM 未能提取到番剧名称\n", .{});
        }

        return anime_name;
    }

    /// 构造单条请求 prompt。
    ///
    /// - 若配置了 prompt_template，且包含 {s}，则做一次字符串插入
    /// - 否则追加 folder_name 作为补充信息
    fn buildSinglePrompt(alloc: std.mem.Allocator, folder_name: []const u8) ![]const u8 {
        if (g_prompt_template) |tpl| {
            if (std.mem.indexOf(u8, tpl, "{s}")) |idx| {
                const before = tpl[0..idx];
                const after = tpl[idx + "{s}".len ..];
                return try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ before, folder_name, after });
            }
            return try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ tpl, folder_name });
        }

        return try std.fmt.allocPrint(alloc,
            \\请根据这个文件夹名称提取番剧信息，只返回番剧的中文名称，不要其他内容。如果有多个季度信息（如 Season 2、S2等），请保留季度信息。
            \\文件夹名: {s}
        , .{folder_name});
    }

    /// 批量提取：把多个文件夹名一次性交给 LLM，返回 folder->name 的映射。
    ///
    /// - 返回 map 的 key/value 都是 owned slice；调用方需逐项释放
    /// - LLM 返回无法判断时 name 为 null，此处会忽略该条（不放入 map）
    pub fn extractAnimeNamesWithLLM(alloc: std.mem.Allocator, folder_names: []const []const u8) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(alloc);
        if (folder_names.len == 0) return map;

        var prompt_buf = std.ArrayList(u8).empty;
        defer prompt_buf.deinit(alloc);
        try prompt_buf.appendSlice(alloc, "请根据每个文件夹名提取对应番剧中文名称，保留季/季度信息例如 S2 Season 2。只输出严格 JSON，不要代码块。JSON 顶层包含 items 数组，每一项包含 folder 和 name 字段；无法判断则 name 为 null。folders:");
        for (folder_names, 0..) |folder, idx| {
            try prompt_buf.appendSlice(alloc, " [");
            const idx_str = try std.fmt.allocPrint(alloc, "{d}", .{idx + 1});
            defer alloc.free(idx_str);
            try prompt_buf.appendSlice(alloc, idx_str);
            try prompt_buf.appendSlice(alloc, "] ");
            try prompt_buf.appendSlice(alloc, folder);
            try prompt_buf.appendSlice(alloc, ";");
        }

        const response = req_llm(alloc, prompt_buf.items) catch |err| {
            log.print("[LLM] 批量 LLM 请求失败: {}\n", .{err});
            return map;
        };
        defer alloc.free(response);

        const content_opt = chatCompletionContent(alloc, response) catch null;
        if (content_opt == null) return map;
        const content_owned = content_opt.?;
        defer alloc.free(content_owned);

        const content = stripCodeFences(content_owned);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| {
            log.print("[LLM] 批量结果 JSON 解析失败: {}\n", .{err});
            return map;
        };
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return map,
        };
        const items_v = root_obj.get("items") orelse return map;
        const items = switch (items_v) {
            .array => |a| a,
            else => return map,
        };

        for (items.items) |it| {
            const obj = switch (it) {
                .object => |o| o,
                else => continue,
            };
            const folder_v = obj.get("folder") orelse continue;
            const name_v = obj.get("name") orelse continue;

            const folder = switch (folder_v) {
                .string => |s| s,
                else => continue,
            };
            const name_opt: ?[]const u8 = switch (name_v) {
                .string => |s| s,
                .null => null,
                else => null,
            };

            if (name_opt) |name| {
                const k = try alloc.dupe(u8, folder);
                errdefer alloc.free(k);
                const v = try alloc.dupe(u8, std.mem.trim(u8, name, &std.ascii.whitespace));
                errdefer alloc.free(v);
                map.put(k, v) catch {
                    alloc.free(k);
                    alloc.free(v);
                };
            }
        }

        return map;
    }
};

/// Bangumi 搜索结果中抽象出的“番剧/条目”信息。
pub const Season = struct {
    id: i32,
    name: []const u8,
    platform: []const u8, // TV, Web, OVA 等
    eps: i32, // 总集数
    score: f64, // 评分
};

/// 单集信息（sort 为集号/排序，可能是小数）。
pub const Episode = struct {
    sort: f64,
    name: []const u8,
};

pub const EpisodeList = std.ArrayList(Episode);

pub const EpisodeData = struct {
    total: i32,
    data: []Episode,
};

const ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 构造 Bangumi v0 search/subjects 的 POST JSON body。
///
/// 新 API 使用 POST JSON body，不再需要 URL 编码。
pub fn buildSearchRequestBody(alloc: std.mem.Allocator, keyword: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "keyword": "{s}",
        \\  "sort": "rank",
        \\  "filter": {{
        \\    "type": [2]
        \\  }}
        \\}}
    , .{keyword});
}

/// 构造 Bangumi v0 episodes endpoint 的 URL（分页）。
pub fn buildEpisodesUrl(alloc: std.mem.Allocator, id: i32, limit: i32, offset: i32) ![]u8 {
    return std.fmt.allocPrint(alloc, "https://api.bgm.tv/v0/episodes?subject_id={d}&limit={d}&offset={d}", .{ id, limit, offset });
}

/// 发送 POST 请求并返回响应 body（owned slice）。
fn fetchPost(alloc: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(alloc);
    defer response_writer.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .user_agent = .{ .override = ua },
            .content_type = .{ .override = "application/json" },
        },
        .payload = body,
        .response_writer = &response_writer.writer,
    });

    return try response_writer.toOwnedSlice();
}

/// 发送 GET 请求并返回响应 body（owned slice）。
fn fetch(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var body = std.ArrayList(u8).empty;
    defer body.deinit(alloc);

    var response_writer = std.Io.Writer.Allocating.init(alloc);
    defer response_writer.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = ua } },
        .response_writer = &response_writer.writer,
    });

    return try response_writer.toOwnedSlice();
}

/// 把 JSON 字符串字段复制为 owned slice。
fn jsonStringDup(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return try alloc.dupe(u8, s);
}

/// 从 json.Value 中取 string（否则返回 null）。
fn valueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// 从 json.Value 中取整数（支持 integer/float/number_string）。
fn valueAsI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// 从 json.Value 中取浮点数（支持 float/integer/number_string）。
fn valueAsF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// 从标题文本中粗略推断季号（用于搜索结果选择打分）。
fn seasonFromText(text: []const u8) u8 {
    if (text.len == 0) return 1;
    if (std.mem.indexOf(u8, text, "第二季") != null or std.mem.indexOf(u8, text, "第2季") != null) return 2;
    if (std.mem.indexOf(u8, text, "第三季") != null or std.mem.indexOf(u8, text, "第3季") != null) return 3;
    if (std.mem.indexOf(u8, text, "第四季") != null or std.mem.indexOf(u8, text, "第4季") != null) return 4;
    if (std.mem.indexOf(u8, text, "第五季") != null or std.mem.indexOf(u8, text, "第5季") != null) return 5;

    if (std.ascii.indexOfIgnoreCase(text, "season")) |idx| {
        var j = idx + 6;
        while (j < text.len and (text[j] == ' ' or text[j] == '-' or text[j] == '_')) : (j += 1) {}
        var k = j;
        while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
        if (k > j) {
            const n = std.fmt.parseInt(u8, text[j..k], 10) catch 1;
            if (n > 0) return n;
        }
    }

    // S2 / S02
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const c = text[i];
        if (c != 'S' and c != 's') continue;
        if (!std.ascii.isDigit(text[i + 1])) continue;
        var k = i + 1;
        while (k < text.len and std.ascii.isDigit(text[k])) : (k += 1) {}
        const n = std.fmt.parseInt(u8, text[i + 1 .. k], 10) catch 0;
        if (n > 0) return n;
    }

    return 1;
}

/// 从 term 中推断“期望季号”。
fn desiredSeasonFromTerm(term: []const u8) u8 {
    // 若用户/上层没有显式带季信息，则默认按第一季倾向选择
    return seasonFromText(term);
}

/// 通过 Bangumi 搜索获取一个最匹配的 Season。
///
/// - term：搜索关键词（建议包含季信息，如 "Season 2"/"S2"）
/// - use_cn：优先使用 name_cn（若存在且非空）
///
/// 返回：
/// - null：未找到合适结果
/// - Season：其 name/platform 为 owned slice，调用方必须 `deinitSeason`
pub fn getSeason(alloc: std.mem.Allocator, term: []const u8, use_cn: bool) !?Season {
    const url = "https://api.bgm.tv/v0/search/subjects";
    const request_body = try buildSearchRequestBody(alloc, term);
    defer alloc.free(request_body);

    log.print("    [API] 请求 URL: {s}\n", .{url});
    log.print("    [API] 请求 body: {s}\n", .{request_body});

    const body = fetchPost(alloc, url, request_body) catch |err| {
        log.print("    [API] 请求失败: {}\n", .{err});
        return err;
    };
    defer alloc.free(body);
    log.print("    [API] 响应长度: {} 字节\n", .{body.len});
    if (body.len < 500) {
        log.print("    [API] 响应内容: {s}\n", .{body});
    } else {
        log.print("    [API] 响应内容 (前200字符): {s}...\n", .{body[0..200]});
    }

    log.print("    [API] 开始解析 JSON...\n", .{});
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| {
        log.print("    [API] JSON 解析失败: {}\n", .{err});
        return err;
    };
    defer parsed.deinit();
    log.print("    [API] JSON 解析成功\n", .{});

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |o| o,
        else => {
            log.print("    [API] 响应不是 JSON 对象\n", .{});
            return null;
        },
    };

    // 新 API 返回的是 {data: [...], total: N} 格式
    const data_node = root_obj.get("data") orelse {
        log.print("    [API] 响应中没有 'data' 字段\n", .{});
        return null;
    };
    const data_array = switch (data_node) {
        .array => |a| a,
        else => {
            log.print("    [API] 'data' 字段不是数组\n", .{});
            return null;
        },
    };
    if (data_array.items.len == 0) {
        log.print("    [API] 搜索结果为空\n", .{});
        return null;
    }
    log.print("    [API] 找到 {} 个搜索结果\n", .{data_array.items.len});

    // 智能选择：优先选择 TV 动画且有集数的结果，并尽量匹配查询里的季信息
    const desired_season: u8 = desiredSeasonFromTerm(term);
    var best_match: ?std.json.ObjectMap = null;
    var best_score: i32 = -1;

    for (data_array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        var score: i32 = 0;

        // 季度匹配（避免同名第二季/续作被误选）
        const cand_name_v = obj.get("name") orelse null;
        const cand_name_cn_v = obj.get("name_cn") orelse null;
        const cand_name = if (cand_name_v) |v| valueAsString(v) orelse "" else "";
        const cand_name_cn = if (cand_name_cn_v) |v| valueAsString(v) orelse "" else "";
        const cand_title: []const u8 = if (cand_name_cn.len > 0) cand_name_cn else cand_name;
        const cand_season: u8 = seasonFromText(cand_title);
        if (cand_season == desired_season) {
            score += 15;
        } else {
            // 不匹配就扣分，但不要扣太狠（避免搜索词确实更像第二季时被完全压制）
            score -= 10;
        }

        // 优先 TV 类型 (+20分)
        if (obj.get("platform")) |platform_val| {
            if (valueAsString(platform_val)) |platform| {
                if (std.mem.eql(u8, platform, "TV")) score += 20;
            }
        }

        // 有集数的 (+10分)
        if (obj.get("eps")) |eps_val| {
            if (valueAsI64(eps_val)) |eps| {
                if (eps > 0) score += 10;
            }
        }

        // 有评分的 (+5分)
        if (obj.get("rating")) |rating_val| {
            if (rating_val == .object) score += 5;
        }

        // 不是锁定或 NSFW 的 (+3分)
        if (obj.get("locked")) |locked_val| {
            if (locked_val == .bool and locked_val.bool == false) score += 3;
        }

        if (score > best_score) {
            best_score = score;
            best_match = obj;
        }
    }

    // 如果没有找到好的匹配，使用第一个结果
    const selected = best_match orelse switch (data_array.items[0]) {
        .object => |o| o,
        else => return null,
    };

    log.print("    [API] 选择最佳匹配（得分: {}）\n", .{best_score});

    const id_val = selected.get("id") orelse return null;
    const id_i64 = valueAsI64(id_val) orelse return null;
    const id_int: i32 = @intCast(id_i64);

    const name_val_v = selected.get("name") orelse return null;
    const name_cn_val_v = selected.get("name_cn") orelse name_val_v;
    const name_val = valueAsString(name_val_v) orelse return null;
    const name_cn_val = valueAsString(name_cn_val_v);

    const chosen: []const u8 = if (use_cn and name_cn_val != null and name_cn_val.?.len > 0) name_cn_val.? else name_val;
    const name_copy = try jsonStringDup(alloc, chosen);

    // 提取平台信息
    const platform_str = if (selected.get("platform")) |p| valueAsString(p) orelse "Unknown" else "Unknown";
    const platform_copy = try jsonStringDup(alloc, platform_str);

    // 提取集数
    const eps_count: i32 = if (selected.get("eps")) |e| blk: {
        const eps_i64 = valueAsI64(e) orelse 0;
        break :blk @intCast(eps_i64);
    } else 0;

    // 提取评分
    var rating_score: f64 = 0.0;
    if (selected.get("rating")) |rating_val| {
        if (rating_val == .object) {
            const rating_obj = rating_val.object;
            if (rating_obj.get("score")) |score_val| {
                rating_score = valueAsF64(score_val) orelse 0.0;
            }
        }
    }

    return Season{
        .id = id_int,
        .name = name_copy,
        .platform = platform_copy,
        .eps = eps_count,
        .score = rating_score,
    };
}

/// 获取某个 Season 的所有 episodes 列表（会处理分页）。
///
/// 返回值为 `std.ArrayList(Episode)`：每个 Episode.name 为 owned slice，调用方必须 `deinitEpisodeList`。
pub fn getEpisodes(alloc: std.mem.Allocator, id: i32, use_cn: bool) !?EpisodeList {
    // Bangumi v0 episodes endpoint 是分页的：必须循环拉取，否则列表不完整会污染缓存并影响重命名。
    var episodes = std.ArrayList(Episode).empty;
    errdefer deinitEpisodeList(alloc, &episodes);

    const limit: i32 = 100;
    var offset: i32 = 0;
    var total: i32 = -1;
    var safety: usize = 0;

    while (safety < 50) : (safety += 1) {
        const url = try buildEpisodesUrl(alloc, id, limit, offset);
        defer alloc.free(url);

        const body = fetch(alloc, url) catch |err| {
            // If we already have some episodes, return what we have.
            if (episodes.items.len > 0) return episodes;
            return err;
        };
        defer alloc.free(body);

        const appended = parseEpisodesResponsePage(alloc, body, use_cn, &episodes, &total, 0, 1) catch |err| {
            if (episodes.items.len > 0) return episodes;
            return err;
        };
        if (appended == 0) break;
        offset += @intCast(appended);
        if (total >= 0 and offset >= total) break;
    }

    return episodes;
}

/// 按 Bangumi episode.type 获取 episodes。
///
/// - episode_type=0：正剧（会额外要求 ep>0，避免混入 ep=0 的条目）
/// - episode_type=1：特典/特别篇（允许 ep=0）
pub fn getEpisodesByType(alloc: std.mem.Allocator, id: i32, use_cn: bool, episode_type: i64) !?EpisodeList {
    var episodes = std.ArrayList(Episode).empty;
    errdefer deinitEpisodeList(alloc, &episodes);

    const limit: i32 = 100;
    var offset: i32 = 0;
    var total: i32 = -1;
    var safety: usize = 0;

    const min_ep: i64 = if (episode_type == 0) 1 else 0;

    while (safety < 50) : (safety += 1) {
        const url = try buildEpisodesUrl(alloc, id, limit, offset);
        defer alloc.free(url);

        const body = fetch(alloc, url) catch |err| {
            if (episodes.items.len > 0) return episodes;
            return err;
        };
        defer alloc.free(body);

        const appended = parseEpisodesResponsePage(alloc, body, use_cn, &episodes, &total, episode_type, min_ep) catch |err| {
            if (episodes.items.len > 0) return episodes;
            return err;
        };
        if (appended == 0) break;

        offset += @intCast(appended);
        if (total >= 0 and offset >= total) break;
    }

    return episodes;
}

/// 解析 Bangumi v0 /episodes 响应的一页，并把“正剧集”追加到 episodes。
///
/// 关键点：Bangumi 的 episodes 会混入特别篇/OVA 等（type=1 等），它们常见的 sort 也从 1/2 开始，
/// 若不过滤会覆盖正片 E01/E02 的名称，导致重命名错误。
///
/// 过滤规则（默认正片）：
/// - type 必须为 0
/// - ep 必须 > 0（避免 ep=0 的特典/条目）
fn parseEpisodesResponsePage(
    alloc: std.mem.Allocator,
    body: []const u8,
    use_cn: bool,
    episodes: *EpisodeList,
    total: *i32,
    episode_type: i64,
    min_ep: i64,
) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = switch (root) {
        .object => |o| o,
        else => return 0,
    };

    if (total.* < 0) {
        const total_node = root_obj.get("total") orelse return 0;
        const total_i64 = valueAsI64(total_node) orelse return 0;
        total.* = @intCast(total_i64);
    }

    const data_node = root_obj.get("data") orelse return 0;
    const data_arr = switch (data_node) {
        .array => |a| a,
        else => return 0,
    };
    if (data_arr.items.len == 0) return 0;

    var appended: usize = 0;
    for (data_arr.items) |ep_node| {
        const ep_obj = switch (ep_node) {
            .object => |o| o,
            else => continue,
        };

        const type_val = ep_obj.get("type") orelse continue;
        const ep_val = ep_obj.get("ep") orelse continue;
        const type_i64 = valueAsI64(type_val) orelse continue;
        const ep_i64 = valueAsI64(ep_val) orelse continue;
        if (type_i64 != episode_type) continue;
        if (ep_i64 < min_ep) continue;

        const sort_val = ep_obj.get("sort") orelse continue;
        const name_val_v = ep_obj.get("name") orelse continue;
        const name_cn_val_v = ep_obj.get("name_cn") orelse name_val_v;

        const sort_f = valueAsF64(sort_val) orelse continue;
        const name_val = valueAsString(name_val_v) orelse continue;
        const name_cn_val = valueAsString(name_cn_val_v);
        const chosen: []const u8 = if (use_cn and name_cn_val != null and name_cn_val.?.len > 0) name_cn_val.? else name_val;
        const name_copy = try jsonStringDup(alloc, chosen);
        try episodes.append(alloc, .{ .sort = sort_f, .name = name_copy });
        appended += 1;
    }

    return appended;
}

test "getEpisodes: filter out specials (type!=0/ep==0) to avoid overriding E01" {
    const fixture =
        "{\n" ++
        "  \"total\": 4,\n" ++
        "  \"data\": [\n" ++
        "    {\"type\": 0, \"ep\": 1, \"sort\": 1, \"name\": \"TV1\", \"name_cn\": \"正片1\"},\n" ++
        "    {\"type\": 0, \"ep\": 2, \"sort\": 2, \"name\": \"TV2\", \"name_cn\": \"正片2\"},\n" ++
        "    {\"type\": 1, \"ep\": 0, \"sort\": 1, \"name\": \"SP1\", \"name_cn\": \"特典1\"},\n" ++
        "    {\"type\": 1, \"ep\": 0, \"sort\": 2, \"name\": \"SP2\", \"name_cn\": \"特典2\"}\n" ++
        "  ]\n" ++
        "}\n";

    var total: i32 = -1;
    var eps = EpisodeList.empty;
    defer deinitEpisodeList(std.testing.allocator, &eps);

    const appended = try parseEpisodesResponsePage(std.testing.allocator, fixture, true, &eps, &total, 0, 1);
    try std.testing.expectEqual(@as(usize, 2), appended);
    try std.testing.expectEqual(@as(usize, 2), eps.items.len);
    try std.testing.expectEqual(@as(f64, 1.0), eps.items[0].sort);
    try std.testing.expectEqualStrings("正片1", eps.items[0].name);
    try std.testing.expectEqual(@as(f64, 2.0), eps.items[1].sort);
    try std.testing.expectEqualStrings("正片2", eps.items[1].name);
}

/// 释放 Season 内部的 name/platform。
pub fn deinitSeason(alloc: std.mem.Allocator, season: Season) void {
    alloc.free(season.name);
    alloc.free(season.platform);
}

/// 释放 EpisodeList：包括每集 name 与 ArrayList 本体。
pub fn deinitEpisodeList(alloc: std.mem.Allocator, list: *EpisodeList) void {
    for (list.items) |ep| {
        alloc.free(ep.name);
    }
    list.deinit(alloc);
}
