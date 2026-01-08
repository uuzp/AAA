const std = @import("std");

/// log模块：负责生成日志文件。
///
/// Zig 0.15 的 File.writer 需要显式 buffer，这里沿用原项目里稳定的 writeAll 写法。
///
/// 约定：
/// - `enabled=false` 时仍会输出到 stderr（std.debug.print），但不会写文件
/// - `init` 会在 cache/logs 下创建一次运行日志文件
pub var file: ?std.fs.File = null;
pub var enabled: bool = false;

/// 初始化日志模块。
///
/// - enabled_=false：只输出控制台，不写文件
/// - enabled_=true：创建 `cache/logs/run_<timestamp>.log` 并写入头部
pub fn init(alloc: std.mem.Allocator, enabled_: bool) !void {
    enabled = enabled_;
    if (!enabled) return;

    const cwd = std.fs.cwd();
    _ = cwd.makePath("cache") catch {};
    _ = cwd.makePath("cache/logs") catch {};

    const path = try std.fmt.allocPrint(alloc, "cache/logs/run_{d}.log", .{std.time.timestamp()});
    defer alloc.free(path);

    file = try cwd.createFile(path, .{ .truncate = true });

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "=== AAA log start (ts={d}) ===\n", .{std.time.timestamp()}) catch "";
    _ = file.?.writeAll(header) catch {};
}

/// 关闭日志文件并重置状态。
pub fn deinit() void {
    if (file) |*f| f.close();
    file = null;
    enabled = false;
}

/// 写入一条日志到文件（内部使用）。
///
/// 说明：
/// - 前缀会加时间戳
/// - 尝试用栈缓冲格式化，失败时回退到堆分配（避免大消息截断）
fn writeToFile(comptime fmt: []const u8, args: anytype) void {
    if (file == null) return;
    const f = file.?;

    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}: ", .{std.time.timestamp()}) catch "";
    _ = f.writeAll(prefix) catch {};

    var stack_buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&stack_buf, fmt, args) catch {
        const heap_msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
        defer std.heap.page_allocator.free(heap_msg);
        _ = f.writeAll(heap_msg) catch {};
        if (heap_msg.len == 0 or heap_msg[heap_msg.len - 1] != '\n') _ = f.writeAll("\n") catch {};
        return;
    };

    _ = f.writeAll(msg) catch {};
    if (msg.len == 0 or msg[msg.len - 1] != '\n') _ = f.writeAll("\n") catch {};
}

/// 打印日志：始终输出到控制台；在 enabled 时也写入日志文件。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    if (!enabled) return;
    writeToFile(fmt, args);
}

/// 打印错误级别日志（前缀 [ERROR]）。
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print("[ERROR] " ++ fmt, args);
}

/// 打印警告级别日志（前缀 [WARN]）。
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    print("[WARN] " ++ fmt, args);
}

/// 打印信息级别日志（前缀 [INFO]）。
pub fn info(comptime fmt: []const u8, args: anytype) void {
    print("[INFO] " ++ fmt, args);
}
