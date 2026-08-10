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
    val fundingLabel: String = ""    // 该链接的文案
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
    val feedUrl: String = ""   // 所属频道的 RSS 地址,用于从播放页跳转频道主页
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

/** 单个频道的累计收听时长（累计“实际播放过的内容毫秒”）。key：feedUrl 非空优先，否则频道名。 */
data class ChannelListen(
    val key: String,
    val title: String,
    val artworkUrl: String,
    val feedUrl: String,
    val listenedMs: Long
)
