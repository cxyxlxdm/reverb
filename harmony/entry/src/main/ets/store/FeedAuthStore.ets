import { JsonFile } from './JsonFile';
import { Log } from '../util/Logger';
import { FeedCredential } from '../model/FeedCredential';

/// 磁盘表示。字段名与 Android `{"v":1,"items":{feed:{"u","p"}}}` 一致 ——
/// 这份文件从不跨端同步,同形只是为了让两端排查时读同一个键。
class StoredItem {
  u: string;
  p: string;

  constructor(u: string, p: string) {
    this.u = u;
    this.p = p;
  }
}

class StoredAuth {
  v: number;
  items: Record<string, StoredItem>;

  constructor(items: Record<string, StoredItem>) {
    this.v = 1;
    this.items = items;
  }
}

/**
 * 私有订阅源的凭据账本:`feedUrl -> 用户名/密码`。与 Android `FeedAuthStore.kt` /
 * macOS `Data/FeedAuthStore.swift` 同一口径。
 *
 * 三条口径(与 `docs/FEATURES.md` 订阅那一节同源):
 *  1. **只存本机,不进任何备份。** `feed_auth.json` 不在 `BackupManager` 的任何导出段里,
 *     系统的「完整备份」只导出订阅列表,不含凭据。换机后用户需要重新输入一次 ——
 *     这是有意的:口令不该跟着 JSON 到处走。
 *  2. **只发给源自己。** [`headerForUrl`] 按主机匹配(= 同主机或互为子域),不对"任意音频
 *     CDN"发送。音频与 feed 常常不同主机,那种情况下宁可不带 —— 把口令交给一个与用户
 *     无关的主机,是本仓库隐私口径里不能接受的一步(见 H253)。
 *  3. **日志只记主机。** `Log.endpoint` 会把 URL 裁到 scheme://host,账号密码一个字都不进日志。
 *
 * 不加密:与应用里其余 JSON 账本一样落在应用私有目录,没有系统钥匙串支持时
 * "加密"只是把钥匙放在同一台设备上,不值得多一层自欺。
 */
export class FeedAuthStore {
  private static FILE = 'feed_auth.json';

  private mem: Record<string, FeedCredential> = {};

  load(): void {
    this.mem = {};
    const root = JsonFile.readObject(FeedAuthStore.FILE);
    if (root === null) return;
    const items = root['items'];
    if (items === undefined || items === null || Array.isArray(items)) return;
    const map = items as Record<string, Object>;
    const keys = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const raw = map[key];
      if (raw === undefined || raw === null || Array.isArray(raw)) continue;
      const item = raw as Record<string, Object>;
      const u = item['u'];
      const p = item['p'];
      if (typeof u !== 'string' || u.length === 0) continue;
      this.mem[key] = new FeedCredential(u, typeof p === 'string' ? p : '');
    }
    if (keys.length > 0) Log.i('FeedAuth', `装载 ${Object.keys(this.mem).length} 条源凭据`);
  }

  get(feedUrl: string): FeedCredential | null {
    const key = feedUrl.trim();
    const found = this.mem[key];
    return found === undefined ? null : found;
  }

  /// 保存(覆盖)某个源的凭据。**同步落盘**:这份文件只有几百字节,而它承载的是
  /// 用户刚输入、马上要用来重试的口令 —— 进程在去抖窗口内被杀就丢,不值得省这一次写盘。
  save(feedUrl: string, credential: FeedCredential): void {
    const key = feedUrl.trim();
    if (key.length === 0 || credential.username.length === 0) return;
    this.mem[key] = credential;
    this.persist();
    Log.i('FeedAuth', `save feed=${Log.endpoint(key)}`);
  }

  forget(feedUrl: string): void {
    const key = feedUrl.trim();
    if (this.mem[key] === undefined) return;
    // ArkTS 不支持 `delete` 运算符,重建一份即可(账本只有几条)
    const next: Record<string, FeedCredential> = {};
    const keys = Object.keys(this.mem);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== key) next[keys[i]] = this.mem[keys[i]];
    }
    this.mem = next;
    this.persist();
    Log.i('FeedAuth', `forget feed=${Log.endpoint(key)}`);
  }

  /// 某个源自己的凭据头(feed 请求用)。
  headerFor(feedUrl: string): string | null {
    const c = this.get(feedUrl);
    return c === null ? null : c.defaultHeader;
  }

  /// 音频 / 逐字稿:只有与某个已存源的**主机**相同(或互为子域)才给凭据。
  ///
  /// 同一主机上存了多份**不同**凭据时不给(不猜) —— 宁可让用户看到 401 再输一次,
  /// 也不要把 A 站的口令发给 B 站。
  headerForUrl(url: string): string | null {
    const host = FeedCredential.hostOf(url);
    if (host.length === 0) return null;
    const keys = Object.keys(this.mem);
    let chosen: FeedCredential | null = null;
    let signature = '';
    let distinct = 0;
    for (let i = 0; i < keys.length; i++) {
      const keyHost = FeedCredential.hostOf(keys[i]);
      if (!FeedCredential.hostMatches(host, keyHost)) continue;
      const c = this.mem[keys[i]];
      const sig = `${c.username}\u0000${c.password}`;
      if (distinct === 0) {
        chosen = c;
        signature = sig;
        distinct = 1;
      } else if (sig !== signature) {
        distinct = 2;
      }
    }
    if (distinct !== 1 || chosen === null) return null;
    return chosen.defaultHeader;
  }

  private persist(): void {
    const items: Record<string, StoredItem> = {};
    const keys = Object.keys(this.mem);
    for (let i = 0; i < keys.length; i++) {
      const c = this.mem[keys[i]];
      items[keys[i]] = new StoredItem(c.username, c.password);
    }
    JsonFile.writeJson(FeedAuthStore.FILE, new StoredAuth(items));
  }
}
