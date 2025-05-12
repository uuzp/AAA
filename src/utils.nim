import std/[os, strutils, strformat, re, tables, options, json, algorithm, sequtils, math, times, sets] # 添加 sets 模块
import std/collections/tables as ctables # 单独导入collections/tables以避免命名冲突
import ./bangumi_api # 添加bangumi_api模块的导入
# import ./core/types # Types will be defined locally or imported from other new modules

# --- 字幕常量和类型定义 (移到前面) ---
const 
  # 已知的基础字幕扩展名
  knownBaseSuffixes* = @[".ssa", ".ass", ".srt", ".sub", ".idx", ".vtt"]

# --- 字幕文件检测函数 ---
proc isSubtitleFile*(filename: string): bool =
  ## 判断一个文件是否为字幕文件
  let (_, _, ext) = splitFile(filename)  # 使用splitFile而不是splitExt
  for suffix in knownBaseSuffixes:
    if ext.toLower().endsWith(suffix.toLower()):
      return true
  return false

# --- 类型定义 ---
type
  SubtitleInfo* = object
    rawExt*: string      # 原始完整扩展名
    suffix*: string      # 字幕后缀部分
    baseExt*: string     # 基础扩展名
    isCompound*: bool    # 是否为复合语言字幕

  LocalFileInfo* = object          ## 本地文件信息
    nameOnly*: string              # 文件名 (不含后缀)
    ext*: string                   # 文件后缀 (例如 ".mkv", ".ass", 带点)
    fullPath*: string              # 文件的完整路径

  CachedEpisodeInfo* = object      ## 存储在 cache.json 中的单集详细信息 (优化结构)
    bangumiSort*: float            # Bangumi API 返回的原始 sort 值
    bangumiName*: string           # Bangumi API 返回的剧集名 (优先中文)
    nameOnly*: Option[string]      # 共享的文件名主体 (不含任何后缀或语言代码), 例如 "Episode 01 - Title"
    videoExt*: Option[string]      # 视频文件后缀 (例如 ".mkv"), 带点
    subtitleExts*: seq[string]     # 字幕文件后缀列表 (例如 @[".scjp.ass", ".tcjp.ass"]), 每个都带点

  CachedSeasonInfo* = object       ## 存储在 cache.json 中的番剧季度详细信息
    bangumiSeasonId*: int          # Bangumi 番剧 ID
    bangumiSeasonName*: string     # Bangumi 番剧名
    totalBangumiEpisodes*: int     # Bangumi API 返回的总集数
    episodes*: Table[string, CachedEpisodeInfo] # 键: formatEpisodeNumber 的结果 (如 "E01")

  CsvCacheEntry* = object          ## cache.csv 中的条目 (原始文件夹名 -> Bangumi ID 映射)
    originalFolderName*: string    # 扫描到的原始的文件夹名称
    bangumiSeasonNameCache*: string # 匹配到的 Bangumi 番剧名 (用于快速显示)
    bangumiSeasonId*: int          # 匹配到的 Bangumi 番剧 ID

# --- 调试和日志函数 ---
proc logDebug*(message: string) =
  ## 记录调试信息到日志文件
  let logDir = "cache/logs"
  try:
    if not dirExists(logDir):
      createDir(logDir)
    let logFile = open(logDir & "/debug_log.txt", fmAppend)
    defer: logFile.close()
    logFile.writeLine(fmt"{getTime()}: {message}")
  except IOError:
    stderr.writeLine "警告: 无法写入调试日志"

# --- 字符串和排序工具函数 (从原 core/utils_string.nim 移动过来) ---
proc getCleanedBaseName*(name: string): string =
  ## 从文件名中移除常见的分辨率、编码、发布组等标签，得到一个更"干净"的基础名称。
  var cleanedName = name
  cleanedName = cleanedName.replace(re"(?i)\b(?:1080p|720p|2160p|4k)\b", "")
  cleanedName = cleanedName.replace(re"(?i)\b(?:x265|h265|x264|h264|avc|hevc)\b", "")
  cleanedName = cleanedName.replace(re"(?i)\b(?:FLAC|AAC|AC3|DTS|Opus)\b", "")
  cleanedName = cleanedName.replace(re"(?i)\b(?:BDRip|BluRay|WEB-DL|WEBRip|HDTV)\b", "")
  cleanedName = cleanedName.replace(re"-\w+$", "") 
  cleanedName = cleanedName.replace(re"_\w+$", "") 
  cleanedName = cleanedName.replace(re"[\s._-]+", ".") 
  cleanedName = cleanedName.strip(chars = {'.'}) 
  while cleanedName.contains(".."):
    cleanedName = cleanedName.replace("..", ".")
  return cleanedName.strip()

