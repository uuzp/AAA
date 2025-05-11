import std/[strformat,strutils, tables, os,options, algorithm, sequtils, re, streams, sets, math] # Added math
# import ./core/types       # Types will be defined locally or in other modules
# import ./core/utils_string # Functions moved to utils.nim or inlined
# import ./core/rule_matcher   # Functions will be moved or inlined
# import ./core/cache_manager # Function will be moved or inlined

import ./bangumi_api      # For Season, EpisodeList, getSeason, getEpisodes etc.
import ./utils            # For LocalFileInfo, file/dir operations, cache I/O, readDir, cache types

# --- 类型定义 (从原 core/types.nim 移动过来) ---
type
  Config* = object                   ## 程序配置对象 (主要用于命令行参数)
    basePath*: string                # 基础路径
    animePath*: string               # 番剧目标路径

  RuleConfig* = object               ## 匹配规则配置
    groups*: seq[string]             # 用于初步筛选的字幕组或关键词列表
    pattern*: string                 # 用于提取番剧名称的正则表达式或普通字符串

  RuleSet* = seq[RuleConfig]         ## 规则配置集合

# --- 规则匹配相关函数 (从原 core/rule_matcher.nim 移动过来) ---
proc extractMatch*(s: string, pattern: string): string =
  ## 使用正则表达式从字符串 s 中提取第一个匹配项。
  var matches: array[1, string]
  if s.find(re(pattern), matches) != -1:
    return matches[0]
  return ""

proc isPlainString*(s: string): bool =
  ## 检查字符串是否不包含常见的正则表达式元字符。
  const regexMetaChars = {'[', ']', '(', ')', '{', '}', '?', '*', '+', '|', '^', '$', '.', '\\'}
  for c in s:
    if c in regexMetaChars:
      return false
  return true

proc matchRule*(title: string, rule: RuleConfig): Option[string] =
  ## 根据单条规则匹配标题。
  if not rule.groups.anyIt(it in title):
    return none(string)
  
  if isPlainString(rule.pattern):
    return some(rule.pattern)
  
  let extracted = extractMatch(title, rule.pattern)
  if extracted.len > 0:
    return some(extracted)
  return none(string)

proc findMatchingRule*(title: string, rules: RuleSet): string =
  ## 在规则集中查找第一个与标题匹配的规则，并返回匹配结果。
  for rule in rules:
    let optMatched = matchRule(title, rule)
    if optMatched.isSome:
      return optMatched.get()
  return ""

proc loadRules*(filename: string): RuleSet =
  ## 从指定文件加载匹配规则。
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

# 全局变量和常量定义
var
  base_path_str: string    # 基础路径字符串，用于存放待处理的番剧文件夹
  anime_path_str: string   # 番剧目标路径字符串
  useCache: bool = true    # 是否使用缓存，默认为 true

