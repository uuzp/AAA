import std/[os, strutils, strformat, re, tables, options, json, algorithm, sequtils, math, times] # Removed sets, streams, Added math and times
import std/collections/tables as ctables # 单独导入collections/tables以避免命名冲突
# import ./core/types # Types will be defined locally or imported from other new modules

# --- 字幕常量和类型定义 (移到前面) ---
const 
  # 已知的基础字幕扩展名
  knownBaseSuffixes* = @[".ssa", ".ass", ".srt", ".sub", ".idx", ".vtt"]
  
  # 复合语言代码列表
  compoundLangCodes* = @[".scjp", ".tcjp", ".sccn", ".tccn"]
  
  # 其他语言代码列表
  simpleLangCodes* = @[
    ".zh-hans", ".zh-hant", ".zh-cn", ".zh-tw", ".zh-hk",
    ".sc", ".tc", ".chs", ".cht", ".gb", ".big5",
    ".jpn", ".jp", ".eng", ".en", ".ger", ".deu",
    ".fre", ".fra", ".kor", ".ko", ".spa", ".es",
    ".ita", ".it", ".rus", ".ru"
  ]

type
  SubtitleInfo* = object          ## 字幕文件信息
    rawExt*: string               # 原始完整扩展名 (如 ".FLAC-CoolFansSub.scjp.ass")
    suffix*: string               # 字幕后缀部分 (如 ".scjp.ass")
    baseExt*: string              # 基础扩展名 (如 ".ass")
    isCompound*: bool             # 是否为复合语言字幕

# --- 字幕文件检测函数 ---
proc isSubtitleFile*(filename: string): bool =
  ## 判断一个文件是否为字幕文件
  let (_, _, ext) = splitFile(filename)  # 使用splitFile而不是splitExt
  for base in knownBaseSuffixes:
    if ext.toLower().endsWith(base.toLower()):
      return true
  return false

# --- 类型定义 ---
type
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

