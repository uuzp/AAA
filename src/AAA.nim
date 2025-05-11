import std/[strformat,strutils, tables, os,options, algorithm, sequtils]
import ./core/types # 导入新的类型定义文件
import ./core/utils_string # 导入字符串工具函数
import ./core/bangumi_api # 导入 Bangumi API 函数
import ./core/cache_manager # 导入缓存管理函数
import ./core/rule_matcher # 导入规则匹配函数
import ./core/file_operations # 导入文件操作函数

# 全局变量和常量定义
var
  base_path_str: string    # 基础路径字符串，用于存放待处理的番剧文件夹
  anime_path_str: string   # 番剧目标路径字符串
  useCache: bool = true    # 是否使用缓存，默认为 true

const
  cacheFile = "cache/cache.csv"       # CSV 缓存文件名，存储基础配置和番剧名到ID的映射
  jsonCacheFile = "cache/cache.json"  # JSON 缓存文件名，存储番剧的详细剧集信息
  defaultBasePath = "."               # 默认的基础路径
  defaultAnimePath = "./anime"        # 默认的番剧目标路径
  # defaultUseCacheCsvVal = "0"       # CSV 缓存中代表 useCache 的值 (历史遗留，当前主要通过命令行控制) (已注释，因为未使用)

  videoExts: seq[string] = @[".mkv", ".mp4", ".avi", ".mov", ".flv", ".rmvb", ".wmv", ".ts", ".webm"] # 常见视频文件后缀
  subtitleExts: seq[string] = @[".ass", ".ssa", ".srt", ".sub", ".vtt"] # 常见字幕文件后缀

# --- 函数定义 ---

proc parseCmdLineArgs(): (Option[string], Option[string], bool) =
  ## 解析命令行参数。
  ## 返回: (基础路径选项, 番剧路径选项, 是否包含 --nocache 标志)
  var optBasePath: Option[string] = none[string]()
  var optAnimePath: Option[string] = none[string]()
  var hasNocache = false

  for param in commandLineParams():
    if param == "--nocache":
      hasNocache = true
    elif param.startsWith("-a="): # anime_path
      optAnimePath = some(param[3 .. ^1])
    elif param.startsWith("-b="): # base_path
      optBasePath = some(param[3 .. ^1])
  return (optBasePath, optAnimePath, hasNocache)

proc initializeConfig() =
  ## 初始化程序配置 (base_path_str, anime_path_str, useCache)。
  ## 路径配置仅由默认值和命令行参数决定。
  ## useCache 由命令行参数决定。
  let (cmdBasePathOpt, cmdAnimePathOpt, cmdHasNocache) = parseCmdLineArgs()

  useCache = not cmdHasNocache # --nocache 标志会禁用缓存

  base_path_str = if cmdBasePathOpt.isSome: cmdBasePathOpt.get() else: defaultBasePath
  anime_path_str = if cmdAnimePathOpt.isSome: cmdAnimePathOpt.get() else: defaultAnimePath

  # 确保 cache 目录存在，因为后续操作会读写缓存文件
  # 这个操作可以放在这里，或者在首次尝试写入缓存文件时进行
  if useCache: # 只有使用缓存时才需要确保目录存在
    try:
      createDir(parentDir(cacheFile)) # cacheFile 和 jsonCacheFile 通常在同一目录下
    except OSError as e:
      stderr.writeLine fmt"警告: 创建缓存目录 '{parentDir(cacheFile)}' 失败: {e.msg}. 缓存功能可能受影响。"

proc readDir(path: string): seq[string] =
  ## 读取指定路径下的所有文件夹名称。
  var dirs = newSeq[string]()
  try:
    for item in walkDir(path):
      if item.kind == pcDir:
        dirs.add(item.path.extractFilename())
  except OSError as e:
    stderr.writeLine fmt"错误: 读取目录 '{path}' 失败: {e.msg}"
  return dirs

