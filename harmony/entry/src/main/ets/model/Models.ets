/// 数据模型:与 Android `data/model/Models.kt` 字段逐一对齐(时间戳统一用毫秒 number)。

/// 一档播客节目(频道)。
export interface Podcast {
  id: string;              // Apple collectionId,或 feedUrl(RSS 直接导入时)
  title: string;
  author: string;
  artworkUrl: string;
  feedUrl: string;
  description: string;
  genre: string;
  isPaid: boolean;
  fundingUrl: string;
  fundingLabel: string;
}

/// 播客中的一集。audioUrl 为 RSS enclosure 中发布方的原始直链。
export interface Episode {
  id: string;              // guid,缺失时回退为 audioUrl
  title: string;
  description: string;
  audioUrl: string;
  artworkUrl: string;
  podcastTitle: string;
  durationSec: number;
  pubDate: string;
  feedUrl: string;         // 所属频道的 RSS 地址
  /**
   * 发布方**自己提供的逐字稿**地址(RSS 的 `podcast:transcript`,Podcasting 2.0)。
   *
   * 有它就不必本机识别:时间轴是发布方给的,又准又免费,而且**可能带词级时间**
   * (JSON 格式的稿一词一条),那才是逐字高亮最准的来源。空串表示这一集没有。
   */
  transcriptUrl: string;
  /// 逐字稿的 MIME(`application/json` / `text/vtt` / `application/srt` …),用于选解析器
  transcriptType: string;
}

/**
 * 逐字稿里的一个词/字及其时刻(逐词高亮用)。与 Android / macOS `TranscribedWord` 字段一致。
 *
 * **不变式:同一句里各条 `text` 原样拼接 == `TranscribedSegment.text`。**
 * 该带的空格就带在 text 里(英文 " deal"),不该带就不带(中文、以及 "prog"+"rammatic"
 * 这种子词)。渲染方因此可以直接顺序拼接、只给当前那条上色,不必猜哪里该补空格。
 *
 * **另一条不变式:同一句里 startMs 单调不减。** 渲染判断"读到哪个词"是从后往前找第一个
 * `startMs <= now`,只要队尾混进一个异常小的值,高亮就会**钉死在那一条再也不动**
 * (Android 端的真实事故,见 TROUBLESHOOTING H60)。由 `TranscriptLines.mergeWords` 保证。
 */
export interface TranscribedWord {
  text: string;
  startMs: number;
  endMs: number;
}

/**
 * 逐字稿的一句:文本 + 起止毫秒 + 可选的词级时间。
 *
 * `words` 为空数组时回退整句高亮 —— 官方 SRT/VTT 稿通常只有句级时间,
 * 本端的系统语音识别更是连句级都要自己推算(见 `playback/SpeechTranscriber`)。
 * 三端同一形状,缓存 JSON 可互通。
 */
export interface TranscribedSegment {
  text: string;
  startMs: number;
  endMs: number;
  words: TranscribedWord[];
}

/// 解析 RSS 后的结果:频道元信息 + 分集列表。
export interface FeedResult {
  podcast: Podcast;
  episodes: Episode[];
}

/// 播放历史一条。
export interface HistoryEntry {
  episode: Episode;
  positionMs: number;
  durationMs: number;
  updatedAt: number;       // 毫秒时间戳
  played: boolean;
}

/// 单个频道的累计收听时长。时长按设备分账(perDevice),展示值为各设备之和;
/// 备份合并按设备取 max(等价 G-Counter CRDT),故重复恢复不会重复统计。
export interface ChannelListen {
  key: string;             // feedUrl 非空优先,否则 podcastTitle
  title: string;
  artworkUrl: string;
  feedUrl: string;
  perDevice: Record<string, number>;
}

/// 搜索结果 + 命中的取源标签(用于 UI 显示"来自 Apple Podcasts / fyyd.de …")。
export interface SearchOutcome {
  podcasts: Podcast[];
  sourceLabel: string;
  failed: boolean;
}

/// 构造空 Podcast(避免各处重复写默认值)。
export function emptyPodcast(): Podcast {
  return {
    id: '', title: '', author: '', artworkUrl: '', feedUrl: '',
    description: '', genre: '', isPaid: false, fundingUrl: '', fundingLabel: ''
  };
}

/// 频道键:与三端一致(feedUrl 非空优先,否则频道名)。
export function channelKeyOf(e: Episode): string {
  return e.feedUrl.length > 0 ? e.feedUrl : e.podcastTitle;
}

/// 累计时长总和(各设备之和)。
export function listenedMsOf(c: ChannelListen): number {
  let sum = 0;
  const keys = Object.keys(c.perDevice);
  for (let i = 0; i < keys.length; i++) sum += c.perDevice[keys[i]];
  return sum;
}