# --- 缓存更新函数 (从原 core/cache_manager.nim 移动过来) ---
proc updateAndSaveJsonCache*(
    jsonCacheToUpdate: var Table[string, utils.CachedSeasonInfo],
    season: bangumi_api.Season,
    bangumiEpisodes: bangumi_api.EpisodeList,
    originalMatchedLocalFiles: seq[utils.LocalFileInfo],
    videoExts: seq[string],
    subtitleExts: seq[string]
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
          let localEpNumOpt = utils.extractEpisodeNumberFromName(localFile.nameOnly) # Returns Option[float]
          if localEpNumOpt.isSome and abs(localEpNumOpt.get() - bangumiEpNum) < 0.001: # .get() is float, bangumiEpNum is float
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
        episodeSubtitleExtsSeq.add(subFile.ext)
        let subFileBaseName = utils.getBaseNameWithoutEpisode(subFile.nameOnly)
        if baseNameForComparisonOpt.isSome and subFileBaseName != baseNameForComparisonOpt.get():
          stderr.writeLine fmt"警告: 番剧 {seasonIdStr} 剧集 {epKey} (sort: {ep.sort}) 的字幕文件 '{subFile.fullPath}' 的基础名 ('{subFileBaseName}') 与已确定的视频/主字幕基础文件名 ('{baseNameForComparisonOpt.get()}') 不一致。"
    
    episodesForJson[epKey] = utils.CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      nameOnly: episodeNameOnlyOpt, # This is the original nameOnly of video (or first sub if no video)
      videoExt: episodeVideoExtOpt,
      subtitleExts: episodeSubtitleExtsSeq
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

# proc readDir has been moved to utils.nim
proc processSampleData(
    sampleFolderName: string,
    rules: RuleSet,
    csvCache: var Table[string, utils.CsvCacheEntry], # Updated type
    jsonCache: var Table[string, utils.CachedSeasonInfo] # Updated type
  ) =
  ## 处理单个番剧样本目录。
  # echo fmt"处理番剧文件夹: '{sampleFolderName}'" # Removed
  var seasonToProcessOpt: Option[bangumi_api.Season] = none(bangumi_api.Season)
  var forceApiFetchForEpisodes = false

  if useCache and csvCache.hasKey(sampleFolderName):
    let entry = csvCache[sampleFolderName]
    seasonToProcessOpt = some(bangumi_api.Season(id: entry.bangumiSeasonId, name: entry.bangumiSeasonNameCache))
    if not jsonCache.hasKey($entry.bangumiSeasonId):
      forceApiFetchForEpisodes = true
  else:
    let matchedName = findMatchingRule(sampleFolderName, rules) # Updated call
    if matchedName.len > 0:
      let seasonOptFromApi = bangumi_api.getSeason(matchedName)
      if seasonOptFromApi.isSome:
        seasonToProcessOpt = seasonOptFromApi
        let s = seasonToProcessOpt.get()
        if useCache:
          utils.appendToCacheCsv(sampleFolderName, s.id, s.name, cacheFile)
          csvCache[sampleFolderName] = utils.CsvCacheEntry( # Updated type
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

  if useCache and not forceApiFetchForEpisodes and jsonCache.hasKey(currentSeasonIdStr):
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
    let episodesOptFromApi = bangumi_api.getEpisodes(currentSeason.id)
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

        let extToCompareWith = currentExt # Explicitly copy currentExt
        if subtitleExts.anyIt(utils.eqIgnoresCase(it, extToCompareWith)): # 如果当前 ext 是一个基本的字幕后缀 (e.g., .ass, .srt)
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
                        # currentExt is modified here, so extToCompareWith is not sufficient if currentExt is needed later with this new value
                        # However, the error is about declaration, not this modification.
                        # Let's assume the modification logic for currentExt and currentName is correct for now.
                        # The primary goal is to fix the "undeclared identifier" error.
                        # If this fixes it, we then need to ensure currentExt is used correctly after modification.
                        # The original logic used currentExt directly after this block.
                        var tempCurrentExt = "." & potentialLangPart & currentExt
                        var tempCurrentName = nameParts[0 .. ^2].join(".")
                        
                        if tempCurrentName.endsWith("."):
                            tempCurrentName = tempCurrentName[0 .. ^2]
                        if tempCurrentName.len == 0 and nameParts.len == 2:
                           tempCurrentName = nameParts[0]
                        
                        currentExt = tempCurrentExt # Assign back to the original var
                        currentName = tempCurrentName # Assign back to the original var


        # 如果文件名是 "video.mkv" currentName="video", currentExt=".mkv"
        # 如果文件名是 "sub.sc.ass"
        #   - splitFile -> name="sub.sc", ext=".ass" -> 上述逻辑后: currentName="sub", currentExt=".sc.ass"
        #   - splitFile -> name="sub", ext=".sc.ass" (较新Nim) -> 上述逻辑不执行, currentName="sub", currentExt=".sc.ass" (正确)
        
        matchedLocalFiles.add(utils.LocalFileInfo(
          nameOnly: currentName,
          ext: currentExt,
          fullPath: item.path
        ))

        # --- 开始补充修正 LocalFileInfo 的 nameOnly 和 ext ---
        var correctedName = matchedLocalFiles[^1].nameOnly
        var correctedExt = matchedLocalFiles[^1].ext
        var needsCorrection = false

        # 检查是否是字幕文件，并且 ext 看起来比基本后缀更复杂
        let lowerCorrectedExt = correctedExt.toLower() # 转为小写以便进行不区分大小写的比较
        for basicSubExt in subtitleExts:
            if lowerCorrectedExt.endsWith(basicSubExt.toLower()) and correctedExt.len > basicSubExt.len:
                needsCorrection = true
                break
        
        if needsCorrection:
            var actualExtPart = "" # 存储最终识别的纯扩展名，如 .srt, .sc.ass
            var namePrefixToRejoin = "" # 存储从复杂 ext 中剥离出来应合并回 nameOnly 的部分

            # 从后向前尝试匹配多部分字幕后缀的可能性
            # 优先级：.lang.basicExt (e.g. .sc.ass), then .basicExt (e.g. .srt)
            var matchedMultiPart = false
            for basicExt in subtitleExts: # .ass, .srt
                # 尝试匹配 .lang.basicExt
                # 这里的语言代码列表可以更完善
                let knownLangCodesForExt = @["sc", "tc", "jp", "eng", "chs", "cht", "gb", "big5", "scjp", "tcjp", "ger", "spa", "fre", "kor", "rus", "ita", "swe", "dan", "nor", "fin", "pol", "tur", "por", "ara", "hin", "vie", "tha", "ind", "may", "dut"]
                for langCode in knownLangCodesForExt:
                    let multiPartExt = "." & langCode & basicExt
                    if lowerCorrectedExt.endsWith(multiPartExt.toLower()):
                        actualExtPart = multiPartExt # 保留原始大小写的 multiPartExt
                        namePrefixToRejoin = correctedExt[0 .. ^(multiPartExt.len + 1)]
                        matchedMultiPart = true
                        break
                if matchedMultiPart: break
            
            if not matchedMultiPart:
                # 如果没有匹配到 .lang.basicExt，则只匹配 .basicExt
                for basicExt in subtitleExts:
                    if lowerCorrectedExt.endsWith(basicExt.toLower()):
                        actualExtPart = basicExt # 保留原始大小写的 basicExt
                        namePrefixToRejoin = correctedExt[0 .. ^(basicExt.len + 1)]
                        break
            
            if actualExtPart.len > 0: # 如果成功识别了扩展名部分
                correctedExt = actualExtPart
                if namePrefixToRejoin.len > 0:
                    correctedName = correctedName & namePrefixToRejoin
            # else: 扩展名部分无法按预期解析，保留原始 currentExt (可能已经是正确的，如 .mkv)
        
        # 清理 correctedName 末尾可能因拼接产生的点
        if correctedName.endsWith("."):
            correctedName = correctedName[0 .. ^2]

        matchedLocalFiles[^1].nameOnly = correctedName
        matchedLocalFiles[^1].ext = correctedExt
        # --- 结束补充修正 ---
        # echo fmt"调试(AAA.processSampleData): 文件 '{item.path}' 解析为 LocalFileInfo: nameOnly='{correctedName}', ext='{correctedExt}'" # DEBUG LOG REMOVED

        count += 1
  else:
    stderr.writeLine fmt"警告: 本地文件夹 '{localFilesPath}' 不存在或不是一个目录。"

  if useCache:
    updateAndSaveJsonCache(jsonCache, currentSeason, bangumiEpisodeList, matchedLocalFiles, videoExts, subtitleExts) # Updated call
  
# --- 主逻辑执行 ---
initializeConfig()

# echo "开始处理..." # Removed, too verbose for final output
let rules = loadRules("cache/fansub.rules") # Updated call

var csvCacheGlobal = if useCache: utils.readCsvCacheEntries(cacheFile) else: initTable[string, CsvCacheEntry]()
var jsonCacheGlobal = if useCache: utils.loadJsonCache(jsonCacheFile) else: initTable[string, CachedSeasonInfo]()

let samples = utils.readDir(base_path_str)

if samples.len == 0:
  let pathType = if base_path_str == defaultBasePath: "默认基础路径" else: "指定基础路径"
  stderr.writeLine fmt"提示: 在{pathType} '{base_path_str}' 下未找到任何番剧文件夹。请确保文件夹存在或通过 -b=<路径> 指定。"

for sample in samples:
  processSampleData(sample, rules, csvCacheGlobal, jsonCacheGlobal)

if useCache:
  utils.saveJsonCache(jsonCacheFile, jsonCacheGlobal)
  # echo fmt"JSON缓存已保存到 {jsonCacheFile}。" # Removed

  # echo "\n开始执行硬链接和重命名操作..." # Removed
  let finalJsonCacheForRename = utils.loadJsonCache(jsonCacheFile)

  if samples.len > 0:
    try:
      if not dirExists(anime_path_str):
        createDir(anime_path_str)
        # echo fmt"创建番剧目标根目录: {anime_path_str}" # Removed
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

    # echo fmt"\n处理原始文件夹: '{originalFolderNameInBase}' 进行硬链接和重命名" # Removed
    utils.createDirectoryHardLinkRecursive(sourceSeasonDir, targetSeasonDirForLinkAndRename)

    if csvCacheGlobal.hasKey(originalFolderNameInBase):
      let csvEntry = csvCacheGlobal[originalFolderNameInBase]
      let seasonIdStr = $csvEntry.bangumiSeasonId
      if finalJsonCacheForRename.hasKey(seasonIdStr):
        let seasonInfo = finalJsonCacheForRename[seasonIdStr]
        var validationStatus = ""
        var actualVideoFilesCountInLinkedDir = 0
        var filesInLinkedDir: seq[string] = @[]

        if dirExists(targetSeasonDirForLinkAndRename):
          for itemEntry in walkDir(targetSeasonDirForLinkAndRename):
            if itemEntry.kind == pcFile:
              filesInLinkedDir.add(itemEntry.path.extractFilename())
              if itemEntry.path.splitFile.ext.toLower() in videoExts:
                actualVideoFilesCountInLinkedDir += 1
        
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
  # echo "\n硬链接和重命名操作完成。" # Removed
else:
  # echo "所有处理完成（缓存未启用）。硬链接和重命名操作已跳过。" # Removed
  # If cache is not used, we can't rename, so all are effectively 【X】 for renaming part
  # However, the task implies processing even without cache for API calls, just no disk cache.
  # The output format is about the *final anime directory name*. If no renaming happens, it's an X.
  for sample in samples: # Need to iterate through samples if cache was off
    echo fmt"{sample} => 【X】"


# echo "程序执行完毕。" # Removed