proc createDirectoryHardLinkRecursive*(sourceDir: string, targetDir: string) =
  ## 递归地将 sourceDir 的内容硬链接到 targetDir。
  ## 所有字幕文件将直接复制而不是硬链接
  if not dirExists(sourceDir):
    stderr.writeLine fmt"错误: 源目录 '{sourceDir}' 不存在，无法执行硬链接。"
    return

  try:
    if not dirExists(targetDir):
      createDir(targetDir)
  except OSError as e:
    stderr.writeLine fmt"严重错误: 创建目标根目录 '{targetDir}' 失败: {e.msg}. 中止此目录的硬链接。"
    return

  var linkedFilesCount = 0
  var copiedFilesCount = 0
  var createdDirsInTargetCount = 0 
  var linkErrorsCount = 0
  var dirCreateErrorsCount = 0

  for kind, itemFullPathInSource in walkDir(sourceDir): 
    if not itemFullPathInSource.startsWith(sourceDir):
      continue
    
    # 获取文件相对路径
    var relativeItemPath: string
    if sourceDir.endsWith(PathSep):
      relativeItemPath = itemFullPathInSource[sourceDir.len .. ^1]
    else:
      if itemFullPathInSource.len > sourceDir.len : 
          relativeItemPath = itemFullPathInSource[(sourceDir.len + 1) .. ^1]
      else: 
          continue
    
    if relativeItemPath.len == 0: 
      continue

    # 直接使用原始文件名构建目标路径，不分解扩展名
    let targetItemPath = targetDir / relativeItemPath
    
    # 获取文件名（不含路径）
    let (_, filenameOnly) = splitPath(itemFullPathInSource)
    
    # 增加日志输出，跟踪文件路径
    logDebug(fmt"处理文件: 源路径='{itemFullPathInSource}', 目标路径='{targetItemPath}', 文件名='{filenameOnly}'")

    # 检查是否为字幕文件
    let isSubtitle = isSubtitleFile(filenameOnly)
    if isSubtitle:
      logDebug(fmt"发现字幕文件: '{filenameOnly}'")
                            
    case kind
    of pcFile:
      let targetFileParentDir = parentDir(targetItemPath)
      try:
        if not dirExists(targetFileParentDir):
          createDir(targetFileParentDir)
          logDebug(fmt"创建目录: '{targetFileParentDir}'")
      except OSError:
        logDebug(fmt"创建目录失败: '{targetFileParentDir}'")
        discard 
      
      try:
        if fileExists(targetItemPath): 
          logDebug(fmt"文件已存在: '{targetItemPath}'")
          discard
        else:
          # 对于字幕文件，使用copyFile而不是createHardLink
          if isSubtitle:
            copyFile(itemFullPathInSource, targetItemPath)
            copiedFilesCount += 1
            logDebug(fmt"复制成功(字幕文件): '{itemFullPathInSource}' -> '{targetItemPath}'")
          else:
            createHardLink(itemFullPathInSource, targetItemPath)
            linkedFilesCount += 1
            logDebug(fmt"硬链接成功: '{itemFullPathInSource}' -> '{targetItemPath}'")
      except OSError as e:
        let operationType = if isSubtitle: "复制" else: "硬链接"
        stderr.writeLine fmt"错误: {operationType}文件 '{itemFullPathInSource}' 到 '{targetItemPath}' 失败: {e.msg}"
        logDebug(fmt"{operationType}失败: '{itemFullPathInSource}' -> '{targetItemPath}', 错误: {e.msg}")
        linkErrorsCount += 1
    of pcDir:
      try:
        if not dirExists(targetItemPath):
          createDir(targetItemPath)
          createdDirsInTargetCount += 1
          logDebug(fmt"创建目录: '{targetItemPath}'")
      except OSError:
        logDebug(fmt"创建目录失败: '{targetItemPath}'")
        dirCreateErrorsCount += 1
    else: 
      discard

  if linkErrorsCount > 0 or dirCreateErrorsCount > 0:
    stderr.writeLine fmt"硬链接期间发生错误: {linkErrorsCount} 个文件链接失败, {dirCreateErrorsCount} 个目录创建失败。"
  
  logDebug(fmt"处理完成: 成功链接 {linkedFilesCount} 个文件, 复制 {copiedFilesCount} 个字幕文件, 创建 {createdDirsInTargetCount} 个目录")

# --- 字幕扩展名处理 ---
proc getSubtitleSuffix*(subFilename, videoBaseName: string): string =
  ## 递归分割字幕文件名，直到找到与视频文件名匹配的部分
  ## 返回字幕文件的后缀部分
  
  # 获取完整的文件名和扩展名
  let (_, name, ext) = splitFile(subFilename)
  
  # 直接比较文件名(不含扩展名)是否与视频文件名相同
  if name == videoBaseName:
    return ext
    
  # 防止死循环：如果文件名中没有点号，直接返回扩展名
  if name.find('.') == -1:
    return ext
    
  # 如果文件名不匹配，但可能是因为字幕文件名包含额外信息
  # 例如: 视频="anime", 字幕="anime.1080p.FLAC-CoolFansSub"
  
  # 分割文件名最后一个点号
  let lastDotPos = name.rfind('.')
  if lastDotPos == -1:
    return ext  # 没有点号，直接返回扩展名
    
  let nameBase = name[0 ..< lastDotPos]
  let nameSuffix = name[lastDotPos .. ^1]
  
  # 检查基础部分是否匹配视频名
  if nameBase == videoBaseName:
    return nameSuffix & ext
    
  # 递归处理剩余部分
  # 限制递归深度，防止死循环
  let maxDepth = 5  # 最多允许5层递归
  var depth = 0
  var currentName = nameBase
  var suffixes = @[nameSuffix]
  
  while depth < maxDepth:
    depth += 1
    
    let nextDotPos = currentName.rfind('.')
    if nextDotPos == -1:
      break  # 没有更多的点号
      
    let nextBase = currentName[0 ..< nextDotPos]
    let nextSuffix = currentName[nextDotPos .. ^1]
    
    suffixes.add(nextSuffix)
    
    if nextBase == videoBaseName:
      # 找到匹配，组合所有后缀
      suffixes.add(ext)
      return suffixes.reversed().join("")
      
    currentName = nextBase
  
  # 如果未找到匹配或达到最大深度，返回原始扩展名
  return ext

