const std = @import("std");

/// config模块：负责从config.toml读取和生成配置
/// 包括LLM请求地址、APIkey、提示词、输入输出文件夹路径、启动参数等
pub const AppConfig = struct {
    base: []const u8, // 源目录
    anime: []const u8, // 输出目录
    use_cn: bool, // 是否优先使用中文名
    debug: bool, // 是否写入调试日志
    llm_url: []const u8, // LLM API地址
    llm_api_key: []const u8, // LLM API密钥
    llm_model: []const u8, // LLM模型名称
    llm_prompt_template: []const u8, // LLM提示词模板
    bangumi_user_agent: []const u8, // Bangumi API User-Agent
    filter_custom_rules: []const []const u8, // 自定义过滤规则（类正则）
    special_folders: []const []const u8, // 特典/附加内容文件夹名列表（仅文件夹名，不含路径）
};

const DEFAULT_BASE = ".";
const DEFAULT_ANIME = "./anime";
const DEFAULT_LLM_URL = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_LLM_MODEL = "arcee-ai/trinity-mini:free";
const DEFAULT_BANGUMI_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
const DEFAULT_PROMPT_TEMPLATE =
    \\根据以下文件夹名称，识别动画名称并返回JSON格式：
    \\文件夹名：{s}
    \\
    \\请返回格式：{{"anime_name": "识别到的动画名称"}}
;

/// 从config.toml加载配置
pub fn loadFromFile(alloc: std.mem.Allocator, path: []const u8) !AppConfig {
    var cfg = try defaultConfig(alloc);
    errdefer deinit(&cfg, alloc);

    const data = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(data);

    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');

    var pending_multiline_key: ?[]const u8 = null;
    var pending_multiline_section: []const u8 = "";
    var pending_multiline_buf = std.ArrayList(u8).empty;
    defer pending_multiline_buf.deinit(alloc);

    var pending_array_key: ?[]const u8 = null;
    var pending_array_section: []const u8 = "";
    var pending_array_items = std.ArrayList([]const u8).empty;
    defer {
        for (pending_array_items.items) |s| alloc.free(s);
        pending_array_items.deinit(alloc);
    }

    while (it.next()) |raw_line_in| {
        var raw_line = raw_line_in;
        if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line = raw_line[0 .. raw_line.len - 1];

        // 正在解析 """ 多行字符串
        if (pending_multiline_key) |k| {
            if (std.mem.indexOf(u8, raw_line, "\"\"\"")) |end_idx| {
                try pending_multiline_buf.appendSlice(alloc, raw_line[0..end_idx]);
                const value = try pending_multiline_buf.toOwnedSlice(alloc);
                pending_multiline_buf.clearRetainingCapacity();
                try applyTomlKeyValue(alloc, &cfg, pending_multiline_section, k, .{ .string = value }, false);
                alloc.free(value);
                pending_multiline_key = null;
                continue;
            } else {
                try pending_multiline_buf.appendSlice(alloc, raw_line);
                try pending_multiline_buf.append(alloc, '\n');
                continue;
            }
        }

        // 正在解析多行数组（目前仅支持字符串数组）
        if (pending_array_key) |k| {
            const cleaned = stripTomlComments(raw_line);
            const line = std.mem.trim(u8, cleaned, &std.ascii.whitespace);
            if (line.len == 0) continue;

            try parseTomlStringArrayLine(alloc, &pending_array_items, line);
            if (std.mem.indexOfScalar(u8, line, ']') != null) {
                const owned = try pending_array_items.toOwnedSlice(alloc);
                pending_array_items.clearRetainingCapacity();
                try applyTomlKeyValue(alloc, &cfg, pending_array_section, k, .{ .string_array = owned }, true);
                for (owned) |s| alloc.free(s);
                alloc.free(owned);
                pending_array_key = null;
            }
            continue;
        }

        const cleaned = stripTomlComments(raw_line);
        const line = std.mem.trim(u8, cleaned, &std.ascii.whitespace);
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], &std.ascii.whitespace);
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
        var value_src = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);
        if (key.len == 0) continue;

        // """ 多行字符串
        if (std.mem.startsWith(u8, value_src, "\"\"\"")) {
            value_src = value_src[3..];
            if (std.mem.indexOf(u8, value_src, "\"\"\"")) |end_idx| {
                const chunk = value_src[0..end_idx];
                const owned = try alloc.dupe(u8, chunk);
                defer alloc.free(owned);
                try applyTomlKeyValue(alloc, &cfg, section, key, .{ .string = owned }, false);
            } else {
                pending_multiline_key = key;
                pending_multiline_section = section;
                pending_multiline_buf.clearRetainingCapacity();
                try pending_multiline_buf.appendSlice(alloc, value_src);
                try pending_multiline_buf.append(alloc, '\n');
            }
            continue;
        }

        // 字符串数组（可多行）
        if (value_src.len > 0 and value_src[0] == '[') {
            pending_array_key = key;
            pending_array_section = section;
            pending_array_items.clearRetainingCapacity();
            try parseTomlStringArrayLine(alloc, &pending_array_items, value_src);
            if (std.mem.indexOfScalar(u8, value_src, ']') != null) {
                // 单行完成
                const owned = try pending_array_items.toOwnedSlice(alloc);
                pending_array_items.clearRetainingCapacity();
                try applyTomlKeyValue(alloc, &cfg, section, key, .{ .string_array = owned }, true);
                for (owned) |s| alloc.free(s);
                alloc.free(owned);
                pending_array_key = null;
            }
            continue;
        }

        if (value_src.len > 0 and value_src[0] == '"') {
            const owned = try parseTomlStringOwned(alloc, value_src);
            defer alloc.free(owned);
            try applyTomlKeyValue(alloc, &cfg, section, key, .{ .string = owned }, false);
            continue;
        }

        if (std.ascii.eqlIgnoreCase(value_src, "true") or std.ascii.eqlIgnoreCase(value_src, "false")) {
            const b = std.ascii.eqlIgnoreCase(value_src, "true");
            try applyTomlKeyValue(alloc, &cfg, section, key, .{ .boolean = b }, false);
            continue;
        }
    }

    return cfg;
}

