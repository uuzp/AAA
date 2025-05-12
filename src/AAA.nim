import std/[strformat, strutils, tables, os, options, algorithm, sequtils, sets, math, times]
import ./bangumi_api
import ./utils except logDebug
from ./utils import logDebug
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
  basePath: string    # 基础路径
  animePath: string   # 番剧目标路径
  useCnName: bool = true  # 是否使用中文名

# --- 缓存更新函数 ---
proc updateCache*(
    cache: var Table[string, utils.CachedSeasonInfo],
    season: bangumi_api.Season,
    episodes: bangumi_api.EpisodeList,
    localFiles: seq[utils.LocalFileInfo],
    videoExts: seq[string],
    subtitleExts: seq[string],
    sourceDir: string
  ) =
  # 更新并保存番剧缓存信息
  let seasonId = $season.id
  var episodesForJson = initTable[string, utils.CachedEpisodeInfo]()
  var usedFiles = initHashSet[utils.LocalFileInfo]()
  var matchedFiles = initTable[float, tuple[video: Option[utils.LocalFileInfo], subs: seq[utils.LocalFileInfo]]]()

  # 初始化匹配表
  for ep in episodes.data:
    matchedFiles[ep.sort] = (video: none[utils.LocalFileInfo](), subs: @[])

  # 第一轮：匹配整数集数(>=1)
  for ep in episodes.data:
    if abs(ep.sort - round(ep.sort)) < 0.001 and ep.sort >= 1.0:
      let epNum = ep.sort
      for file in localFiles:
        if file notin usedFiles:
          let fileEpOpt = utils.extractEpisodeNumber(file.nameOnly)
          if fileEpOpt.isSome and abs(fileEpOpt.get() - epNum) < 0.001:
            let ext = file.ext.toLower()
            if ext in videoExts:
              if matchedFiles[epNum].video.isNone:
                matchedFiles[epNum].video = some(file)
                usedFiles.incl(file)
            elif subtitleExts.anyIt(ext.endsWith(it)):
              matchedFiles[epNum].subs.add(file)
              usedFiles.incl(file)

  # 第二轮：匹配小数集数或特殊集数(0, 0.5等)
  for ep in episodes.data:
    let isFloat = abs(ep.sort - round(ep.sort)) >= 0.001
    let isSpecial = ep.sort == 0.0
    
    if isFloat or isSpecial:
      let epNum = ep.sort
      for file in localFiles:
        if file notin usedFiles:
          let fileEpOpt = utils.extractEpisodeNumber(file.nameOnly)
          if fileEpOpt.isSome and abs(fileEpOpt.get() - epNum) < 0.001:
            let ext = file.ext.toLower()
            if ext in videoExts:
              if matchedFiles[epNum].video.isNone:
                matchedFiles[epNum].video = some(file)
                usedFiles.incl(file)
            elif subtitleExts.anyIt(ext.endsWith(it)):
              # 检查是否已添加
              var alreadyAdded = false
              for existingSub in matchedFiles[epNum].subs:
                if existingSub.fullPath == file.fullPath:
                  alreadyAdded = true
                  break
              if not alreadyAdded:
                matchedFiles[epNum].subs.add(file)
                usedFiles.incl(file)
  
  # 回退策略：按顺序分配剩余文件
  var remainingVideos = localFiles.filter(proc (f: utils.LocalFileInfo): bool =
    f.ext.toLower() in videoExts and f notin usedFiles)
  var remainingSubs = localFiles.filter(proc (f: utils.LocalFileInfo): bool =
    subtitleExts.anyIt(f.ext.toLower().endsWith(it)) and f notin usedFiles)
  
  remainingVideos.sort(utils.naturalCompare)
  remainingSubs.sort(utils.naturalCompare)

  var videoIdx, subIdx = 0

  # 按排序顺序遍历剧集
  var sortedEps = episodes.data
  sortedEps.sort(proc(a,b: bangumi_api.Episode): int = cmp(a.sort, b.sort))

  for ep in sortedEps:
    var match = matchedFiles.getOrDefault(ep.sort)

    # 分配视频
    if match.video.isNone and videoIdx < remainingVideos.len:
      match.video = some(remainingVideos[videoIdx])
      usedFiles.incl(remainingVideos[videoIdx])
      videoIdx += 1
    
    # 分配字幕
    if match.subs.len == 0 and subIdx < remainingSubs.len:
      # 启发式匹配：如果有视频，尝试匹配文件名
      var assigned = false
      if match.video.isSome and subIdx < remainingSubs.len:
        let videoBase = utils.getBaseNameWithoutEpisode(match.video.get().nameOnly)
        let subBase = utils.getBaseNameWithoutEpisode(remainingSubs[subIdx].nameOnly)
        if videoBase == subBase:
          match.subs.add(remainingSubs[subIdx])
          usedFiles.incl(remainingSubs[subIdx])
          subIdx += 1
          assigned = true
      
      # 如果没有匹配到，直接分配下一个
      if not assigned and subIdx < remainingSubs.len:
        match.subs.add(remainingSubs[subIdx])
        usedFiles.incl(remainingSubs[subIdx])
        subIdx += 1
          
    matchedFiles[ep.sort] = match

  # 根据匹配结果构建缓存
  for ep in episodes.data:
    let epKey = utils.formatEpisodeNumber(ep.sort, episodes.total)
    let files = matchedFiles.getOrDefault(ep.sort)

    var nameOpt: Option[string] = none[string]()
    var videoExtOpt: Option[string] = none[string]()
    var subExts: seq[string] = @[]

    # 记录文件名
    if files.video.isSome:
      let video = files.video.get()
      nameOpt = some(video.nameOnly)
      videoExtOpt = some(video.ext)
    elif files.subs.len > 0:
      nameOpt = some(files.subs[0].nameOnly)

    # 记录字幕扩展名
    if files.subs.len > 0:
      let baseNameOpt = if files.video.isSome:
                         some(utils.getBaseNameWithoutEpisode(files.video.get().nameOnly))
                       elif files.subs.len > 0:
                         some(utils.getBaseNameWithoutEpisode(files.subs[0].nameOnly))
                       else:
                         none[string]()

      for sub in files.subs:
        # 获取字幕扩展名
        let origExt = sub.ext
        let videoBase = if files.video.isSome: files.video.get().nameOnly else: ""
        let cleanExt = utils.getCleanSubtitleExtension(origExt, videoBase)
        
        logDebug(fmt"字幕扩展名: 原始='{origExt}', 清理后='{cleanExt}'")
        
        # 对复合语言代码特殊处理
        if origExt.toLower().contains(".scjp") or 
           origExt.toLower().contains(".tcjp") or 
           origExt.toLower().contains(".sccn") or 
           origExt.toLower().contains(".tccn"):
          logDebug(fmt"复合语言代码: '{origExt}'")
          subExts.add(origExt)
        else:
          subExts.add(cleanExt)
        
        # 检查基础名匹配
        if baseNameOpt.isSome:
          let subBase = utils.getBaseNameWithoutEpisode(sub.nameOnly)
          let cleanSubBase = utils.getCleanedBaseName(subBase)
          let cleanBaseToCompare = utils.getCleanedBaseName(baseNameOpt.get())
          if cleanSubBase != cleanBaseToCompare:
            logDebug(fmt"字幕基础名不匹配: 字幕='{cleanSubBase}', 视频='{cleanBaseToCompare}'")
    
    # 添加到结果
    episodesForJson[epKey] = utils.CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      nameOnly: nameOpt,
      videoExt: videoExtOpt,
      subtitleExts: subExts
    )

  # 更新缓存
  cache[seasonId] = utils.CachedSeasonInfo(
    bangumiSeasonId: season.id,
    bangumiSeasonName: season.name,
    totalBangumiEpisodes: episodes.total,
    episodes: episodesForJson
  )

