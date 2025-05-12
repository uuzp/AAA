import std/[strformat,strutils, tables, os,options, algorithm, sequtils, streams, sets, math, times]
import ./bangumi_api      # Bangumi API 相关功能
import ./utils except logDebug # 避免命名冲突
from ./utils import logDebug  # 显式导入logDebug
# import ./test except main # extractAnimeName 已内联，不再需要导入

# --- 类型定义 ---
type
  Config* = object                   ## 程序配置对象 (主要用于命令行参数)
    basePath*: string                # 基础路径
    animePath*: string               # 番剧目标路径

# RuleConfig 和 RuleSet 类型定义已删除

# --- 字幕处理优化函数 ---

proc isCommonLanguageCode(code: string): bool =
  ## 检查是否为常见语言代码，增加对复合语言代码的支持
  let lowerCode = code.toLowerAscii()
  
  # 先检查是否包含小数点，如scjp.ass中的scjp
  if lowerCode.contains("."):
    let parts = lowerCode.split('.')
    if parts.len >= 2:
      # 取第一部分检查是否为语言代码
      return isCommonLanguageCode(parts[0])
  
  # 检查标准语言代码
  return lowerCode in ["sc", "tc", "jp", "en", "chs", "cht", "jap", "jpn", "chi", "eng", 
                     "scjp", "tcjp", "sccn", "tccn", "jpcn", "ensc", "entc"] # 增加复合语言代码支持

proc similarityScore(a, b: string): float =
  ## 计算两个字符串的相似度（0-1，1为完全相同）
  if a.len == 0 or b.len == 0:
    return 0.0
  
  # 将字符串转换为小写以忽略大小写差异
  let strA = a.toLowerAscii()
  let strB = b.toLowerAscii()
  
  # 计算最长公共子序列长度
  var lcs = 0
  var i, j = 0
  while i < strA.len and j < strB.len:
    if strA[i] == strB[j]:
      inc lcs
      inc i
      inc j
    elif strA.len - i > strB.len - j:
      inc i
    else:
      inc j
  
  # 返回相似度得分
  return lcs.float / max(strA.len, strB.len).float

proc matchSubtitleToVideo(videoName, subtitleName: string): bool =
  ## 基于文件名相似度匹配视频和字幕文件
  let videoBase = utils.getBaseNameWithoutEpisode(videoName)
  let subBase = utils.getBaseNameWithoutEpisode(subtitleName)
  
  # 记录匹配过程
  logDebug(fmt"匹配字幕: 视频基础名='{videoBase}', 字幕基础名='{subBase}'")
  
  # 使用更高的阈值识别复合语言代码字幕
  if subtitleName.toLower().contains(".scjp") or 
     subtitleName.toLower().contains(".tcjp") or
     subtitleName.toLower().contains(".sccn") or
     subtitleName.toLower().contains(".tccn"):
    logDebug(fmt"处理复合语言字幕匹配: '{subtitleName}'")
    # 对于复合语言代码字幕文件，使用更低的阈值（0.6）
    let similarity = similarityScore(videoBase, subBase)
    logDebug(fmt"复合语言字幕相似度: {similarity}")
    return similarity > 0.6
    
  # 如果相似度超过0.7则认为匹配
  let similarity = similarityScore(videoBase, subBase)
  logDebug(fmt"相似度得分: {similarity}")
  return similarity > 0.7

proc renameSubtitleToMatchVideo(dirPath: string, videoFile, subFile: utils.LocalFileInfo): string =
  ## 重命名字幕文件以匹配视频文件的命名模式
  ## 返回新的文件名（不包含路径）
  let videoNameOnly = videoFile.nameOnly
  
  # 使用utils中的递归函数获取字幕后缀
  let subExt = utils.getSubtitleSuffix(subFile.fullPath, videoNameOnly)
  
  # 生成新的字幕文件名，保留完整后缀（含语言标记）
  let newSubName = videoNameOnly & subExt
  logDebug(fmt"生成新字幕文件名: '{newSubName}'，保留原后缀: '{subExt}'")
  return newSubName

proc logRename(originalPath, newPath: string) =
  ## 记录重命名操作到日志文件
  try:
    let logDir = "cache/logs"
    if not dirExists(logDir):
      createDir(logDir)
    
    let logFile = open(logDir & "/rename_log.txt", fmAppend)
    defer: logFile.close()
    logFile.writeLine(fmt"{getTime()}: {originalPath} -> {newPath}")
  except IOError:
    stderr.writeLine "警告: 无法写入重命名日志"

