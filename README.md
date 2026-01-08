# AAA（Anime Auto Arrange）

[English version](README.en.md)

**AAA** 是一个用 Zig 编写的命令行工具，用来自动整理动漫/番剧文件，让你的媒体库更整洁、命名更规范。

主要功能：

- 从文件名或文件夹名解析番剧名称、季与集数
- 调用 Bangumi（bgm.tv）API 获取条目与剧集信息，自动补全元数据
- 匹配本地视频与字幕文件，生成统一的标准命名
- 在目标目录以**硬链接**生成整理后的目录结构（不复制文件、节省空间）
- 可选：在识别不确定时调用 OpenRouter（LLM）做辅助提示和校验

> 该项目已迁移到 Zig（推荐 Zig 0.15.2）。另有旧的 Nim 实现保存在 `nim` 分支。

---

## 要求

- Zig 0.15.2（或兼容版本）
- Windows / macOS / Linux（已在多平台测试）
- 网络访问：需要访问 `https://api.bgm.tv`
-（可选）OpenRouter API Key（用于启用 LLM 辅助）

---

## 获取与构建

- 下载：从 Releases 页面获取对应平台的二进制文件，放到可执行路径或当前目录。
- 源码构建：

```powershell
zig build -Doptimize=ReleaseSmall
```

构建产物（Windows 示例）：`zig-out/bin/aaa.exe`

---

## 使用方法

支持两种运行方式：

1. 通过 Zig 直接运行：

```powershell
zig build run -- "D:\输入\番剧" "D:\输出\整理结果" 1 debug
```

2. 直接运行可执行文件：

```powershell
./zig-out/bin/aaa.exe "D:\输入\番剧" "D:\输出\整理结果" 1 debug
```

### 参数说明（位置参数）

1. `输入目录`：要整理的源目录（默认 `.`，会递归扫描子目录）
2. `输出目录`：整理结果的目标目录（默认 `./anime`）
3. `使用中文名(0/1)`：`1` 优先使用 Bangumi 的中文名，`0` 使用原名（默认 `1`）

### 额外开关

- `debug`（或 `--debug` / `-d`）：启用时会把运行日志写入 `cache/logs/run_<timestamp>.log`

### 默认值总结

- 输入目录：`.`
- 输出目录：`./anime`
- 使用中文名：`1`
- debug：关闭

---

## 示例

Windows：

```powershell
# 普通运行
.\aaa.exe "D:\input\anime" "D:\output\arranged" 1

# 启用 debug，会写日志
.\aaa.exe "D:\input\anime" "D:\output\arranged" 1 debug

# 省略第三个参数（使用默认中文名），但启用 debug
.\aaa.exe "D:\input\anime" "D:\output\arranged" debug
```

Linux/macOS：

```bash
./aaa "./input/anime" "./output/arranged" 1
```

示例输入目录结构：

```
input_dir/
    AnimeA/
        S01E01.mkv
        S01E02.mkv
    AnimeB.S02/
        AnimeB - 01.mkv
        AnimeB - 02.mkv
    SomeShow.S01.E01.mkv
```

> 注意：程序使用**硬链接**生成输出文件，所以输入与输出需要位于同一文件系统。

---

## LLM（可选）

当自动解析结果不确定或需要人工风格判断时，程序可以调用 OpenRouter 提供的 Chat Completions 接口做辅助。启用方法：在运行前设置环境变量 `OPENROUTER_API_KEY`。

```powershell
$env:OPENROUTER_API_KEY = "你的 key"
```

> LLM 调用是可选且可能产生外部请求费用，默认不启用。

---