const
  cacheFile = "cache/cache.csv"       # CSV缓存文件
  jsonCacheFile = "cache/cache.json"  # JSON缓存文件
  defaultBasePath = "."               # 默认基础路径
  defaultAnimePath = "./anime"        # 默认番剧路径

  videoExts: seq[string] = @[".mkv", ".mp4", ".avi", ".mov", ".flv", ".rmvb", ".wmv", ".ts", ".webm"]
  subtitleExts: seq[string] = @[".ass", ".ssa", ".srt", ".sub", ".vtt", 
                              ".scjp.ass", ".tcjp.ass", ".sccn.ass", ".tccn.ass",
                              ".sc.ass", ".tc.ass", ".jp.ass", ".en.ass",
                              ".scjp.srt", ".tcjp.srt", ".sccn.srt", ".tccn.srt"]

# --- 命令行与配置处理 ---

proc parseCmdLine(): (string, string, bool) =
  # 解析命令行参数
  var basePath = defaultBasePath
  var animePath = defaultAnimePath
  var nameType = true

  let params = commandLineParams()
  if params.len >= 1:
    basePath = params[0]
  if params.len >= 2:
    animePath = params[1]
  if params.len >= 3:
    nameType = params[2] == "1"

  return (basePath, animePath, nameType)

proc initConfig() =
  # 初始化程序配置
  # 先尝试从缓存读取
  if fileExists(cacheFile):
    try:
      let f = open(cacheFile, fmRead)
      defer: f.close()
      
      if not f.endOfFile():
        let configLine = f.readLine()
        let parts = configLine.split(',')
        
        if parts.len >= 3:
          basePath = parts[0]
          animePath = parts[1]
          useCnName = parts[2] == "1"
          
          # 确保缓存目录存在
          try:
            createDir(parentDir(cacheFile))
          except OSError as e:
            stderr.writeLine fmt"警告: 创建缓存目录失败: {e.msg}"
          
          return
    except IOError as e:
      stderr.writeLine fmt"警告: 读取缓存失败: {e.msg}"

  # 使用命令行参数
  let (cmdBase, cmdAnime, cmdName) = parseCmdLine()

  basePath = cmdBase
  animePath = cmdAnime
  useCnName = cmdName

  # 确保缓存目录存在
  try:
    createDir(parentDir(cacheFile))
  except OSError as e:
    stderr.writeLine fmt"警告: 创建缓存目录失败: {e.msg}"
  
  # 写入配置到缓存
  try:
    let f = open(cacheFile, fmWrite)
    defer: f.close()
    let nameValue = if useCnName: "1" else: "0"
    f.writeLine basePath & "," & animePath & "," & nameValue
  except IOError as e:
    stderr.writeLine fmt"警告: 写入配置失败: {e.msg}"