proc processEpisodeFiles(
    dirPath: string, 
    epNumber: float, 
    videoFile: Option[utils.LocalFileInfo], 
    subtitleFiles: seq[utils.LocalFileInfo]
  ) =
  ## 处理同一集数的所有相关文件（视频+字幕）
  if videoFile.isNone or subtitleFiles.len == 0:
    return
  
  let video = videoFile.get()
  logDebug(fmt"处理剧集文件: 集数={epNumber}, 视频文件='{video.fullPath}', 字幕文件数量={subtitleFiles.len}")
  
  for sub in subtitleFiles:
    logDebug(fmt"处理字幕: 名称='{sub.nameOnly}', 扩展名='{sub.ext}', 完整路径='{sub.fullPath}'")
    
    # 检查原始字幕文件是否存在
    if not fileExists(sub.fullPath):
      logDebug(fmt"字幕文件不存在: '{sub.fullPath}'")
      continue
    
    # 检查字幕与视频是否匹配
    if matchSubtitleToVideo(video.nameOnly, sub.nameOnly):
      # 生成新文件名
      let newSubName = renameSubtitleToMatchVideo(dirPath, video, sub)
      let oldPath = sub.fullPath
      let newPath = dirPath / newSubName
      
      logDebug(fmt"尝试重命名: '{oldPath}' -> '{newPath}'")
      
      # 执行重命名
      if oldPath != newPath:
        try:
          moveFile(oldPath, newPath)
          logRename(oldPath, newPath)
          logDebug(fmt"重命名成功: '{oldPath}' -> '{newPath}'")
        except OSError as e:
          stderr.writeLine fmt"错误: 重命名字幕文件失败: {oldPath} -> {newPath}, 原因: {e.msg}"
          logDebug(fmt"重命名失败: '{oldPath}' -> '{newPath}', 错误: {e.msg}")
    else:
      logDebug(fmt"字幕与视频不匹配，跳过: '{sub.fullPath}'")

# --- 番剧名提取函数 ---
proc extractAnimeName*(line: string): string = # 设为导出，因为 processSampleData 会间接调用
  ## 从文件夹名 (line) 中提取番剧名。
  var extractedName = "" # 使用局部变量以避免与 proc 名冲突
  # 检查是否以 [ 开头
  if line.startsWith("["):
    # 检查是否为特殊情况：[xxx] name [xxx]
    let firstCloseBracket = line.find("]")
    if firstCloseBracket != -1 and firstCloseBracket + 1 < line.len:
      # 检查后面是否有空格，表示 [xxx] name 格式
      if line[firstCloseBracket + 1] == ' ':
        let nextOpenBracket = line.find("[", firstCloseBracket)
        if nextOpenBracket != -1:
          extractedName = line[firstCloseBracket + 1 .. nextOpenBracket - 1].strip()
          return extractedName # 直接返回

    # 分割字符串为数组
    let parts = line.split("]")
    
    # 检查第一个部分是否为 [Rev 或 [rev
    if parts[0].toLowerAscii() == "[rev":
      # 如果是 Rev 开头，取第三个位置
      if parts.len > 2:
        extractedName = parts[2].strip(leading=true, chars={'['})
    else:
      # 否则取第二个位置
      if parts.len > 1:
        extractedName = parts[1].strip(leading=true, chars={'['})
  else:
    # 如果不是以 [ 开头，寻找 _ 前的部分
    let underscorePos = line.find('_')
    if underscorePos != -1:
      extractedName = line[0..<underscorePos]
  
  # 最后去除可能的前后空格
  return extractedName.strip()

# findMatchingRule 现在直接使用 extractAnimeName
# proc findMatchingRule*(title: string): string = # 旧签名: proc findMatchingRule*(title: string, rules: RuleSet): string
#   ## 使用新的逻辑从文件夹名 (title) 中提取番剧名。
#   return extractAnimeName(title)

# loadRules 函数已删除

# 全局变量和常量定义
var
  base_path_str: string    # 基础路径字符串，用于存放待处理的番剧文件夹
  anime_path_str: string   # 番剧目标路径字符串
  use_name_cn: bool = true # 是否使用中文名，默认为true