proc safeGetSubtitleSuffix*(subFilename, videoBaseName: string): string =
  ## 包装getSubtitleSuffix函数，增加额外的安全检查和调试信息
  logDebug(fmt"尝试获取字幕后缀: 字幕文件='{subFilename}', 视频文件名='{videoBaseName}'")
  result = getSubtitleSuffix(subFilename, videoBaseName)
  logDebug(fmt"获取到字幕后缀: '{result}'")
  return result

proc parseSubtitleExtension*(fullExt: string, videoBaseName: string = ""): SubtitleInfo =
  ## 解析字幕扩展名，返回结构化信息
  ## 如果提供了视频基本文件名，则尝试匹配
  result.rawExt = fullExt
  
  # 查找基础扩展名
  for base in knownBaseSuffixes:
    if fullExt.toLower().endsWith(base.toLower()):
      result.baseExt = fullExt[^base.len..^1]
      break
  
  # 如果没有找到已知扩展名，使用最后一个.后的内容
  if result.baseExt.len == 0:
    let lastDot = fullExt.rfind('.')
    if lastDot >= 0:
      result.baseExt = fullExt[lastDot..^1]
    else:
      result.baseExt = fullExt
  
  # 设置复合标志
  result.isCompound = fullExt.count('.') > 1
  
  # 如果提供了视频基本文件名，则使用新的递归匹配逻辑
  if videoBaseName.len > 0:
    # 假设我们有完整的文件名，构造一个临时文件名
    let tempFullName = videoBaseName & fullExt
    # 获取字幕后缀
    result.suffix = safeGetSubtitleSuffix(tempFullName, videoBaseName)
  else:
    # 兼容旧逻辑，返回整个扩展名
    result.suffix = fullExt

proc isCompoundSubtitle*(filename: string): bool =
  ## 判断是否为复合语言代码字幕文件
  # 检查文件是否是字幕文件
  if not isSubtitleFile(filename):
    return false
    
  # 提取文件名部分(不含路径但含扩展名)
  let (_, filenameOnly) = splitPath(filename)
  
  # 提取不带扩展名的文件名
  let (_, nameWithoutExt, _) = splitFile(filenameOnly)
  
  # 检查文件名中是否有多个点号，表示可能有复合语言代码
  # 例如: episode01.scjp.ass
  return nameWithoutExt.contains('.')

# --- 字幕文件复制/硬链接逻辑 ---
proc processSubtitleFile*(sourceFile, targetFile: string): bool =
  ## 处理字幕文件(始终复制而非硬链接)
  ## 返回是否成功
  if not fileExists(sourceFile):
    logDebug(fmt"字幕文件不存在: '{sourceFile}'")
    return false
    
  # 创建目标目录（如果不存在）
  let targetDir = parentDir(targetFile)
  if not dirExists(targetDir):
    try:
      createDir(targetDir)
      logDebug(fmt"创建目录: '{targetDir}'")
    except OSError as e:
      logDebug(fmt"创建目录失败: '{targetDir}', 错误: {e.msg}")
      return false
  
  # 已存在则跳过
  if fileExists(targetFile):
    logDebug(fmt"字幕文件已存在: '{targetFile}'")
    return true
    
  try:
    # 所有字幕文件都直接复制
    copyFile(sourceFile, targetFile)
    logDebug(fmt"复制字幕成功: '{sourceFile}' -> '{targetFile}'")
    return true
  except OSError as e:
    logDebug(fmt"复制字幕失败: '{sourceFile}' -> '{targetFile}', 错误: {e.msg}")
    return false

# --- 字幕文件重命名逻辑 ---
proc getSubtitleFilesByPattern*(files: seq[string], pattern: string): seq[string] =
  ## 根据模式匹配字幕文件
  result = @[]
  let patternLower = pattern.toLower()
  
  for file in files:
    if isSubtitleFile(file) and file.toLower().contains(patternLower):
      result.add(file)

