import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 搜索历史(`filesDir/search_history.json`),最近 20 条、新的在前。
 *
 * **只在本机留存**:不进手动备份、不进局域网同步。理由与 Android `SearchHistoryStore`
 * 同一段 —— 它是"这台设备上顺手搜过什么"的快捷方式,含用户自己的关键词;
 * 删了就删了,本地没有第二条路径会把它带回来,所以也不需要墓碑。
 *
 * 写入时机只有一个:**真正发起检索**时(见 `DiscoverPage.runSearch`)。输入到一半、
 * 粘贴了却不提交都不记。上限与四端一致(20 条 / 单条 100 字)。
 */
@Observed
export class SearchHistoryStore {
  items: string[] = [];
  private static FILE = 'search_history.json';
  private static LIMIT = 20;
  private static MAX_LENGTH = 100;

  load(): void {
    const arr = JsonFile.readArray(SearchHistoryStore.FILE);
    const out: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const q = J.asStr(arr[i]).trim();
      if (q.length === 0 || out.indexOf(q) >= 0) continue;
      out.push(q);
      if (out.length >= SearchHistoryStore.LIMIT) break;
    }
    this.items = out;
    Log.i('Store', `搜索历史加载 ${out.length} 条`);
  }

  /// 记一条:去重(同词提到最前)、限长、最多留 LIMIT 条。
  record(raw: string): void {
    let q = raw.trim();
    if (q.length === 0) return;
    if (q.length > SearchHistoryStore.MAX_LENGTH) {
      q = q.substring(0, SearchHistoryStore.MAX_LENGTH);
    }
    const next = this.items.filter((x: string) => x !== q);
    next.unshift(q);
    this.items = next.slice(0, SearchHistoryStore.LIMIT);
    JsonFile.writeJson(SearchHistoryStore.FILE, this.items);
  }

  remove(q: string): void {
    const next = this.items.filter((x: string) => x !== q);
    if (next.length === this.items.length) return;
    this.items = next;
    JsonFile.writeJson(SearchHistoryStore.FILE, this.items);
  }

  clear(): void {
    if (this.items.length === 0) return;
    this.items = [];
    JsonFile.writeJson(SearchHistoryStore.FILE, this.items);
  }
}