proc splitAlphaNumeric*(s: string): seq[string] =
  ## 将字符串分割为交替的非数字和数字序列。
  result = @[]
  if s.len == 0: return
  var currentChunk = ""
  var currentIsDigit = if s.len > 0: s[0].isDigit() else: false
  for c in s:
    if c.isDigit() == currentIsDigit:
      currentChunk.add(c)
    else:
      if currentChunk.len > 0: result.add(currentChunk)
      currentChunk = $c 
      currentIsDigit = c.isDigit()
  if currentChunk.len > 0: 
    result.add(currentChunk)

proc naturalCompare*(a: LocalFileInfo, b: LocalFileInfo): int =
  ## 自然比较两个 LocalFileInfo 对象的文件名 (nameOnly)。
  let partsA = splitAlphaNumeric(a.nameOnly.toLower()) 
  let partsB = splitAlphaNumeric(b.nameOnly.toLower())
  for i in 0 .. min(partsA.len - 1, partsB.len - 1):
    let partA = partsA[i]
    let partB = partsB[i]
    let partAIsPotentiallyNumeric = partA.len > 0 and partA[0].isDigit()
    let partBIsPotentiallyNumeric = partB.len > 0 and partB[0].isDigit()
    if partAIsPotentiallyNumeric and partBIsPotentiallyNumeric:
      var numAOpt: Option[int]
      var numBOpt: Option[int]
      try:
        if partA.all(isDigit): numAOpt = some(parseInt(partA))
      except ValueError: discard 
      try:
        if partB.all(isDigit): numBOpt = some(parseInt(partB))
      except ValueError: discard 
      if numAOpt.isSome and numBOpt.isSome: 
        let numA = numAOpt.get()
        let numB = numBOpt.get()
        if numA < numB: return -1
        if numA > numB: return 1
      elif numAOpt.isSome: 
        return -1 
      elif numBOpt.isSome: 
        return 1  
      else: 
        if partA < partB: return -1
        if partA > partB: return 1
    else: 
      if partA < partB: return -1
      if partA > partB: return 1
  if partsA.len < partsB.len: return -1
  if partsA.len > partsB.len: return 1
  let extComp = cmp(a.ext.toLower(), b.ext.toLower())
  if extComp != 0: return extComp
  return 0

proc eqIgnoresCase*(a, b: string): bool =
  ## 不区分大小写比较两个字符串是否相等
  return cmpIgnoreCase(a, b) == 0

proc getBaseNameWithoutEpisode*(fileName: string): string =
  ## 尝试从文件名中移除剧集编号部分，返回基础文件名。
  ## 例如: "[SubsPlease] Mushishi Zoku Shou - 01 (1080p) [F0ECC044]" -> "[SubsPlease] Mushishi Zoku Shou"
  ## "[DBD-Raws][Mushishi][20.5][1080P]" -> "[DBD-Raws][Mushishi]"
  var baseName = fileName
  # 移除括号/方括号中的数字和可能的 "v2", "OVA", "SP", "NCED", "NCOP", "Preview", "PV" 等
  # 这些通常是明确的剧集指示或类型标记，可以先移除
  baseName = baseName.replace(re(r"\s*\[\s*(?:\d+(?:\.\d+)?v\d?|S\d+E\d+|SP\d*|OVA\d*|OAD\d*|NCED|NCOP|Preview|PV)\s*\]", {reIgnoreCase}), "")
  baseName = baseName.replace(re(r"\s*\(\s*(?:\d+(?:\.\d+)?v\d?|S\d+E\d+|SP\d*|OVA\d*|OAD\d*|NCED|NCOP|Preview|PV)\s*\)", {reIgnoreCase}), "")

  # 尝试移除更通用的剧集编号模式，例如 " - 01", " E01 ", " S01E01 "
  # 这个模式需要小心，避免移除文件名中其他部分的数字或 "-TAG"
  # (?<=\D) 确保数字前是非数字字符或开头，避免移除 x265 中的 265
  # \s+|$ 确保数字后是空格或行尾
  baseName = baseName.replace(re(r"(?i)(?:^|\s|\[|\()(?:S\d+E|E|EP|第)?(\d+(?:\.\d+)?)v?\d*(?:END)?(?:$|\s|\]|\))"), " ")
  
  # 进一步尝试移除被空格或特定分隔符包围的纯数字集数，这通常在更复杂的命名中
  # 例如 "... Vol.01 ...", "... 01 ...", "... - 01 - ..."
  # (?<=[^a-zA-Z0-9]) 确保数字前是非字母数字字符 (lookbehind)
  # (?=[^a-zA-Z0-9]|$) 确保数字后是非字母数字字符或行尾 (lookahead)
  baseName = baseName.replace(re(r"(?<=[^a-zA-Z0-9\.]|^)(\d+(?:\.\d+)?)(?=[^a-zA-Z0-9\.]|$)"), "")


  # 清理：移除常见标签，这些标签通常在剧集编号之后或独立存在
  # 将 getCleanedBaseName 中的部分逻辑移到这里，但在移除数字之后进行，以保护标签中的数字
  baseName = baseName.replace(re("(?i)\\b(?:1080p|720p|2160p|4k|BDRip|BluRay|WEB-DL|WEBRip|HDTV)\\b"), "")
  baseName = baseName.replace(re("(?i)\\b(?:x265|h265|x264|h264|avc|hevc)\\b"), "")
  baseName = baseName.replace(re("(?i)\\b(?:FLAC|AAC|AC3|DTS|Opus)\\b"), "")
  
  # 清理多余的空格和末尾的特殊字符
  baseName = baseName.replace(re(r"\s{2,}"), " ").strip(chars = {' ', '-', '_', '.'})
  # 移除末尾可能存在的 " -" 或 "_ " 等
  if baseName.endsWith(" -"):
    baseName = baseName[0 .. ^3].strip(chars = {' ', '-', '_', '.'})
  return baseName