proc renameSubtitleFile*(sourceFile, targetFile: string): bool =
  ## 重命名字幕文件，保留完整扩展名
  if not fileExists(sourceFile):
    logDebug(fmt"要重命名的字幕文件不存在: '{sourceFile}'")
    return false
    
  if sourceFile == targetFile:
    logDebug(fmt"字幕文件名已正确，无需重命名: '{sourceFile}'")
    return true
    
  try:
    moveFile(sourceFile, targetFile)
    logDebug(fmt"重命名字幕成功: '{sourceFile}' -> '{targetFile}'")
    return true
  except OSError as e:
    logDebug(fmt"重命名字幕失败: '{sourceFile}' -> '{targetFile}', 错误: {e.msg}")
    return false

# --- 集成到现有系统的修改版renameFilesBasedOnCache ---
proc renameFilesBasedOnCache*(
    targetSeasonPath: string,
    seasonInfo: CachedSeasonInfo,
    filesInTargetDir: seq[string] 
  ) =
  ## 根据缓存信息重命名文件 (使用新的字幕匹配逻辑)
  
  if not dirExists(targetSeasonPath):
    stderr.writeLine fmt"错误: 目标番剧文件夹 '{targetSeasonPath}' 不存在，无法重命名。"
    return

  var renamedFilesCount = 0
  var renameErrorsCount = 0
  
  # 详细记录所有文件列表，帮助调试
  logDebug(fmt"目标文件夹'{targetSeasonPath}'中的所有文件:")
  for file in filesInTargetDir:
    logDebug(fmt"  - {file}")

  # 处理每个剧集
  for epKey, cachedEp in pairs(seasonInfo.episodes):
    if cachedEp.nameOnly.isNone:
      continue
      
    let cleanBangumiEpName = sanitizeFilename(cachedEp.bangumiName)
    let newFileNameBasePart = sanitizeFilename(fmt"{epKey} - {cleanBangumiEpName}")
    let cachedNameOnly = cachedEp.nameOnly.get()
    let cleanedCachedName = getCleanedBaseName(cachedNameOnly)
    
    # --- 视频文件处理 ---
    var matchedVideoFile: Option[string] = none(string)
    var matchedVideoName = ""
    
    if cachedEp.videoExt.isSome:
      let videoExt = cachedEp.videoExt.get()
      
      # 查找匹配的视频文件
      for file in filesInTargetDir:
        let (_, namePart, extPart) = splitFile(file)
        if extPart == videoExt:
          let cleanedNamePart = getCleanedBaseName(namePart)
          if cleanedNamePart == cleanedCachedName:
            matchedVideoFile = some(file)
            matchedVideoName = namePart  # 记录找到的视频文件名
            break
      
      # 重命名视频文件
      if matchedVideoFile.isSome:
        let oldVideoPath = targetSeasonPath / matchedVideoFile.get()
        let newVideoPath = targetSeasonPath / (newFileNameBasePart & videoExt)
        
        if oldVideoPath != newVideoPath:
          if fileExists(oldVideoPath):
            try:
              moveFile(oldVideoPath, newVideoPath)
              renamedFilesCount += 1
              logDebug(fmt"重命名视频成功: '{oldVideoPath}' -> '{newVideoPath}'")
            except OSError as e:
              stderr.writeLine fmt"错误: 重命名视频文件 '{oldVideoPath}' 到 '{newVideoPath}' 失败: {e.msg}"
              renameErrorsCount += 1
              logDebug(fmt"重命名视频失败: '{oldVideoPath}' -> '{newVideoPath}', 错误: {e.msg}")
          else:
            stderr.writeLine fmt"警告: 预期的视频文件 '{oldVideoPath}' 在尝试重命名时未找到。"
            logDebug(fmt"视频文件未找到: '{oldVideoPath}'")
    
    # --- 字幕文件处理 (新逻辑) ---
    # 如果没找到视频文件，则使用缓存中的名称
    if matchedVideoName.len == 0:
      matchedVideoName = cachedNameOnly # 使用缓存中的名称作为后备

    # 查找所有匹配视频文件名的字幕文件
    var matchedSubFiles: seq[string] = @[]
    for file in filesInTargetDir:
      if isSubtitleFile(file):
        let (_, subNameFull, _) = splitFile(file)
        
        # 1. 尝试直接匹配文件名
        if subNameFull == matchedVideoName:
          matchedSubFiles.add(file)
          continue
          
        # 2. 尝试匹配清理后的文件名
        let cleanedSubName = getCleanedBaseName(subNameFull)
        if cleanedSubName == cleanedCachedName:
          matchedSubFiles.add(file)
          continue
          
        # 3. 尝试递归分割字幕文件名
        var currentName = subNameFull
        var depth = 0
        let maxDepth = 5  # 设置递归深度限制
        while currentName.len > 0 and currentName.find('.') != -1 and depth < maxDepth:
          depth += 1
          
          # 使用rfind找到最后一个点号，从后向前分割
          let lastDotPos = currentName.rfind('.')
          if lastDotPos == -1:
            break  # 安全检查
            
          let nameBase = currentName[0 ..< lastDotPos]
          
          # 检查是否匹配
          if nameBase == matchedVideoName or getCleanedBaseName(nameBase) == cleanedCachedName:
            matchedSubFiles.add(file)
            break
            
          # 更新下一次迭代的名称
          currentName = nameBase

    # 记录找到的匹配字幕文件
    logDebug(fmt"剧集 {epKey} 找到的匹配字幕文件: {matchedSubFiles}")
    
    # 重命名匹配的字幕文件
    for subFile in matchedSubFiles:
      # 在重命名字幕文件之前处理文件名
      let oldSubPath = targetSeasonPath / subFile

      # 递归获取字幕文件的后缀
      proc getSubtitleExt(subFilename: string, videoBaseName: string): string =
        # 先尝试直接分割
        let (_, name, ext) = splitFile(subFilename)
        
        # 如果文件名直接匹配，返回扩展名
        if name == videoBaseName:
          return ext
        
        # 如果没有点号，则无法进一步分割
        if name.find('.') == -1:
          return ext
        
        # 递归分割
        let (_, innerName, innerExt) = splitFile(name)
        
        # 检查分割后的内部名称是否与视频名匹配
        if innerName == videoBaseName:
          # 匹配成功，返回内部扩展名+原始扩展名
          return innerExt & ext
        
        # 继续递归分割
        let remainingSuffix = getSubtitleExt(innerName, videoBaseName)
        if remainingSuffix.len > 0:
          return remainingSuffix & innerExt & ext
        
        # 如果无法匹配，返回原始扩展名
        return ext

      # 获取视频文件名作为基准
      let videoBaseName = if matchedVideoName.len > 0: matchedVideoName else: cleanedCachedName

      # 获取字幕文件的后缀
      let subExt = getSubtitleExt(subFile, videoBaseName)
      logDebug(fmt"字幕处理: 文件='{subFile}', 视频名='{videoBaseName}', 获取到后缀='{subExt}'")

      # 构建新路径
      let newSubPath = targetSeasonPath / (newFileNameBasePart & subExt)

      if oldSubPath != newSubPath and fileExists(oldSubPath):
        try:
          moveFile(oldSubPath, newSubPath)
          renamedFilesCount += 1
          logDebug(fmt"重命名字幕成功: '{oldSubPath}' -> '{newSubPath}'")
        except OSError as e:
          stderr.writeLine fmt"错误: 重命名字幕文件 '{oldSubPath}' 到 '{newSubPath}' 失败: {e.msg}"
          renameErrorsCount += 1
          logDebug(fmt"重命名字幕失败: '{oldSubPath}' -> '{newSubPath}', 错误: {e.msg}")
      else:
        if oldSubPath == newSubPath:
          logDebug(fmt"字幕文件名已正确，无需重命名: '{oldSubPath}'")
        else:
          stderr.writeLine fmt"警告: 预期的字幕文件 '{oldSubPath}' 在尝试重命名时未找到。"
          logDebug(fmt"字幕文件未找到: '{oldSubPath}'")
  
  # 总结
  if renameErrorsCount > 0:
    stderr.writeLine fmt"番剧 '{seasonInfo.bangumiSeasonName}' 重命名期间发生 {renameErrorsCount} 个错误。"
  
  logDebug(fmt"重命名完成: 成功重命名 {renamedFilesCount} 个文件，失败 {renameErrorsCount} 个文件")

