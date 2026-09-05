import { Episode, Podcast } from '../model/Models';

// 2026-09-03 从中国区 19 个分类的 535 个去重 feed 中线下生成。真机连续三次无法建立
// TCP/TLS 才纳入；按精确路径而非整站封禁，避免同一托管商恢复后误伤新节目。
const BLOCKED_FEEDS = new Set<string>([
  'http://cdn.himalaya.com/bd8417922c8c43e59df55818bf6d10b1.xml',
  'https://access.acast.com/rss/3d30295e-f7fb-5af1-b618-30a8763cc75a',
  'https://anchor.fm/s/101fb6240/podcast/rss',
  'https://anchor.fm/s/3147e0d8/podcast/rss',
  'https://anchor.fm/s/81d05f80/podcast/rss',
  'https://anchor.fm/s/f6370248/podcast/rss',
  'https://anchor.fm/s/fde23850/podcast/rss',
  'https://feeds.acast.com/public/shows/0185cea5-9e3b-4b82-a887-26f91f92765f',
  'https://feeds.acast.com/public/shows/4d1603d1-3c56-4f4d-a5b3-7611f87011a9',
  'https://feeds.acast.com/public/shows/4d90c19e-d564-4949-a998-27e24cca2aee',
  'https://feeds.acast.com/public/shows/62b0ada25c7ea10012f541cb',
  'https://feeds.acast.com/public/shows/67573202e417dbfb211f744a',
  'https://feeds.acast.com/public/shows/67585c62102e6d4448d44969',
  'https://feeds.acast.com/public/shows/67587e77c705e441797aff96',
  'https://feeds.acast.com/public/shows/6818be7d1d28d62313ac8ef3',
  'https://feeds.acast.com/public/shows/6818cd43eb146d8e35d312c7',
  'https://feeds.acast.com/public/shows/6819ae2bf30c20bff775e8a1',
  'https://feeds.acast.com/public/shows/8fb79794-2f6a-41f0-9ae1-d7766f4e4092',
  'https://feeds.acast.com/public/shows/98ddd5a0-c00b-4f80-9a5b-d4584d0040ac',
  'https://feeds.feedburner.com/dancarlin/history',
  'https://podcasts.files.bbci.co.uk/m000hmmf.rss',
  'https://podcasts.files.bbci.co.uk/p02nq0gn.rss',
  'https://podcasts.files.bbci.co.uk/p02nrsln.rss',
  'https://podcasts.files.bbci.co.uk/p02pc9tn.rss',
  'https://podcasts.files.bbci.co.uk/p02pc9zn.rss',
  'https://rss.wbur.org/circleround/podcast',
  'https://www.abc.net.au/feeds/2888650/podcast.xml',
  'https://www.abc.net.au/feeds/9989710/podcast.xml',
  'https://www.swr.de/~podcast/swrkultur/programm/podcast-swr-das-wissen-102.xml',
  'https://www.theguardian.com/football/series/footballweekly/podcast.xml'
]);

export class CatalogFeedFilter {
  static keepPodcasts(items: Podcast[]): Podcast[] {
    return items.filter((item: Podcast): boolean => !CatalogFeedFilter.blocked(item.feedUrl));
  }

  static keepEpisodes(items: Episode[]): Episode[] {
    return items.filter((item: Episode): boolean => !CatalogFeedFilter.blocked(item.feedUrl));
  }

  static blocked(feedUrl: string): boolean {
    return BLOCKED_FEEDS.has(CatalogFeedFilter.normalize(feedUrl));
  }

  private static normalize(feedUrl: string): string {
    let value = feedUrl.trim();
    const fragment = value.indexOf('#');
    if (fragment >= 0) value = value.substring(0, fragment);
    const query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    while (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }
}
