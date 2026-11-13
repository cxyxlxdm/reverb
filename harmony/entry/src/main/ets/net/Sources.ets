import { Http, J } from './Http';
import { Episode, Podcast, emptyPodcast } from '../model/Models';
import { Genres } from '../model/Genres';
import { htmlToText } from '../util/HtmlText';
import { Log } from '../util/Logger';

/// 四路取源,全部免费无鉴权:Apple iTunes / Apple Charts / fyyd.de / gpodder.net。
/// 字段映射以 Android 为基线(Episode.id 用 trackId、isPaid 取 collectionPrice||trackPrice、
/// genre 走 Genres.key 归一化、pubDate 截断 10 字符),并吸收 macOS 的类型过滤与单对象兼容。

// ───────────────────────── Apple iTunes ─────────────────────────

export class ITunesSource {
  /// 频道搜索。
  static async search(query: string, region: string, limit: number = 50): Promise<Podcast[]> {
    const cc = region.length > 0 ? `&country=${region}` : '';
    const url = `https://itunes.apple.com/search?media=podcast&term=${Http.encode(query)}${cc}&limit=${limit}`;
    return ITunesSource.parsePodcasts(await Http.json(url));
  }

  /// 单集搜索。
  static async searchEpisodes(query: string, region: string, limit: number = 50): Promise<Episode[]> {
    const cc = region.length > 0 ? `&country=${region}` : '';
    const url = `https://itunes.apple.com/search?media=podcast&entity=podcastEpisode&term=${Http.encode(query)}${cc}&limit=${limit}`;
    return ITunesSource.parseEpisodes(await Http.json(url));
  }

  /// 批量 lookup(榜单只给 id,需回查详情;country 让分类名本地化)。
  static async lookupBatch(ids: string[], region: string): Promise<Podcast[]> {
    if (ids.length === 0) return [];
    const cc = region.length > 0 ? `&country=${region}` : '';
    const url = `https://itunes.apple.com/lookup?id=${ids.join(',')}&entity=podcast${cc}`;
    return ITunesSource.parsePodcasts(await Http.json(url));
  }

  static parsePodcasts(root: Record<string, Object> | null): Podcast[] {
    const results = J.arr(root, 'results');
    const out: Podcast[] = [];
    for (let i = 0; i < results.length; i++) {
      const o = J.asObj(results[i]);
      if (o === null) continue;
      // macOS 的类型过滤:排除非频道条目
      const wrapper = J.str(o, 'wrapperType');
      const kind = J.str(o, 'kind');
      if (wrapper.length > 0 && wrapper !== 'track' && wrapper !== 'collection' && wrapper !== 'artist') continue;
      if (kind.length > 0 && kind !== 'podcast') continue;

      const feed = J.str(o, 'feedUrl');
      if (feed.length === 0) continue;   // 没有 feed 就无法播放,直接丢弃

      const p = emptyPodcast();
      const cid = J.str(o, 'collectionId');
      p.id = cid.length > 0 ? cid : feed;
      const cname = J.str(o, 'collectionName');
      p.title = cname.length > 0 ? cname : J.str(o, 'trackName');
      p.author = J.str(o, 'artistName');
      const a600 = J.str(o, 'artworkUrl600');
      p.artworkUrl = a600.length > 0 ? a600 : J.str(o, 'artworkUrl100');
      p.feedUrl = feed;
      p.genre = Genres.key(J.str(o, 'primaryGenreName'));
      p.isPaid = J.num(o, 'collectionPrice') > 0 || J.num(o, 'trackPrice') > 0;
      out.push(p);
    }
    return out;
  }

  static parseEpisodes(root: Record<string, Object> | null): Episode[] {
    const results = J.arr(root, 'results');
    const out: Episode[] = [];
    for (let i = 0; i < results.length; i++) {
      const o = J.asObj(results[i]);
      if (o === null) continue;
      // 结果里首条常是频道包装,只取真正的单集
      const isEpisode = J.str(o, 'wrapperType') === 'podcastEpisode' || J.str(o, 'kind') === 'podcast-episode';
      if (!isEpisode) continue;
      const epUrl = J.str(o, 'episodeUrl');
      const audio = epUrl.length > 0 ? epUrl : J.str(o, 'previewUrl');
      if (audio.length === 0) continue;

      const durMs = J.num(o, 'trackTimeMillis');
      const trackId = J.str(o, 'trackId');
      const a600 = J.str(o, 'artworkUrl600');
      const a160 = J.str(o, 'artworkUrl160');
      const art = a600.length > 0 ? a600 : (a160.length > 0 ? a160 : J.str(o, 'artworkUrl100'));
      out.push({
        id: trackId.length > 0 ? trackId : audio,
        title: J.str(o, 'trackName'),
        description: htmlToText(J.str(o, 'description')),
        audioUrl: audio,
        artworkUrl: art,
        podcastTitle: J.str(o, 'collectionName'),
        durationSec: durMs > 0 ? Math.floor(durMs / 1000) : 0,
        pubDate: J.str(o, 'releaseDate').substring(0, 10),
        feedUrl: J.str(o, 'feedUrl'),
        transcriptUrl: '',
        transcriptType: '',
        // 目录接口不给章表地址;等用户进频道、RSS 解析过之后才会有(与逐字稿同一条)
        chaptersUrl: '',
        chaptersType: ''
      });
    }
    return out;
  }
}

