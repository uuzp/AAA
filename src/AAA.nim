import std/[strformat,strutils,re, httpclient, tables, os,options,sequtils, streams,json, algorithm, sets]

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
  defaultUseCacheCsvVal = "0"       # CSV 缓存中代表 useCache 的值 (历史遗留，当前主要通过命令行控制)

  videoExts: seq[string] = @[".mkv", ".mp4", ".avi", ".mov", ".flv", ".rmvb", ".wmv", ".ts", ".webm"] # 常见视频文件后缀
  subtitleExts: seq[string] = @[".ass", ".ssa", ".srt", ".sub", ".vtt"] # 常见字幕文件后缀

# --- 类型定义 ---
type
  Config = object                   ## 程序配置对象 (主要用于命令行参数)
    basePath: string                # 基础路径
    animePath: string               # 番剧目标路径

  Season = object                   ## Bangumi 番剧季度信息 (API获取后，程序内部使用)
    id: int                         # 番剧在 Bangumi 上的 ID
    name: string                    # 番剧名称 (优先使用中文名)

  Episode = object                  ## Bangumi 单集信息 (API获取后，程序内部使用)
    sort: float                     # 剧集排序号
    name: string                    # 剧集名称 (优先使用中文名)

  EpisodeList = object              ## Bangumi 剧集列表 (API获取后，程序内部使用)
    total: int                      # 总集数
    data: seq[Episode]              # 剧集数据序列

  # --- 用于解析 Bangumi API 原始 JSON 数据的类型 ---
  RawEpisode = object               ## API 返回的原始单集数据结构
    sort: float
    name: string                    # 原名
    name_cn: string                 # 中文名

  RawEpisodeList = object           ## API 返回的原始剧集列表数据结构
    total: int
    data: seq[RawEpisode]

  SeasonSearchResult = object       ## API 搜索番剧结果中的单项数据结构
    id: int
    name: string                    # 原名
    name_cn: string                 # 中文名

  SeasonResponse = object           ## API 搜索番剧的顶层响应数据结构
    results: int                    # 搜索结果数量
    list: seq[SeasonSearchResult]   # 搜索结果列表
  
  # --- 新增的缓存和本地文件相关类型 ---
  LocalFileInfo = object          ## 本地文件信息
    nameOnly: string              # 文件名 (不含后缀)
    ext: string                   # 文件后缀 (例如 ".mkv", ".ass", 带点)
    fullPath: string              # 文件的完整路径

  CachedEpisodeInfo = object      ## 存储在 cache.json 中的单集详细信息
    bangumiSort: float            # Bangumi API 返回的原始 sort 值
    bangumiName: string           # Bangumi API 返回的剧集名 (优先中文)
    localVideoFile: Option[LocalFileInfo]
    localSubtitleFile: Option[LocalFileInfo]

  CachedSeasonInfo = object       ## 存储在 cache.json 中的番剧季度详细信息
    bangumiSeasonId: int          # Bangumi 番剧 ID
    bangumiSeasonName: string     # Bangumi 番剧名
    totalBangumiEpisodes: int     # Bangumi API 返回的总集数
    episodes: Table[string, CachedEpisodeInfo] # 键: formatEpisodeNumber 的结果 (如 "E01")

  CsvCacheEntry = object          ## cache.csv 中的条目 (原始文件夹名 -> Bangumi ID 映射)
    originalFolderName: string    # 扫描到的原始的文件夹名称
    bangumiSeasonNameCache: string # 匹配到的 Bangumi 番剧名 (用于快速显示)
    bangumiSeasonId: int          # 匹配到的 Bangumi 番剧 ID

  RuleConfig = object               ## 匹配规则配置
    groups: seq[string]             # 用于初步筛选的字幕组或关键词列表
    pattern: string                 # 用于提取番剧名称的正则表达式或普通字符串

  RuleSet = seq[RuleConfig]         ## 规则配置集合

# --- 自然排序辅助函数 ---
proc splitAlphaNumeric(s: string): seq[string] =
  ## 将字符串分割为交替的非数字和数字序列。
  result = @[]
  if s.len == 0: return
  var currentChunk = ""
  # 确保即使字符串为空，currentIsDigit 也有初始值，尽管在这种情况下循环不会执行
  var currentIsDigit = if s.len > 0: s[0].isDigit() else: false

  for c in s:
    if c.isDigit() == currentIsDigit:
      currentChunk.add(c)
    else:
      if currentChunk.len > 0: result.add(currentChunk) # Add previous chunk
      currentChunk = $c # Start new chunk
      currentIsDigit = c.isDigit()
  
  if currentChunk.len > 0: # Add the very last chunk
    result.add(currentChunk)

proc naturalCompare(a: LocalFileInfo, b: LocalFileInfo): int =
  ## 自然比较两个 LocalFileInfo 对象的文件名 (nameOnly)。
  let partsA = splitAlphaNumeric(a.nameOnly.toLower()) # 忽略大小写比较
  let partsB = splitAlphaNumeric(b.nameOnly.toLower())

  for i in 0 .. min(partsA.len - 1, partsB.len - 1):
    let partA = partsA[i]
    let partB = partsB[i]

    # 检查块是否可能为数字 (非空且首字符为数字)
    let partAIsPotentiallyNumeric = partA.len > 0 and partA[0].isDigit()
    let partBIsPotentiallyNumeric = partB.len > 0 and partB[0].isDigit()

    if partAIsPotentiallyNumeric and partBIsPotentiallyNumeric:
      var numAOpt: Option[int]
      var numBOpt: Option[int]
      try:
        if partA.all(isDigit): numAOpt = some(parseInt(partA))
      except ValueError: discard # 解析失败则numAOpt保持none
      try:
        if partB.all(isDigit): numBOpt = some(parseInt(partB))
      except ValueError: discard # 解析失败则numBOpt保持none

      if numAOpt.isSome and numBOpt.isSome: # 两者都是有效数字
        let numA = numAOpt.get()
        let numB = numBOpt.get()
        if numA < numB: return -1
        if numA > numB: return 1
        # 数字相同，继续比较下一个部分
      elif numAOpt.isSome: # 只有 A 是数字
        return -1 # 数字通常排在文本前
      elif numBOpt.isSome: # 只有 B 是数字
        return 1  # 数字通常排在文本前
      else: # 两者都不是有效数字（可能是 "0abc" 或解析失败），按文本比较
        if partA < partB: return -1
        if partA > partB: return 1
    else: # 非数字部分的文本比较
      if partA < partB: return -1
      if partA > partB: return 1
  
  # 如果一个是另一个的前缀 (例如 "file" vs "file1")
  if partsA.len < partsB.len: return -1
  if partsA.len > partsB.len: return 1
  
  # 如果文件名部分完全相同，可以比较后缀名作为次要排序依据
  let extComp = cmp(a.ext.toLower(), b.ext.toLower())
  if extComp != 0: return extComp

  return 0

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
      echo fmt"警告: 创建缓存目录 '{parentDir(cacheFile)}' 失败: {e.msg}. 缓存功能可能受影响。"

