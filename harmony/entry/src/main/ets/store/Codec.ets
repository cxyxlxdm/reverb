import { Episode, Podcast, HistoryEntry, ChannelListen, emptyPodcast } from '../model/Models';
import { J } from '../net/Http';

/// Podcast / Episode / HistoryEntry / ChannelListen 的 JSON 编解码。
/// 对应 Android `PodcastJson`/`EpisodeJson`/`ChannelListenJson`(macOS 靠 Codable 自动合成)。
/// 解码一律给默认值,容忍旧版本/半损坏数据。

export class Codec {
  static podcastToJson(p: Podcast): Record<string, Object> {
    return {
      'id': p.id, 'title': p.title, 'author': p.author, 'artworkUrl': p.artworkUrl,
      'feedUrl': p.feedUrl, 'description': p.description, 'genre': p.genre,
      'isPaid': p.isPaid, 'fundingUrl': p.fundingUrl, 'fundingLabel': p.fundingLabel,
      'altFeeds': p.altFeeds
    };
  }

  static podcastFromJson(o: Record<string, Object> | null): Podcast {
    const p = emptyPodcast();
    if (o === null) return p;
    p.id = J.str(o, 'id');
    p.title = J.str(o, 'title');
    p.author = J.str(o, 'author');
    p.artworkUrl = J.str(o, 'artworkUrl');
    p.feedUrl = J.str(o, 'feedUrl');
    p.description = J.str(o, 'description');
    p.genre = J.str(o, 'genre');
    const paid = o['isPaid'];
    p.isPaid = typeof paid === 'boolean' ? paid : false;
    p.fundingUrl = J.str(o, 'fundingUrl');
    p.fundingLabel = J.str(o, 'fundingLabel');
    const alts = o['altFeeds'];
    p.altFeeds = Array.isArray(alts) ? alts.filter((s: Object) => typeof s === 'string' && (s as string).length > 0) as string[] : [];
    return p;
  }

  static episodeToJson(e: Episode): Record<string, Object> {
    return {
      'id': e.id, 'title': e.title, 'description': e.description, 'audioUrl': e.audioUrl,
      'artworkUrl': e.artworkUrl, 'podcastTitle': e.podcastTitle,
      'durationSec': e.durationSec, 'pubDate': e.pubDate, 'feedUrl': e.feedUrl,
      'transcriptUrl': e.transcriptUrl, 'transcriptType': e.transcriptType,
      // 章节地址必须在这里:历史 / 下载 / 收藏 / 批注 / 缓存 / 播放态 / 备份都走这一份编解码,
      // 漏了就是"刚搜到的那一集有章节、冷启动后同一个节目就没有了"(Android 装机验收抓到的,
      // 见 `EpisodeJson.kt` 的同一条注释)。
      'chaptersUrl': e.chaptersUrl, 'chaptersType': e.chaptersType
    };
  }

  static episodeFromJson(o: Record<string, Object> | null): Episode {
    return {
      id: J.str(o, 'id'),
      title: J.str(o, 'title'),
      description: J.str(o, 'description'),
      audioUrl: J.str(o, 'audioUrl'),
      artworkUrl: J.str(o, 'artworkUrl'),
      podcastTitle: J.str(o, 'podcastTitle'),
      durationSec: J.num(o, 'durationSec'),
      pubDate: J.str(o, 'pubDate'),
      feedUrl: J.str(o, 'feedUrl'),
      // 老缓存里没有这两个键,`J.str` 给空串 —— 等于"这一集没有官方稿",与事实一致:
      // 下次刷新订阅时会从 RSS 重新解析出来
      transcriptUrl: J.str(o, 'transcriptUrl'),
      transcriptType: J.str(o, 'transcriptType'),
      // 老缓存里没有这两个键,`J.str` 给空串 —— 等于"这一集没有章节",下次刷新订阅时补上
      chaptersUrl: J.str(o, 'chaptersUrl'),
      chaptersType: J.str(o, 'chaptersType')
    };
  }

  static historyToJson(h: HistoryEntry): Record<string, Object> {
    return {
      'episode': Codec.episodeToJson(h.episode),
      'positionMs': h.positionMs,
      'durationMs': h.durationMs,
      'updatedAt': h.updatedAt,
      'played': h.played
    };
  }

  static historyFromJson(o: Record<string, Object> | null): HistoryEntry {
    const played = o === null ? false : o['played'];
    return {
      episode: Codec.episodeFromJson(J.obj(o, 'episode')),
      positionMs: J.num(o, 'positionMs'),
      durationMs: J.num(o, 'durationMs'),
      updatedAt: J.num(o, 'updatedAt'),
      played: typeof played === 'boolean' ? played : false
    };
  }

  /// 收听时长:perDevice 分账 + 冗余写出 listenedMs(便于人读与旧版本读取)。
  static channelListenToJson(c: ChannelListen, totalMs: number): Record<string, Object> {
    return {
      'key': c.key, 'title': c.title, 'artworkUrl': c.artworkUrl, 'feedUrl': c.feedUrl,
      'perDevice': c.perDevice as Object, 'listenedMs': totalMs
    };
  }

  /// 返回 [频道, 旧格式扁平毫秒];新格式扁平值为 0。
  static channelListenFromJson(o: Record<string, Object> | null): [ChannelListen, number] {
    const pd: Record<string, number> = {};
    const raw = o === null ? undefined : o['perDevice'];
    if (raw !== undefined && raw !== null && !Array.isArray(raw)) {
      const m = raw as Record<string, Object>;
      const keys = Object.keys(m);
      for (let i = 0; i < keys.length; i++) {
        const v = m[keys[i]];
        if (typeof v === 'number') pd[keys[i]] = v;
      }
    }
    const c: ChannelListen = {
      key: J.str(o, 'key'),
      title: J.str(o, 'title'),
      artworkUrl: J.str(o, 'artworkUrl'),
      feedUrl: J.str(o, 'feedUrl'),
      perDevice: pd
    };
    const legacy = Object.keys(pd).length === 0 ? J.num(o, 'listenedMs') : 0;
    return [c, legacy];
  }
}
