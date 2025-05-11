import ./types
import ./utils_string # naturalCompare 在 updateAndSaveJsonCache 中使用
import std/[strformat, strutils, re, json, tables, os, options, algorithm, sets]

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
  var preciseMatchResults = initTable[float, tuple[video: Option[LocalFileInfo], sub: Option[LocalFileInfo]]]()

  for ep in bangumiEpisodes.data: 
    let bangumiEpNum = int(ep.sort) 
    var currentFoundVideo: Option[LocalFileInfo] = none[LocalFileInfo]() 
    var currentFoundSub: Option[LocalFileInfo] = none[LocalFileInfo]()   

    for localFile in originalMatchedLocalFiles: 
      let localEpNumOpt = extractEpisodeNumberFromName(localFile.nameOnly) 
      
      if localEpNumOpt.isSome and localEpNumOpt.get() == bangumiEpNum: 
        let lowerExt = localFile.ext.toLower()
        if lowerExt in videoExts:
          if currentFoundVideo.isNone: 
            currentFoundVideo = some(localFile)
        elif lowerExt in subtitleExts:
          if currentFoundSub.isNone: 
            currentFoundSub = some(localFile)
      
      if currentFoundVideo.isSome and currentFoundSub.isSome: 
        break
    
    if currentFoundVideo.isSome: usedByPreciseMatch.incl(currentFoundVideo.get())
    if currentFoundSub.isSome: usedByPreciseMatch.incl(currentFoundSub.get())
    preciseMatchResults[ep.sort] = (video: currentFoundVideo, sub: currentFoundSub)

  var remainingVideos = newSeq[LocalFileInfo]()    
  var remainingSubtitles = newSeq[LocalFileInfo]() 

  for fileInfo in originalMatchedLocalFiles: # Renamed 'file' to 'fileInfo' to avoid conflict
    if fileInfo notin usedByPreciseMatch: 
      if fileInfo.ext.toLower() in videoExts:
        remainingVideos.add(fileInfo)
      elif fileInfo.ext.toLower() in subtitleExts:
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
    var (finalVideoFile, finalSubtitleFile) = preciseMatchResults.getOrDefault(ep.sort) 

    if finalVideoFile.isNone and videoSeqIdx < remainingVideos.len:
      finalVideoFile = some(remainingVideos[videoSeqIdx])
      videoSeqIdx += 1 
      # echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 视频 '{finalVideoFile.get().nameOnly}{finalVideoFile.get().ext}'" # 减少默认输出
    
    if finalSubtitleFile.isNone and subSeqIdx < remainingSubtitles.len:
      finalSubtitleFile = some(remainingSubtitles[subSeqIdx])
      subSeqIdx += 1 
      # echo fmt"  顺序匹配: Bangumi S{season.id}E{int(ep.sort)} ('{ep.name}') -> 字幕 '{finalSubtitleFile.get().nameOnly}{finalSubtitleFile.get().ext}'" # 减少默认输出

    episodesForJson[epKey] = CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      localVideoFile: finalVideoFile,
      localSubtitleFile: finalSubtitleFile
    )
    
    # var parts: seq[string] # 减少默认输出
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