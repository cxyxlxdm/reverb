package com.yuyin.reverb.data.model

/** 一档播客节目（频道）。 */
data class Podcast(
    val id: String,          // Apple collectionId，或 feedUrl（RSS 直接导入时）
    val title: String,
    val author: String,
    val artworkUrl: String,
    val feedUrl: String,
    val description: String = "",
    val genre: String = "",  // 分类（Apple primaryGenreName 或 RSS itunes:category）
    val isPaid: Boolean = false,     // 付费节目（Apple 价格 > 0）
    val fundingUrl: String = "",     // 会员/购买/支持页链接（RSS podcast:funding）
    val fundingLabel: String = "",   // 该链接的文案
    val altFeeds: List<String> = emptyList()  // 同节目备用 RSS 源（可达优先、小宇宙垫底，见 H311）
)

/** 播客中的一集。audioUrl 为 RSS enclosure 中发布方的原始直链，播放时直接流式拉取。 */
data class Episode(
    val id: String,          // guid，缺失时回退为 audioUrl
    val title: String,
    val description: String,
    val audioUrl: String,
    val artworkUrl: String,
    val podcastTitle: String,
    val durationSec: Long = 0,
    val pubDate: String = "",
    val feedUrl: String = "",  // 所属频道的 RSS 地址,用于从播放页跳转频道主页
    /**
     * 直播流(用户直接粘进搜索框的音频流地址,**没有 RSS、没有时长、不可回退**)。
     *
     * 它不是"一集节目",只是一条正在播的流:缓存、下载、历史、收听时长、断点续播、
     * 已播标记、队列自动跳过 —— **一律不参与**(见 PlayerController 里以 isLive 为闸的几处)。
     * 落盘时也刻意不存 current(与电台同口径):流地址隔天多半已经失效,恢复出来只会是
     * 一个点了没反应的迷你条。
     */
    val isLive: Boolean = false,
    /**
     * 发布方**自己提供的逐字稿**地址(RSS 的 `podcast:transcript`,Podcasting 2.0)。
     *
     * 有它就不必本机识别:时间轴是发布方给的,又准又免费。空串表示这一集没有。
     * 合并前的大陆商店渠道**只有这一条路**(那个包里不含离线识别引擎),它直接决定那个包
     * 的播放页有没有第三页;现在只有一份包、引擎在包里,这一条是「优先走的那条」(见 H205)。
     */
    val transcriptUrl: String = "",
    /// 逐字稿的 MIME(`application/json` / `text/vtt` / `application/srt` …),用于选解析器
    val transcriptType: String = "",
    /**
     * 发布方给的**章节**地址(RSS 的 `podcast:chapters`,Podcasting 2.0)。
     *
     * 与逐字稿同一条思路:章节表由发布方维护,本机只是取回 JSON 并按时间跳转,
     * 不做任何推断。空串表示这一集没有章节 —— 播放页就**不出现**章节入口,
     * 而不是摆一个点进去空着的按钮。
     */
    val chaptersUrl: String = "",
    /// 章节表的 MIME,目前只认 JSON(`application/json+chapters` / `application/json`)
    val chaptersType: String = ""
)

/**
 * 逐字稿里的一个词/字及其时刻(逐词高亮用)。与 macOS `TranscribedWord` 字段一致。
 *
 * **不变式:同一句里各条 `text` 原样拼接 == `TranscribedSegment.text`。**
 * 也就是说该带的空格就带在 text 里(英文 " deal"),不该带就不带(中文、以及
 * "prog"+"rammatic" 这种子词)。渲染方因此可以直接顺序拼接、只给当前那条上色,
 * 不需要猜哪里该补空格 —— 猜错的后果是英文子词被拼成两个词。
 */
data class TranscribedWord(
    val text: String,
    val startMs: Int,
    val endMs: Int
)

/**
 * 逐字稿的一句:文本 + 起止毫秒。
 *
 * `words` 为 null 时回退整句高亮 —— 官方 SRT/VTT 稿通常只有句级时间,
 * 鸿蒙的系统 ASR 更是连句级都要自己推算(见该端注释)。三端同一形状,缓存 JSON 可互通。
 */
data class TranscribedSegment(
    val text: String,
    val startMs: Int,
    val endMs: Int,
    val words: List<TranscribedWord>? = null
)

/**
 * 发布方给的一章(Podcasting 2.0 `podcast:chapters` 的 JSON 表)。
 *
 * `startMs` 是**这一章从哪一秒开始**,不是区间:一章一直延续到下一章开头,
 * 最后一章延续到结尾。所以章表只需要起点,结束时刻由列表本身决定 ——
 * 与逐字稿"每句自带起止"不同,这是章节规范本来的形状。
 *
 * 字段与 macOS / 鸿蒙保持同名(`startMs` / `title` / `imageUrl` / `url`),方便三端对读。
 */
data class Chapter(
    val startMs: Int,
    val title: String,
    val imageUrl: String = "",
    val url: String = ""
)

/** 解析 RSS 后的结果：频道元信息 + 分集列表。 */
data class FeedResult(
    val podcast: Podcast,
    val episodes: List<Episode>
)

/** 单集下载状态（内存态，用于展示进度）。 */
sealed interface DownloadStatus {
    data object Queued : DownloadStatus
    data class Downloading(val progress: Float) : DownloadStatus
    data object Completed : DownloadStatus
    data object Failed : DownloadStatus
}

/** 已下载的一集（持久化）：分集信息 + 本地文件路径。 */
data class DownloadedEpisode(
    val episode: Episode,
    val localPath: String
)

/** 播放历史一条：分集 + 上次进度 + 更新时间 + 是否已播完。 */
data class HistoryEntry(
    val episode: Episode,
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
    val played: Boolean = false
)

/**
 * 单个频道的累计收听时长（累计“实际播放过的内容毫秒”）。key：feedUrl 非空优先，否则频道名。
 *
 * 时长**按设备分账**存于 perDevice（设备ID → 毫秒），展示值 listenedMs 为各设备之和。
 * 这样备份恢复的合并规则可取「按设备取 max」而非相加，重复恢复同一份备份不会重复统计
 * （等价于 G-Counter CRDT）；跨设备恢复则天然把两台的时长加总。
 */
data class ChannelListen(
    val key: String,
    val title: String,
    val artworkUrl: String,
    val feedUrl: String,
    val perDevice: Map<String, Long> = emptyMap()
) {
    /** 展示用总时长 = 各设备之和。 */
    val listenedMs: Long get() = perDevice.values.sum()
}