proc processSampleData(
    sampleFolderName: string,
    rules: RuleSet,
    csvCache: var Table[string, CsvCacheEntry],
    jsonCache: var Table[string, CachedSeasonInfo]
  ) =
  ## 处理单个番剧样本目录。
  echo fmt"处理番剧文件夹: '{sampleFolderName}'"
  var seasonToProcessOpt: Option[Season] = none(Season)
  var forceApiFetchForEpisodes = false

  if useCache and csvCache.hasKey(sampleFolderName):
    let entry = csvCache[sampleFolderName]
    seasonToProcessOpt = some(Season(id: entry.bangumiSeasonId, name: entry.bangumiSeasonNameCache))
    # echo fmt"信息: 从 cache.csv 找到 '{sampleFolderName}' -> ID: {entry.bangumiSeasonId}, 名称: {entry.bangumiSeasonNameCache}"
    if not jsonCache.hasKey($entry.bangumiSeasonId):
      # echo fmt"信息: cache.json 中未找到番剧 ID '{entry.bangumiSeasonId}' 的详细信息，将尝试从API获取。"
      forceApiFetchForEpisodes = true
  else:
    # echo fmt"信息: cache.csv 中未找到 '{sampleFolderName}'，尝试规则匹配和API获取。"
    let matchedName = findMatchingRule(sampleFolderName, rules)
    if matchedName.len > 0:
      let seasonOptFromApi = getSeason(matchedName)
      if seasonOptFromApi.isSome:
        seasonToProcessOpt = seasonOptFromApi
        let s = seasonToProcessOpt.get()
        if useCache:
          appendToCacheCsv(sampleFolderName, s, cacheFile)
          csvCache[sampleFolderName] = CsvCacheEntry(
            originalFolderName: sampleFolderName,
            bangumiSeasonNameCache: s.name,
            bangumiSeasonId: s.id
          )
          # echo fmt"信息: '{sampleFolderName}' 匹配到 '{s.name}' (ID: {s.id})，已更新到 cache.csv。"
        forceApiFetchForEpisodes = true
      else:
        stderr.writeLine fmt"错误: 为 '{sampleFolderName}' (匹配为 '{matchedName}') 获取番剧信息失败。"
        return
    else:
      stderr.writeLine fmt"提示: '{sampleFolderName}' 未匹配到任何规则。"
      return

  if seasonToProcessOpt.isNone:
    stderr.writeLine fmt"严重错误: 未能确定 '{sampleFolderName}' 的番剧信息。"
    return
  
  let currentSeason = seasonToProcessOpt.get()
  let currentSeasonIdStr = $currentSeason.id
  var bangumiEpisodeList: EpisodeList

  if useCache and not forceApiFetchForEpisodes and jsonCache.hasKey(currentSeasonIdStr):
    let cachedSeasonDetails = jsonCache[currentSeasonIdStr]
    if cachedSeasonDetails.episodes.len > 0:
      var episodesData = newSeq[Episode]()
      for _, epInfo in cachedSeasonDetails.episodes.pairs:
        episodesData.add(Episode(sort: epInfo.bangumiSort, name: epInfo.bangumiName))
      episodesData.sort(proc(a,b: Episode): int = cmp(a.sort, b.sort))
      bangumiEpisodeList = EpisodeList(total: cachedSeasonDetails.totalBangumiEpisodes, data: episodesData)
      # echo fmt"信息: 使用 cache.json 中番剧 ID '{currentSeasonIdStr}' 的剧集列表。"
    else:
      forceApiFetchForEpisodes = true
      # echo fmt"信息: cache.json 中番剧 ID '{currentSeasonIdStr}' 条目无剧集数据，将从API获取。"
  
  if forceApiFetchForEpisodes or not jsonCache.hasKey(currentSeasonIdStr) or jsonCache[currentSeasonIdStr].episodes.len == 0 : # 确保在需要时获取
    # echo fmt"信息: 从 API 获取番剧 ID '{currentSeasonIdStr}' ({currentSeason.name}) 的剧集列表。"
    let episodesOptFromApi = getEpisodes(currentSeason.id)
    if episodesOptFromApi.isNone:
      stderr.writeLine fmt"错误: 无法获取番剧 ID '{currentSeason.id}' ({currentSeason.name}) 的剧集列表。"
      return
    bangumiEpisodeList = episodesOptFromApi.get()
  
  let localFilesPath = base_path_str / sampleFolderName
  # echo fmt"信息: 准备扫描本地文件夹: {localFilesPath}"
  var matchedLocalFiles = newSeq[LocalFileInfo]()

  if dirExists(localFilesPath):
    var count = 0
    for item in walkDir(localFilesPath):
      if item.kind == pcFile:
        var (originalDir, originalName, originalExt) = splitFile(item.path)
        var currentName = originalName
        var currentExt = originalExt

        # 检查原始文件名是否直接匹配已知的多部分字幕后缀 (例如 .sc.ass)
        # splitFile("file.sc.ass") -> name="file", ext=".sc.ass" (Nim 0.20+)
        # splitFile("file.sc.ass") -> name="file.sc", ext=".ass" (Nim < 0.20 or depending on OS behavior)
        # 我们需要处理的是 name="file.sc", ext=".ass" 的情况，并将其转换为 name="file", ext=".sc.ass"

        if subtitleExts.anyIt(eqIgnoresCase(it, currentExt)): # 如果当前 ext 是一个基本的字幕后缀 (e.g., .ass, .srt)
            let nameParts = currentName.split('.')
            if nameParts.len > 1:
                # 检查 name 的最后一部分是否像语言代码
                # (e.g., "sc", "tc", "en", "scjp", "chs", "cht", "jpn")
                let potentialLangPart = nameParts[^1]
                
                # 启发式判断语言代码: 2-5个字符，主要是字母，可能包含数字或连字符
                var isLangCode = false
                if potentialLangPart.len >= 2 and potentialLangPart.len <= 5:
                    isLangCode = potentialLangPart.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')
                elif potentialLangPart.len > 5 and potentialLangPart.contains('-'): # 允许更长的带连字符的，如 zh-Hans
                    isLangCode = potentialLangPart.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')


                if isLangCode:
                    # 确认这个 langPart 不是一个数字（避免误判文件名中的数字为语言代码）
                    var allDigits = true
                    for c in potentialLangPart:
                        if not c.isDigit:
                            allDigits = false
                            break
                    if not allDigits:
                        currentExt = "." & potentialLangPart & currentExt  # Prepend lang part to ext
                        currentName = nameParts[0 .. ^2].join(".")  # Remove lang part from name
                        if currentName.endsWith("."): # 如果join后末尾是点（例如只有一个部分时）
                            currentName = currentName[0 .. ^2]
                        if currentName.len == 0 and nameParts.len == 2: # 如果原名是 "lang.ext"
                           currentName = nameParts[0]


        # 如果文件名是 "video.mkv" currentName="video", currentExt=".mkv"
        # 如果文件名是 "sub.sc.ass"
        #   - splitFile -> name="sub.sc", ext=".ass" -> 上述逻辑后: currentName="sub", currentExt=".sc.ass"
        #   - splitFile -> name="sub", ext=".sc.ass" (较新Nim) -> 上述逻辑不执行, currentName="sub", currentExt=".sc.ass" (正确)
        
        matchedLocalFiles.add(LocalFileInfo(
          nameOnly: currentName,
          ext: currentExt,
          fullPath: item.path
        ))
        count += 1
    # echo fmt"信息: 在 '{localFilesPath}' 中扫描到 {count} 个文件。"
  else:
    stderr.writeLine fmt"警告: 本地文件夹 '{localFilesPath}' 不存在或不是一个目录。"

  if useCache:
    updateAndSaveJsonCache(jsonCache, currentSeason, bangumiEpisodeList, matchedLocalFiles, videoExts, subtitleExts)
    # echo fmt"信息: 已为 '{sampleFolderName}' (番剧: {currentSeason.name}, ID: {currentSeason.id}) 更新内存中的JSON缓存。"
  
  # echo fmt"处理 '{sampleFolderName}' 完成。本地文件已扫描并尝试匹配。"

