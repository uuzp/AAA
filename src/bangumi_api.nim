import std/[httpclient, json, options, strformat, strutils]

# --- 类型定义 (从原 types.nim 移动过来) ---
type
  Season* = object                   ## Bangumi 番剧季度信息 (API获取后，程序内部使用)
    id*: int                         # 番剧在 Bangumi 上的 ID
    name*: string                    # 番剧名称 (优先使用中文名)

  Episode* = object                  ## Bangumi 单集信息 (API获取后，程序内部使用)
    sort*: float                     # 剧集排序号
    name*: string                    # 剧集名称 (优先使用中文名)

  EpisodeList* = object              ## Bangumi 剧集列表 (API获取后，程序内部使用)
    total*: int                      # 总集数
    data*: seq[Episode]              # 剧集数据序列

  RawEpisode* = object               ## API 返回的原始单集数据结构
    sort*: float
    name*: string                    # 原名
    name_cn*: string                 # 中文名

  RawEpisodeList* = object           ## API 返回的原始剧集列表数据结构
    total*: int
    data*: seq[RawEpisode]

  SeasonSearchResult* = object       ## API 搜索番剧结果中的单项数据结构
    id*: int
    name*: string                    # 原名
    name_cn*: string                 # 中文名

  SeasonResponse* = object           ## API 搜索番剧的顶层响应数据结构
    results*: int                    # 搜索结果数量
    list*: seq[SeasonSearchResult]   # 搜索结果列表

# --- Bangumi API 相关函数 (从原 core/bangumi_api.nim 移动过来) ---
func setURL*(k: string): string =
  ## 构建 Bangumi 搜索番剧的 API URL。
  &"http://api.bgm.tv/search/subject/{k}?type=2&responseGroup=small"

func setURL*(id: int): string =
  ## 构建 Bangumi 获取番剧剧集的 API URL。
  &"http://api.bgm.tv/v0/episodes?subject_id={id}"

func url*(id: int): string =
  ## 构建番剧在 Bangumi 网站上的 URL。
  "http://bgm.tv/subject/" & $id

proc getApiData*[T](apiUrl: string): Option[T] =
  ## 从指定的 API URL 获取数据并解析为类型 T。
  ## 使用自定义 User-Agent。
  var client = newHttpClient(headers = newHttpHeaders({"User-Agent": "uuzp/AAA/0.1.0(https://github.com/uuzp/AAA )"}))
  try:
    let response = client.getContent(apiUrl)
    let jsonData = parseJson(response)
    result = some(jsonData.to(T))
  except CatchableError as e:
    echo &"错误: 从 URL {apiUrl} 获取或解析数据失败: {e.msg}"
    result = none(T)
  finally:
    client.close()

proc getSeason*(searchTerm: string, useCnName: bool = true): Option[Season] =
  ## 根据搜索词从 Bangumi API 获取番剧信息。
  ## 返回番剧的 ID 和名称 (根据useCnName决定是否优先使用中文名)。
  let apiUrl = setURL(searchTerm)
  let apiResponseOpt = getApiData[SeasonResponse](apiUrl)

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
  ## 根据番剧 ID 从 Bangumi API 获取剧集列表。
  ## 返回总集数和剧集信息 (根据useCnName决定是否优先使用中文名)。
  let apiUrl = setURL(id)
  let rawListOpt = getApiData[RawEpisodeList](apiUrl)

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