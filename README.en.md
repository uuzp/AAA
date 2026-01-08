# AAA (Anime Auto Arrange)

**AAA** is a small command-line tool written in Zig that helps you organize anime/series files into a clean, consistent directory structure with standardized filenames.

Key features:

- Parse series name, season and episode information from filenames and folder names
- Query Bangumi (bgm.tv) to fetch metadata and episode lists
- Match local video and subtitle files and generate standardized filenames
- Create the organized layout in the destination directory using **hard links** (no duplicate file data)
- Optional: use OpenRouter (LLM) for assisted parsing when the automatic rules are uncertain

---

## Requirements

- Zig 0.15.2 (recommended) or compatible
- Windows / macOS / Linux
- Network access to `https://api.bgm.tv`
- (Optional) OpenRouter API key for LLM assistance

---

## Download & Build

- Download pre-built binaries from the Releases page for your platform.
- Build from source:

```powershell
zig build -Doptimize=ReleaseSmall
```

Build output (Windows example): `zig-out/bin/aaa.exe`

---

## Usage

Two common ways to run AAA:

1. Run via Zig during development:

```powershell
zig build run -- "D:\input\anime" "D:\output\arranged" 1 debug
```

2. Run the compiled binary directly:

```powershell
./zig-out/bin/aaa.exe "D:\input\anime" "D:\output\arranged" 1 debug
```

### Positional arguments

1. `input_dir` — directory to scan (default `.`)
2. `output_dir` — destination for organized files (default `./anime`)
3. `use_chinese_name` — `1` to prefer Bangumi Chinese names, `0` to use original names (default `1`)

### Extra flags

- `debug` (or `--debug` / `-d`) — when present, writes a log file to `cache/logs/run_<timestamp>.log`

### Defaults summary

- input_dir: `.`
- output_dir: `./anime`
- use_chinese_name: `1`
- debug: off

---

## Examples

Windows:

```powershell
# Normal run
.\aaa.exe "D:\input\anime" "D:\output\arranged" 1

# With debug logging
.\aaa.exe "D:\input\anime" "D:\output\arranged" 1 debug

# Omit 3rd parameter (defaults to Chinese name), but enable debug
.\aaa.exe "D:\input\anime" "D:\output\arranged" debug
```

Linux/macOS:

```bash
./aaa "./input/anime" "./output/arranged" 1
```

Sample input layout:

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

> Note: The tool uses **hard links** for output files, so the input and output directories should be on the same filesystem.

---

## LLM (optional)

If automatic parsing is uncertain, AAA can call OpenRouter's Chat Completions API to help extract or validate series names. To enable this, set the `OPENROUTER_API_KEY` environment variable before running.

```powershell
$env:OPENROUTER_API_KEY = "your_key"
```

LLM calls are optional and may incur external API usage costs. They are disabled by default.

---