# --- 文件操作和重命名辅助函数 (从原 core/file_operations.nim 移动过来) ---
proc sanitizeFilename*(filename: string): string =
  ## 清理文件名，移除或替换非法字符，并限制长度。
  let invalidCharsPattern = re(r"[\\/:*?""<>|]") 
  result = filename.replace(invalidCharsPattern, "_") 
  result = result.strip() 

  while result.endsWith(".") or result.endsWith(" "):
    result = result[0 .. ^2]
  
  if result.len > 240: 
    result = result[0 .. 239].strip()
    while result.endsWith(".") or result.endsWith(" "): 
      result = result[0 .. ^2]
  return result

# 文件操作函数
proc createDirectoryHardLink*(sourceDir: string, targetDir: string) =
  # 递归地将sourceDir内容硬链接到targetDir，字幕文件直接复制
  if not dirExists(sourceDir):
    stderr.writeLine fmt"错误: 源目录 '{sourceDir}' 不存在"
    return

  try:
    if not dirExists(targetDir):
      createDir(targetDir)
  except OSError as e:
    stderr.writeLine fmt"错误: 创建目标目录失败: {targetDir}, {e.msg}"
    return

  var linkedCount, copiedCount, dirCount, errorCount = 0

  for kind, srcPath in walkDir(sourceDir): 
    # 获取相对路径
    var relPath: string
    if sourceDir.endsWith(PathSep):
      relPath = srcPath[sourceDir.len .. ^1]
    else:
      if srcPath.len > sourceDir.len: 
        relPath = srcPath[(sourceDir.len + 1) .. ^1]
      else: 
        continue
    
    if relPath.len == 0: 
      continue

    let targetPath = targetDir / relPath
    let (_, filename) = splitPath(srcPath)
    let isSubtitle = isSubtitleFile(filename)
    
    logDebug(fmt"处理文件: '{srcPath}' -> '{targetPath}'")
    
    case kind
    of pcFile:
      let targetParentDir = parentDir(targetPath)
      try:
        if not dirExists(targetParentDir):
          createDir(targetParentDir)
          logDebug(fmt"创建目录: '{targetParentDir}'")
      except OSError:
        logDebug(fmt"创建目录失败: '{targetParentDir}'")
      
      if fileExists(targetPath): 
        logDebug(fmt"文件已存在: '{targetPath}'")
      else:
        try:
          if isSubtitle:
            copyFile(srcPath, targetPath)
            copiedCount += 1
            logDebug(fmt"复制字幕成功: '{srcPath}' -> '{targetPath}'")
          else:
            createHardLink(srcPath, targetPath)
            linkedCount += 1
            logDebug(fmt"硬链接成功: '{srcPath}' -> '{targetPath}'")
        except OSError as e:
          let opType = if isSubtitle: "复制" else: "硬链接"
          stderr.writeLine fmt"错误: {opType}文件失败: {srcPath} -> {targetPath}, {e.msg}"
          errorCount += 1
    of pcDir:
      try:
        if not dirExists(targetPath):
          createDir(targetPath)
          dirCount += 1
      except OSError:
        logDebug(fmt"创建目录失败: '{targetPath}'")
        errorCount += 1
    else: 
      discard

  if errorCount > 0:
    stderr.writeLine fmt"发生错误: {errorCount} 个操作失败"
  
  logDebug(fmt"处理完成: 链接={linkedCount}, 复制={copiedCount}, 目录={dirCount}")