# --- 缓存处理相关函数 (从原 core/cache_manager.nim 移动过来) ---
proc extractEpisodeNumberFromName*(fileName: string): Option[float] =
  ## 尝试从文件名中提取剧集号 (可能包含小数)。
  let patterns = [
    re"S\d+[._-]?E(\d+(?:\.\d+)?)\b", # E20 or E20.5
    re"\b(?:EP|E|第|\[)\s*(\d+(?:\.\d+)?)\b", # EP20, E 20, 第20, [20, EP20.5, E 20.5
    re"\[(\d+(?:\.\d+)?)\]", # [20], [20.5]
    re"\s-\s(\d+(?:\.\d+)?)\b", # - 20, - 20.5
    re"\b(\d+(?:\.\d+)?)\s*\[", # 20 [, 20.5 [
    re"\b(\d+(?:\.\d+)?)(?:v\d)?\b"  # 20, 20.5 (作为最后的捕获，可能较宽泛), 忽略可能的 v2, v3 版本号
  ]
  for pattern in patterns:
    var match: array[1, string]
    if fileName.find(pattern, match) != -1:
      try:
        return some(parseFloat(match[0]))
      except ValueError:
        continue
  return none[float]()

proc formatEpisodeNumber*(currentSort: float, totalEpisodes: int): string =
  ## 根据总集数格式化剧集编号，例如 E01, E20.5。
  let sortInt = int(currentSort)
  # 检查 currentSort 是否非常接近一个整数，如果是，则当作整数处理小数部分
  let sortFrac = if abs(currentSort - round(currentSort)) < 0.0001: 0.0 else: currentSort - float(sortInt)

  var numStr = $sortInt
  var prefix = "E"
  var requiredDigits = 1
  if totalEpisodes >= 10000: requiredDigits = 5
  elif totalEpisodes >= 1000: requiredDigits = 4
  elif totalEpisodes >= 100: requiredDigits = 3
  elif totalEpisodes >= 10: requiredDigits = 2
  
  let zerosToPad = requiredDigits - numStr.len
  if zerosToPad > 0:
    for _ in 1 .. zerosToPad: prefix.add('0')
  
  var formattedEpStr = prefix & numStr
  if sortFrac > 0.001: # 使用一个小的阈值来处理浮点数精度
    let fracStr = $sortFrac
    if fracStr.startsWith("0."):
      formattedEpStr.add(fracStr[1 .. ^1]) # 添加 ".5"
    elif fracStr.startsWith("."):
      formattedEpStr.add(fracStr)
    else: # 对于像 "1.0" 这样的情况（如果 sortFrac 意外地是这样），这可能不是预期的
          # 但对于典型的 .5, .25 应该是安全的
      formattedEpStr.add("." & fracStr.replace("0.", ".")) # 确保移除 "0."
  return formattedEpStr

