import ./types
import std/[httpclient, json, options, strformat, strutils]

# --- Bangumi API 相关函数 ---
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
    echo &"错误: 从 URL {apiUrl} 获取或解析数据失败: {e.msg}" # 保持错误输出，但后续会考虑用 Result 类型
    result = none(T)
  finally:
    client.close()

proc getSeason*(searchTerm: string): Option[Season] =
  ## 根据搜索词从 Bangumi API 获取番剧信息。
  ## 返回番剧的 ID 和名称 (优先中文名)。
  let apiUrl = setURL(searchTerm)
  let apiResponseOpt = getApiData[SeasonResponse](apiUrl)

  if apiResponseOpt.isSome:
    let apiResponse = apiResponseOpt.get()
    if apiResponse.list.len > 0:
      let firstResult = apiResponse.list[0]
      let seasonName = if firstResult.name_cn.len > 0: firstResult.name_cn else: firstResult.name
      return some(Season(id: firstResult.id, name: seasonName))
  return none(Season)

proc getEpisodes*(id: int): Option[EpisodeList] =
  ## 根据番剧 ID 从 Bangumi API 获取剧集列表。
  ## 返回总集数和剧集信息 (名称优先中文名)。
  let apiUrl = setURL(id)
  let rawListOpt = getApiData[RawEpisodeList](apiUrl)

  if rawListOpt.isSome:
    let rawList = rawListOpt.get()
    var episodes = newSeq[Episode]()
    for rawEp in rawList.data:
      let episodeName = if rawEp.name_cn.len > 0: rawEp.name_cn else: rawEp.name
      episodes.add(Episode(sort: rawEp.sort, name: episodeName))
    return some(EpisodeList(total: rawList.total, data: episodes))
  return none(EpisodeList)