# 处理单个番剧文件夹
proc processSampleData(
    folder: string,
    csvCache: var Table[string, utils.CsvCacheEntry],
    jsonCache: var Table[string, utils.CachedSeasonInfo]
  ) =
  # 处理一个番剧文件夹：匹配名称、获取信息、更新缓存
  var seasonOpt: Option[bangumi_api.Season] = none(bangumi_api.Season)
  var needFetchEpisodes = false

  # 尝试从缓存获取
  if csvCache.hasKey(folder):
    let entry = csvCache[folder]
    seasonOpt = some(bangumi_api.Season(id: entry.bangumiSeasonId, name: entry.bangumiSeasonNameCache))
    needFetchEpisodes = not jsonCache.hasKey($entry.bangumiSeasonId)
  else:
    # 提取番剧名
    let animeName = extractAnimeName(folder)
    if animeName.len > 0:
      let seasonFromApi = bangumi_api.getSeason(animeName, useCnName)
      if seasonFromApi.isSome:
        seasonOpt = seasonFromApi
        let season = seasonOpt.get()
        utils.appendToCacheCsv(folder, season.id, season.name, cacheFile)
        csvCache[folder] = utils.CsvCacheEntry(
          originalFolderName: folder,
          bangumiSeasonNameCache: season.name,
          bangumiSeasonId: season.id
        )
        needFetchEpisodes = true
      else:
        stderr.writeLine fmt"错误: 获取番剧信息失败: '{folder}' (匹配为 '{animeName}')"
        return
    else:
      stderr.writeLine fmt"提示: '{folder}' 未匹配到番剧名"
      return

  if seasonOpt.isNone:
    stderr.writeLine fmt"错误: 无法确定番剧信息: '{folder}'"
    return
  
  let season = seasonOpt.get()
  let seasonId = $season.id
  var episodeList: bangumi_api.EpisodeList

  # 获取剧集信息
  if not needFetchEpisodes and jsonCache.hasKey(seasonId):
    let cached = jsonCache[seasonId]
    if cached.episodes.len > 0:
      var episodes = newSeq[bangumi_api.Episode]()
      for _, epInfo in cached.episodes.pairs:
        episodes.add(bangumi_api.Episode(sort: epInfo.bangumiSort, name: epInfo.bangumiName))
      episodes.sort(proc(a,b: bangumi_api.Episode): int = cmp(a.sort, b.sort))
      episodeList = bangumi_api.EpisodeList(total: cached.totalBangumiEpisodes, data: episodes)
    else:
      needFetchEpisodes = true
  
  if needFetchEpisodes:
    let episodesFromApi = bangumi_api.getEpisodes(season.id, useCnName)
    if episodesFromApi.isNone:
      stderr.writeLine fmt"错误: 获取剧集列表失败: ID={season.id}, {season.name}"
      return
    episodeList = episodesFromApi.get()
  
  # 处理本地文件
  let localPath = basePath / folder
  var localFiles = newSeq[utils.LocalFileInfo]()

  if dirExists(localPath):
    for item in walkDir(localPath):
      if item.kind == pcFile:
        let (dirPath, name, ext) = splitFile(item.path)
        var currentName = name
        var currentExt = ext

        # 调试信息
        logDebug(fmt"处理文件: '{item.path}'")
        
        # 对字幕文件特殊处理
        let extLower = currentExt.toLower()
        if subtitleExts.anyIt(utils.eqIgnoresCase(it, extLower)):
          # 检查复合语言代码
          if name.contains(".scjp") or name.contains(".tcjp") or
             name.contains(".sccn") or name.contains(".tccn"):
            logDebug(fmt"检测到复合语言代码: '{name}{ext}'")
            
            let dotPos = name.rfind(".")
            if dotPos != -1:
              let langPart = name[dotPos+1 .. ^1]
              currentName = name[0 ..< dotPos]
              currentExt = "." & langPart & ext
              logDebug(fmt"复合语言处理: 名称='{currentName}', 扩展名='{currentExt}'")
          else:
            # 处理普通语言代码
            let parts = currentName.split('.')
            if parts.len > 1:
              let potentialLang = parts[^1]
              
              # 判断是否为语言代码
              var isLang = false
              if potentialLang.len >= 2 and potentialLang.len <= 5:
                isLang = potentialLang.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')
              elif potentialLang.len > 5 and potentialLang.contains('-'):
                isLang = potentialLang.all(proc (c: char): bool = c.isAlphaNumeric or c == '-')

              # 检查已知语言代码
              if isCommonLanguageCode(potentialLang):
                isLang = true
                logDebug(fmt"检测到语言代码: '{potentialLang}'")

              if isLang:
                # 确认不是纯数字
                var allDigits = true
                for c in potentialLang:
                  if not c.isDigit:
                    allDigits = false
                    break
                    
                if not allDigits:
                  let tempExt = "." & potentialLang & currentExt
                  let tempName = parts[0 .. ^2].join(".")
                  
                  if tempName.endsWith("."):
                    currentName = tempName[0 .. ^2]
                  elif tempName.len == 0 and parts.len == 2:
                    currentName = parts[0]
                  else:
                    currentName = tempName
                  
                  currentExt = tempExt
                  logDebug(fmt"语言处理: 名称='{currentName}', 扩展名='{currentExt}'")
        
        # 记录处理结果
        logDebug(fmt"文件处理结果: 名称='{currentName}', 扩展名='{currentExt}'")
        
        localFiles.add(utils.LocalFileInfo(
          nameOnly: currentName,
          ext: currentExt,
          fullPath: item.path
        ))
  else:
    stderr.writeLine fmt"警告: 文件夹不存在: '{localPath}'"

  # 更新缓存
  updateCache(jsonCache, season, episodeList, localFiles, videoExts, subtitleExts, localPath)