# --- 缓存更新函数 ---
proc updateAndSaveJsonCache*(
    jsonCacheToUpdate: var Table[string, utils.CachedSeasonInfo],
    season: bangumi_api.Season,
    bangumiEpisodes: bangumi_api.EpisodeList,
    originalMatchedLocalFiles: seq[utils.LocalFileInfo],
    videoExts: seq[string],
    subtitleExts: seq[string],
    sourceDir: string  # 添加源目录参数
  ) =
  let seasonIdStr = $season.id
  var episodesForJson = initTable[string, utils.CachedEpisodeInfo]()
  var usedLocalFiles = initHashSet[utils.LocalFileInfo]()
  var matchedEpisodeFiles = initTable[float, tuple[video: Option[utils.LocalFileInfo], subs: seq[utils.LocalFileInfo]]]()

  # Initialize matchedEpisodeFiles for all bangumi episodes
  for ep in bangumiEpisodes.data:
    matchedEpisodeFiles[ep.sort] = (video: none[utils.LocalFileInfo](), subs: newSeq[utils.LocalFileInfo]())

  # Pass 1: Match Integer Episodes (>= 1)
  for ep in bangumiEpisodes.data:
    if abs(ep.sort - round(ep.sort)) < 0.001 and ep.sort >= 1.0: # Check if it's an integer >= 1
      let bangumiEpNum = ep.sort
      for localFile in originalMatchedLocalFiles:
        if localFile notin usedLocalFiles:
          let localEpNumOpt = utils.extractEpisodeNumberFromName(localFile.nameOnly) # Returns Option[float]
          if localEpNumOpt.isSome and abs(localEpNumOpt.get() - bangumiEpNum) < 0.001: # .get() is float, bangumiEpNum is float
            let lowerExt = localFile.ext.toLower()
            if lowerExt in videoExts:
              if matchedEpisodeFiles[bangumiEpNum].video.isNone:
                matchedEpisodeFiles[bangumiEpNum].video = some(localFile)
                usedLocalFiles.incl(localFile)
            elif subtitleExts.anyIt(lowerExt.endsWith(it)):
              matchedEpisodeFiles[bangumiEpNum].subs.add(localFile)
              usedLocalFiles.incl(localFile)

  # Pass 2: Match Float Episodes or Special Integer Episodes (e.g., 0, 0.5, 20.5)
  for ep in bangumiEpisodes.data:
    let isFloatEp = abs(ep.sort - round(ep.sort)) >= 0.001
    let isSpecialIntEp = ep.sort == 0.0 # Add other special integers if needed, e.g. ep.sort < 1.0
    if isFloatEp or isSpecialIntEp:
      let bangumiEpNum = ep.sort
      for localFile in originalMatchedLocalFiles:
        if localFile notin usedLocalFiles:
          let localEpNumOpt = utils.extractEpisodeNumberFromName(localFile.nameOnly)
          if localEpNumOpt.isSome and abs(localEpNumOpt.get() - bangumiEpNum) < 0.001:
            let lowerExt = localFile.ext.toLower()
            if lowerExt in videoExts:
              if matchedEpisodeFiles[bangumiEpNum].video.isNone: # Check if not already matched by integer pass (unlikely for same ep.sort)
                matchedEpisodeFiles[bangumiEpNum].video = some(localFile)
                usedLocalFiles.incl(localFile)
            elif subtitleExts.anyIt(lowerExt.endsWith(it)):
              # Check if not already matched by integer pass (unlikely for same ep.sort)
              var alreadyAdded = false
              for existingSub in matchedEpisodeFiles[bangumiEpNum].subs:
                if existingSub.fullPath == localFile.fullPath:
                  alreadyAdded = true
                  break
              if not alreadyAdded:
                matchedEpisodeFiles[bangumiEpNum].subs.add(localFile)
                usedLocalFiles.incl(localFile)
  
  # Fallback: Assign remaining local files sequentially to remaining Bangumi episodes
  # This part is simplified for now: it will try to fill gaps if an episode has neither video nor subs from precise passes.
  var remainingLocalVideos = originalMatchedLocalFiles.filter(proc (f: utils.LocalFileInfo): bool =
    f.ext.toLower() in videoExts and f notin usedLocalFiles)
  var remainingLocalSubtitles = originalMatchedLocalFiles.filter(proc (f: utils.LocalFileInfo): bool =
    subtitleExts.anyIt(f.ext.toLower().endsWith(it)) and f notin usedLocalFiles)
  
  remainingLocalVideos.sort(utils.naturalCompare)
  remainingLocalSubtitles.sort(utils.naturalCompare)

  var videoSeqIdx = 0
  var subSeqIdx = 0

  # Iterate through Bangumi episodes sorted by 'sort' to ensure sequential assignment is somewhat logical
  var sortedBangumiEps = bangumiEpisodes.data
  sortedBangumiEps.sort(proc(a,b: bangumi_api.Episode): int = cmp(a.sort, b.sort))

  for ep in sortedBangumiEps:
    var currentMatch = matchedEpisodeFiles.getOrDefault(ep.sort) # Should always exist due to initialization

    if currentMatch.video.isNone and videoSeqIdx < remainingLocalVideos.len:
      currentMatch.video = some(remainingLocalVideos[videoSeqIdx])
      usedLocalFiles.incl(remainingLocalVideos[videoSeqIdx]) # Mark as used by fallback
      videoSeqIdx += 1
    
    # Try to assign remaining subtitles if no subs were found for this episode yet
    # This is a simple sequential assignment; more sophisticated logic might be needed if subs can belong to multiple episodes
    if currentMatch.subs.len == 0 and subSeqIdx < remainingLocalSubtitles.len:
      # Heuristic: if a video was found (either precise or fallback), try to match subtitle name (excluding episode)
      var assignedSub = false
      if currentMatch.video.isSome and subSeqIdx < remainingLocalSubtitles.len :
          let videoBaseName = utils.getBaseNameWithoutEpisode(currentMatch.video.get().nameOnly)
          let subBaseName = utils.getBaseNameWithoutEpisode(remainingLocalSubtitles[subSeqIdx].nameOnly)
          if videoBaseName == subBaseName:
              currentMatch.subs.add(remainingLocalSubtitles[subSeqIdx])
              usedLocalFiles.incl(remainingLocalSubtitles[subSeqIdx])
              inc(subSeqIdx)
              assignedSub = true
      
      if not assignedSub and subSeqIdx < remainingLocalSubtitles.len: # If no video or base name didn't match, just assign next sub
          currentMatch.subs.add(remainingLocalSubtitles[subSeqIdx])
          usedLocalFiles.incl(remainingLocalSubtitles[subSeqIdx])
          inc(subSeqIdx)
          
    matchedEpisodeFiles[ep.sort] = currentMatch # Update the table with fallback assignments

  # Construct episodesForJson using the results from matchedEpisodeFiles
  for ep in bangumiEpisodes.data: # Iterate in original order or sorted by API if that's preferred for JSON output
    let epKey = utils.formatEpisodeNumber(ep.sort, bangumiEpisodes.total)
    let filesForEp = matchedEpisodeFiles.getOrDefault(ep.sort) # Should exist

    var episodeNameOnlyOpt: Option[string] = none[string]()
    var episodeVideoExtOpt: Option[string] = none[string]()
    var episodeSubtitleExtsSeq: seq[string] = @[]

    if filesForEp.video.isSome:
      let videoInfo = filesForEp.video.get()
      # Store the original nameOnly of the matched video file for rename reference
      episodeNameOnlyOpt = some(videoInfo.nameOnly)
      episodeVideoExtOpt = some(videoInfo.ext)
    elif filesForEp.subs.len > 0: # If no video, try to use first sub's nameOnly
      episodeNameOnlyOpt = some(filesForEp.subs[0].nameOnly)
    # If neither video nor subs, episodeNameOnlyOpt remains none

    if filesForEp.subs.len > 0:
      let baseNameForComparisonOpt = if filesForEp.video.isSome:
                                       some(utils.getBaseNameWithoutEpisode(filesForEp.video.get().nameOnly))
                                     elif filesForEp.subs.len > 0: # If no video, use first sub's base name
                                       some(utils.getBaseNameWithoutEpisode(filesForEp.subs[0].nameOnly))
                                     else:
                                       none[string]()

      for subFile in filesForEp.subs:
        # 原始扩展名更安全，尤其是对于复合语言代码
        let originalSubExt = subFile.ext
        # 使用视频文件名作为第二个参数，确保语言标记被正确保留
        let videoBaseName = if filesForEp.video.isSome: filesForEp.video.get().nameOnly else: ""
        let cleanSubExt = utils.getCleanSubtitleExtension(originalSubExt, videoBaseName)
        
        # 记录字幕扩展名处理
        logDebug(fmt"字幕扩展名处理: 原始='{originalSubExt}', 清理后='{cleanSubExt}'")
        
        # 对于复合语言代码的特殊处理
        if originalSubExt.toLower().contains(".scjp") or 
           originalSubExt.toLower().contains(".tcjp") or 
           originalSubExt.toLower().contains(".sccn") or 
           originalSubExt.toLower().contains(".tccn"):
          
          logDebug(fmt"检测到复合语言代码: '{originalSubExt}'")
          episodeSubtitleExtsSeq.add(originalSubExt) # 保留原始扩展名
        else:
          episodeSubtitleExtsSeq.add(cleanSubExt) # 使用清理后的字幕扩展名，保留语言代码但移除其他部分
        
        let rawSubFileBaseName = utils.getBaseNameWithoutEpisode(subFile.nameOnly)
        let cleanedSubFileBaseName = utils.getCleanedBaseName(rawSubFileBaseName)
        if baseNameForComparisonOpt.isSome:
          # 此处 baseNameForComparisonOpt.get() 已经是移除了集数的基础名
          let cleanedBaseNameToCompare = utils.getCleanedBaseName(baseNameForComparisonOpt.get())
          if cleanedSubFileBaseName != cleanedBaseNameToCompare:
            # 此警告现在应该不会出现，因为比较的是清理后的基础名
            stderr.writeLine fmt"警告: 番剧 {seasonIdStr} 剧集 {epKey} (sort: {ep.sort}) 的字幕文件 '{subFile.fullPath}' 的清理后基础名 ('{cleanedSubFileBaseName}') 与已确定的视频/主字幕的清理后基础文件名 ('{cleanedBaseNameToCompare}') 不一致。"
    
    episodesForJson[epKey] = utils.CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      nameOnly: episodeNameOnlyOpt, # 存储视频文件（或首个字幕文件）的原始 nameOnly，用于后续重命名时的基础名匹配
      videoExt: episodeVideoExtOpt,
      subtitleExts: episodeSubtitleExtsSeq # 存储与此剧集匹配的所有字幕文件的原始完整后缀
    )

  let seasonInfoEntry = utils.CachedSeasonInfo(
    bangumiSeasonId: season.id,
    bangumiSeasonName: season.name,
    totalBangumiEpisodes: bangumiEpisodes.total,
    episodes: episodesForJson
  )
  jsonCacheToUpdate[seasonIdStr] = seasonInfoEntry