proc readDir(path: string): seq[string] =
  ## 读取指定路径下的所有文件夹名称。
  var dirs = newSeq[string]()
  try:
    for item in walkDir(path):
      if item.kind == pcDir:
        dirs.add(item.path.extractFilename())
  except OSError as e:
    echo fmt"错误: 读取目录 '{path}' 失败: {e.msg}"
  return dirs

# --- Bangumi API 相关函数 ---
func setURL*(k: string): string =
  ## 构建 Bangumi 搜索番剧的 API URL。
  &"http://api.bgm.tv/search/subject/{k}?type=2&responseGroup=small"

func setURL*(id: int): string =
  ## 构建 Bangumi 获取番剧剧集的 API URL。
  &"http://api.bgm.tv/v0/episodes?subject_id={id}"

func url*(id: int): string =
  ## 构建番剧在 Bangumi 网站上的 URL。
  "http://bgm.tv/subject/" & $id

proc getApiData[T](apiUrl: string): Option[T] =
  ## 从指定的 API URL 获取数据并解析为类型 T。
  ## 使用自定义 User-Agent。
  var client = newHttpClient(headers = newHttpHeaders({"User-Agent": "uuzp/AAA/0.1.0(https://github.com/uuzp/AAA )"}))
  try:
    let response = client.getContent(apiUrl)
    let jsonData = parseJson(response)
    result = some(jsonData.to(T))
  except CatchableError as e:
    echo &"错误: 从 URL {apiUrl} 获取或解析数据失败: {e.msg}"
    result = none(T)
  finally:
    client.close()

proc getSeason(searchTerm: string): Option[Season] =
  ## 根据搜索词从 Bangumi API 获取番剧信息。
  ## 返回番剧的 ID 和名称 (优先中文名)。
  let apiUrl = setURL(searchTerm)
  let apiResponseOpt = getApiData[SeasonResponse](apiUrl)

  if apiResponseOpt.isSome:
    let apiResponse = apiResponseOpt.get()
    if apiResponse.list.len > 0:
      let firstResult = apiResponse.list[0]
      let seasonName = if firstResult.name_cn.len > 0: firstResult.name_cn else: firstResult.name
      return some(Season(id: firstResult.id, name: seasonName))
    # else: # 无需输出，调用者处理 Option.isNone
    #   echo &"未在 API 响应中找到番剧: {searchTerm}"
  return none(Season)

proc getEpisodes(id: int): Option[EpisodeList] =
  ## 根据番剧 ID 从 Bangumi API 获取剧集列表。
  ## 返回总集数和剧集信息 (名称优先中文名)。
  let apiUrl = setURL(id)
  let rawListOpt = getApiData[RawEpisodeList](apiUrl)

  if rawListOpt.isSome:
    let rawList = rawListOpt.get()
    var episodes = newSeq[Episode]()
    for rawEp in rawList.data:
      let episodeName = if rawEp.name_cn.len > 0: rawEp.name_cn else: rawEp.name
      episodes.add(Episode(sort: rawEp.sort, name: episodeName))
    return some(EpisodeList(total: rawList.total, data: episodes))
  return none(EpisodeList)

# --- 缓存处理函数 ---

proc extractEpisodeNumberFromName(fileName: string): Option[int] =
  ## 尝试从文件名中提取剧集号。
  ## 注意: 这个实现比较基础，可能需要根据实际文件名格式进行大量调整和增强。
  ## 它会尝试匹配多种模式，并返回第一个成功匹配的数字。
  let patterns = [
    re"S\d+[._-]?E(\d{1,3})\b",       # 匹配 SxxExx, Sxx.Exx, Sxx_Exx, Sxx-Exx 格式
    re"\b(?:EP|E|第|\[)\s*(\d{1,3})\b", # EP01, E01, 第01, [01] (单词边界)
    re"\[(\d{1,3})\]",                # [01] (更宽松)
    re"\s-\s(\d{1,3})\b",             # " - 01"
    re"\b(\d{1,3})\s*\[",             # "01 ["
    re"\b(\d{1,3})\b"                 # 独立的数字，作为最后的尝试 (可能误匹配)
  ]

  for pattern in patterns:
    var match: array[1, string]
    if fileName.find(pattern, match) != -1:
      try:
        let num = parseInt(match[0])
        echo fmt"调试: extractEpisodeNumberFromName: 从 '{fileName}' 提取到剧集号: {num}"
        return some(num)
      except ValueError:
        # echo fmt"调试: extractEpisodeNumberFromName: 尝试从 '{fileName}' 用模式 '{pattern}' 解析数字 '{match[0]}' 失败" # 这个日志可能过于频繁
        continue # 解析失败，尝试下一个模式
  echo fmt"调试: extractEpisodeNumberFromName: 未能从 '{fileName}' 提取到剧集号"
  return none[int]()

proc formatEpisodeNumber(currentSort: float, totalEpisodes: int): string =
  ## 根据总集数格式化剧集编号，例如 E1, E01, E001。
  let num = int(currentSort)
  let numStr = $num
  var prefix = "E"
  var requiredDigits = 1
  if totalEpisodes >= 10000: requiredDigits = 5
  elif totalEpisodes >= 1000: requiredDigits = 4
  elif totalEpisodes >= 100: requiredDigits = 3
  elif totalEpisodes >= 10: requiredDigits = 2
  
  let zerosToPad = requiredDigits - numStr.len
  if zerosToPad > 0:
    for _ in 1 .. zerosToPad: prefix.add('0')
  return prefix & numStr