# --- 字幕扩展名处理 ---
proc getSubtitleSuffix*(subFilename, videoBaseName: string): string =
  # 提取字幕文件的后缀部分
  let (_, name, ext) = splitFile(subFilename)
  
  # 直接比较是否匹配
  if name == videoBaseName:
    return ext
  
  # 防止死循环
  if name.find('.') == -1:
    return ext
  
  # 递归处理找到匹配部分
  let lastDot = name.rfind('.')
  if lastDot == -1:
    return ext
  
  let nameBase = name[0 ..< lastDot]
  let nameSuffix = name[lastDot .. ^1]
  
  if nameBase == videoBaseName:
    return nameSuffix & ext
  
  # 限制递归深度
  let maxDepth = 5
  var depth = 0
  var currentName = nameBase
  var suffixes = @[nameSuffix]
  
  while depth < maxDepth:
    depth += 1
    
    let nextDot = currentName.rfind('.')
    if nextDot == -1:
      break
    
    let nextBase = currentName[0 ..< nextDot]
    let nextSuffix = currentName[nextDot .. ^1]
    
    suffixes.add(nextSuffix)
    
    if nextBase == videoBaseName:
      suffixes.add(ext)
      return suffixes.reversed().join("")
    
    currentName = nextBase
  
  return ext

proc safeGetSubtitleSuffix*(subFilename, videoBaseName: string): string =
  ## 包装getSubtitleSuffix函数，增加额外的安全检查和调试信息
  logDebug(fmt"尝试获取字幕后缀: 字幕文件='{subFilename}', 视频文件名='{videoBaseName}'")
  result = getSubtitleSuffix(subFilename, videoBaseName)
  logDebug(fmt"获取到字幕后缀: '{result}'")
  return result

proc parseSubtitleExtension*(fullExt: string, videoBaseName: string = ""): SubtitleInfo =
  # 解析字幕扩展名，返回结构化信息
  result.rawExt = fullExt
  
  # 找到基础扩展名
  for base in knownBaseSuffixes:
    if fullExt.toLower().endsWith(base.toLower()):
      result.baseExt = fullExt[^base.len..^1]
      break
  
  if result.baseExt.len == 0:
    let lastDot = fullExt.rfind('.')
    if lastDot >= 0:
      result.baseExt = fullExt[lastDot..^1]
    else:
      result.baseExt = fullExt
  
  # 设置复合标志 - 简单判断：含有多个点号即为复合
  result.isCompound = fullExt.count('.') > 1
  
  # 处理字幕后缀
  if videoBaseName.len > 0:
    let tempFullName = videoBaseName & fullExt
    result.suffix = getSubtitleSuffix(tempFullName, videoBaseName)
  else:
    result.suffix = fullExt

proc isCompoundSubtitle*(filename: string): bool =
  # 判断是否为包含多个点号的字幕文件
  if not isSubtitleFile(filename):
    return false
  
  let (_, filenameOnly) = splitPath(filename)
  let (_, nameWithoutExt, _) = splitFile(filenameOnly)
  
  return nameWithoutExt.contains('.')

# --- 字幕文件复制/硬链接逻辑 ---
proc processSubtitleFile*(sourceFile, targetFile: string): bool =
  # 处理字幕文件(总是复制而非硬链接)
  if not fileExists(sourceFile):
    logDebug(fmt"字幕文件不存在: '{sourceFile}'")
    return false
  
  # 创建目标目录
  let targetDir = parentDir(targetFile)
  if not dirExists(targetDir):
    try:
      createDir(targetDir)
    except OSError as e:
      logDebug(fmt"创建目录失败: '{targetDir}', {e.msg}")
      return false
  
  # 已存在则跳过
  if fileExists(targetFile):
    logDebug(fmt"字幕文件已存在: '{targetFile}'")
    return true
  
  try:
    copyFile(sourceFile, targetFile)
    logDebug(fmt"复制字幕成功: '{sourceFile}' -> '{targetFile}'")
    return true
  except OSError as e:
    logDebug(fmt"复制字幕失败: '{sourceFile}' -> '{targetFile}', {e.msg}")
    return false

# --- 字幕文件重命名逻辑 ---
proc getSubtitleFilesByPattern*(files: seq[string], pattern: string): seq[string] =
  # 根据模式匹配字幕文件
  result = @[]
  let patternLower = pattern.toLower()
  
  for file in files:
    if isSubtitleFile(file) and file.toLower().contains(patternLower):
      result.add(file)

proc renameSubtitleFile*(sourceFile, targetFile: string): bool =
  # 重命名字幕文件，保留完整扩展名
  if not fileExists(sourceFile):
    logDebug(fmt"字幕文件不存在: '{sourceFile}'")
    return false
  
  if sourceFile == targetFile:
    logDebug(fmt"文件名已正确，无需重命名: '{sourceFile}'")
    return true
  
  try:
    moveFile(sourceFile, targetFile)
    logDebug(fmt"重命名成功: '{sourceFile}' -> '{targetFile}'")
    return true
  except OSError as e:
    logDebug(fmt"重命名失败: '{sourceFile}' -> '{targetFile}', {e.msg}")
    return false

