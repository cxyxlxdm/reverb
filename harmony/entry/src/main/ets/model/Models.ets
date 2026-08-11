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