proc appendToCacheCsv(originalInputName: string, season: Season) =
  ## 将番剧的原始文件夹名、Bangumi番剧名和Bangumi番剧ID追加到 cache.csv。
  ## 格式: originalFolderName,bangumiSeasonName,bangumiSeasonId
  let line = fmt"{originalInputName},{season.name},{season.id}"
  try:
    # createDir(parentDir(cacheFile)) # 目录创建已移至 initializeConfig 或首次写入时
    let f = open(cacheFile, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError as e:
    echo &"错误: 追加到 {cacheFile} 失败: {e.msg}"

proc readCsvCacheEntries(filePath: string): Table[string, CsvCacheEntry] =
  ## 从 cache.csv 加载原始文件夹名到 Bangumi Season ID 的映射。
  ## Key: originalFolderName, Value: CsvCacheEntry
  result = initTable[string, CsvCacheEntry]()
  if not fileExists(filePath):
    return

  try:
    for line in lines(filePath):
      let strippedLine = line.strip()
      if strippedLine.len == 0 or strippedLine.startsWith("#"): # 忽略空行或注释行
        continue

      let parts = strippedLine.split(',')
      if parts.len == 3: # originalFolderName,bangumiSeasonName,bangumiSeasonId
        try:
          let entry = CsvCacheEntry(
            originalFolderName: parts[0].strip(),
            bangumiSeasonNameCache: parts[1].strip(),
            bangumiSeasonId: parseInt(parts[2].strip())
          )
          result[entry.originalFolderName] = entry
        except ValueError:
          echo fmt"警告: 解析 cache.csv 行时ID无效: {strippedLine}"
      else:
        # 此处不再处理旧的 basePath,animePath 格式，initializeConfig 已调整
        echo fmt"警告: cache.csv 行格式无法识别 (期望3个字段): {strippedLine}"
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}"

proc loadJsonCache(filePath: string): Table[string, CachedSeasonInfo] =
  ## 从 cache.json 加载番剧剧集缓存数据。
  ## Key: bangumiSeasonId (string), Value: CachedSeasonInfo
  result = initTable[string, CachedSeasonInfo]()
  if not fileExists(filePath):
    return
  try:
    let content = readFile(filePath)
    if content.len == 0:
      return
    let jsonData = parseJson(content)
    if jsonData.kind == JObject:
      for seasonIdKey, seasonNode in jsonData.pairs:
        try:
          result[seasonIdKey] = seasonNode.to(CachedSeasonInfo)
        except JsonKindError, ValueError: # to() 可能会抛出这些错误
          echo fmt"警告: 解析 cache.json 中番剧ID '{seasonIdKey}' 的数据失败。"
    else:
      echo &"警告: {filePath} 的根不是一个有效的 JSON 对象。"
  except JsonParsingError as e:
    echo &"错误: 解析 {filePath} (JSON) 失败: {e.msg}"
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}"

proc saveJsonCache(filePath: string, cacheData: Table[string, CachedSeasonInfo]) =
  ## 将番剧剧集缓存数据保存到 cache.json，并确保番剧ID和剧集按顺序排列。
  var rootNode = newJObject()

  # 1. 对番剧ID进行排序
  var sortedSeasonIdInts = newSeq[int]()
  for seasonIdKey in cacheData.keys:
    try:
      sortedSeasonIdInts.add(parseInt(seasonIdKey))
    except ValueError:
      echo fmt"警告: saveJsonCache - 无法将番剧ID '{seasonIdKey}' 解析为整数，跳过此条目。"
      continue
  
  sortedSeasonIdInts.sort(cmp[int]) # 按数字升序排序

  for seasonIdInt in sortedSeasonIdInts:
    let seasonIdKey = $seasonIdInt # 转回字符串作为JSON的key
    if not cacheData.hasKey(seasonIdKey):
        echo fmt"警告: saveJsonCache - 排序后的ID '{seasonIdKey}' 在原始缓存数据中未找到。"
        continue
    
    let seasonInfo = cacheData[seasonIdKey]
    var seasonInfoNode = newJObject()

    # 添加 seasonInfo 的基本字段
    seasonInfoNode["bangumiSeasonId"] = %*(seasonInfo.bangumiSeasonId)
    seasonInfoNode["bangumiSeasonName"] = %*(seasonInfo.bangumiSeasonName)
    seasonInfoNode["totalBangumiEpisodes"] = %*(seasonInfo.totalBangumiEpisodes)

    # 2. 对该番剧的剧集进行排序
    var sortedEpisodeKeys = newSeq[string]()
    if seasonInfo.episodes.len > 0: # 确保 episodes 表有内容
      for epKey in seasonInfo.episodes.keys:
        sortedEpisodeKeys.add(epKey)
      
      sortedEpisodeKeys.sort(cmp[string]) # 按字母数字顺序排序 (如 "E01", "E02", "E10")

      var episodesNode = newJObject()
      for epKey in sortedEpisodeKeys:
        if seasonInfo.episodes.hasKey(epKey):
          episodesNode[epKey] = %*(seasonInfo.episodes[epKey])
        else:
          echo fmt"警告: saveJsonCache - 番剧ID '{seasonIdKey}', 排序后的剧集Key '{epKey}' 在剧集数据中未找到。"
      seasonInfoNode["episodes"] = episodesNode # 添加排序后的剧集对象
    else:
      seasonInfoNode["episodes"] = newJObject() # 如果没有剧集，则添加一个空的 episodes 对象
      echo fmt"调试: saveJsonCache - 番剧ID '{seasonIdKey}' 的 episodes 表为空，将写入空对象。"

    rootNode[seasonIdKey] = seasonInfoNode   # 将整个番剧信息添加到根节点

  try:
    # createDir(parentDir(filePath)) # 目录创建已移至 initializeConfig 或首次写入时
    writeFile(filePath, pretty(rootNode))
  except IOError as e:
    echo &"错误: 写入到 {filePath} 失败: {e.msg}"

