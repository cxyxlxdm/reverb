import { Station, StationMeta } from '../model/Station';
import { Http, J } from './Http';
import { Log } from '../util/Logger';

/**
 * 在线直播电台目录(radio-browser.info)。
 *
 * - 免 Key、CC0、无账号 —— 符合「零后端、不接三方 SDK」:这里只是一次公开 HTTP GET;
 * - **两个镜像**:`de1` 先试,失败退 `de2`(2026-11-22 实测两台都通;at1/nl1 在本机不通,
 *   所以不写进列表);
 * - 日志只记"镜像 + 条数",**不记查询词** —— 搜索词是用户输入,与不记录 URL 同一口径。
 *
 * 与 Android `RadioBrowserSource.kt` 同参数:`popular` 取中国区按点击量倒序,
 * `search` 按名称匹配;`lastcheckok=0`(目录自己标记为不可用)的条目在解析侧剔掉。
 */
export class RadioBrowserSource {
  private static readonly HOSTS: string[] = ['de1.api.radio-browser.info', 'de2.api.radio-browser.info'];

  async popular(limit: number = 40): Promise<Station[]> {
    return this.fetch('/json/stations/search?countrycode=CN&hidebroken=true'
      + `&order=clickcount&reverse=true&limit=${limit}`, 'popular');
  }

  async search(query: string, limit: number = 50): Promise<Station[]> {
    const q = query.trim();
    if (q.length === 0) return [];
    return this.fetch(`/json/stations/search?name=${encodeURIComponent(q)}&hidebroken=true&limit=${limit}`,
      `search words=${q.split(/\s+/).length}`);
  }

  private async fetch(path: string, tag: string): Promise<Station[]> {
    for (let i = 0; i < RadioBrowserSource.HOSTS.length; i++) {
      const host = RadioBrowserSource.HOSTS[i];
      const text = await Http.text(`https://${host}${path}`, 12000);
      if (text === null) {
        Log.w('RadioDir', `镜像不可用 ${host} ${tag}`);
        continue;
      }
      const list = RadioBrowserSource.parse(text);
      Log.i('RadioDir', `目录 ${host} ${tag} count=${list.length}`);
      return list;
    }
    throw new Error('radio directory unreachable');
  }

  /// 目录响应 → Station[]。坏元素逐条跳过,不因为一条缺字段丢掉整页。
  static parse(text: string): Station[] {
    let raw: Object;
    try {
      raw = JSON.parse(text) as Object;
    } catch (e) {
      return [];
    }
    if (!Array.isArray(raw)) return [];
    const arr = raw as Object[];
    const out: Station[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      // 目录自己标了 lastcheckok=0 —— 它最近一次探测就是失败,别拿来当"能听"
      if (J.num(o, 'lastcheckok') === 0) continue;
      const resolved = J.str(o, 'url_resolved').trim();
      const url = resolved.length > 0 ? resolved : J.str(o, 'url').trim();
      if (url.length === 0) continue;
      const name = J.str(o, 'name').trim();
      if (name.length === 0) continue;
      if (seen.has(url)) continue;
      seen.add(url);
      const uuid = J.str(o, 'stationuuid').trim();
      out.push({
        id: uuid.length > 0 ? `rb:${uuid}` : `rb:${url}`,
        name: name,
        url: url,
        logo: J.str(o, 'favicon'),
        // 目录不给分组:它有自己的 tag 体系,与本端的四档不是一套,猜一个反而会分类错
        group: '',
        country: J.str(o, 'countrycode') || J.str(o, 'country'),
        source: StationMeta.SOURCE_DIRECTORY
      });
    }
    return out;
  }
}
