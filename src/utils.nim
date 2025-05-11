import std/[os, strutils, strformat, re, tables, options, json, algorithm, sequtils, math] # Removed sets, streams, Added math
import std/collections/tables as ctables # 单独导入collections/tables以避免命名冲突
# import ./core/types # Types will be defined locally or imported from other new modules

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

# --- 字符串和排序工具函数 (从原 core/utils_string.nim 移动过来) ---
proc getCleanedBaseName*(name: string): string =
  ## 从文件名中移除常见的分辨率、编码、发布组等标签，得到一个更“干净”的基础名称。
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
  # 移除括号/方括号中的数字和可能的 "v2", "OVA", "SP" 等
  baseName = baseName.replace(re(r"\s*\[\s*(?:\d+(?:\.\d+)?|SP\d*|OVA\d*|OAD\d*|NCED|NCOP|Preview|PV)\s*\]", {reIgnoreCase}), "")
  baseName = baseName.replace(re(r"\s*\(\s*(?:\d+(?:\.\d+)?|SP\d*|OVA\d*|OAD\d*|NCED|NCOP|Preview|PV)\s*\)", {reIgnoreCase}), "")
  # 移除 " - 01", " 01 ", " E01 " 等模式
  baseName = baseName.replace(re(r"\s*(?:-|E|EP)?\s*\d+(?:\.\d+)?(?:v\d)?(?:\s*-|\s+|$)", {reIgnoreCase}), " ") # 保留一个空格用于后续清理
  # 移除单独的数字，通常在末尾或被空格包围
  baseName = baseName.replace(re(r"\b\d+(?:\.\d+)?\b"), "") # 这个通常不需要 reIgnoreCase，但为了统一，可以加上
  # 清理多余的空格和末尾的特殊字符
  baseName = baseName.replace(re(r"\s+"), " ").strip(chars = {' ', '-', '_', '.'})
  # 移除末尾可能存在的 " -"
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
  var createdDirsInTargetCount = 0 
  var linkErrorsCount = 0
  var dirCreateErrorsCount = 0

  for kind, itemFullPathInSource in walkDir(sourceDir): 
    if not itemFullPathInSource.startsWith(sourceDir):
      continue
    
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

    let targetItemPath = targetDir / relativeItemPath

    case kind
    of pcFile:
      let targetFileParentDir = parentDir(targetItemPath)
      try:
        if not dirExists(targetFileParentDir):
          createDir(targetFileParentDir)
      except OSError:
        discard 
      
      try:
        if fileExists(targetItemPath): 
          discard
        else:
          createHardLink(itemFullPathInSource, targetItemPath)
          linkedFilesCount += 1
      except OSError as e:
        stderr.writeLine fmt"错误: 硬链接文件 '{itemFullPathInSource}' 到 '{targetItemPath}' 失败: {e.msg}"
        linkErrorsCount += 1
    of pcDir:
      try:
        if not dirExists(targetItemPath):
          createDir(targetItemPath)
          createdDirsInTargetCount += 1
      except OSError:
        dirCreateErrorsCount += 1
    else: 
      discard

  if linkErrorsCount > 0 or dirCreateErrorsCount > 0:
    stderr.writeLine fmt"硬链接期间发生错误: {linkErrorsCount} 个文件链接失败, {dirCreateErrorsCount} 个目录创建失败。"