proc updateAndSaveJsonCache(
    jsonCacheToUpdate: var Table[string, CachedSeasonInfo],
    season: Season,
    bangumiEpisodes: EpisodeList,
    originalMatchedLocalFiles: seq[LocalFileInfo]
  ) =
  ## 更新（或创建）并准备保存指定番剧的剧集信息到内存中的 jsonCacheToUpdate。
  ## 包含精确匹配和基于排序的后备匹配逻辑。
  
  echo fmt"调试: updateAndSaveJsonCache: 开始处理番剧 '{season.name}' (ID: {season.id})。接收到 {originalMatchedLocalFiles.len} 个本地文件。"
  if originalMatchedLocalFiles.len > 0 and originalMatchedLocalFiles.len <= 3: # 打印少量文件名用于调试
    for i in 0 .. min(originalMatchedLocalFiles.len - 1, 2):
      echo fmt"  本地文件示例 {i+1} (原始): {originalMatchedLocalFiles[i].nameOnly}{originalMatchedLocalFiles[i].ext}"
  elif originalMatchedLocalFiles.len > 3:
    echo fmt"  本地文件示例 1 (原始): {originalMatchedLocalFiles[0].nameOnly}{originalMatchedLocalFiles[0].ext}"
    echo "  ... (更多原始文件未显示)"

  let seasonIdStr = $season.id
  var episodesForJson = initTable[string, CachedEpisodeInfo]() # 最终存储到JSON的剧集信息
  
  # --- 阶段一：基于剧集号的精确匹配 ---
  var usedByPreciseMatch = initHashSet[LocalFileInfo]() # 跟踪已通过精确匹配使用的本地文件
  # 存储每个Bangumi剧集（按其原始sort值索引）的精确匹配结果
  var preciseMatchResults = initTable[float, tuple[video: Option[LocalFileInfo], sub: Option[LocalFileInfo]]]()

  for ep in bangumiEpisodes.data: # 遍历所有Bangumi剧集
    let bangumiEpNum = int(ep.sort) # 当前Bangumi剧集的集号
    var currentFoundVideo: Option[LocalFileInfo] = none[LocalFileInfo]() # 当前Bangumi剧集精确匹配到的视频
    var currentFoundSub: Option[LocalFileInfo] = none[LocalFileInfo]()   # 当前Bangumi剧集精确匹配到的字幕

    for localFile in originalMatchedLocalFiles: # 遍历所有本地文件，尝试为当前Bangumi剧集找到匹配
      let localEpNumOpt = extractEpisodeNumberFromName(localFile.nameOnly) # 从本地文件名提取剧集号
      
      if localEpNumOpt.isSome and localEpNumOpt.get() == bangumiEpNum: # 如果提取成功且与当前Bangumi剧集号匹配
        # echo fmt"  精确匹配尝试: Bangumi S{season.id}E{bangumiEpNum} ('{ep.name}') vs 本地 '{localFile.nameOnly}{localFile.ext}' (提取号: {localEpNumOpt.get()})"
        let lowerExt = localFile.ext.toLower()
        if lowerExt in videoExts:
          if currentFoundVideo.isNone: # 只取第一个匹配到的视频
            currentFoundVideo = some(localFile)
            # echo fmt"    -> 精确匹配成功 (视频): {localFile.nameOnly}{localFile.ext}"
        elif lowerExt in subtitleExts:
          if currentFoundSub.isNone: # 只取第一个匹配到的字幕
            currentFoundSub = some(localFile)
            # echo fmt"    -> 精确匹配成功 (字幕): {localFile.nameOnly}{localFile.ext}"
      
      if currentFoundVideo.isSome and currentFoundSub.isSome: # 如果视频和字幕都找到了，提前结束对当前Bangumi剧集的本地文件搜索
        break
    
    # 记录当前Bangumi剧集的精确匹配结果，并标记使用的本地文件
    if currentFoundVideo.isSome: usedByPreciseMatch.incl(currentFoundVideo.get())
    if currentFoundSub.isSome: usedByPreciseMatch.incl(currentFoundSub.get())
    preciseMatchResults[ep.sort] = (video: currentFoundVideo, sub: currentFoundSub)

  # --- 准备阶段二的数据：分离并排序剩余的本地文件 ---
  var remainingVideos = newSeq[LocalFileInfo]()    # 未被精确匹配的视频文件
  var remainingSubtitles = newSeq[LocalFileInfo]() # 未被精确匹配的字幕文件

  for file in originalMatchedLocalFiles:
    if file notin usedByPreciseMatch: # 只处理未被精确匹配使用的文件
      if file.ext.toLower() in videoExts:
        remainingVideos.add(file)
      elif file.ext.toLower() in subtitleExts:
        remainingSubtitles.add(file)
  
  remainingVideos.sort(naturalCompare)    # 自然排序剩余视频文件
  remainingSubtitles.sort(naturalCompare) # 自然排序剩余字幕文件

  echo fmt"调试: 精确匹配完成。剩余 {remainingVideos.len} 个视频和 {remainingSubtitles.len} 个字幕待排序匹配。"
  if remainingVideos.len > 0: echo fmt"  排序后剩余视频示例 1: {remainingVideos[0].nameOnly}{remainingVideos[0].ext}"
  if remainingSubtitles.len > 0: echo fmt"  排序后剩余字幕示例 1: {remainingSubtitles[0].nameOnly}{remainingSubtitles[0].ext}"


  # --- 组合结果并进行阶段二（顺序匹配作为后备） ---
  var videoSeqIdx = 0 # 剩余视频文件的索引用
  var subSeqIdx = 0   # 剩余字幕文件的索引用

  for ep in bangumiEpisodes.data: # 再次遍历Bangumi剧集，构建最终的episodesForJson
    let epKey = formatEpisodeNumber(ep.sort, bangumiEpisodes.total) # E01, E02 ...
    var (finalVideoFile, finalSubtitleFile) = preciseMatchResults.getOrDefault(ep.sort) # 获取精确匹配结果

    # 如果精确匹配未能找到视频文件，并且还有剩余的已排序视频文件，则尝试顺序匹配
    if finalVideoFile.isNone and videoSeqIdx < remainingVideos.len:
      finalVideoFile = some(remainingVideos[videoSeqIdx])
      videoSeqIdx += 1 # 消耗一个剩余视频文件
      echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 视频 '{finalVideoFile.get().nameOnly}{finalVideoFile.get().ext}'"
    
    # 如果精确匹配未能找到字幕文件，并且还有剩余的已排序字幕文件，则尝试顺序匹配
    if finalSubtitleFile.isNone and subSeqIdx < remainingSubtitles.len:
      finalSubtitleFile = some(remainingSubtitles[subSeqIdx])
      subSeqIdx += 1 # 消耗一个剩余字幕文件
      echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 字幕 '{finalSubtitleFile.get().nameOnly}{finalSubtitleFile.get().ext}'"

    episodesForJson[epKey] = CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      localVideoFile: finalVideoFile,
      localSubtitleFile: finalSubtitleFile
    )
    
    # 调试输出最终匹配结果
    var parts: seq[string]
    var matchedSomething = false
    if finalVideoFile.isSome:
      parts.add("视频: " & finalVideoFile.get().nameOnly & finalVideoFile.get().ext)
      matchedSomething = true
    if finalSubtitleFile.isSome:
      parts.add("字幕: " & finalSubtitleFile.get().nameOnly & finalSubtitleFile.get().ext)
      matchedSomething = true
    
    if matchedSomething:
      let joinedPartsStr = parts.join(", ")
      echo fmt"  最终匹配 S{season.id}E{int(ep.sort)} ('{ep.name}'): {joinedPartsStr}"
    # 如果精确匹配和顺序匹配都没有找到任何文件 for this ep
    elif preciseMatchResults.getOrDefault(ep.sort).video.isNone and preciseMatchResults.getOrDefault(ep.sort).sub.isNone:
      echo fmt"  最终匹配 S{season.id}E{int(ep.sort)} ('{ep.name}'): 无本地文件匹配"


  let seasonInfoEntry = CachedSeasonInfo(
    bangumiSeasonId: season.id,
    bangumiSeasonName: season.name,
    totalBangumiEpisodes: bangumiEpisodes.total,
    episodes: episodesForJson
  )
  jsonCacheToUpdate[seasonIdStr] = seasonInfoEntry
  # echo fmt"调试: 已更新内存中Json缓存条目 for ID {seasonIdStr}"