# 主程序入口
proc main() =
  # 初始化
  initConfig()
  
  var csvCache = utils.readCsvCache(cacheFile)
  var jsonCache = utils.loadJsonCache(jsonCacheFile)
  
  let folders = utils.readDir(basePath)
  
  if folders.len == 0:
    let pathType = if basePath == defaultBasePath: "默认" else: "指定"
    stderr.writeLine fmt"提示: 在{pathType}路径 '{basePath}' 下未找到番剧文件夹"
    return
  
  # 处理每个文件夹
  for folder in folders:
    processSampleData(folder, csvCache, jsonCache)
  
  # 保存缓存
  utils.saveJsonCache(jsonCacheFile, jsonCache)
  
  # 创建目标目录
  if folders.len > 0:
    try:
      if not dirExists(animePath):
        createDir(animePath)
    except OSError as e:
      stderr.writeLine fmt"错误: 创建目标目录失败: '{animePath}', {e.msg}"
  
  # 最终JSON缓存
  let finalCache = utils.loadJsonCache(jsonCacheFile)
  
  # 处理每个文件夹
  for folder in folders:
    var renamed = false
    var finalName = ""
  
    # 源目录和目标目录
    let sourceDir = basePath / folder
    var targetDir = animePath / folder
  
    if not dirExists(sourceDir):
      stderr.writeLine fmt"警告: 源目录不存在: '{sourceDir}'"
      echo fmt"{folder} => 【X】"
      continue
  
    # 创建硬链接
    utils.createDirectoryHardLink(sourceDir, targetDir)
  
    # 尝试从缓存获取信息
    if csvCache.hasKey(folder):
      let entry = csvCache[folder]
      let id = $entry.bangumiSeasonId
      if finalCache.hasKey(id):
        let info = finalCache[id]
        var validStatus = ""
        var videoCount = 0
        var filesInTarget: seq[string] = @[]
        var localFiles = newSeq[utils.LocalFileInfo]()
  
        # 统计目标目录中的文件
        if dirExists(targetDir):
          for item in walkDir(targetDir):
            if item.kind == pcFile:
              let filename = item.path.extractFilename()
              filesInTarget.add(filename)
              
              # 处理复合语言代码
              if filename.toLower().contains(".scjp.") or filename.toLower().contains(".tcjp.") or
                 filename.toLower().contains(".sccn.") or filename.toLower().contains(".tccn."):
                logDebug(fmt"处理目标目录复合语言字幕: '{filename}'")
                
                # 手动分离文件名和扩展名
                let dotPos = filename.rfind(".")
                if dotPos != -1:
                  var extStartPos = -1
                  for langCode in @[".scjp.", ".tcjp.", ".sccn.", ".tccn."]:
                    let lcPos = filename.toLower().find(langCode)
                    if lcPos != -1:
                      extStartPos = lcPos
                      break
                  
                  if extStartPos != -1:
                    let nameOnly = filename[0 ..< extStartPos]
                    let ext = filename[extStartPos .. ^1]
                    logDebug(fmt"复合语言拆分: 名称='{nameOnly}', 扩展名='{ext}'")
                    localFiles.add(utils.LocalFileInfo(
                      nameOnly: nameOnly,
                      ext: ext,
                      fullPath: item.path
                    ))
                  else:
                    # 回退到普通处理
                    let (dirPath, nameOnly, ext) = splitFile(item.path)
                    localFiles.add(utils.LocalFileInfo(
                      nameOnly: nameOnly,
                      ext: ext,
                      fullPath: item.path
                    ))
                else:
                  localFiles.add(utils.LocalFileInfo(
                    nameOnly: filename,
                    ext: "",
                    fullPath: item.path
                  ))
              else:
                # 普通文件
                let (dirPath, nameOnly, ext) = splitFile(item.path)
                localFiles.add(utils.LocalFileInfo(
                  nameOnly: nameOnly,
                  ext: ext,
                  fullPath: item.path
                ))
              
              # 检查是否为视频
              let fileExt = extractFilename(item.path).toLower()
              let isVideo = videoExts.anyIt(fileExt.endsWith(it))
              if isVideo:
                videoCount += 1
        
        # 验证文件数量
        let expectedEpisodes = info.totalBangumiEpisodes
        var skipRename = false
  
        if expectedEpisodes < videoCount:
          stderr.writeLine fmt"警告: 番剧 '{folder}' (ID: {id}) 视频文件过多. 预期={expectedEpisodes}, 实际={videoCount}"
          validStatus = "【X-校验失败-文件过多】"
          finalName = folder
          renamed = false
          skipRename = true
        elif videoCount < expectedEpisodes:
          stderr.writeLine fmt"提示: 番剧 '{folder}' (ID: {id}) 视频文件不足. 预期={expectedEpisodes}, 实际={videoCount}"
  
        # 重命名文件
        if not skipRename:
          utils.renameFilesBasedOnCache(targetDir, info, filesInTarget)
          
          let desiredName = utils.sanitizeFilename(info.bangumiSeasonName)
          var finalPath = targetDir
          
          if dirExists(targetDir):
            if targetDir != (animePath / desiredName):
              let newPath = animePath / desiredName
              try:
                moveDir(targetDir, newPath)
                renamed = true
                finalName = desiredName
                finalPath = newPath
              except OSError as e:
                stderr.writeLine fmt"错误: 重命名目录失败: {targetDir} -> {newPath}, {e.msg}"
                if dirExists(targetDir):
                  finalName = folder
                else:
                  finalName = ""
                renamed = false
            else:
              renamed = true
              finalName = desiredName
          else:
            stderr.writeLine fmt"错误: 目标目录不存在: '{targetDir}'"
            finalName = ""
            renamed = false
  
          # 验证结果
          if renamed and finalName.len > 0 and not dirExists(finalPath):
            stderr.writeLine fmt"错误: 目录在重命名后丢失: '{finalPath}'"
            validStatus = if validStatus.len > 0: validStatus & " " else: "" & "【X-目录丢失】"
            renamed = false
            finalName = folder
          elif not renamed and finalName.len == 0 and not dirExists(targetDir):
            validStatus = if validStatus.len > 0: validStatus & " " else: "" & "【X-处理失败】"
  
        # 输出结果
        if finalName.len > 0:
          echo fmt"{folder} => {finalName}{validStatus}"
        else:
          echo fmt"{folder} => 【X】{validStatus}"
      else:
        stderr.writeLine fmt"警告: JSON缓存中未找到ID '{id}' (来自 '{folder}')"
        echo fmt"{folder} => 【X】"
    else:
      stderr.writeLine fmt"警告: CSV缓存中未找到 '{folder}'"
      echo fmt"{folder} => 【X】"

# 执行主程序
main()
