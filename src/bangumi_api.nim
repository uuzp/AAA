import std/[httpclient, json, options, strformat, strutils]

# 类型定义
type
  Season* = object 
    id*: int              # 番剧ID
    name*: string         # 番剧名称

  Episode* = object 
    sort*: float          # 剧集排序号
    name*: string         # 剧集名称

  EpisodeList* = object 
    total*: int           # 总集数
    data*: seq[Episode]   # 剧集数据

  RawEpisode* = object 
    sort*: float
    name*: string         # 原名
    name_cn*: string      # 中文名

  RawEpisodeList* = object 
    total*: int
    data*: seq[RawEpisode]

  SeasonSearchResult* = object 
    id*: int
    name*: string         # 原名
    name_cn*: string      # 中文名

  SeasonResponse* = object
    results*: int                    
    list*: seq[SeasonSearchResult]   

# API相关函数
func buildSearchUrl*(k: string): string =
  &"http://api.bgm.tv/search/subject/{k}?type=2&responseGroup=small"

func buildEpisodesUrl*(id: int): string =
  &"http://api.bgm.tv/v0/episodes?subject_id={id}"

func buildSeasonUrl*(id: int): string =
  "http://bgm.tv/subject/" & $id

proc fetchApi*[T](apiUrl: string): Option[T] =
  # 从API获取数据并解析为指定类型
  var client = newHttpClient(headers = newHttpHeaders({"User-Agent": "uuzp/AAA/0.1.0(https://github.com/uuzp/AAA )"}))
  try:
    let response = client.getContent(apiUrl)
    let jsonData = parseJson(response)
    result = some(jsonData.to(T))
  except CatchableError as e:
    echo &"错误: API请求失败: {apiUrl}, {e.msg}"
    result = none(T)
  finally:
    client.close()

proc getSeason*(searchTerm: string, useCnName: bool = true): Option[Season] =
  # 搜索番剧信息
  let apiUrl = buildSearchUrl(searchTerm)
  let apiResponseOpt = fetchApi[SeasonResponse](apiUrl)

  if apiResponseOpt.isSome:
    let apiResponse = apiResponseOpt.get()
    if apiResponse.list.len > 0:
      let firstResult = apiResponse.list[0]
      let seasonName = if useCnName and firstResult.name_cn.len > 0: 
                          firstResult.name_cn 
                       else: 
                          firstResult.name
      return some(Season(id: firstResult.id, name: seasonName))
  return none(Season)

proc getEpisodes*(id: int, useCnName: bool = true): Option[EpisodeList] =
  # 获取番剧剧集列表
  let apiUrl = buildEpisodesUrl(id)
  let rawListOpt = fetchApi[RawEpisodeList](apiUrl)

  if rawListOpt.isSome:
    let rawList = rawListOpt.get()
    var episodes = newSeq[Episode]()
    for rawEp in rawList.data:
      let episodeName = if useCnName and rawEp.name_cn.len > 0: 
                            rawEp.name_cn 
                        else: 
                            rawEp.name
      episodes.add(Episode(sort: rawEp.sort, name: episodeName))
    return some(EpisodeList(total: rawList.total, data: episodes))
  return none(EpisodeList)