proc appendToCacheCsv*(originalInputName: string, seasonId: int, seasonName: string, cacheFilePath: string) =
  ## 将番剧的原始文件夹名、Bangumi番剧名和Bangumi番剧ID追加到 cache.csv。
  let line = fmt"{originalInputName},{seasonName},{seasonId}"
  try:
    let f = open(cacheFilePath, fmAppend)
    defer: f.close()
    f.writeLine(line)
  except IOError as e:
    echo &"错误: 追加到 {cacheFilePath} 失败: {e.msg}"

proc readCsvCacheEntries*(filePath: string): Table[string, CsvCacheEntry] =
  ## 从 cache.csv 加载原始文件夹名到 Bangumi Season ID 的映射。
  ## 忽略文件的第一行，因为它包含程序配置信息。
  result = initTable[string, CsvCacheEntry]()
  if not fileExists(filePath):
    return
  
  var isFirstLine = true
  try:
    for line in lines(filePath):
      let strippedLine = line.strip()
      # 跳过第一行（配置信息）、空行和注释行
      if isFirstLine:
        isFirstLine = false
        continue
      
      if strippedLine.len == 0 or strippedLine.startsWith("#"):
        continue
        
      let parts = strippedLine.split(',')
      if parts.len == 3: 
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
        echo fmt"警告: cache.csv 行格式无法识别 (期望3个字段): {strippedLine}"
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}"

