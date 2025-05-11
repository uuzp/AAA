import ./types
import ./utils_string # naturalCompare 在 updateAndSaveJsonCache 中使用
import std/[strformat, strutils, re, json, tables, os, options, algorithm, sets, sequtils] # 添加 sequtils

# --- 缓存处理函数 ---

proc extractEpisodeNumberFromName*(fileName: string): Option[int] =
  ## 尝试从文件名中提取剧集号。
  ## 注意: 这个实现比较基础，可能需要根据实际文件名格式进行大量调整和增强。
  ## 它会尝试匹配多种模式，并返回第一个成功匹配的数字。
  let patterns = [
    re"S\d+[._-]?E(\d{1,3})\b",
    re"\b(?:EP|E|第|\[)\s*(\d{1,3})\b",
    re"\[(\d{1,3})\]",
    re"\s-\s(\d{1,3})\b",
    re"\b(\d{1,3})\s*\[",
    re"\b(\d{1,3})\b"
  ]

  for pattern in patterns:
    var match: array[1, string]
    if fileName.find(pattern, match) != -1:
      try:
        let num = parseInt(match[0])
        # echo fmt"调试: extractEpisodeNumberFromName: 从 '{fileName}' 提取到剧集号: {num}" # 减少默认输出
        return some(num)
      except ValueError:
        # echo fmt"调试: extractEpisodeNumberFromName: 尝试从 '{fileName}' 用模式 '{pattern}' 解析数字 '{match[0]}' 失败"
        continue # 解析失败，尝试下一个模式
  # echo fmt"调试: extractEpisodeNumberFromName: 未能从 '{fileName}' 提取到剧集号" # 减少默认输出
  return none[int]()

proc formatEpisodeNumber*(currentSort: float, totalEpisodes: int): string =
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

proc appendToCacheCsv*(originalInputName: string, season: Season, cacheFilePath: string) =
  ## 将番剧的原始文件夹名、Bangumi番剧名和Bangumi番剧ID追加到 cache.csv。
  ## 格式: originalFolderName,bangumiSeasonName,bangumiSeasonId
  let line = fmt"{originalInputName},{season.name},{season.id}"
  try:
    # 确保目录存在已在 initializeConfig 中处理
    let f = open(cacheFilePath, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError as e:
    echo &"错误: 追加到 {cacheFilePath} 失败: {e.msg}" # 保持错误输出

proc readCsvCacheEntries*(filePath: string): Table[string, CsvCacheEntry] =
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
          echo fmt"警告: 解析 cache.csv 行时ID无效: {strippedLine}" # 保持警告
      else:
        echo fmt"警告: cache.csv 行格式无法识别 (期望3个字段): {strippedLine}" # 保持警告
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}" # 保持错误输出

proc loadJsonCache*(filePath: string): Table[string, CachedSeasonInfo] =
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
        except JsonKindError, ValueError: 
          echo fmt"警告: 解析 cache.json 中番剧ID '{seasonIdKey}' 的数据失败。" # 保持警告
    else:
      echo &"警告: {filePath} 的根不是一个有效的 JSON 对象。" # 保持警告
  except JsonParsingError as e:
    echo &"错误: 解析 {filePath} (JSON) 失败: {e.msg}" # 保持错误输出
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}" # 保持错误输出

proc saveJsonCache*(filePath: string, cacheData: Table[string, CachedSeasonInfo]) =
  ## 将番剧剧集缓存数据保存到 cache.json，并确保番剧ID和剧集按顺序排列。
  var rootNode = newJObject()

  # 1. 对番剧ID进行排序
  var sortedSeasonIdInts = newSeq[int]()
  for seasonIdKey in cacheData.keys:
    try:
      sortedSeasonIdInts.add(parseInt(seasonIdKey))
    except ValueError:
      # echo fmt"警告: saveJsonCache - 无法将番剧ID '{seasonIdKey}' 解析为整数，跳过此条目。" # 减少默认输出
      continue
  
  sortedSeasonIdInts.sort(cmp[int]) # 按数字升序排序

  for seasonIdInt in sortedSeasonIdInts:
    let seasonIdKey = $seasonIdInt # 转回字符串作为JSON的key
    if not cacheData.hasKey(seasonIdKey):
        # echo fmt"警告: saveJsonCache - 排序后的ID '{seasonIdKey}' 在原始缓存数据中未找到。" # 减少默认输出
        continue
    
    let seasonInfo = cacheData[seasonIdKey]
    var seasonInfoNode = newJObject()

    # 添加 seasonInfo 的基本字段
    seasonInfoNode["bangumiSeasonId"] = %*(seasonInfo.bangumiSeasonId)
    seasonInfoNode["bangumiSeasonName"] = %*(seasonInfo.bangumiSeasonName)
    seasonInfoNode["totalBangumiEpisodes"] = %*(seasonInfo.totalBangumiEpisodes)

    # 2. 对该番剧的剧集进行排序
    var sortedEpisodeKeys = newSeq[string]()
    if seasonInfo.episodes.len > 0: 
      for epKey in seasonInfo.episodes.keys:
        sortedEpisodeKeys.add(epKey)
      
      sortedEpisodeKeys.sort(cmp[string]) 

      var episodesNode = newJObject()
      for epKey in sortedEpisodeKeys:
        if seasonInfo.episodes.hasKey(epKey):
          episodesNode[epKey] = %*(seasonInfo.episodes[epKey])
        # else: # 减少默认输出
          # echo fmt"警告: saveJsonCache - 番剧ID '{seasonIdKey}', 排序后的剧集Key '{epKey}' 在剧集数据中未找到。"
      seasonInfoNode["episodes"] = episodesNode 
    else:
      seasonInfoNode["episodes"] = newJObject() 
      # echo fmt"调试: saveJsonCache - 番剧ID '{seasonIdKey}' 的 episodes 表为空，将写入空对象。" # 减少默认输出

    rootNode[seasonIdKey] = seasonInfoNode   

  try:
    # 确保目录存在已在 initializeConfig 中处理
    writeFile(filePath, pretty(rootNode))
  except IOError as e:
    echo &"错误: 写入到 {filePath} 失败: {e.msg}" # 保持错误输出

