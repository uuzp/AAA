import std/[strformat, strutils, tables, os, options, algorithm, sequtils, sets, math, times]
import ./bangumi_api
import ./utils except logDebug
from ./utils import logDebug

# --- 类型定义 ---
type
  Config* = object                   ## 程序配置对象 (主要用于命令行参数)
    basePath*: string                # 基础路径
    animePath*: string               # 番剧目标路径

# 全局变量和常量定义
var
  basePath: string    # 基础路径
  animePath: string   # 番剧目标路径
  useCnName: bool = true  # 是否使用中文名

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
    csvCache: var Table[string, CsvCacheEntry],
    jsonCache: var Table[string, CachedSeasonInfo]
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
        # 简单处理：直接使用splitFile获取文件名和扩展名
        let (_, name, ext) = splitFile(item.path)
        
        logDebug(fmt"处理文件: '{item.path}'")
        
        localFiles.add(utils.LocalFileInfo(
          nameOnly: name,
          ext: ext,
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
              
              # 处理文件信息 - 简化这段代码
              # 对于所有文件统一用splitFile处理,不再对复合语言代码特殊处理
              # 后续重命名时会正确处理字幕后缀
              let (dirPath, nameOnly, ext) = splitFile(item.path)
              localFiles.add(utils.LocalFileInfo(
                nameOnly: nameOnly,
                ext: ext,
                fullPath: item.path
              ))
              
              # 检查是否为视频
              let fileExt = ext.toLower()
              let isVideo = videoExts.anyIt(fileExt == it or fileExt.endsWith(it))
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