const std = @import("std");

/// io/util：纯工具模块。
///
/// 约束：
/// - 只依赖 std（不依赖本项目其它模块），避免 import 循环。
/// - 收敛多个模块重复实现的字符串/文件类型/文件名清洗逻辑。
/// 常见字幕“基础后缀”。
///
/// 注意：这里按后缀匹配（endsWith），用于兼容复合扩展名（例如 ".scjp.ass"）。
pub const subtitle_base_suffixes = [_][]const u8{ ".ssa", ".ass", ".srt", ".sub", ".idx", ".vtt" };

/// 默认支持的视频扩展名（包含点），忽略大小写。
pub const default_video_exts = [_][]const u8{ ".mkv", ".mp4", ".avi", ".mov", ".flv", ".rmvb", ".wmv", ".ts", ".webm", ".m4v", ".mpg", ".mpeg" };

/// 默认支持的字幕扩展名列表。
///
/// 说明：因为扫描阶段拿到的通常是“最后一个扩展名”（例如 foo.scjp.ass 的 extension 为 .ass），
/// 所以这里主要保留基础后缀即可。
pub const default_subtitle_exts = subtitle_base_suffixes;

/// ASCII 忽略大小写的 endsWith。
pub fn endsWithIgnoreAsciiCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const start = haystack.len - needle.len;
    return std.ascii.eqlIgnoreCase(haystack[start..], needle);
}

/// ASCII 忽略大小写的 contains（朴素扫描）。
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 生成 ASCII 小写副本（owned slice）。
pub fn asciiLowerCopy(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// 判断扩展名是否在列表中（忽略大小写）。
///
/// ext 建议包含点（例如 ".mkv"）。
pub fn isExtInListIgnoreAsciiCase(ext: []const u8, list: []const []const u8) bool {
    for (list) |v| {
        if (std.ascii.eqlIgnoreCase(ext, v)) return true;
        if (endsWithIgnoreAsciiCase(ext, v)) return true;
    }
    return false;
}

/// 是否为视频文件（按扩展名判断，忽略大小写）。
pub fn isVideoFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return isExtInListIgnoreAsciiCase(ext, default_video_exts[0..]);
}

/// 是否为字幕文件（按扩展名判断；支持复合后缀；忽略大小写）。
pub fn isSubtitleFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return isExtInListIgnoreAsciiCase(ext, subtitle_base_suffixes[0..]);
}

/// 将字符串转换为适合 Windows 文件名的安全形式。
///
/// 规则：
/// - 替换 Windows 不允许的字符为 `_`
/// - 去掉末尾的点/空格
/// - 做长度裁剪（避免过长路径）
pub fn sanitizeFilename(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    for (name) |c| {
        const invalid = switch (c) {
            '\\', '/', ':', '*', '?', '"', '<', '>', '|' => true,
            else => false,
        };
        try out.append(alloc, if (invalid) '_' else c);
    }

    while (out.items.len > 0 and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == ' ')) _ = out.pop();
    if (out.items.len > 240) out.shrinkRetainingCapacity(240);
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '.' or out.items[out.items.len - 1] == ' ')) _ = out.pop();

    return out.toOwnedSlice(alloc);
}

test "sanitizeFilename replaces invalid and trims" {
    const alloc = std.testing.allocator;
    const out = try sanitizeFilename(alloc, "a:b*?c. ");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a_b__c", out);
}

test "isVideoFile/isSubtitleFile basic" {
    try std.testing.expect(isVideoFile("x.MKV"));
    try std.testing.expect(isSubtitleFile("x.ass"));
    try std.testing.expect(isSubtitleFile("x.scjp.ass"));
    try std.testing.expect(!isSubtitleFile("x.mkv"));
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("HelloWorld", "world"));
    try std.testing.expect(!containsIgnoreCase("Hello", "World!"));
}