# --- 主逻辑执行 ---
initializeConfig()

echo "开始处理..."
let rules = loadRules("cache/fansub.rules")

var csvCacheGlobal = if useCache: readCsvCacheEntries(cacheFile) else: initTable[string, CsvCacheEntry]()
var jsonCacheGlobal = if useCache: loadJsonCache(jsonCacheFile) else: initTable[string, CachedSeasonInfo]()

let samples = readDir(base_path_str)

if samples.len == 0:
  let pathType = if base_path_str == defaultBasePath: "默认基础路径" else: "指定基础路径"
  stderr.writeLine fmt"提示: 在{pathType} '{base_path_str}' 下未找到任何番剧文件夹。请确保文件夹存在或通过 -b=<路径> 指定。"

for sample in samples:
  processSampleData(sample, rules, csvCacheGlobal, jsonCacheGlobal)

if useCache:
  saveJsonCache(jsonCacheFile, jsonCacheGlobal)
  echo fmt"JSON缓存已保存到 {jsonCacheFile}。"

  echo "\n开始执行硬链接和重命名操作..."
  let finalJsonCacheForRename = loadJsonCache(jsonCacheFile) # 确保使用最新的缓存

  if samples.len > 0:
    try:
      if not dirExists(anime_path_str):
        createDir(anime_path_str)
        echo fmt"创建番剧目标根目录: {anime_path_str}"
    except OSError as e:
      stderr.writeLine fmt"严重错误: 创建番剧目标根目录 '{anime_path_str}' 失败: {e.msg}. 硬链接和重命名操作可能失败。"

  for originalFolderNameInBase in samples:
    let sourceSeasonDir = base_path_str / originalFolderNameInBase
    let targetSeasonDirForLinkAndRename = anime_path_str / originalFolderNameInBase

    if dirExists(sourceSeasonDir):
      echo fmt"\n处理原始文件夹: '{originalFolderNameInBase}' 进行硬链接和重命名"
      
      # echo fmt"  步骤 1: 硬链接内容从 '{sourceSeasonDir}' 到 '{targetSeasonDirForLinkAndRename}'" # 减少输出
      createDirectoryHardLinkRecursive(sourceSeasonDir, targetSeasonDirForLinkAndRename)

      if csvCacheGlobal.hasKey(originalFolderNameInBase):
        let csvEntry = csvCacheGlobal[originalFolderNameInBase]
        let seasonIdStr = $csvEntry.bangumiSeasonId
        if finalJsonCacheForRename.hasKey(seasonIdStr):
          let seasonInfo = finalJsonCacheForRename[seasonIdStr]
          # echo fmt"  步骤 2: 重命名 '{targetSeasonDirForLinkAndRename}' 中的文件 (基于番剧: {seasonInfo.bangumiSeasonName})" # 减少输出
          renameFilesBasedOnCache(targetSeasonDirForLinkAndRename, seasonInfo, originalFolderNameInBase)
        else:
          stderr.writeLine fmt"警告: 在JSON缓存中未找到番剧ID '{seasonIdStr}' (来自文件夹 '{originalFolderNameInBase}') 的详细信息，无法重命名。"
      else:
        stderr.writeLine fmt"警告: 在CSV缓存中未找到文件夹 '{originalFolderNameInBase}' 的条目，无法重命名。"
    else:
      stderr.writeLine fmt"警告: 源文件夹 '{sourceSeasonDir}' 不存在或不是目录，跳过硬链接和重命名。"
  echo "\n硬链接和重命名操作完成。"
else:
  echo "所有处理完成（缓存未启用）。硬链接和重命名操作已跳过。"

echo "程序执行完毕。"