/// 获取默认配置（分配所有字段；调用方必须 deinit）
pub fn defaultConfig(alloc: std.mem.Allocator) !AppConfig {
    return getDefault(alloc);
}

/// 获取默认配置
fn getDefault(alloc: std.mem.Allocator) !AppConfig {
    return AppConfig{
        .base = try alloc.dupe(u8, DEFAULT_BASE),
        .anime = try alloc.dupe(u8, DEFAULT_ANIME),
        .use_cn = true,
        .debug = false,
        .llm_url = try alloc.dupe(u8, DEFAULT_LLM_URL),
        .llm_api_key = std.process.getEnvVarOwned(alloc, "OPENROUTER_API_KEY") catch try alloc.dupe(u8, ""),
        .llm_model = try alloc.dupe(u8, DEFAULT_LLM_MODEL),
        .llm_prompt_template = try alloc.dupe(u8, DEFAULT_PROMPT_TEMPLATE),
        .bangumi_user_agent = try alloc.dupe(u8, DEFAULT_BANGUMI_UA),
        .filter_custom_rules = try alloc.alloc([]const u8, 0),
        .special_folders = try alloc.alloc([]const u8, 0),
    };
}

/// 从命令行参数解析配置
pub fn parseArgs(alloc: std.mem.Allocator, args: [][:0]u8) !AppConfig {
    var cfg = try getDefault(alloc);

    try applyArgsOverrides(alloc, &cfg, args);
    return cfg;
}