# --- 规则匹配相关函数 ---
proc extractMatch*(s: string, pattern: string): string =
  ## 使用正则表达式从字符串 s 中提取第一个匹配项。
  ## 如果没有匹配，则返回空字符串。
  var matches: array[1, string] # 假设我们只需要捕获组0或整个匹配
  if s.find(re(pattern), matches) != -1:
    return matches[0]
  return ""

proc loadRules(filename: string): RuleSet =
  ## 从指定文件加载匹配规则。
  ## 文件格式: group1,group2=regex_pattern
  ## 以 # 开头的行或空行将被忽略。
  result = @[]
  if not fileExists(filename):
    echo fmt"警告: 规则文件 '{filename}' 不存在。"
    return
  
  let fileStream = newFileStream(filename, fmRead)
  defer: fileStream.close()

  for line in fileStream.lines:
    let trimmedLine = line.strip()
    if trimmedLine.len == 0 or trimmedLine.startsWith("#"):
      continue

    let parts = trimmedLine.split('=', 1)
    if parts.len < 2:
      echo fmt"警告：规则文件 '{filename}' 中的行格式错误 (缺少 '='): {trimmedLine}"
      continue
    
    let groupsStr = parts[0].strip()
    let patternStr = parts[1].strip()
    
    let groupsSeq = groupsStr.split(',').map(proc(s: string): string = s.strip())
    
    result.add(RuleConfig(
      groups: groupsSeq,
      pattern: patternStr
    ))

proc isPlainString(s: string): bool =
  ## 检查字符串是否不包含常见的正则表达式元字符。
  ## 用于判断规则中的 pattern 是否可以直接作为字符串匹配。
  const regexMetaChars = {'[', ']', '(', ')', '{', '}', '?', '*', '+', '|', '^', '$', '.', '\\'}
  for c in s:
    if c in regexMetaChars:
      return false
  return true

proc matchRule(title: string, rule: RuleConfig): Option[string] =
  ## 根据单条规则匹配标题。
  ## 首先检查标题是否包含规则中的任一 group。
  ## 然后，如果 pattern 是普通字符串则直接返回，否则使用正则提取。
  if not rule.groups.anyIt(it in title): # 检查字幕组/关键词是否在标题中
    return none(string)
  
  if isPlainString(rule.pattern): # 如果规则的 pattern 是简单字符串
    return some(rule.pattern) # 直接返回 pattern 作为匹配结果 (通常是番剧名)
  
  # 如果 pattern 是正则表达式
  let extracted = extractMatch(title, rule.pattern)
  if extracted.len > 0:
    # 如果正则提取结果与原标题相同，说明可能规则不精确，但仍视为匹配
    # 否则返回提取到的子串
    return some(extracted) 
  return none(string)

proc findMatchingRule(title: string, rules: RuleSet): string =
  ## 在规则集中查找第一个与标题匹配的规则，并返回匹配结果 (通常是番剧名)。
  ## 如果没有匹配的规则，则返回空字符串。
  for rule in rules:
    let optMatched = matchRule(title, rule)
    if optMatched.isSome:
      return optMatched.get()
  return ""

