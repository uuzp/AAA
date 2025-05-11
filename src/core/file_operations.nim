import ./types
import std/[os, strutils, strformat, re, tables, options]
import std/collections/tables as ctables # 单独导入collections/tables以避免命名冲突

# --- 文件操作和重命名辅助函数 ---
proc sanitizeFilename*(filename: string): string =
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

proc createDirectoryHardLinkRecursive*(sourceDir: string, targetDir: string) =
  ## 递归地将 sourceDir 的内容硬链接到 targetDir。
  ## sourceDir 内的文件会硬链接到 targetDir 下的同名文件。
  ## sourceDir 内的子目录会在 targetDir 下创建，并递归处理。
  if not dirExists(sourceDir):
    stderr.writeLine fmt"错误: 源目录 '{sourceDir}' 不存在，无法执行硬链接。"
    return

  # echo fmt"  尝试硬链接目录内容从 '{sourceDir}' 到 '{targetDir}'" # 减少默认输出
  
  # 确保目标根目录存在
  try:
    if not dirExists(targetDir):
      createDir(targetDir)
      # echo fmt"    创建目标根目录: {targetDir}" # 减少默认输出
  except OSError as e:
    stderr.writeLine fmt"    严重错误: 创建目标根目录 '{targetDir}' 失败: {e.msg}. 中止此目录的硬链接。"
    return

  var linkedFilesCount = 0
  var createdDirsInTargetCount = 0 
  var linkErrorsCount = 0
  var dirCreateErrorsCount = 0

  for kind, itemFullPathInSource in walkDir(sourceDir): 
    if not itemFullPathInSource.startsWith(sourceDir):
      # echo fmt"    警告: 遍历路径 '{itemFullPathInSource}' 不在源目录 '{sourceDir}' 下，跳过。" # 减少默认输出
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
        # echo fmt"      警告: 为文件链接创建父目录 '{targetFileParentDir}' 失败: {e.msg}" # 减少默认输出
        discard # 即使父目录创建失败，也尝试链接
      
      try:
        if fileExists(targetItemPath): 
          # echo fmt"      警告: 目标文件 '{targetItemPath}' 已存在，跳过硬链接。" # 减少默认输出
          discard
        else:
          createHardLink(itemFullPathInSource, targetItemPath)
          linkedFilesCount += 1
      except OSError as e:
        stderr.writeLine fmt"      错误: 硬链接文件 '{itemFullPathInSource}' 到 '{targetItemPath}' 失败: {e.msg}"
        linkErrorsCount += 1
    of pcDir:
      try:
        if not dirExists(targetItemPath):
          createDir(targetItemPath)
          createdDirsInTargetCount += 1
      except OSError:
        # echo fmt"      警告: 创建目标子目录 '{targetItemPath}' 失败: {e.msg}" # 减少默认输出
        dirCreateErrorsCount += 1
    else: 
      discard

  # echo fmt"    硬链接完成: {linkedFilesCount} 个文件已链接, {createdDirsInTargetCount} 个新目录已在目标中创建。" # 减少默认输出
  if linkErrorsCount > 0 or dirCreateErrorsCount > 0:
    stderr.writeLine fmt"    硬链接期间发生错误: {linkErrorsCount} 个文件链接失败, {dirCreateErrorsCount} 个目录创建失败。"