const
  cacheFile = "cache/cache.csv"       # CSV 缓存文件名，存储基础配置和番剧名到ID的映射
  jsonCacheFile = "cache/cache.json"  # JSON 缓存文件名，存储番剧的详细剧集信息
  defaultBasePath = "."               # 默认的基础路径
  defaultAnimePath = "./anime"        # 默认的番剧目标路径

  videoExts: seq[string] = @[".mkv", ".mp4", ".avi", ".mov", ".flv", ".rmvb", ".wmv", ".ts", ".webm"] # 支持的视频文件后缀
  subtitleExts: seq[string] = @[".ass", ".ssa", ".srt", ".sub", ".vtt", 
                               ".scjp.ass", ".tcjp.ass", ".sccn.ass", ".tccn.ass",
                               ".sc.ass", ".tc.ass", ".jp.ass", ".en.ass",
                               ".scjp.srt", ".tcjp.srt", ".sccn.srt", ".tccn.srt"] # 支持的字幕文件后缀

# --- 命令行与配置处理 ---

proc parseCmdLineArgs(): (string, string, bool) =
  ## 解析命令行参数。
  ## 返回: (基础路径, 番剧路径, 是否使用中文名)
  var basePath = defaultBasePath
  var animePath = defaultAnimePath
  var nameType = true  # 默认使用name_cn

  let params = commandLineParams()
  if params.len >= 1:
    basePath = params[0]  # 第一个参数为basepath
  if params.len >= 2:
    animePath = params[1]  # 第二个参数为animepath
  if params.len >= 3:
    nameType = params[2] == "1"  # 1使用name_cn，0使用name

  return (basePath, animePath, nameType)

