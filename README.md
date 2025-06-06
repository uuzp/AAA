# AAA (Auto Anime Archive) 番剧整理工具

AAA(Auto Anime Archive)是一个用于自动整理动画/番剧文件的工具，可以从文件夹名提取番剧名称，使用Bangumi API获取番剧信息，匹配本地视频和字幕文件，并按照标准格式重命名和整理你的番剧文件。

## 功能特点

- 自动从文件夹名提取番剧名称并匹配到Bangumi数据库
- 智能匹配视频文件和字幕文件到正确的剧集
- 自动重命名字幕文件以匹配视频文件的命名模式
- 创建硬链接到目标目录，保持原文件不变
- 支持CSV和JSON格式的缓存，减少API请求
- 智能处理多种字幕格式和语言代码

## 安装

1. 安装Nim编程语言（https://nim-lang.org/install.html）
2. 克隆本仓库到本地
3. 编译项目：
   ```
   nim c -d:release src/AAA.nim
   ```

## 使用方法

基本用法：
```
./AAA [基础路径] [番剧目标路径] [名称类型]
```

参数说明：
- `基础路径`: 待处理的番剧文件夹所在的目录，默认为当前目录 `.`
- `番剧目标路径`: 处理后的番剧将存放的目录，默认为 `./anime`
- `名称类型`: 使用中文名(1)或原名(0)，默认为中文名(1)

示例：
```
./AAA "D:\动画下载" "D:\整理后的动画" 1
```

## 工作原理

1. 程序会扫描基础路径下的所有文件夹
2. 对每个文件夹，尝试提取番剧名称
3. 使用提取的名称查询Bangumi API获取番剧信息和剧集列表
4. 分析文件夹中的视频和字幕文件，将它们匹配到对应的剧集
5. 在目标路径创建硬链接，保持原文件不变
6. 重命名文件，使其符合标准格式

## 缓存机制

程序使用两种缓存文件减少API请求：
- `cache/cache.csv`: 存储基础配置和番剧名到ID的映射
- `cache/cache.json`: 存储番剧的详细剧集信息

## 项目结构

- `src/AAA.nim`: 主程序入口
- `src/bangumi_api.nim`: Bangumi API相关功能
- `src/utils.nim`: 本地文件信息、文件/目录操作、缓存读写和工具函数

## 依赖项

本工具仅依赖Nim标准库中的以下模块：
- strformat, strutils, tables, os, options, algorithm, sequtils, streams, sets, math, times

## 输出结果

程序处理完成后会显示处理结果，格式为：
```
原文件夹名 => 新文件夹名[状态]
```

状态标记说明：
- 无标记：成功处理
- 【X】：处理失败
- 【X-校验失败-文件过多】：本地文件数量超过API返回的剧集数量
- 【X-目录丢失】：处理过程中目录丢失
- 【X-处理失败】：其他处理失败情况

## 功能完成列表

- [x] 解析动漫下载目录
- [x] 获取API数据
- [x] 硬链接到媒体库
- [x] 根据数据重命名
- [x] 视频和字幕匹配
- [x] ~~更多字幕组规则~~ 通用匹配规则
- [ ] 更多特例匹配
- [ ] 代码优化