proc processSampleData(
    sampleFolderName: string,
    rules: RuleSet,
    csvCache: var Table[string, CsvCacheEntry], # 传入整个CSV缓存以便更新
    jsonCache: var Table[string, CachedSeasonInfo] # 传入JSON缓存以便更新和检查
  ) =
  ## 处理单个番剧样本目录 (sampleFolderName)。
  ## 1. 检查CSV缓存，获取SeasonID。
  ## 2. 如果CSV缓存未命中，则通过规则匹配和API获取Season信息，并更新CSV缓存。
  ## 3. 检查JSON缓存，获取详细剧集信息（包括本地文件匹配情况）。
  ## 4. 如果JSON缓存未命中或不完整，则通过API获取Bangumi剧集列表。
  ## 5. 扫描本地文件夹中的文件。 (TODO)
  ## 6. 匹配本地文件和Bangumi剧集。(TODO)
  ## 7. 更新JSON缓存（内存中）。

  var seasonToProcessOpt: Option[Season] = none(Season)
  var forceApiFetchForEpisodes = false # 是否强制从API获取剧集（即使JSON缓存中有）

  # 步骤 1 & 2: 处理 CSV 缓存和获取 Season 对象
  if useCache and csvCache.hasKey(sampleFolderName):
    let entry = csvCache[sampleFolderName]
    seasonToProcessOpt = some(Season(id: entry.bangumiSeasonId, name: entry.bangumiSeasonNameCache))
    echo fmt"信息: 从 cache.csv 找到 '{sampleFolderName}' -> ID: {entry.bangumiSeasonId}, 名称: {entry.bangumiSeasonNameCache}"
    
    # 检查JSON缓存是否已存在此SeasonID的条目
    if jsonCache.hasKey($entry.bangumiSeasonId):
      let cachedSeasonDetails = jsonCache[$entry.bangumiSeasonId]
      echo fmt"信息: cache.json 中已存在番剧 ID '{entry.bangumiSeasonId}' ({cachedSeasonDetails.bangumiSeasonName}) 的条目。"
      # 在这里可以加入逻辑判断是否需要强制更新本地文件列表或重新从API获取剧集
      # 例如，如果用户指定了 --force-refresh-local 或 --force-refresh-api
      # forceApiFetchForEpisodes = true # 示例：强制刷新
    else:
      echo fmt"信息: cache.json 中未找到番剧 ID '{entry.bangumiSeasonId}' 的详细信息，将尝试从API获取。"
      forceApiFetchForEpisodes = true # JSON中没有，肯定要API获取
  else:
    echo fmt"信息: cache.csv 中未找到 '{sampleFolderName}'，尝试规则匹配和API获取。"
    let matchedName = findMatchingRule(sampleFolderName, rules)
    if matchedName.len > 0:
      let seasonOptFromApi = getSeason(matchedName)
      if seasonOptFromApi.isSome:
        seasonToProcessOpt = seasonOptFromApi
        let s = seasonToProcessOpt.get()
        if useCache:
          appendToCacheCsv(sampleFolderName, s)
          csvCache[sampleFolderName] = CsvCacheEntry(
            originalFolderName: sampleFolderName,
            bangumiSeasonNameCache: s.name,
            bangumiSeasonId: s.id
          )
          echo fmt"信息: '{sampleFolderName}' 匹配到 '{s.name}' (ID: {s.id})，已更新到 cache.csv。"
        forceApiFetchForEpisodes = true # 新获取的Season，需要从API获取剧集
      else:
        echo fmt"错误: 为 '{sampleFolderName}' (匹配为 '{matchedName}') 获取番剧信息失败。"
        return
    else:
      echo fmt"提示: '{sampleFolderName}' 未匹配到任何规则。"
      return

  if seasonToProcessOpt.isNone:
    echo fmt"严重错误: 未能确定 '{sampleFolderName}' 的番剧信息。"
    return
  
  let currentSeason = seasonToProcessOpt.get()
  let currentSeasonIdStr = $currentSeason.id

  # 步骤 3 & 4: 获取 Bangumi 剧集列表 (如果需要)
  var bangumiEpisodeList: EpisodeList
  var episodesAlreadyInJson = false

  if useCache and not forceApiFetchForEpisodes and jsonCache.hasKey(currentSeasonIdStr):
    let cachedSeasonDetails = jsonCache[currentSeasonIdStr]
    if cachedSeasonDetails.episodes.len > 0: # 简单判断，如果已有剧集则尝试使用
      var episodesData = newSeq[Episode]()
      for _, epInfo in cachedSeasonDetails.episodes.pairs: # Table迭代用pairs
        episodesData.add(Episode(sort: epInfo.bangumiSort, name: epInfo.bangumiName))
      # 需要按 sort 排序，因为 Table 不保证顺序
      episodesData.sort(proc(a,b: Episode): int = cmp(a.sort, b.sort))

      bangumiEpisodeList = EpisodeList(total: cachedSeasonDetails.totalBangumiEpisodes, data: episodesData)
      episodesAlreadyInJson = true
      echo fmt"信息: 使用 cache.json 中番剧 ID '{currentSeasonIdStr}' 的剧集列表。"
    else: # JSON中有Season条目但无剧集数据
      forceApiFetchForEpisodes = true
      echo fmt"信息: cache.json 中番剧 ID '{currentSeasonIdStr}' 条目无剧集数据，将从API获取。"


  if forceApiFetchForEpisodes or not episodesAlreadyInJson :
    echo fmt"信息: 从 API 获取番剧 ID '{currentSeasonIdStr}' ({currentSeason.name}) 的剧集列表。"
    let episodesOptFromApi = getEpisodes(currentSeason.id)
    if episodesOptFromApi.isNone:
      echo fmt"错误: 无法获取番剧 ID '{currentSeason.id}' ({currentSeason.name}) 的剧集列表。"
      return
    bangumiEpisodeList = episodesOptFromApi.get()
  
  # 步骤 5: 扫描本地文件夹中的文件
  let localFilesPath = base_path_str / sampleFolderName # 构造本地番剧文件夹路径
  echo fmt"信息: 准备扫描本地文件夹: {localFilesPath}"
  var matchedLocalFiles = newSeq[LocalFileInfo]() # 存储扫描和识别结果

  if dirExists(localFilesPath):
    var count = 0
    for item in walkDir(localFilesPath):
      if item.kind == pcFile:
        let filePath = item.path
        let (_, name, ext) = splitFile(filePath)
        matchedLocalFiles.add(LocalFileInfo(
          nameOnly: name,
          ext: ext,
          fullPath: filePath
        ))
        count += 1
        # echo fmt"  发现文件: {filePath} (名: {name}, 后缀: {ext})" # 详细调试信息
    echo fmt"信息: 在 '{localFilesPath}' 中扫描到 {count} 个文件。"
  else:
    echo fmt"警告: 本地文件夹 '{localFilesPath}' 不存在或不是一个目录。"

  # 步骤 6: 匹配本地文件和Bangumi剧集 (这部分已在 updateAndSaveJsonCache 中处理)

  # 步骤 7: 更新JSON缓存（内存中）
  if useCache:
    updateAndSaveJsonCache(jsonCache, currentSeason, bangumiEpisodeList, matchedLocalFiles)
    echo fmt"信息: 已为 '{sampleFolderName}' (番剧: {currentSeason.name}, ID: {currentSeason.id}) 更新内存中的JSON缓存。"
  
  echo fmt"处理 '{sampleFolderName}' 完成。本地文件已扫描并尝试匹配。"


# --- 新增的硬链接和重命名辅助函数 ---
proc sanitizeFilename(filename: string): string =
  ## 清理文件名，移除或替换非法字符，并限制长度。
  let invalidCharsPattern = re(r"[\\/:*?""<>|]") # 正则表达式匹配Windows和Linux非法字符
  result = filename.replace(invalidCharsPattern, "_") # 用下划线替换
  result = result.strip() # 去除首尾空格

  # 进一步清理，防止文件名以点或空格结尾 (Windows问题)
  while result.endsWith(".") or result.endsWith(" "):
    result = result[0 .. ^2]
  
  # 限制总长度 (例如，200个字符，不含扩展名部分，实际限制取决于文件系统)
  # 这个限制应该在拼接完番剧名、集数、剧集名之后，但在附加扩展名之前应用。
  # 这里仅作为通用清理函数的一部分。
  if result.len > 240: # 稍微宽松一点的限制
    result = result[0 .. 239].strip()
    while result.endsWith(".") or result.endsWith(" "): # 再次清理末尾
      result = result[0 .. ^2]
  return result