proc renameFilesBasedOnCache*(
    targetSeasonPath: string, 
    seasonInfo: CachedSeasonInfo,
    originalFolderName: string 
  ) =
  ## 根据 seasonInfo 重命名 targetSeasonPath 下的文件。
  ## targetSeasonPath 是硬链接后的番剧文件夹路径。

  # echo fmt"    开始重命名番剧 '{seasonInfo.bangumiSeasonName}' (源文件夹: '{originalFolderName}') 内的文件，位于: '{targetSeasonPath}'" # 减少默认输出

  if not dirExists(targetSeasonPath):
    stderr.writeLine fmt"    错误: 目标番剧文件夹 '{targetSeasonPath}' 不存在，无法重命名。"
    return

  var renamedFilesCount = 0
  var renameErrorsCount = 0
  for epKey, valFromTable in pairs(seasonInfo.episodes):
    let cachedEp = valFromTable # Assuming valFromTable is indeed CachedEpisodeInfo
    let episodeNumberFormatted = epKey
    
    let cleanEpisodeName = sanitizeFilename(cachedEp.bangumiName)

    if cachedEp.localVideoFile.isSome:
      let videoInfo = cachedEp.localVideoFile.get()
      let originalFileNameWithExt = extractFilename(videoInfo.fullPath)
      let oldHardlinkedVideoPath = targetSeasonPath / originalFileNameWithExt

      if fileExists(oldHardlinkedVideoPath):
        let baseNameWithoutExt = fmt"{episodeNumberFormatted} - {cleanEpisodeName}"
        let finalBaseName = sanitizeFilename(baseNameWithoutExt)
        let newVideoFileNameWithExt = finalBaseName & videoInfo.ext

        let newHardlinkedVideoPath = targetSeasonPath / newVideoFileNameWithExt

        if oldHardlinkedVideoPath != newHardlinkedVideoPath:
          try:
            # echo fmt"      重命名视频: '{oldHardlinkedVideoPath}' -> '{newHardlinkedVideoPath}'" # 减少默认输出
            moveFile(oldHardlinkedVideoPath, newHardlinkedVideoPath)
            renamedFilesCount += 1
          except OSError as e:
            stderr.writeLine fmt"      错误: 重命名视频文件 '{oldHardlinkedVideoPath}' 失败: {e.msg}"
            renameErrorsCount += 1
      # else: # 减少默认输出
        # echo fmt"      警告: 预期的硬链接视频文件 '{oldHardlinkedVideoPath}' (来自缓存条目 {videoInfo.nameOnly}{videoInfo.ext}) 在目标目录中未找到。"

    if cachedEp.localSubtitleFile.isSome:
      let subInfo = cachedEp.localSubtitleFile.get()
      let originalFileNameWithExt = extractFilename(subInfo.fullPath)
      let oldHardlinkedSubPath = targetSeasonPath / originalFileNameWithExt

      if fileExists(oldHardlinkedSubPath):
        let baseNameWithoutExt = fmt"{episodeNumberFormatted} - {cleanEpisodeName}"
        let finalBaseName = sanitizeFilename(baseNameWithoutExt)
        let newSubFileNameWithExt = finalBaseName & subInfo.ext
        
        let newHardlinkedSubPath = targetSeasonPath / newSubFileNameWithExt

        if oldHardlinkedSubPath != newHardlinkedSubPath:
          try:
            # echo fmt"      重命名字幕: '{oldHardlinkedSubPath}' -> '{newHardlinkedSubPath}'" # 减少默认输出
            moveFile(oldHardlinkedSubPath, newHardlinkedSubPath)
            renamedFilesCount += 1
          except OSError as e:
            stderr.writeLine fmt"      错误: 重命名字幕文件 '{oldHardlinkedSubPath}' 失败: {e.msg}"
            renameErrorsCount += 1
      # else: # 减少默认输出
        # echo fmt"      警告: 预期的硬链接字幕文件 '{oldHardlinkedSubPath}' (来自缓存条目 {subInfo.nameOnly}{subInfo.ext}) 在目标目录中未找到。"

  # echo fmt"    番剧 '{seasonInfo.bangumiSeasonName}' 重命名完成。成功: {renamedFilesCount} 个文件, 失败: {renameErrorsCount} 个。" # 减少默认输出
  if renameErrorsCount > 0:
    stderr.writeLine fmt"    番剧 '{seasonInfo.bangumiSeasonName}' 重命名期间发生 {renameErrorsCount} 个错误。"