// ───────────────────────── Apple 榜单 ─────────────────────────

export class AppleChartsSource {
  /// 综合榜(新版 marketingtools 接口,只给 id,需 lookupBatch 回查)。
  static async top(region: string, limit: number): Promise<Podcast[]> {
    const url = `https://rss.marketingtools.apple.com/api/v2/${region}/podcasts/top/${limit}/podcasts.json`;
    const root = await Http.json(url);
    const feed = J.obj(root, 'feed');
    const results = J.arr(feed, 'results');
    const ids: string[] = [];
    for (let i = 0; i < results.length; i++) {
      const o = J.asObj(results[i]);
      const id = J.str(o, 'id');
      if (id.length > 0) ids.push(id);
    }
    if (ids.length === 0) return [];
    return ITunesSource.lookupBatch(ids, region);
  }

  /// 分类榜(旧版接口)。entry 在只有一条时是对象而非数组,需兼容(macOS 侧的修正)。
  static async topByGenre(region: string, genreId: number, limit: number): Promise<Podcast[]> {
    const url = `https://itunes.apple.com/${region}/rss/toppodcasts/limit=${limit}/genre=${genreId}/json`;
    const root = await Http.json(url);
    const feed = J.obj(root, 'feed');
    if (feed === null) return [];
    const raw = feed['entry'];
    const entries: Object[] = Array.isArray(raw) ? raw as Object[] : (raw === undefined || raw === null ? [] : [raw]);
    const ids: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e = J.asObj(entries[i]);
      const idObj = J.obj(e, 'id');
      const attrs = J.obj(idObj, 'attributes');
      const imId = J.str(attrs, 'im:id');
      if (imId.length > 0) ids.push(imId);
    }
    if (ids.length === 0) return [];
    return ITunesSource.lookupBatch(ids, region);
  }
}

// ───────────────────────── fyyd.de ─────────────────────────

export class FyydSource {
  static async search(query: string, count: number = 30): Promise<Podcast[]> {
    const url = `https://api.fyyd.de/0.2/search/podcast?title=${Http.encode(query)}&count=${count}`;
    return FyydSource.parse(await Http.json(url));
  }

  static async hot(count: number = 30): Promise<Podcast[]> {
    const url = `https://api.fyyd.de/0.2/feature/podcast/hot?count=${count}`;
    return FyydSource.parse(await Http.json(url));
  }

  private static parse(root: Record<string, Object> | null): Podcast[] {
    const data = J.arr(root, 'data');
    const out: Podcast[] = [];
    for (let i = 0; i < data.length; i++) {
      const o = J.asObj(data[i]);
      if (o === null) continue;
      const feed = J.str(o, 'xmlURL');
      if (feed.length === 0) continue;
      const p = emptyPodcast();
      p.id = feed;
      p.title = J.str(o, 'title');
      p.author = J.str(o, 'author');
      p.artworkUrl = J.str(o, 'imgURL');
      p.feedUrl = feed;
      p.description = htmlToText(J.str(o, 'description'));
      out.push(p);
    }
    return out;
  }
}

// ───────────────────────── gpodder.net ─────────────────────────

export class GpodderSource {
  /// 顶层返回 JSON 数组;无 limit 参数,客户端截断。
  static async search(query: string, limit: number = 30): Promise<Podcast[]> {
    const url = `https://gpodder.net/search.json?q=${Http.encode(query)}`;
    const arr = await Http.jsonArray(url);
    if (arr === null) return [];
    const out: Podcast[] = [];
    for (let i = 0; i < arr.length && out.length < limit; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const feed = J.str(o, 'url');
      if (feed.length === 0) continue;
      const p = emptyPodcast();
      p.id = feed;
      p.title = J.str(o, 'title');
      p.author = J.str(o, 'author');
      const logo = J.str(o, 'logo_url');
      p.artworkUrl = logo.length > 0 ? logo : J.str(o, 'scaled_logo_url');
      p.feedUrl = feed;
      p.description = htmlToText(J.str(o, 'description'));
      out.push(p);
    }
    Log.d('Gpodder', `搜索命中 ${out.length}`);
    return out;
  }
}