/// 将命令行参数覆盖到现有配置上。
///
/// 位置参数为 `<base> <anime> <use_cn>`，并支持 `debug/--debug/-d`。
pub fn applyArgsOverrides(alloc: std.mem.Allocator, cfg: *AppConfig, args: [][:0]u8) !void {
    var pos: [3][]const u8 = .{ "", "", "" };
    var pos_len: usize = 0;

    if (args.len > 1) {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = std.mem.sliceTo(args[i], 0);
            if (std.ascii.eqlIgnoreCase(a, "debug") or
                std.mem.eql(u8, a, "--debug") or
                std.mem.eql(u8, a, "-d"))
            {
                cfg.debug = true;
                continue;
            }
            if (pos_len < pos.len) {
                pos[pos_len] = a;
                pos_len += 1;
            }
        }
    }

    if (pos_len >= 1 and pos[0].len > 0) {
        alloc.free(cfg.base);
        cfg.base = try alloc.dupe(u8, pos[0]);
    }
    if (pos_len >= 2 and pos[1].len > 0) {
        alloc.free(cfg.anime);
        cfg.anime = try alloc.dupe(u8, pos[1]);
    }
    if (pos_len >= 3 and pos[2].len > 0) {
        cfg.use_cn = parseBoolArg(pos[2], cfg.use_cn);
    }
}

/// 解析命令行 bool 参数（兼容 1/0、true/false、yes/no、on/off）；无法解析时返回 default。
fn parseBoolArg(s: []const u8, default: bool) bool {
    if (s.len == 0) return default;
    if (std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "true") or
        std.ascii.eqlIgnoreCase(s, "yes") or
        std.ascii.eqlIgnoreCase(s, "on")) return true;
    if (std.mem.eql(u8, s, "0") or
        std.ascii.eqlIgnoreCase(s, "false") or
        std.ascii.eqlIgnoreCase(s, "no") or
        std.ascii.eqlIgnoreCase(s, "off")) return false;
    return default;
}

/// 释放 `AppConfig` 内所有由 `alloc` 分配的字段。
///
/// 注意：`AppConfig` 内的字符串、字符串数组均为 owned memory。
pub fn deinit(cfg: *AppConfig, alloc: std.mem.Allocator) void {
    alloc.free(cfg.base);
    alloc.free(cfg.anime);
    alloc.free(cfg.llm_url);
    alloc.free(cfg.llm_api_key);
    alloc.free(cfg.llm_model);
    alloc.free(cfg.llm_prompt_template);
    alloc.free(cfg.bangumi_user_agent);

    for (cfg.filter_custom_rules) |s| alloc.free(s);
    alloc.free(cfg.filter_custom_rules);

    for (cfg.special_folders) |s| alloc.free(s);
    alloc.free(cfg.special_folders);
}

const TomlValue = union(enum) {
    string: []const u8,
    boolean: bool,
    string_array: []const []const u8,
};

/// 去掉 TOML 行尾注释（支持字符串内的 `#` 不被当作注释）。
fn stripTomlComments(line: []const u8) []const u8 {
    var in_string = false;
    var escape = false;
    for (line, 0..) |c, i| {
        if (escape) {
            escape = false;
            continue;
        }
        if (in_string and c == '\\') {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string and c == '#') return line[0..i];
    }
    return line;
}

/// 替换一个 owned string 字段（先 free 旧值，再 dupe 新值）。
fn replaceOwnedString(alloc: std.mem.Allocator, dst: *[]const u8, src: []const u8) !void {
    alloc.free(dst.*);
    dst.* = try alloc.dupe(u8, src);
}

/// 替换一个 owned string array 字段（深拷贝；先释放旧数组及其元素）。
fn replaceOwnedStringArray(alloc: std.mem.Allocator, dst: *[]const []const u8, src: []const []const u8) !void {
    for (dst.*) |s| alloc.free(s);
    alloc.free(dst.*);

    var out = try alloc.alloc([]const u8, src.len);
    errdefer {
        for (out) |s| alloc.free(s);
        alloc.free(out);
    }
    for (src, 0..) |s, i| out[i] = try alloc.dupe(u8, s);
    dst.* = out;
}