proc createDirectoryHardLinkRecursive(sourceDir: string, targetDir: string) =
  ## 递归地将 sourceDir 的内容硬链接到 targetDir。
  ## sourceDir 内的文件会硬链接到 targetDir 下的同名文件。
  ## sourceDir 内的子目录会在 targetDir 下创建，并递归处理。
  if not dirExists(sourceDir):
    echo fmt"错误: 源目录 '{sourceDir}' 不存在，无法执行硬链接。"
    return

  echo fmt"  尝试硬链接目录内容从 '{sourceDir}' 到 '{targetDir}'"
  
  # 确保目标根目录存在
  try:
    if not dirExists(targetDir):
      createDir(targetDir)
      echo fmt"    创建目标根目录: {targetDir}"
  except OSError as e:
    echo fmt"    严重错误: 创建目标根目录 '{targetDir}' 失败: {e.msg}. 中止此目录的硬链接。"
    return

  var linkedFilesCount = 0
  var createdDirsInTargetCount = 0 # 统计在目标路径下创建的目录数
  var linkErrorsCount = 0
  var dirCreateErrorsCount = 0

  # 遍历源目录中的所有项目 (文件和目录)
  for kind, itemFullPathInSource in walkDir(sourceDir): # itemFullPathInSource 是绝对路径
    # 计算相对于 sourceDir 的路径
    if not itemFullPathInSource.startsWith(sourceDir):
      echo fmt"    警告: 遍历路径 '{itemFullPathInSource}' 不在源目录 '{sourceDir}' 下，跳过。"
      continue
    
    var relativeItemPath: string
    if sourceDir.endsWith(PathSep):
      relativeItemPath = itemFullPathInSource[sourceDir.len .. ^1]
    else:
      # 如果 sourceDir 不以分隔符结尾，则相对路径从 sourceDir.len + 1 开始
      if itemFullPathInSource.len > sourceDir.len : # 确保不是源目录本身
          relativeItemPath = itemFullPathInSource[(sourceDir.len + 1) .. ^1]
      else: # 是源目录本身，跳过
          continue
    
    if relativeItemPath.len == 0: # 再次确认跳过源目录本身
      continue

    let targetItemPath = targetDir / relativeItemPath

    case kind
    of pcFile:
      let targetFileParentDir = parentDir(targetItemPath)
      try:
        if not dirExists(targetFileParentDir): # 确保目标文件的父目录存在
          createDir(targetFileParentDir)
          # echo fmt"      创建父目录 (用于文件链接): {targetFileParentDir}" # 详细日志
      except OSError as e:
        echo fmt"      警告: 为文件链接创建父目录 '{targetFileParentDir}' 失败: {e.msg}"
        # 即使父目录创建失败，也尝试链接，createHardLink 可能会给出更具体的错误
      
      try:
        if fileExists(targetItemPath): # 如果目标文件已存在 (可能是上次运行留下的)
          echo fmt"      警告: 目标文件 '{targetItemPath}' 已存在，跳过硬链接。"
        else:
          createHardLink(itemFullPathInSource, targetItemPath)
          # echo fmt"      硬链接文件: '{itemFullPathInSource}' -> '{targetItemPath}'" # 详细日志
          linkedFilesCount += 1
      except OSError as e:
        echo fmt"      错误: 硬链接文件 '{itemFullPathInSource}' 到 '{targetItemPath}' 失败: {e.msg}"
        linkErrorsCount += 1
    of pcDir:
      try:
        if not dirExists(targetItemPath): # 只在目标子目录不存在时创建
          createDir(targetItemPath)
          # echo fmt"      创建目标子目录: {targetItemPath}" # 详细日志
          createdDirsInTargetCount += 1
      except OSError as e:
        echo fmt"      警告: 创建目标子目录 '{targetItemPath}' 失败: {e.msg}"
        dirCreateErrorsCount += 1
    else: # pcLinkToFile, pcLinkToDir (符号链接等，目前不特殊处理)
      discard

  echo fmt"    硬链接完成: {linkedFilesCount} 个文件已链接, {createdDirsInTargetCount} 个新目录已在目标中创建。"
  if linkErrorsCount > 0 or dirCreateErrorsCount > 0:
    echo fmt"    硬链接期间发生错误: {linkErrorsCount} 个文件链接失败, {dirCreateErrorsCount} 个目录创建失败。"

proc renameFilesBasedOnCache(
    targetSeasonPath: string, # anime_path_str / originalFolderNameInBase
    seasonInfo: CachedSeasonInfo,
    originalFolderName: string # 用于调试或记录
  ) =
  ## 根据 seasonInfo 重命名 targetSeasonPath 下的文件。
  ## targetSeasonPath 是硬链接后的番剧文件夹路径。

  echo fmt"    开始重命名番剧 '{seasonInfo.bangumiSeasonName}' (源文件夹: '{originalFolderName}') 内的文件，位于: '{targetSeasonPath}'"

  if not dirExists(targetSeasonPath):
    echo fmt"    错误: 目标番剧文件夹 '{targetSeasonPath}' 不存在，无法重命名。"
    return

  var renamedFilesCount = 0
  var renameErrorsCount = 0

  # 遍历缓存中的剧集信息
  for epKey, cachedEp in seasonInfo.episodes.pairs: # epKey 是 "E01", "E02" 等
    let episodeNumberFormatted = epKey # 使用缓存中的key作为格式化后的集数
    
    # 清理番剧名和剧集名（来自API，可能包含特殊字符）
    let cleanSeasonName = sanitizeFilename(seasonInfo.bangumiSeasonName)
    let cleanEpisodeName = sanitizeFilename(cachedEp.bangumiName)

    # 处理视频文件
    if cachedEp.localVideoFile.isSome:
      let videoInfo = cachedEp.localVideoFile.get()
      # videoInfo.fullPath 是原始基础路径下的完整路径
      # 我们需要的是硬链接后在 targetSeasonPath 下的对应文件名
      let originalFileNameWithExt = extractFilename(videoInfo.fullPath) # 例如 "Episode 01.mkv"
      let oldHardlinkedVideoPath = targetSeasonPath / originalFileNameWithExt

      if fileExists(oldHardlinkedVideoPath):
        let baseNameWithoutExt = fmt"{cleanSeasonName} - {episodeNumberFormatted} - {cleanEpisodeName}"
        # 对拼接后的基本名称再做一次清理和长度限制
        let finalBaseName = sanitizeFilename(baseNameWithoutExt)
        let newVideoFileNameWithExt = finalBaseName & videoInfo.ext # 保留原始ext

        let newHardlinkedVideoPath = targetSeasonPath / newVideoFileNameWithExt

        if oldHardlinkedVideoPath == newHardlinkedVideoPath:
          # echo fmt"      视频文件 '{oldHardlinkedVideoPath}' 无需重命名。" # 可能过于冗余
          discard
        else:
          try:
            echo fmt"      重命名视频: '{oldHardlinkedVideoPath}' -> '{newHardlinkedVideoPath}'"
            moveFile(oldHardlinkedVideoPath, newHardlinkedVideoPath)
            renamedFilesCount += 1
          except OSError as e:
            echo fmt"      错误: 重命名视频文件 '{oldHardlinkedVideoPath}' 失败: {e.msg}"
            renameErrorsCount += 1
      else:
        echo fmt"      警告: 预期的硬链接视频文件 '{oldHardlinkedVideoPath}' (来自缓存条目 {videoInfo.nameOnly}{videoInfo.ext}) 在目标目录中未找到。"

    # 处理字幕文件
    if cachedEp.localSubtitleFile.isSome:
      let subInfo = cachedEp.localSubtitleFile.get()
      let originalFileNameWithExt = extractFilename(subInfo.fullPath)
      let oldHardlinkedSubPath = targetSeasonPath / originalFileNameWithExt

      if fileExists(oldHardlinkedSubPath):
        let baseNameWithoutExt = fmt"{cleanSeasonName} - {episodeNumberFormatted} - {cleanEpisodeName}"
        let finalBaseName = sanitizeFilename(baseNameWithoutExt)
        let newSubFileNameWithExt = finalBaseName & subInfo.ext # 保留原始ext
        
        let newHardlinkedSubPath = targetSeasonPath / newSubFileNameWithExt

        if oldHardlinkedSubPath == newHardlinkedSubPath:
          # echo fmt"      字幕文件 '{oldHardlinkedSubPath}' 无需重命名。"
          discard
        else:
          try:
            echo fmt"      重命名字幕: '{oldHardlinkedSubPath}' -> '{newHardlinkedSubPath}'"
            moveFile(oldHardlinkedSubPath, newHardlinkedSubPath)
            renamedFilesCount += 1
          except OSError as e:
            echo fmt"      错误: 重命名字幕文件 '{oldHardlinkedSubPath}' 失败: {e.msg}"
            renameErrorsCount += 1
      else:
        echo fmt"      警告: 预期的硬链接字幕文件 '{oldHardlinkedSubPath}' (来自缓存条目 {subInfo.nameOnly}{subInfo.ext}) 在目标目录中未找到。"

  echo fmt"    番剧 '{seasonInfo.bangumiSeasonName}' 重命名完成。成功: {renamedFilesCount} 个文件, 失败: {renameErrorsCount} 个。"