proc initializeConfig() =
  ## 初始化程序配置 (base_path_str, anime_path_str, use_name_cn)。
  ## 首先尝试从缓存文件读取配置，如果不存在则使用命令行参数。
  
  # 首先检查缓存文件是否存在，如果存在则从中读取配置
  if fileExists(cacheFile):
    try:
      let f = open(cacheFile, fmRead)
      defer: f.close()
      
      # 从第一行读取配置
      if not f.endOfFile():
        let configLine = f.readLine()
        let configParts = configLine.split(',')
        
        if configParts.len >= 3:
          base_path_str = configParts[0]
          anime_path_str = configParts[1]
          use_name_cn = configParts[2] == "1"
          # 读取缓存成功，提前返回
          
          # 确保 cache 目录存在
          try:
            createDir(parentDir(cacheFile))
          except OSError as e:
            stderr.writeLine fmt"警告: 创建缓存目录 '{parentDir(cacheFile)}' 失败: {e.msg}. 缓存功能可能受影响。"
          
          return
    except IOError as e:
      stderr.writeLine fmt"警告: 读取缓存文件 '{cacheFile}' 失败: {e.msg}，将使用命令行参数"

  # 如果缓存文件不存在或读取失败，则使用命令行参数
  let (cmdBasePath, cmdAnimePath, cmdNameType) = parseCmdLineArgs()

  base_path_str = cmdBasePath
  anime_path_str = cmdAnimePath
  use_name_cn = cmdNameType

  # 确保 cache 目录存在，因为后续操作会读写缓存文件
  try:
    createDir(parentDir(cacheFile))
  except OSError as e:
    stderr.writeLine fmt"警告: 创建缓存目录 '{parentDir(cacheFile)}' 失败: {e.msg}. 缓存功能可能受影响。"
  
  # 写入配置到缓存文件第一行
  try:
    let f = open(cacheFile, fmWrite)
    defer: f.close()
    let nameTypeValue = if use_name_cn: "1" else: "0"
    f.writeLine base_path_str & "," & anime_path_str & "," & nameTypeValue
  except IOError as e:
    stderr.writeLine fmt"警告: 写入配置到缓存文件 '{cacheFile}' 失败: {e.msg}"