proc renameFilesBasedOnCache*(
    targetPath: string,
    seasonInfo: CachedSeasonInfo,
    files: seq[string] 
  ) =
  # 根据缓存信息重命名文件
  if not dirExists(targetPath):
    stderr.writeLine fmt"错误: 目标文件夹 '{targetPath}' 不存在"
    return

  var renamedCount = 0
  var errorCount = 0
  
  # 记录调试信息
  logDebug(fmt"目标文件夹'{targetPath}'中的文件:")
  for file in files:
    logDebug(fmt"  - {file}")

  # 处理每个剧集
  for epKey, ep in pairs(seasonInfo.episodes):
    if ep.nameOnly.isNone:
      continue
    
    let cleanEpName = sanitizeFilename(ep.bangumiName)
    let newBaseName = sanitizeFilename(fmt"{epKey} - {cleanEpName}")
    let cachedName = ep.nameOnly.get()
    let cleanedCachedName = getCleanedBaseName(cachedName)
    
    # 处理视频文件
    var videoFile: Option[string] = none(string)
    var videoName = ""
    
    if ep.videoExt.isSome:
      let videoExt = ep.videoExt.get()
      
      # 查找匹配的视频文件
      for file in files:
        let (_, namePart, extPart) = splitFile(file)
        if extPart == videoExt:
          let cleanedName = getCleanedBaseName(namePart)
          if cleanedName == cleanedCachedName:
            videoFile = some(file)
            videoName = namePart
            break
      
      # 重命名视频文件
      if videoFile.isSome:
        let oldPath = targetPath / videoFile.get()
        let newPath = targetPath / (newBaseName & videoExt)
        
        if oldPath != newPath and fileExists(oldPath):
          try:
            moveFile(oldPath, newPath)
            renamedCount += 1
            logDebug(fmt"重命名视频: '{oldPath}' -> '{newPath}'")
          except OSError as e:
            stderr.writeLine fmt"错误: 重命名失败: {oldPath} -> {newPath}, {e.msg}"
            errorCount += 1
    
    # 处理字幕文件
    if videoName.len == 0:
      videoName = cachedName

    # 查找匹配的字幕文件
    var subFiles: seq[string] = @[]
    for file in files:
      if isSubtitleFile(file):
        let (_, subName, _) = splitFile(file)
        
        # 直接匹配
        if subName == videoName:
          subFiles.add(file)
          continue
        
        # 匹配清理后名称
        let cleanedSubName = getCleanedBaseName(subName)
        if cleanedSubName == cleanedCachedName:
          subFiles.add(file)
          continue
        
        # 递归分割匹配
        var curName = subName
        var depth = 0
        while curName.len > 0 and curName.find('.') != -1 and depth < 5:
          depth += 1
          let lastDot = curName.rfind('.')
          if lastDot == -1:
            break
            
          let nameBase = curName[0 ..< lastDot]
          if nameBase == videoName or getCleanedBaseName(nameBase) == cleanedCachedName:
            subFiles.add(file)
            break
            
          curName = nameBase

    # 重命名字幕文件
    for subFile in subFiles:
      let oldSubPath = targetPath / subFile
      
      # 获取字幕后缀
      let videoBaseName = if videoName.len > 0: videoName else: cleanedCachedName
      let subExt = getSubtitleSuffix(subFile, videoBaseName)
      
      # 构建新路径
      let newSubPath = targetPath / (newBaseName & subExt)

      if oldSubPath != newSubPath and fileExists(oldSubPath):
        try:
          moveFile(oldSubPath, newSubPath)
          renamedCount += 1
          logDebug(fmt"重命名字幕: '{oldSubPath}' -> '{newSubPath}'")
        except OSError as e:
          stderr.writeLine fmt"错误: 重命名失败: {oldSubPath} -> {newSubPath}, {e.msg}"
          errorCount += 1
  
  # 总结
  if errorCount > 0:
    stderr.writeLine fmt"重命名过程中有 {errorCount} 个错误"
  
  logDebug(fmt"重命名完成: 成功={renamedCount}, 失败={errorCount}")

# --- 缓存处理相关函数 (从原 core/cache_manager.nim 移动过来) ---
proc extractEpisodeNumber*(fileName: string): Option[float] =
  # 尝试从文件名中提取剧集号
  let patterns = [
    re"S\d+[._-]?E(\d+(?:\.\d+)?)\b",               # S01E20, S01E20.5
    re"\b(?:EP|E|第|\[)\s*(\d+(?:\.\d+)?)\b",       # EP20, E20, 第20, [20
    re"\[(\d+(?:\.\d+)?)\]",                        # [20], [20.5]
    re"\s-\s(\d+(?:\.\d+)?)\b",                     # - 20, - 20.5
    re"\b(\d+(?:\.\d+)?)\s*\[",                     # 20 [, 20.5 [
    re"\b(\d+(?:\.\d+)?)(?:v\d)?\b"                 # 20, 20.5, 20v2
  ]
  
  for pattern in patterns:
    var match: array[1, string]
    if fileName.find(pattern, match) != -1:
      try:
        return some(parseFloat(match[0]))
      except ValueError:
        continue
        
  return none[float]()