proc updateAndSaveJsonCache*(
    jsonCacheToUpdate: var Table[string, CachedSeasonInfo],
    season: Season,
    bangumiEpisodes: EpisodeList,
    originalMatchedLocalFiles: seq[LocalFileInfo],
    videoExts: seq[string], # 传入视频后缀列表
    subtitleExts: seq[string] # 传入字幕后缀列表
  ) =
  ## 更新（或创建）并准备保存指定番剧的剧集信息到内存中的 jsonCacheToUpdate。
  ## 包含精确匹配和基于排序的后备匹配逻辑。
  
  # echo fmt"调试: updateAndSaveJsonCache: 开始处理番剧 '{season.name}' (ID: {season.id})。接收到 {originalMatchedLocalFiles.len} 个本地文件。" # 减少默认输出
  # if originalMatchedLocalFiles.len > 0 and originalMatchedLocalFiles.len <= 3: 
  #   for i in 0 .. min(originalMatchedLocalFiles.len - 1, 2):
  #     echo fmt"  本地文件示例 {i+1} (原始): {originalMatchedLocalFiles[i].nameOnly}{originalMatchedLocalFiles[i].ext}"
  # elif originalMatchedLocalFiles.len > 3:
  #   echo fmt"  本地文件示例 1 (原始): {originalMatchedLocalFiles[0].nameOnly}{originalMatchedLocalFiles[0].ext}"
  #   echo "  ... (更多原始文件未显示)"

  let seasonIdStr = $season.id
  var episodesForJson = initTable[string, CachedEpisodeInfo]() 
  
  var usedByPreciseMatch = initHashSet[LocalFileInfo]()
  # 修改 preciseMatchResults 以存储字幕文件序列
  var preciseMatchResults = initTable[float, tuple[video: Option[LocalFileInfo], subs: seq[LocalFileInfo]]]()

  for ep in bangumiEpisodes.data:
    let bangumiEpNum = int(ep.sort)
    var currentFoundVideo: Option[LocalFileInfo] = none[LocalFileInfo]()
    var currentFoundSubs: seq[LocalFileInfo] = @[] # 用于收集当前剧集所有匹配的字幕

    for localFile in originalMatchedLocalFiles:
      let localEpNumOpt = extractEpisodeNumberFromName(localFile.nameOnly)

      if localEpNumOpt.isSome and localEpNumOpt.get() == bangumiEpNum:
        let lowerExt = localFile.ext.toLower()
        if lowerExt in videoExts:
          if currentFoundVideo.isNone: # 只取第一个匹配的视频
            currentFoundVideo = some(localFile)
        elif subtitleExts.any(proc(basicExt: string): bool = lowerExt.endsWith(basicExt)): # 检查是否以任一基本字幕后缀结尾
          currentFoundSubs.add(localFile) # 添加所有匹配的字幕
    
    if currentFoundVideo.isSome: usedByPreciseMatch.incl(currentFoundVideo.get())
    for subFile in currentFoundSubs: usedByPreciseMatch.incl(subFile) # 将所有精确匹配的字幕加入已使用集合
    preciseMatchResults[ep.sort] = (video: currentFoundVideo, subs: currentFoundSubs)

  var remainingVideos = newSeq[LocalFileInfo]()
  var remainingSubtitles = newSeq[LocalFileInfo]()

  for fileInfo in originalMatchedLocalFiles: # Renamed 'file' to 'fileInfo' to avoid conflict
    if fileInfo notin usedByPreciseMatch:
      let lowerExt = fileInfo.ext.toLower()
      if lowerExt in videoExts:
        remainingVideos.add(fileInfo)
      elif subtitleExts.any(proc(basicExt: string): bool = lowerExt.endsWith(basicExt)): # 同样修改这里的判断逻辑
        remainingSubtitles.add(fileInfo)
  
  remainingVideos.sort(naturalCompare)
  remainingSubtitles.sort(naturalCompare) 

  # echo fmt"调试: 精确匹配完成。剩余 {remainingVideos.len} 个视频和 {remainingSubtitles.len} 个字幕待排序匹配。" # 减少默认输出
  # if remainingVideos.len > 0: echo fmt"  排序后剩余视频示例 1: {remainingVideos[0].nameOnly}{remainingVideos[0].ext}"
  # if remainingSubtitles.len > 0: echo fmt"  排序后剩余字幕示例 1: {remainingSubtitles[0].nameOnly}{remainingSubtitles[0].ext}"

  var videoSeqIdx = 0 
  var subSeqIdx = 0   

  for ep in bangumiEpisodes.data:
    let epKey = formatEpisodeNumber(ep.sort, bangumiEpisodes.total)
    var finalVideoFile = preciseMatchResults.getOrDefault(ep.sort).video
    var finalSubtitleFiles = preciseMatchResults.getOrDefault(ep.sort).subs

    if finalVideoFile.isNone and videoSeqIdx < remainingVideos.len:
      finalVideoFile = some(remainingVideos[videoSeqIdx])
      videoSeqIdx += 1
      # echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 视频 '{finalVideoFile.get().nameOnly}{finalVideoFile.get().ext}'"
    
    # 如果精确匹配没有找到字幕，并且还有剩余字幕，则从剩余字幕中分配一个
    # 注意：此处的顺序匹配仍然只为每个剧集分配一个“额外”的字幕（如果精确匹配为空）。
    # 如果希望将所有剩余字幕按顺序分配给没有精确匹配字幕的剧集，逻辑会更复杂。
    # 目前，如果精确匹配的 finalSubtitleFiles 不为空，则不进行顺序匹配字幕。
    if finalSubtitleFiles.len == 0 and subSeqIdx < remainingSubtitles.len:
      finalSubtitleFiles.add(remainingSubtitles[subSeqIdx]) # 添加到序列
      subSeqIdx += 1
      # echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 字幕 '{finalSubtitleFiles[^1].nameOnly}{finalSubtitleFiles[^1].ext}'"

    var episodeNameOnlyOpt: Option[string] = none[string]()
    var episodeVideoExtOpt: Option[string] = none[string]()
    var episodeSubtitleExtsSeq: seq[string] = @[]

    if finalVideoFile.isSome:
      let videoInfo = finalVideoFile.get()
      episodeNameOnlyOpt = some(videoInfo.nameOnly) # 视频的 nameOnly 作为基准
      episodeVideoExtOpt = some(videoInfo.ext)
    
    if finalSubtitleFiles.len > 0:
      if episodeNameOnlyOpt.isNone: # 如果没有视频文件，则以第一个字幕文件的 nameOnly 为基准
        episodeNameOnlyOpt = some(finalSubtitleFiles[0].nameOnly)
      
      for subFile in finalSubtitleFiles:
        episodeSubtitleExtsSeq.add(subFile.ext)
        # 可选的健壮性检查:
        if episodeNameOnlyOpt.isSome and subFile.nameOnly != episodeNameOnlyOpt.get():
          stderr.writeLine fmt"警告: 番剧 {seasonIdStr} 剧集 {epKey} 的字幕文件 '{subFile.fullPath}' 的 nameOnly ('{subFile.nameOnly}') 与已确定的基础文件名 ('{episodeNameOnlyOpt.get()}') 不一致。"

    episodesForJson[epKey] = CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      nameOnly: episodeNameOnlyOpt,
      videoExt: episodeVideoExtOpt,
      subtitleExts: episodeSubtitleExtsSeq
    )
    
    # var parts: seq[string]
    # var matchedSomething = false
    # if finalVideoFile.isSome:
    #   parts.add("视频: " & finalVideoFile.get().nameOnly & finalVideoFile.get().ext)
    #   matchedSomething = true
    # if finalSubtitleFile.isSome:
    #   parts.add("字幕: " & finalSubtitleFile.get().nameOnly & finalSubtitleFile.get().ext)
    #   matchedSomething = true
    
    # if matchedSomething:
    #   let joinedPartsStr = parts.join(", ")
    #   echo fmt"  最终匹配 S{season.id}E{int(ep.sort)} ('{ep.name}'): {joinedPartsStr}"
    # elif preciseMatchResults.getOrDefault(ep.sort).video.isNone and preciseMatchResults.getOrDefault(ep.sort).sub.isNone:
    #   echo fmt"  最终匹配 S{season.id}E{int(ep.sort)} ('{ep.name}'): 无本地文件匹配"


  let seasonInfoEntry = CachedSeasonInfo(
    bangumiSeasonId: season.id,
    bangumiSeasonName: season.name,
    totalBangumiEpisodes: bangumiEpisodes.total,
    episodes: episodesForJson
  )
  jsonCacheToUpdate[seasonIdStr] = seasonInfoEntry
  # echo fmt"调试: 已更新内存中Json缓存条目 for ID {seasonIdStr}" # 减少默认输出