proc processSampleData(
    sampleFolderName: string,
    csvCache: var Table[string, utils.CsvCacheEntry],
    jsonCache: var Table[string, utils.CachedSeasonInfo]
  ) =
  ## 处理单个本地番剧文件夹：匹配规则、获取信息、更新缓存。
  var seasonToProcessOpt: Option[bangumi_api.Season] = none(bangumi_api.Season)
  var forceApiFetchForEpisodes = false

  if csvCache.hasKey(sampleFolderName):
    let entry = csvCache[sampleFolderName]
    seasonToProcessOpt = some(bangumi_api.Season(id: entry.bangumiSeasonId, name: entry.bangumiSeasonNameCache))
    if not jsonCache.hasKey($entry.bangumiSeasonId):
      forceApiFetchForEpisodes = true
  else:
    let matchedName = extractAnimeName(sampleFolderName) # 直接调用 extractAnimeName
    if matchedName.len > 0:
      let seasonOptFromApi = bangumi_api.getSeason(matchedName, use_name_cn)
      if seasonOptFromApi.isSome:
        seasonToProcessOpt = seasonOptFromApi
        let s = seasonToProcessOpt.get()
        utils.appendToCacheCsv(sampleFolderName, s.id, s.name, cacheFile)
        csvCache[sampleFolderName] = utils.CsvCacheEntry(
          originalFolderName: sampleFolderName,
          bangumiSeasonNameCache: s.name,
          bangumiSeasonId: s.id
        )
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
  var bangumiEpisodeList: bangumi_api.EpisodeList

  if not forceApiFetchForEpisodes and jsonCache.hasKey(currentSeasonIdStr):
    let cachedSeasonDetails = jsonCache[currentSeasonIdStr]
    if cachedSeasonDetails.episodes.len > 0:
      var episodesData = newSeq[bangumi_api.Episode]()
      for _, epInfo in cachedSeasonDetails.episodes.pairs:
        episodesData.add(bangumi_api.Episode(sort: epInfo.bangumiSort, name: epInfo.bangumiName))
      episodesData.sort(proc(a,b: bangumi_api.Episode): int = cmp(a.sort, b.sort))
      bangumiEpisodeList = bangumi_api.EpisodeList(total: cachedSeasonDetails.totalBangumiEpisodes, data: episodesData)
    else:
      forceApiFetchForEpisodes = true
  
  if forceApiFetchForEpisodes or not jsonCache.hasKey(currentSeasonIdStr) or jsonCache[currentSeasonIdStr].episodes.len == 0 : # 确保在需要时获取
    let episodesOptFromApi = bangumi_api.getEpisodes(currentSeason.id, use_name_cn)
    if episodesOptFromApi.isNone:
      stderr.writeLine fmt"错误: 无法获取番剧 ID '{currentSeason.id}' ({currentSeason.name}) 的剧集列表。"
      return
    bangumiEpisodeList = episodesOptFromApi.get()
  
  let localFilesPath = base_path_str / sampleFolderName
  var matchedLocalFiles = newSeq[utils.LocalFileInfo]()

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

        # 调试日志：记录原始文件信息
        logDebug(fmt"处理文件: 原始路径='{item.path}', 分解后：dir='{originalDir}', name='{originalName}', ext='{originalExt}'")
        
        let extToCompareWith = currentExt # Explicitly copy currentExt
        if subtitleExts.anyIt(utils.eqIgnoresCase(it, extToCompareWith)): # 如果当前 ext 是一个基本的字幕后缀 (e.g., .ass, .srt)
            # 先检查完整路径是否已包含复合语言代码
            if originalName.contains(".scjp") or originalName.contains(".tcjp") or
               originalName.contains(".sccn") or originalName.contains(".tccn"):
                logDebug(fmt"检测到复合语言代码: '{originalName}{originalExt}'")
                
                # 从完整路径中提取正确的名称和扩展名
                let dotPos = originalName.rfind(".")
                if dotPos != -1:
                    let langPart = originalName[dotPos+1 .. ^1]
                    currentName = originalName[0 ..< dotPos]
                    currentExt = "." & langPart & originalExt
                    logDebug(fmt"复合语言处理: 名称='{currentName}', 扩展名='{currentExt}'")
            else:
                # 原有的语言代码处理逻辑
                let nameParts = currentName.split('.')
                if nameParts.len > 1:
                    # 检查 name 的最后一部分是否像语言代码
                    # (e.g., "sc", "tc", "en", "scjp", "tcjp", "chs", "cht", "jpn")
                    let potentialLangPart = nameParts[^1]
                    
                    # 启发式判断语言代码: 2-5个字符，主要是字母，可能包含数字或连字符
                    var isLangCode = false
                    if potentialLangPart.len >= 2 and potentialLangPart.len <= 5:
                        isLangCode = potentialLangPart.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')
                    elif potentialLangPart.len > 5 and potentialLangPart.contains('-'): # 允许更长的带连字符的，如 zh-Hans
                        isLangCode = potentialLangPart.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')

                    # 额外检查是否为已知语言代码
                    if isCommonLanguageCode(potentialLangPart):
                        isLangCode = true
                        logDebug(fmt"检测到已知语言代码: '{potentialLangPart}'")

                    if isLangCode:
                        # 确认这个 langPart 不是一个数字（避免误判文件名中的数字为语言代码）
                        var allDigits = true
                        for c in potentialLangPart:
                            if not c.isDigit:
                                allDigits = false
                                break
                        if not allDigits:
                            var tempCurrentExt = "." & potentialLangPart & currentExt
                            var tempCurrentName = nameParts[0 .. ^2].join(".")
                            
                            if tempCurrentName.endsWith("."):
                                tempCurrentName = tempCurrentName[0 .. ^2]
                            if tempCurrentName.len == 0 and nameParts.len == 2:
                               tempCurrentName = nameParts[0]
                            
                            logDebug(fmt"处理语言代码: 原始='{currentName}{currentExt}' -> 新='{tempCurrentName}{tempCurrentExt}'")
                            currentExt = tempCurrentExt # Assign back to the original var
                            currentName = tempCurrentName # Assign back to the original var
        
        # 记录最终处理结果
        logDebug(fmt"文件处理结果: 名称='{currentName}', 扩展名='{currentExt}'")

        # 如果文件名是 "video.mkv" currentName="video", currentExt=".mkv"
        # 如果文件名是 "sub.sc.ass"
        #   - splitFile -> name="sub.sc", ext=".ass" -> 上述逻辑后: currentName="sub", currentExt=".sc.ass"
        #   - splitFile -> name="sub", ext=".sc.ass" (较新Nim) -> 上述逻辑不执行, currentName="sub", currentExt=".sc.ass" (正确)
        
        matchedLocalFiles.add(utils.LocalFileInfo(
          nameOnly: currentName,
          ext: currentExt,
          fullPath: item.path
        ))

        count += 1
  else:
    stderr.writeLine fmt"警告: 本地文件夹 '{localFilesPath}' 不存在或不是一个目录。"

  updateAndSaveJsonCache(jsonCache, currentSeason, bangumiEpisodeList, matchedLocalFiles, videoExts, subtitleExts, localFilesPath) # 传入localFilesPath
  
# --- 主逻辑 ---
initializeConfig() # 初始化配置

var csvCacheGlobal = utils.readCsvCacheEntries(cacheFile)
var jsonCacheGlobal = utils.loadJsonCache(jsonCacheFile)

let samples = utils.readDir(base_path_str)

if samples.len == 0:
  let pathType = if base_path_str == defaultBasePath: "默认基础路径" else: "指定基础路径"
  stderr.writeLine fmt"提示: 在{pathType} '{base_path_str}' 下未找到任何番剧文件夹。请确保文件夹存在或通过命令行参数指定。"

for sample in samples:
  processSampleData(sample, csvCacheGlobal, jsonCacheGlobal)

utils.saveJsonCache(jsonCacheFile, jsonCacheGlobal) # 保存更新后的JSON缓存

let finalJsonCacheForRename = utils.loadJsonCache(jsonCacheFile) # 加载最终用于重命名的JSON缓存