proc formatEpisodeNumber*(sort: float, total: int): string =
  # 根据总集数格式化剧集编号
  let sortInt = int(sort)
  let hasFraction = abs(sort - round(sort)) >= 0.0001
  
  var numStr = $sortInt
  var prefix = "E"
  var digits = 1
  
  if total >= 10000: digits = 5
  elif total >= 1000: digits = 4
  elif total >= 100: digits = 3
  elif total >= 10: digits = 2
  
  # 补零
  let zeros = digits - numStr.len
  if zeros > 0:
    for _ in 1 .. zeros: 
      prefix.add('0')
  
  var result = prefix & numStr
  
  # 处理小数部分
  if hasFraction:
    let frac = sort - float(sortInt)
    let fracStr = $frac
    
    if fracStr.startsWith("0."):
      result.add(fracStr[1 .. ^1])
    elif fracStr.startsWith("."):
      result.add(fracStr)
    else:
      result.add("." & fracStr.replace("0.", "."))
      
  return result

proc appendToCacheCsv*(folder: string, id: int, name: string, path: string) =
  # 将番剧信息追加到CSV缓存
  let line = fmt"{folder},{name},{id}"
  try:
    let f = open(path, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError as e:
    echo &"错误: 写入缓存失败: {path}, {e.msg}"

proc readCsvCache*(path: string): Table[string, CsvCacheEntry] =
  # 读取CSV缓存
  result = initTable[string, CsvCacheEntry]()
  if not fileExists(path):
    return
  
  var skipFirst = true
  try:
    for line in lines(path):
      # 跳过首行(配置信息)、空行和注释
      if skipFirst:
        skipFirst = false
        continue
      
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#"):
        continue
        
      let parts = stripped.split(',')
      if parts.len == 3: 
        try:
          let entry = CsvCacheEntry(
            originalFolderName: parts[0].strip(),
            bangumiSeasonNameCache: parts[1].strip(),
            bangumiSeasonId: parseInt(parts[2].strip())
          )
          result[entry.originalFolderName] = entry
        except ValueError:
          echo fmt"警告: 解析缓存ID无效: {stripped}"
      else:
        echo fmt"警告: 缓存行格式错误: {stripped}"
  except IOError as e:
    echo &"错误: 读取缓存失败: {path}, {e.msg}"

proc loadJsonCache*(path: string): Table[string, CachedSeasonInfo] =
  # 从JSON缓存加载番剧数据
  result = initTable[string, CachedSeasonInfo]()
  if not fileExists(path):
    return
    
  try:
    let content = readFile(path)
    if content.len == 0:
      return
      
    let jsonData = parseJson(content)
    if jsonData.kind == JObject:
      for idKey, seasonNode in jsonData.pairs:
        try:
          result[idKey] = seasonNode.to(CachedSeasonInfo)
        except JsonKindError, ValueError: 
          echo fmt"警告: 解析JSON缓存失败, ID='{idKey}'"
    else:
      echo &"警告: {path} 不是有效的JSON对象"
  except JsonParsingError as e:
    echo &"错误: 解析JSON缓存失败: {path}, {e.msg}"
  except IOError as e:
    echo &"错误: 读取缓存失败: {path}, {e.msg}"

proc saveJsonCache*(path: string, cache: Table[string, CachedSeasonInfo]) =
  # 保存番剧数据到JSON缓存
  var rootNode = newJObject()
  var sortedIds = newSeq[int]()
  
  # 收集并排序番剧ID
  for idKey in cache.keys:
    try:
      sortedIds.add(parseInt(idKey))
    except ValueError:
      continue
  
  sortedIds.sort(cmp[int])

  # 按ID顺序构建JSON
  for id in sortedIds:
    let idKey = $id
    if not cache.hasKey(idKey):
      continue
    
    let seasonInfo = cache[idKey]
    var seasonNode = newJObject()

    seasonNode["bangumiSeasonId"] = %*(seasonInfo.bangumiSeasonId)
    seasonNode["bangumiSeasonName"] = %*(seasonInfo.bangumiSeasonName)
    seasonNode["totalBangumiEpisodes"] = %*(seasonInfo.totalBangumiEpisodes)

    # 处理剧集信息
    if seasonInfo.episodes.len > 0: 
      var sortedEpKeys = toSeq(seasonInfo.episodes.keys)
      sortedEpKeys.sort(cmp[string]) 

      var episodesNode = newJObject()
      for epKey in sortedEpKeys:
        if seasonInfo.episodes.hasKey(epKey):
          episodesNode[epKey] = %*(seasonInfo.episodes[epKey])
      
      seasonNode["episodes"] = episodesNode 
    else:
      seasonNode["episodes"] = newJObject() 
      
    rootNode[idKey] = seasonNode   

  try:
    writeFile(path, pretty(rootNode))
  except IOError as e:
    echo &"错误: 写入缓存失败: {path}, {e.msg}"

proc readDir*(path: string): seq[string] =
  # 读取目录下的所有文件夹
  var dirs = newSeq[string]()
  try:
    for item in walkDir(path):
      if item.kind == pcDir:
        dirs.add(item.path.extractFilename())
  except OSError as e:
    stderr.writeLine fmt"错误: 读取目录失败: {path}, {e.msg}"
  
  return dirs

# --- 向后兼容函数 ---
proc getCleanSubtitleExtension*(fullExt: string, videoBaseName: string = ""): string =
  # 向后兼容的字幕扩展名处理函数
  let subInfo = parseSubtitleExtension(fullExt, videoBaseName)
  return subInfo.suffix

# --- 从AAA.nim移动的函数 ---

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
  # 匹配视频和字幕文件
  let videoBase = getBaseNameWithoutEpisode(videoName)
  let subBase = getBaseNameWithoutEpisode(subtitleName)
  
  logDebug(fmt"匹配字幕: 视频='{videoBase}', 字幕='{subBase}'")
  
  # 计算相似度
  let similarity = similarityScore(videoBase, subBase)
  logDebug(fmt"相似度: {similarity}")
  
  # 统一使用0.7作为阈值
  return similarity > 0.7

proc renameSubtitleToMatchVideo(dirPath: string, videoFile, subFile: LocalFileInfo): string =
  ## 重命名字幕文件以匹配视频文件的命名模式
  ## 返回新的文件名（不包含路径）
  let videoNameOnly = videoFile.nameOnly
  
  # 使用utils中的递归函数获取字幕后缀
  let subExt = getSubtitleSuffix(subFile.fullPath, videoNameOnly)
  
  # 生成新的字幕文件名，保留完整后缀（含语言标记）
  let newSubName = videoNameOnly & subExt
  logDebug(fmt"生成新字幕文件名: '{newSubName}'，保留原后缀: '{subExt}'")
  return newSubName

proc processEpisodeFiles(
    dirPath: string, 
    epNumber: float, 
    videoFile: Option[LocalFileInfo], 
    subtitleFiles: seq[LocalFileInfo]
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
          logDebug(fmt"重命名成功: '{oldPath}' -> '{newPath}'")
        except OSError as e:
          stderr.writeLine fmt"错误: 重命名字幕文件失败: {oldPath} -> {newPath}, 原因: {e.msg}"
          logDebug(fmt"重命名失败: '{oldPath}' -> '{newPath}', 错误: {e.msg}")
    else:
      logDebug(fmt"字幕与视频不匹配，跳过: '{sub.fullPath}'")

proc extractAnimeName_old*(line: string): string = # 设为导出，因为 processSampleData 会间接调用
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

proc extractAnimeName*(line: string): string =
  ## 从文件夹名 (line) 中提取番剧名。
  # 首先判断是否包含rev，决定取第几个部分
  let hasRev = line.toLowerAscii().contains("rev")
  let targetIndex = if hasRev: 3 else: 2
  
  # 判断是否以[开头
  if line.startsWith("["):
    # 按[和]分割字符串，并去除空字符串
    let parts = line.split({'[', ']'}).filterIt(it.len > 0)
    return parts[targetIndex-1].strip()
  else:
    # 如果不是以[开头，取_前面的部分
    let underscorePos = line.find('_')
    if underscorePos != -1:
      return line[0..<underscorePos].strip()
  
  # 如果没有匹配到任何模式，返回空字符串
  return ""

proc matchFilesToEpisodes(
    episodes: seq[bangumi_api.Episode],
    localFiles: seq[LocalFileInfo],
    videoExts: seq[string],
    subtitleExts: seq[string]
  ): tuple[matchedFiles: Table[float, tuple[video: Option[LocalFileInfo], subs: seq[LocalFileInfo]]], usedFiles: HashSet[LocalFileInfo]] =
  ## 将本地文件匹配到剧集
  result.matchedFiles = initTable[float, tuple[video: Option[LocalFileInfo], subs: seq[LocalFileInfo]]]()
  result.usedFiles = initHashSet[LocalFileInfo]()
  
  # 初始化匹配表
  for ep in episodes:
    result.matchedFiles[ep.sort] = (video: none[LocalFileInfo](), subs: @[])
  
  # 第一轮：匹配整数集数(>=1)
  for ep in episodes:
    if abs(ep.sort - round(ep.sort)) < 0.001 and ep.sort >= 1.0:
      let epNum = ep.sort
      for file in localFiles:
        if file notin result.usedFiles:
          let fileEpOpt = extractEpisodeNumber(file.nameOnly)
          if fileEpOpt.isSome and abs(fileEpOpt.get() - epNum) < 0.001:
            let ext = file.ext.toLower()
            if ext in videoExts:
              if result.matchedFiles[epNum].video.isNone:
                result.matchedFiles[epNum].video = some(file)
                result.usedFiles.incl(file)
            elif subtitleExts.anyIt(ext.endsWith(it)):
              result.matchedFiles[epNum].subs.add(file)
              result.usedFiles.incl(file)
  
  # 第二轮：匹配小数集数或特殊集数(0, 0.5等)
  for ep in episodes:
    let isFloat = abs(ep.sort - round(ep.sort)) >= 0.001
    let isSpecial = ep.sort == 0.0
    
    if isFloat or isSpecial:
      let epNum = ep.sort
      for file in localFiles:
        if file notin result.usedFiles:
          let fileEpOpt = extractEpisodeNumber(file.nameOnly)
          if fileEpOpt.isSome and abs(fileEpOpt.get() - epNum) < 0.001:
            let ext = file.ext.toLower()
            if ext in videoExts:
              if result.matchedFiles[epNum].video.isNone:
                result.matchedFiles[epNum].video = some(file)
                result.usedFiles.incl(file)
            elif subtitleExts.anyIt(ext.endsWith(it)):
              if not result.matchedFiles[epNum].subs.anyIt(it.fullPath == file.fullPath):
                result.matchedFiles[epNum].subs.add(file)
                result.usedFiles.incl(file)
  
  return result

proc assignRemainingFiles(
    matchedFiles: var Table[float, tuple[video: Option[LocalFileInfo], subs: seq[LocalFileInfo]]],
    usedFiles: var HashSet[LocalFileInfo],
    remainingVideos: seq[LocalFileInfo],
    remainingSubs: seq[LocalFileInfo],
    episodes: seq[bangumi_api.Episode]
  ) =
  ## 分配剩余的文件
  var videoIdx, subIdx = 0
  
  # 按排序顺序遍历剧集
  var sortedEps = episodes
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
        let videoBase = getBaseNameWithoutEpisode(match.video.get().nameOnly)
        let subBase = getBaseNameWithoutEpisode(remainingSubs[subIdx].nameOnly)
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

proc buildEpisodeCache(
    matchedFiles: Table[float, tuple[video: Option[LocalFileInfo], subs: seq[LocalFileInfo]]],
    episodes: seq[bangumi_api.Episode],
    totalEpisodes: int
  ): Table[string, CachedEpisodeInfo] =
  ## 构建剧集缓存信息
  result = initTable[string, CachedEpisodeInfo]()
  
  for ep in episodes:
    let epKey = formatEpisodeNumber(ep.sort, totalEpisodes)
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
                         some(getBaseNameWithoutEpisode(files.video.get().nameOnly))
                       elif files.subs.len > 0:
                         some(getBaseNameWithoutEpisode(files.subs[0].nameOnly))
                       else:
                         none[string]()
      
      for sub in files.subs:
        let origExt = sub.ext
        let videoBase = if files.video.isSome: files.video.get().nameOnly else: ""
        let cleanExt = getSubtitleSuffix(sub.nameOnly, videoBase)
        
        logDebug(fmt"字幕扩展名: 原始='{origExt}', 清理后='{cleanExt}'")
        subExts.add(cleanExt)
    
    # 添加到结果
    result[epKey] = CachedEpisodeInfo(
      bangumiSort: ep.sort,
      bangumiName: ep.name,
      nameOnly: nameOpt,
      videoExt: videoExtOpt,
      subtitleExts: subExts
    )

proc updateCache*(
    cache: var Table[string, CachedSeasonInfo],
    season: bangumi_api.Season,
    episodes: bangumi_api.EpisodeList,
    localFiles: seq[LocalFileInfo],
    videoExts: seq[string],
    subtitleExts: seq[string],
    sourceDir: string
  ) =
  ## 更新并保存番剧缓存信息
  let seasonId = $season.id
  
  # 匹配文件到剧集
  let (matchedFiles, usedFiles) = matchFilesToEpisodes(episodes.data, localFiles, videoExts, subtitleExts)
  
  # 处理剩余文件
  var remainingVideos = localFiles.filter(proc (f: LocalFileInfo): bool =
    f.ext.toLower() in videoExts and f notin usedFiles)
  var remainingSubs = localFiles.filter(proc (f: LocalFileInfo): bool =
    subtitleExts.anyIt(f.ext.toLower().endsWith(it)) and f notin usedFiles)
  
  remainingVideos.sort(naturalCompare)
  remainingSubs.sort(naturalCompare)
  
  # 分配剩余文件
  var mutableMatchedFiles = matchedFiles
  var mutableUsedFiles = usedFiles
  assignRemainingFiles(mutableMatchedFiles, mutableUsedFiles, remainingVideos, remainingSubs, episodes.data)
  
  # 构建缓存
  let episodesForJson = buildEpisodeCache(mutableMatchedFiles, episodes.data, episodes.total)
  
  # 更新缓存
  cache[seasonId] = CachedSeasonInfo(
    bangumiSeasonId: season.id,
    bangumiSeasonName: season.name,
    totalBangumiEpisodes: episodes.total,
    episodes: episodesForJson
  )