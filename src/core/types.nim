import std/[options, tables] # 导入可能需要的模块

# --- 类型定义 ---
type
  Config* = object                   ## 程序配置对象 (主要用于命令行参数)
    basePath*: string                # 基础路径
    animePath*: string               # 番剧目标路径

  Season* = object                   ## Bangumi 番剧季度信息 (API获取后，程序内部使用)
    id*: int                         # 番剧在 Bangumi 上的 ID
    name*: string                    # 番剧名称 (优先使用中文名)

  Episode* = object                  ## Bangumi 单集信息 (API获取后，程序内部使用)
    sort*: float                     # 剧集排序号
    name*: string                    # 剧集名称 (优先使用中文名)

  EpisodeList* = object              ## Bangumi 剧集列表 (API获取后，程序内部使用)
    total*: int                      # 总集数
    data*: seq[Episode]              # 剧集数据序列

  # --- 用于解析 Bangumi API 原始 JSON 数据的类型 ---
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
  
  # --- 新增的缓存和本地文件相关类型 ---
  LocalFileInfo* = object          ## 本地文件信息
    nameOnly*: string              # 文件名 (不含后缀)
    ext*: string                   # 文件后缀 (例如 ".mkv", ".ass", 带点)
    fullPath*: string              # 文件的完整路径

  CachedEpisodeInfo* = object      ## 存储在 cache.json 中的单集详细信息
    bangumiSort*: float            # Bangumi API 返回的原始 sort 值
    bangumiName*: string           # Bangumi API 返回的剧集名 (优先中文)
    localVideoFile*: Option[LocalFileInfo]
    localSubtitleFile*: Option[LocalFileInfo]

  CachedSeasonInfo* = object       ## 存储在 cache.json 中的番剧季度详细信息
    bangumiSeasonId*: int          # Bangumi 番剧 ID
    bangumiSeasonName*: string     # Bangumi 番剧名
    totalBangumiEpisodes*: int     # Bangumi API 返回的总集数
    episodes*: Table[string, CachedEpisodeInfo] # 键: formatEpisodeNumber 的结果 (如 "E01")

  CsvCacheEntry* = object          ## cache.csv 中的条目 (原始文件夹名 -> Bangumi ID 映射)
    originalFolderName*: string    # 扫描到的原始的文件夹名称
    bangumiSeasonNameCache*: string # 匹配到的 Bangumi 番剧名 (用于快速显示)
    bangumiSeasonId*: int          # 匹配到的 Bangumi 番剧 ID

  RuleConfig* = object               ## 匹配规则配置
    groups*: seq[string]             # 用于初步筛选的字幕组或关键词列表
    pattern*: string                 # 用于提取番剧名称的正则表达式或普通字符串

  RuleSet* = seq[RuleConfig]         ## 规则配置集合