if samples.len > 0:
  try:
    if not dirExists(anime_path_str):
      createDir(anime_path_str) # 创建总的番剧目标目录（如果不存在）
  except OSError as e:
    stderr.writeLine fmt"严重错误: 创建番剧目标根目录 '{anime_path_str}' 失败: {e.msg}. 硬链接和重命名操作可能失败。"

for originalFolderNameInBase in samples:
  var successfulRename = false
  var finalAnimePathName = ""

  let sourceSeasonDir = base_path_str / originalFolderNameInBase
  var targetSeasonDirForLinkAndRename = anime_path_str / originalFolderNameInBase # Initial target

  if not dirExists(sourceSeasonDir):
    stderr.writeLine fmt"警告: 源文件夹 '{sourceSeasonDir}' 不存在或不是目录，跳过。"
    echo fmt"{originalFolderNameInBase} => 【X】"
    continue

  utils.createDirectoryHardLinkRecursive(sourceSeasonDir, targetSeasonDirForLinkAndRename) # 创建硬链接

  if csvCacheGlobal.hasKey(originalFolderNameInBase):
    let csvEntry = csvCacheGlobal[originalFolderNameInBase]
    let seasonIdStr = $csvEntry.bangumiSeasonId
    if finalJsonCacheForRename.hasKey(seasonIdStr):
      let seasonInfo = finalJsonCacheForRename[seasonIdStr]
      var validationStatus = ""
      var actualVideoFilesCountInLinkedDir = 0
      var filesInLinkedDir: seq[string] = @[]
      var linkedLocalFiles = newSeq[utils.LocalFileInfo]()

      if dirExists(targetSeasonDirForLinkAndRename):
        for itemEntry in walkDir(targetSeasonDirForLinkAndRename):
          if itemEntry.kind == pcFile:
            let filename = itemEntry.path.extractFilename()
            filesInLinkedDir.add(filename)
            
            # 构建硬链接目录中的文件信息，用于后续处理
            # 对于复合语言代码字幕，不使用splitFile处理，避免扩展名被错误分割
            if filename.toLower().contains(".scjp.") or filename.toLower().contains(".tcjp.") or
               filename.toLower().contains(".sccn.") or filename.toLower().contains(".tccn."):
              
              logDebug(fmt"处理anime目录中的复合语言代码字幕: '{filename}'")
              
              # 手动分离文件名和扩展名
              let dotPos = filename.rfind(".")
              if dotPos != -1:
                # 查找复合语言代码的位置
                var extStartPos = -1
                for langCode in @[".scjp.", ".tcjp.", ".sccn.", ".tccn."]:
                  let lcPos = filename.toLower().find(langCode)
                  if lcPos != -1:
                    extStartPos = lcPos
                    break
                
                if extStartPos != -1:
                  let nameOnly = filename[0 ..< extStartPos]
                  let ext = filename[extStartPos .. ^1]
                  logDebug(fmt"复合语言字幕拆分: 名称='{nameOnly}', 扩展名='{ext}'")
                  linkedLocalFiles.add(utils.LocalFileInfo(
                    nameOnly: nameOnly,
                    ext: ext,
                    fullPath: itemEntry.path
                  ))
                else:
                  # 回退到普通处理
                  let (dirPath, nameOnly, ext) = splitFile(itemEntry.path)
                  linkedLocalFiles.add(utils.LocalFileInfo(
                    nameOnly: nameOnly,
                    ext: ext,
                    fullPath: itemEntry.path
                  ))
              else:
                # 没有扩展名，保持原样
                linkedLocalFiles.add(utils.LocalFileInfo(
                  nameOnly: filename,
                  ext: "",
                  fullPath: itemEntry.path
                ))
            else:
              # 普通文件使用splitFile
              let (dirPath, nameOnly, ext) = splitFile(itemEntry.path)
              linkedLocalFiles.add(utils.LocalFileInfo(
                nameOnly: nameOnly,
                ext: ext,
                fullPath: itemEntry.path
              ))
            
            # 检查是否是视频文件
            let fileExt = extractFilename(itemEntry.path).toLower()
            let isVideo = videoExts.anyIt(fileExt.endsWith(it))
            if isVideo:
              actualVideoFilesCountInLinkedDir += 1
      
      # 现在对硬链接目录中的文件进行处理
      var linkedMatchedEpisodeFiles = initTable[float, tuple[video: Option[utils.LocalFileInfo], subs: seq[utils.LocalFileInfo]]]()
      
      # 为所有剧集初始化匹配表
      for episodeKey, episodeInfo in seasonInfo.episodes:
        linkedMatchedEpisodeFiles[episodeInfo.bangumiSort] = (video: none[utils.LocalFileInfo](), subs: newSeq[utils.LocalFileInfo]())
      
      # 匹配视频和字幕文件
      for file in linkedLocalFiles:
        let epNumOpt = utils.extractEpisodeNumberFromName(file.nameOnly)
        if epNumOpt.isSome:
          let epNum = epNumOpt.get()
          if linkedMatchedEpisodeFiles.hasKey(epNum):
            # 对于复合语言代码字幕文件的特殊处理
            if file.ext.toLower().contains(".scjp.") or file.ext.toLower().contains(".tcjp.") or
               file.ext.toLower().contains(".sccn.") or file.ext.toLower().contains(".tccn."):
              logDebug(fmt"匹配复合语言字幕: EP={epNum}, 文件='{file.fullPath}'")
              linkedMatchedEpisodeFiles[epNum].subs.add(file)
            # 普通文件处理
            elif file.ext.toLower() in videoExts:
              if linkedMatchedEpisodeFiles[epNum].video.isNone:
                linkedMatchedEpisodeFiles[epNum].video = some(file)
            elif subtitleExts.anyIt(file.ext.toLower().endsWith(it)):
              linkedMatchedEpisodeFiles[epNum].subs.add(file)
      
      # 现在对硬链接目录中的每集视频和字幕进行处理（重命名）
      for epNum, filesForEp in linkedMatchedEpisodeFiles.pairs:
        if filesForEp.video.isSome and filesForEp.subs.len > 0:
          processEpisodeFiles(targetSeasonDirForLinkAndRename, epNum, filesForEp.video, filesForEp.subs)
      
      let expectedTotalEpisodes = seasonInfo.totalBangumiEpisodes
      var skipRenameDueToValidationError = false

      if expectedTotalEpisodes < actualVideoFilesCountInLinkedDir:
        stderr.writeLine fmt"警告: 番剧 '{originalFolderNameInBase}' (ID: {seasonIdStr}) 本地视频文件过多。预期: {expectedTotalEpisodes}, 实际: {actualVideoFilesCountInLinkedDir}。跳过重命名。"
        validationStatus = "【X-校验失败-文件过多】"
        finalAnimePathName = originalFolderNameInBase # Keep original name if skipping rename
        successfulRename = false # Explicitly mark as not successfully "renamed to new standard"
        skipRenameDueToValidationError = true
      elif actualVideoFilesCountInLinkedDir < expectedTotalEpisodes:
         stderr.writeLine fmt"提示: 番剧 '{originalFolderNameInBase}' (ID: {seasonIdStr}) 本地视频文件数量不足。预期: {expectedTotalEpisodes}, 实际: {actualVideoFilesCountInLinkedDir}。将尝试按顺序重命名已有文件。"
         # validationStatus = "【注意-文件不齐】" # Optional: User prefers no failure mark here

      if not skipRenameDueToValidationError:
        utils.renameFilesBasedOnCache(targetSeasonDirForLinkAndRename, seasonInfo, filesInLinkedDir)
        
        let desiredSeasonFolderName = utils.sanitizeFilename(seasonInfo.bangumiSeasonName)
        var finalPathForValidation = targetSeasonDirForLinkAndRename
        
        if dirExists(targetSeasonDirForLinkAndRename):
          if targetSeasonDirForLinkAndRename != (anime_path_str / desiredSeasonFolderName):
            let potentialNewPath = anime_path_str / desiredSeasonFolderName
            try:
              moveDir(targetSeasonDirForLinkAndRename, potentialNewPath)
              successfulRename = true
              finalAnimePathName = desiredSeasonFolderName
              finalPathForValidation = potentialNewPath
            except OSError as e:
              stderr.writeLine fmt"  错误: 重命名文件夹 '{targetSeasonDirForLinkAndRename}' 到 '{potentialNewPath}' 失败: {e.msg}"
              if dirExists(targetSeasonDirForLinkAndRename): # If move failed, but original linked dir exists
                 finalAnimePathName = originalFolderNameInBase
              else: # Original linked dir also gone somehow
                 finalAnimePathName = ""
              successfulRename = false
          else: # Name is already correct
            successfulRename = true
            finalAnimePathName = desiredSeasonFolderName
            finalPathForValidation = targetSeasonDirForLinkAndRename
        else: # Linking failed to create targetSeasonDirForLinkAndRename initially
           stderr.writeLine fmt"错误: 硬链接目标目录 '{targetSeasonDirForLinkAndRename}' 未创建。"
           finalAnimePathName = ""
           successfulRename = false

        # Post-rename/move validation (directory existence)
        if successfulRename and finalAnimePathName.len > 0 and not dirExists(finalPathForValidation):
            stderr.writeLine fmt"错误: 番剧目录 '{finalPathForValidation}' 在重命名/移动后丢失。"
            validationStatus = if validationStatus.len > 0: validationStatus & " " else: "" & "【X-目录丢失】"
            successfulRename = false # Mark as overall failure if dir is gone
            finalAnimePathName = originalFolderNameInBase # Revert to original for output if new path is lost
        elif not successfulRename and finalAnimePathName.len == 0 and not dirExists(targetSeasonDirForLinkAndRename):
            # If linking failed AND rename wasn't even attempted or failed to set a name
            validationStatus = if validationStatus.len > 0: validationStatus & " " else: "" & "【X-处理失败】"


      if finalAnimePathName.len > 0 : # Covers successful rename or skipped rename with original name
        echo fmt"{originalFolderNameInBase} => {finalAnimePathName}{validationStatus}"
      else: # General failure case
        echo fmt"{originalFolderNameInBase} => 【X】{validationStatus}"
        
    else:
      stderr.writeLine fmt"警告: JSON缓存中未找到ID '{seasonIdStr}' (来自 '{originalFolderNameInBase}')，无法确定最终名称。"
      echo fmt"{originalFolderNameInBase} => 【X】"
  else:
    stderr.writeLine fmt"警告: CSV缓存中未找到 '{originalFolderNameInBase}'，无法处理。"
    echo fmt"{originalFolderNameInBase} => 【X】"