# --- 主逻辑执行 ---
initializeConfig() # 首先初始化配置

let rules = loadRules("cache/fansub.rules") # 加载匹配规则

var csvCacheGlobal = if useCache: readCsvCacheEntries(cacheFile) else: initTable[string, CsvCacheEntry]()
var jsonCacheGlobal = if useCache: loadJsonCache(jsonCacheFile) else: initTable[string, CachedSeasonInfo]()

let samples = readDir(base_path_str) # 读取基础路径下的所有目录作为样本

if samples.len == 0 and base_path_str == defaultBasePath:
  echo fmt"提示: 在默认基础路径 '{base_path_str}' 下未找到任何番剧文件夹。请确保文件夹存在或通过 -b=<路径> 指定。"
elif samples.len == 0:
  echo fmt"提示: 在指定基础路径 '{base_path_str}' 下未找到任何番剧文件夹。"

for sample in samples:
  processSampleData(sample, rules, csvCacheGlobal, jsonCacheGlobal)

if useCache:
  saveJsonCache(jsonCacheFile, jsonCacheGlobal) # 保存主处理流程的JSON缓存
  echo fmt"\n主处理流程完成，JSON缓存已保存到 {jsonCacheFile}。"

  # --- 开始新的硬链接和重命名逻辑 ---
  echo "\n开始执行硬链接和重命名操作..."
  # 重新加载JSON缓存，确保使用的是包含所有番剧信息的最新版本
  let finalJsonCacheForRename = loadJsonCache(jsonCacheFile)

  if samples.len > 0:
    # 确保 anime_path_str 目录存在，如果不存在则创建
    try:
      if not dirExists(anime_path_str):
        createDir(anime_path_str)
        echo fmt"创建番剧目标根目录: {anime_path_str}"
    except OSError as e:
      echo fmt"严重错误: 创建番剧目标根目录 '{anime_path_str}' 失败: {e.msg}. 硬链接和重命名操作可能失败。"
      # 即使这里失败，后续的 createDirectoryHardLinkRecursive 也会尝试创建子目录

  for originalFolderNameInBase in samples: # 使用之前从 base_path_str 读取的文件夹列表
    let sourceSeasonDir = base_path_str / originalFolderNameInBase
    let targetSeasonDirForLinkAndRename = anime_path_str / originalFolderNameInBase # 这是硬链接的目标目录，也是重命名的操作目录

    if dirExists(sourceSeasonDir):
      echo fmt"\n处理原始文件夹: '{originalFolderNameInBase}'"
      
      # 步骤 1: 硬链接
      echo fmt"  步骤 1: 硬链接内容从 '{sourceSeasonDir}' 到 '{targetSeasonDirForLinkAndRename}'"
      createDirectoryHardLinkRecursive(sourceSeasonDir, targetSeasonDirForLinkAndRename)

      # 步骤 2: 重命名 (在目标路径下)
      if csvCacheGlobal.hasKey(originalFolderNameInBase):
        let csvEntry = csvCacheGlobal[originalFolderNameInBase]
        let seasonIdStr = $csvEntry.bangumiSeasonId
        if finalJsonCacheForRename.hasKey(seasonIdStr):
          let seasonInfo = finalJsonCacheForRename[seasonIdStr]
          echo fmt"  步骤 2: 重命名 '{targetSeasonDirForLinkAndRename}' 中的文件 (基于番剧: {seasonInfo.bangumiSeasonName})"
          renameFilesBasedOnCache(targetSeasonDirForLinkAndRename, seasonInfo, originalFolderNameInBase)
        else:
          echo fmt"  警告: 在JSON缓存中未找到番剧ID '{seasonIdStr}' (来自文件夹 '{originalFolderNameInBase}') 的详细信息，无法重命名。"
      else:
        echo fmt"  警告: 在CSV缓存中未找到文件夹 '{originalFolderNameInBase}' 的条目，无法重命名。"
    else:
      echo fmt"  警告: 源文件夹 '{sourceSeasonDir}' 不存在或不是目录，跳过硬链接和重命名。"
  echo "\n硬链接和重命名操作完成。"
else:
  echo "所有处理完成（缓存未启用）。硬链接和重命名操作已跳过，因为它们依赖于缓存。"

echo "程序执行完毕。"