proc loadJsonCache*(filePath: string): Table[string, CachedSeasonInfo] =
  ## 从 cache.json 加载番剧剧集缓存数据。
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
          echo fmt"警告: 解析 cache.json 中番剧ID '{seasonIdKey}' 的数据失败。"
    else:
      echo &"警告: {filePath} 的根不是一个有效的 JSON 对象。"
  except JsonParsingError as e:
    echo &"错误: 解析 {filePath} (JSON) 失败: {e.msg}"
  except IOError as e:
    echo &"错误: 读取 {filePath} 失败: {e.msg}"

proc saveJsonCache*(filePath: string, cacheData: Table[string, CachedSeasonInfo]) =
  ## 将番剧剧集缓存数据保存到 cache.json，并确保番剧ID和剧集按顺序排列。
  var rootNode = newJObject()
  var sortedSeasonIdInts = newSeq[int]()
  for seasonIdKey in cacheData.keys:
    try:
      sortedSeasonIdInts.add(parseInt(seasonIdKey))
    except ValueError:
      continue
  
  sortedSeasonIdInts.sort(cmp[int])

  for seasonIdInt in sortedSeasonIdInts:
    let seasonIdKey = $seasonIdInt 
    if not cacheData.hasKey(seasonIdKey):
        continue
    
    let seasonInfo = cacheData[seasonIdKey]
    var seasonInfoNode = newJObject()

    seasonInfoNode["bangumiSeasonId"] = %*(seasonInfo.bangumiSeasonId)
    seasonInfoNode["bangumiSeasonName"] = %*(seasonInfo.bangumiSeasonName)
    seasonInfoNode["totalBangumiEpisodes"] = %*(seasonInfo.totalBangumiEpisodes)

    var sortedEpisodeKeys = newSeq[string]()
    if seasonInfo.episodes.len > 0: 
      for epKey in seasonInfo.episodes.keys:
        sortedEpisodeKeys.add(epKey)
      
      sortedEpisodeKeys.sort(cmp[string]) 

      var episodesNode = newJObject()
      for epKey in sortedEpisodeKeys:
        if seasonInfo.episodes.hasKey(epKey):
          episodesNode[epKey] = %*(seasonInfo.episodes[epKey])
      seasonInfoNode["episodes"] = episodesNode 
    else:
      seasonInfoNode["episodes"] = newJObject() 
    rootNode[seasonIdKey] = seasonInfoNode   

  try:
    writeFile(filePath, pretty(rootNode))
  except IOError as e:
    echo &"错误: 写入到 {filePath} 失败: {e.msg}"

proc readDir*(path: string): seq[string] =
  ## 读取指定路径下的所有文件夹名称。
  var dirs = newSeq[string]()
  try:
    for item in walkDir(path):
      if item.kind == pcDir:
        dirs.add(item.path.extractFilename())
  except OSError as e:
    stderr.writeLine fmt"错误: 读取目录 '{path}' 失败: {e.msg}"
  return dirs

# --- 向后兼容函数 ---
proc getCleanSubtitleExtension*(originalFullExt: string, videoBaseName: string = ""): string =
  ## 向后兼容版本的字幕扩展名处理函数
  ## 从完整的扩展名字符串中提取干净的字幕后缀
  let subInfo = parseSubtitleExtension(originalFullExt, videoBaseName)
  return subInfo.suffix