import ./types
import ./utils_string
import std/[os, strutils, strformat, re, tables, options, streams]
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
    filesInTargetDir: seq[string] # 新增参数：targetSeasonPath下的所有文件名（带后缀）
  ) =
  ## 根据 seasonInfo 和目标目录中的实际文件列表重命名文件。
  ## targetSeasonPath 是硬链接后的番剧文件夹路径。

  let logFilePath = targetSeasonPath / "rename_operations.log"
  var logStream = newFileStream(logFilePath, fmWrite)
  if logStream == nil:
    stderr.writeLine fmt"严重错误: 无法打开日志文件 '{logFilePath}' 进行写入。"
    # 即使日志无法打开，也尝试继续执行，但调试信息会丢失
  
  defer:
    if logStream != nil:
      logStream.close()

  if not dirExists(targetSeasonPath):
    let errorMsg = fmt"    错误: 目标番剧文件夹 '{targetSeasonPath}' 不存在，无法重命名。"
    if logStream != nil: logStream.writeLine(errorMsg) else: stderr.writeLine(errorMsg)
    return

  if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 开始处理番剧 '{seasonInfo.bangumiSeasonName}' 于路径 '{targetSeasonPath}'") # DEBUG LOG
  var renamedFilesCount = 0
  var renameErrorsCount = 0

  for epKey, cachedEp in pairs(seasonInfo.episodes): # epKey is "E01", "E02", etc.
    let episodeNameForLog = cachedEp.nameOnly.get("N/A") # 使用 Option.get(defaultValue)
    if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 处理剧集 '{epKey}', 缓存名称: '{episodeNameForLog}'") # DEBUG LOG
    if cachedEp.nameOnly.isNone:
      if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}' 在缓存中没有基础文件名 (nameOnly)，跳过重命名。" ) # DEBUG LOG (原注释取消)
      continue

    # 构建新文件名的基础部分 (不含集数和剧集名之外的任何原始文件名中的标签)
    let cleanBangumiEpName = sanitizeFilename(cachedEp.bangumiName)
    let newFileNameBasePart = sanitizeFilename(fmt"{epKey} - {cleanBangumiEpName}") # 例如 "E01 - 绿之座"

    # 处理视频文件
    if cachedEp.videoExt.isSome:
      let videoExt = cachedEp.videoExt # 保持 Option[string] 类型
      var oldVideoFileOriginalName: Option[string] = none(string)

      # 尝试在 filesInTargetDir 中找到对应的旧视频文件
      for actualFileInDir in filesInTargetDir: # actualFileInDir is "原始文件名.mkv"
        var (fileDir, namePart, extPart) = splitFile(actualFileInDir)
        discard fileDir # 我们在这里不使用目录部分
        let expectedExt = videoExt.get("N/A")  # 使用正确的Option.get方法
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频匹配 - 目标文件: '{actualFileInDir}', 名称部分: '{namePart}', 扩展名: '{extPart}', 期望扩展名: '{expectedExt}'") # DEBUG LOG
        if videoExt.isSome and extPart == videoExt.get():
          # 精确匹配：如果当前文件的 namePart (无后缀) 与缓存中的 nameOnly (无后缀) 相同
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频匹配 - 尝试精确匹配 namePart '{namePart}' 与 cachedEp.nameOnly '{cachedEp.nameOnly.get(""无nameOnly"")}'") # DEBUG LOG
          if cachedEp.nameOnly.isSome and namePart == cachedEp.nameOnly.get():
            oldVideoFileOriginalName = some(actualFileInDir)
            if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频匹配 - 找到旧视频文件: '{actualFileInDir}'") # DEBUG LOG
            break
      
      if oldVideoFileOriginalName.isSome:
        let oldVideoName = oldVideoFileOriginalName.get()
        let currentVideoExt = videoExt.get()
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 准备重命名视频 - 旧文件确定为: '{oldVideoName}'") # DEBUG LOG
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): PRE-CONSTRUCT VIDEO PATH - targetSeasonPath='{targetSeasonPath}', oldVideoFileOriginalName='{oldVideoName}', newFileNameBasePart='{newFileNameBasePart}', videoExt='{currentVideoExt}'")
        let oldVideoFullPath = targetSeasonPath / oldVideoName
        let newVideoFullName = newFileNameBasePart & currentVideoExt
        let newVideoFullPath = targetSeasonPath / newVideoFullName
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名 - 旧路径: '{oldVideoFullPath}', 新路径: '{newVideoFullPath}'") # DEBUG LOG

        if oldVideoFullPath != newVideoFullPath:
          if fileExists(oldVideoFullPath):
            try:
              moveFile(oldVideoFullPath, newVideoFullPath)
              renamedFilesCount += 1
              if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名成功: '{oldVideoFullPath}' -> '{newVideoFullPath}'") # DEBUG LOG
            except OSError as e:
              let errorMsg = fmt"      错误: 重命名视频文件 '{oldVideoFullPath}' 到 '{newVideoFullPath}' 失败: {e.msg}"
              if logStream != nil: logStream.writeLine(errorMsg) else: stderr.writeLine(errorMsg)
              if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 视频重命名失败: {e.msg}") # DEBUG LOG
              renameErrorsCount += 1
          else: # 文件在扫描后但在重命名时消失了？不太可能，除非外部操作
            let warnMsg = fmt"      警告: 预期的视频文件 '{oldVideoFullPath}' 在尝试重命名时未找到。" # DEBUG LOG (原注释取消)
            if logStream != nil: logStream.writeLine(warnMsg) else: stderr.writeLine(warnMsg)
        else: # 文件名已正确
          if logStream != nil: logStream.writeLine(fmt"      信息: 视频文件 '{oldVideoFullPath}' 名称已符合期望格式 '{newVideoFullName}'，无需重命名。" ) # DEBUG LOG (原注释取消)
      else: # 减少默认输出
        let expectedExtStr = videoExt.get("N/A")
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}': 未能在目标目录中找到匹配的视频文件 (期望后缀: {expectedExtStr})。" ) # DEBUG LOG (原注释取消)

    # 处理字幕文件
    if cachedEp.subtitleExts.len > 0:
      for subExtExpected in cachedEp.subtitleExts: # e.g., ".scjp.ass"
        if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕处理 - 剧集 '{epKey}', 期望字幕后缀: '{subExtExpected}'") # DEBUG LOG
        var oldSubFileOriginalName: Option[string] = none(string)
        for actualFileInDir in filesInTargetDir: # actualFileInDir is "原始文件名.scjp.ass"
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕匹配 - 目标文件: '{actualFileInDir}', 期望后缀: '{subExtExpected}'") # DEBUG LOG
          if actualFileInDir.endsWith(subExtExpected): # 区分大小写匹配，如果需要忽略，则 .toLower().endsWith(...)
            # 获取文件名中期望字幕后缀之前的部分
            let nameBeforeExpectedSubExt = actualFileInDir[0 .. ^(subExtExpected.len+1)]
            # 对这部分再次使用 splitFile 来分离其文件名主体
            var (fileDir, namePartOfSub, extAlso) = splitFile(nameBeforeExpectedSubExt)
            discard fileDir
            discard extAlso # 这部分应该是空的，或者如果原始文件名更复杂则可能包含内容
            # 精确匹配：如果当前字幕文件的 namePartOfSub (在字幕后缀之前，无视频后缀) 与缓存中的 nameOnly (视频的原始名，无后缀) 相同
            let cachedNameOnlyForCompare = cachedEp.nameOnly.get("无nameOnly缓存值")
            if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕匹配 - 原始比较值:")
            if logStream != nil: logStream.writeLine(fmt"  - actualFileInDir (原始字幕名): '{actualFileInDir}'")
            if logStream != nil: logStream.writeLine(fmt"  - subExtExpected (期望后缀): '{subExtExpected}'")
            if logStream != nil: logStream.writeLine(fmt"  - nameBeforeExpectedSubExt (去除期望后缀后): '{nameBeforeExpectedSubExt}'")
            if logStream != nil: logStream.writeLine(fmt"  - namePartOfSub (从上面提取的基础名): '{namePartOfSub}'")
            if logStream != nil: logStream.writeLine(fmt"  - cachedEp.nameOnly (缓存中的基础名): '{cachedNameOnlyForCompare}'")

            # 使用清理后的名称进行比较
            let cleanNamePartOfSub = getCleanedBaseName(namePartOfSub) # 调用新的清理函数
            let cleanCachedNameOnly = getCleanedBaseName(cachedNameOnlyForCompare) # 调用新的清理函数

            if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕匹配 - 清理后比较值:")
            if logStream != nil: logStream.writeLine(fmt"  - cleanNamePartOfSub: '{cleanNamePartOfSub}'")
            if logStream != nil: logStream.writeLine(fmt"  - cleanCachedNameOnly: '{cleanCachedNameOnly}'")
            
            if cachedEp.nameOnly.isSome and cleanNamePartOfSub == cleanCachedNameOnly and cleanNamePartOfSub.len > 0: # 确保清理后仍有内容
              oldSubFileOriginalName = some(actualFileInDir)
              if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕匹配 - 找到旧字幕文件: '{actualFileInDir}' (因为 cleanNamePartOfSub == cleanCachedNameOnly)")
              break
        
        if oldSubFileOriginalName.isSome:
          let oldSubName = oldSubFileOriginalName.get()
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 准备重命名字幕 - 旧文件确定为: '{oldSubName}'") # DEBUG LOG
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): PRE-CONSTRUCT SUB PATH - targetSeasonPath='{targetSeasonPath}', oldSubFileOriginalName='{oldSubName}', newFileNameBasePart='{newFileNameBasePart}', subExtExpected='{subExtExpected}'")
          let oldSubFullPath = targetSeasonPath / oldSubName
          let newSubFullName = newFileNameBasePart & subExtExpected
          let newSubFullPath = targetSeasonPath / newSubFullName
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名 - 旧路径: '{oldSubFullPath}', 新路径: '{newSubFullPath}'") # DEBUG LOG

          if oldSubFullPath != newSubFullPath:
            if fileExists(oldSubFullPath):
              try:
                moveFile(oldSubFullPath, newSubFullPath)
                renamedFilesCount += 1
                if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名成功: '{oldSubFullPath}' -> '{newSubFullPath}'") # DEBUG LOG
              except OSError as e:
                let errorMsg = fmt"      错误: 重命名字幕文件 '{oldSubFullPath}' 到 '{newSubFullPath}' 失败: {e.msg}"
                if logStream != nil: logStream.writeLine(errorMsg) else: stderr.writeLine(errorMsg)
                if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 字幕重命名失败: {e.msg}") # DEBUG LOG
                renameErrorsCount += 1
            else:
              let warnMsg = fmt"      警告: 预期的字幕文件 '{oldSubFullPath}' 在尝试重命名时未找到。" # DEBUG LOG (原注释取消)
              if logStream != nil: logStream.writeLine(warnMsg) else: stderr.writeLine(warnMsg)
          else: # 文件名已正确
            if logStream != nil: logStream.writeLine(fmt"      信息: 字幕文件 '{oldSubFullPath}' 名称已符合期望格式 '{newSubFullName}'，无需重命名。" ) # DEBUG LOG (原注释取消)
        else: # 减少默认输出
          if logStream != nil: logStream.writeLine(fmt"调试(renameFilesBasedOnCache): 番剧 '{seasonInfo.bangumiSeasonName}', 剧集 '{epKey}': 未能在目标目录中找到匹配的字幕文件 (期望后缀: {subExtExpected})。" ) # DEBUG LOG (原注释取消)
  
  if logStream != nil: logStream.writeLine(fmt"    番剧 '{seasonInfo.bangumiSeasonName}' 重命名完成。成功: {renamedFilesCount} 个文件, 失败: {renameErrorsCount} 个。" ) # DEBUG LOG (原注释取消)
  if renameErrorsCount > 0:
    let errorMsg = fmt"    番剧 '{seasonInfo.bangumiSeasonName}' 重命名期间发生 {renameErrorsCount} 个错误。"
    if logStream != nil: logStream.writeLine(errorMsg) else: stderr.writeLine(errorMsg)