proc renameFilesBasedOnCache*(
    targetSeasonPath: string,
    seasonInfo: CachedSeasonInfo,
    filesInTargetDir: seq[string] 
  ) =
  ## 根据 seasonInfo 和目标目录中的实际文件列表重命名文件。
  # Log file writing removed for cleaner output
  # let logFilePath = targetSeasonPath / "rename_operations.log"
  # var logStream = newFileStream(logFilePath, fmWrite)
  # if logStream == nil:
  #   stderr.writeLine fmt"严重错误: 无法打开日志文件 '{logFilePath}' 进行写入。"
  #
  # defer:
  #   if logStream != nil:
  #     logStream.close()

  if not dirExists(targetSeasonPath):
    stderr.writeLine fmt"错误: 目标番剧文件夹 '{targetSeasonPath}' 不存在，无法重命名。" # Kept stderr for critical errors
    return

  # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 开始处理番剧 '{seasonInfo.bangumiSeasonName}' 于路径 '{targetSeasonPath}'")
  var renamedFilesCount = 0
  var renameErrorsCount = 0

  for epKey, cachedEp in pairs(seasonInfo.episodes):
    # let episodeNameForLog = cachedEp.nameOnly.get("N/A")  # Removed log-specific var
    # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 处理剧集 '{epKey}', 缓存名称: '{episodeNameForLog}'")
    if cachedEp.nameOnly.isNone:
      # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}' 在缓存中没有基础文件名 (nameOnly)，跳过重命名。" )
      continue

    let cleanBangumiEpName = sanitizeFilename(cachedEp.bangumiName) # Uses sanitizeFilename from this module
    let newFileNameBasePart = sanitizeFilename(fmt"{epKey} - {cleanBangumiEpName}") # Uses sanitizeFilename

    if cachedEp.videoExt.isSome:
      let videoExt = cachedEp.videoExt
      var oldVideoFileOriginalName: Option[string] = none(string)

      for actualFileInDir in filesInTargetDir:
        var (fileDir, namePart, extPart) = splitFile(actualFileInDir)
        discard fileDir
        if cachedEp.videoExt.isSome and extPart == cachedEp.videoExt.get():
          # cachedEp.nameOnly now stores the original nameOnly of the matched video file
          if cachedEp.nameOnly.isSome and namePart == cachedEp.nameOnly.get():
            oldVideoFileOriginalName = some(actualFileInDir)
            break
      
      if oldVideoFileOriginalName.isSome:
        let oldVideoName = oldVideoFileOriginalName.get()
        let currentVideoExt = videoExt.get()
        # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 准备重命名视频 - 旧文件确定为: '{oldVideoName}'")
        # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): PRE-CONSTRUCT VIDEO PATH - targetSeasonPath='{targetSeasonPath}', oldVideoFileOriginalName='{oldVideoName}', newFileNameBasePart='{newFileNameBasePart}', videoExt='{currentVideoExt}'")
        let oldVideoFullPath = targetSeasonPath / oldVideoName
        let newVideoFullName = newFileNameBasePart & currentVideoExt
        let newVideoFullPath = targetSeasonPath / newVideoFullName
        # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名 - 旧路径: '{oldVideoFullPath}', 新路径: '{newVideoFullPath}'")

        if oldVideoFullPath != newVideoFullPath:
          if fileExists(oldVideoFullPath):
            try:
              moveFile(oldVideoFullPath, newVideoFullPath)
              renamedFilesCount += 1
              # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名成功: '{oldVideoFullPath}' -> '{newVideoFullPath}'")
            except OSError as e:
              stderr.writeLine fmt"错误: 重命名视频文件 '{oldVideoFullPath}' 到 '{newVideoFullPath}' 失败: {e.msg}" # Kept stderr
              # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名失败: {e.msg}")
              renameErrorsCount += 1
          else:
            stderr.writeLine fmt"警告: 预期的视频文件 '{oldVideoFullPath}' 在尝试重命名时未找到。" # Kept stderr
            # if logStream != nil: logStream.writeLine(warnMsg) else: stderr.writeLine(warnMsg)
        # else: # Log removed
          # if logStream != nil: logStream.writeLine(fmt"信息: 视频文件 '{oldVideoFullPath}' 名称已符合期望格式 '{newVideoFullName}'，无需重命名。" )
      # else: # Log removed
        # let expectedExtStr = videoExt.get("N/A")
        # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}': 未能在目标目录中找到匹配的视频文件 (期望后缀: {expectedExtStr})。" )

    if cachedEp.subtitleExts.len > 0:
      for subExtExpected in cachedEp.subtitleExts:
        # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕处理 - 剧集 '{epKey}', 期望字幕后缀: '{subExtExpected}'")
        var oldSubFileOriginalName: Option[string] = none(string)
        for actualFileInDir in filesInTargetDir:
          if actualFileInDir.endsWith(subExtExpected): # Check if the file has the expected subtitle extension
            var (fileDir, namePartOfSub, extAlso) = splitFile(actualFileInDir[0 .. ^(subExtExpected.len+1)])
            discard fileDir
            discard extAlso # This should be empty if subExtExpected was the full extension part

            # cachedEp.nameOnly stores the original nameOnly of the associated video file (or a primary sub if no video)
            # We expect the subtitle's original name (before its specific language extension) to match this.
            if cachedEp.nameOnly.isSome and namePartOfSub == cachedEp.nameOnly.get():
              oldSubFileOriginalName = some(actualFileInDir)
              break
            # Fallback: if direct nameOnly match fails, compare base names (without episode numbers)
            # This helps if video is "Show - 01" and sub is "Show - 01.sc"
            # and cachedEp.nameOnly was "Show - 01"
            # but actualFileInDir is "Show - 01.sc.ass" -> namePartOfSub becomes "Show - 01.sc"
            # In this case, we need to compare getBaseNameWithoutEpisode(namePartOfSub) with getBaseNameWithoutEpisode(cachedEp.nameOnly.get())
            # However, the primary strategy is direct match of nameOnly (which should be the video's nameOnly)
            # The current CachedEpisodeInfo.nameOnly is already the *original* nameOnly of the video/primary file.
            # So, namePartOfSub (which is actualFileInDir minus subExtExpected) should directly match.
            # The issue might be if subExtExpected is just ".ass" but the file is ".sc.ass".
            # The `subExtExpected` comes from `CachedEpisodeInfo.subtitleExts`, which should be correctly populated
            # by `updateAndSaveJsonCache` to include things like ".sc.ass".

            # Let's refine the subtitle matching:
            # The `namePartOfSub` is `actualFileInDir` with `subExtExpected` stripped.
            # This `namePartOfSub` should be identical to `cachedEp.nameOnly.get()` if `cachedEp.nameOnly`
            # was derived from the video file that this subtitle belongs to.
            # Example:
            # Video: "Title [01].mkv" -> cachedEp.nameOnly = "Title [01]"
            # Sub:   "Title [01].sc.ass" -> subExtExpected = ".sc.ass"
            #        actualFileInDir = "Title [01].sc.ass"
            #        namePartOfSub (after stripping .sc.ass) = "Title [01]"
            #        This matches cachedEp.nameOnly.

            # If cachedEp.nameOnly was derived from another subtitle (because no video was found),
            # then namePartOfSub should match that.
            # The current logic `namePartOfSub == cachedEp.nameOnly.get()` should cover this.
            # No need for getCleanedBaseName here for matching, as cachedEp.nameOnly is already the target original name.
            # getCleanedBaseName was for a different comparison strategy.
        
        if oldSubFileOriginalName.isSome:
          let oldSubName = oldSubFileOriginalName.get()
          # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 准备重命名字幕 - 旧文件确定为: '{oldSubName}'")
          # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): PRE-CONSTRUCT SUB PATH - targetSeasonPath='{targetSeasonPath}', oldSubFileOriginalName='{oldSubName}', newFileNameBasePart='{newFileNameBasePart}', subExtExpected='{subExtExpected}'")
          let oldSubFullPath = targetSeasonPath / oldSubName
          let newSubFullName = newFileNameBasePart & subExtExpected
          let newSubFullPath = targetSeasonPath / newSubFullName
          # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名 - 旧路径: '{oldSubFullPath}', 新路径: '{newSubFullPath}'")

          if oldSubFullPath != newSubFullPath:
            if fileExists(oldSubFullPath):
              try:
                moveFile(oldSubFullPath, newSubFullPath)
                renamedFilesCount += 1
                # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名成功: '{oldSubFullPath}' -> '{newSubFullPath}'")
              except OSError as e:
                stderr.writeLine fmt"错误: 重命名字幕文件 '{oldSubFullPath}' 到 '{newSubFullPath}' 失败: {e.msg}" # Kept stderr
                # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名失败: {e.msg}")
                renameErrorsCount += 1
            else:
              stderr.writeLine fmt"警告: 预期的字幕文件 '{oldSubFullPath}' 在尝试重命名时未找到。" # Kept stderr
              # if logStream != nil: logStream.writeLine(warnMsg) else: stderr.writeLine(warnMsg)
          # else: # Log removed
            # if logStream != nil: logStream.writeLine(fmt"信息: 字幕文件 '{oldSubFullPath}' 名称已符合期望格式 '{newSubFullName}'，无需重命名。" )
        # else: # Log removed
          # if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}': 未能在目标目录中找到匹配的字幕文件 (期望后缀: {subExtExpected})。" )
  
  # if logStream != nil: logStream.writeLine(fmt"番剧 '{seasonInfo.bangumiSeasonName}' 重命名完成。成功: {renamedFilesCount} 个文件, 失败: {renameErrorsCount} 个。" )
  if renameErrorsCount > 0:
    stderr.writeLine fmt"番剧 '{seasonInfo.bangumiSeasonName}' 重命名期间发生 {renameErrorsCount} 个错误。" # Kept stderr
    # if logStream != nil: logStream.writeLine(errorMsg) else: stderr.writeLine(errorMsg)

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
  result = initTable[string, CsvCacheEntry]()
  if not fileExists(filePath):
    return
  try:
    for line in lines(filePath):
      let strippedLine = line.strip()
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