/// 将解析到的 TOML 键值对应用到 `AppConfig`。
///
/// 支持的 section/key：
/// - [paths] base/anime
/// - [options] use_cn/debug
/// - [llm] url/api_key/model/prompt_template
/// - [bangumi] user_agent
/// - [filter] custom_rules
/// - [specials] folders (字符串数组)
fn applyTomlKeyValue(
    alloc: std.mem.Allocator,
    cfg: *AppConfig,
    section: []const u8,
    key: []const u8,
    value: TomlValue,
    value_is_temp_array: bool,
) !void {
    _ = value_is_temp_array;

    if (std.mem.eql(u8, section, "paths")) {
        if (std.mem.eql(u8, key, "base")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.base, value.string);
        } else if (std.mem.eql(u8, key, "anime")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.anime, value.string);
        }
        return;
    }
    if (std.mem.eql(u8, section, "options")) {
        if (std.mem.eql(u8, key, "use_cn")) {
            if (value == .boolean) cfg.use_cn = value.boolean;
        } else if (std.mem.eql(u8, key, "debug")) {
            if (value == .boolean) cfg.debug = value.boolean;
        }
        return;
    }
    if (std.mem.eql(u8, section, "llm")) {
        if (std.mem.eql(u8, key, "url")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.llm_url, value.string);
        } else if (std.mem.eql(u8, key, "api_key")) {
            if (value == .string and value.string.len > 0) {
                try replaceOwnedString(alloc, &cfg.llm_api_key, value.string);
            }
        } else if (std.mem.eql(u8, key, "model")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.llm_model, value.string);
        } else if (std.mem.eql(u8, key, "prompt_template")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.llm_prompt_template, value.string);
        }
        return;
    }
    if (std.mem.eql(u8, section, "bangumi")) {
        if (std.mem.eql(u8, key, "user_agent")) {
            if (value == .string) try replaceOwnedString(alloc, &cfg.bangumi_user_agent, value.string);
        }
        return;
    }
    if (std.mem.eql(u8, section, "filter")) {
        if (std.mem.eql(u8, key, "custom_rules")) {
            if (value == .string_array) try replaceOwnedStringArray(alloc, &cfg.filter_custom_rules, value.string_array);
        }
        return;
    }

    if (std.mem.eql(u8, section, "specials")) {
        if (std.mem.eql(u8, key, "folders") or std.mem.eql(u8, key, "folder_names")) {
            if (value == .string_array) try replaceOwnedStringArray(alloc, &cfg.special_folders, value.string_array);
        }
        return;
    }
}

/// 解析一个 TOML 双引号字符串，并返回 owned slice。
///
/// 当前仅支持单行、双引号格式（"...")，并处理常见转义字符。
fn parseTomlStringOwned(alloc: std.mem.Allocator, src: []const u8) ![]const u8 {
    // 仅支持双引号字符串（单行）
    if (src.len < 2 or src[0] != '"') return error.InvalidToml;
    var i: usize = 1;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '"') {
            // 忽略 closing quote 后面的内容（例如空白/逗号）
            return out.toOwnedSlice(alloc);
        }
        if (c == '\\') {
            i += 1;
            if (i >= src.len) return error.InvalidToml;
            const esc = src[i];
            switch (esc) {
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                't' => try out.append(alloc, '\t'),
                '\\' => try out.append(alloc, '\\'),
                '"' => try out.append(alloc, '"'),
                else => try out.append(alloc, esc),
            }
            continue;
        }
        try out.append(alloc, c);
    }

    return error.InvalidToml;
}

/// 解析 TOML 字符串数组的一行，并把解析到的元素追加到 `out`。
///
/// 允许数组跨多行：调用方会不断喂入行内容，直到遇到 `]`。
fn parseTomlStringArrayLine(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), line: []const u8) !void {
    // 允许行内出现 [ 或 ]，以及字符串元素与逗号。
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '"') continue;
        const rest = line[i..];
        const s = try parseTomlStringOwned(alloc, rest);
        defer alloc.free(s);
        try out.append(alloc, try alloc.dupe(u8, s));

        // 前进到字符串结束（包含 escape）
        var j: usize = 1;
        var escape = false;
        while (j < rest.len) : (j += 1) {
            const c = rest[j];
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') {
                break;
            }
        }
        i += j;
    }
}
