import type common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { Station, StationMeta } from '../model/Station';
import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 电台 JSON 的七键编解码(备份与本地存储共用)。
/// 键名与 Android `StationJson.kt` 逐字一致 —— 这是四端 `reverb-backup.json` 的互通契约。
export class StationJson {
  static toJson(s: Station): Record<string, Object> {
    return {
      'id': s.id,
      'name': s.name,
      'url': s.url,
      'logo': s.logo,
      'group': s.group,
      'country': s.country,
      'source': s.source
    };
  }

  /**
   * 从 JSON 还原。`url` 为空的一律返回 null —— 没有地址的电台点了没反应,
   * 收进列表只是多一条"看起来在、其实不能用"的记录(与 Android 同判据)。
   */
  static fromJson(o: Record<string, Object> | null): Station | null {
    if (o === null) return null;
    const url = J.str(o, 'url').trim();
    if (url.length === 0) return null;
    const name = J.str(o, 'name').trim();
    const id = J.str(o, 'id').trim();
    const source = J.str(o, 'source').trim();
    return {
      id: id.length > 0 ? id : `local:${url}`,
      name: name.length > 0 ? name : url,
      url: url,
      logo: J.str(o, 'logo'),
      group: StationMeta.normalizeGroup(J.str(o, 'group')),
      country: J.str(o, 'country'),
      source: source.length > 0 ? source : StationMeta.SOURCE_MANUAL
    };
  }
}

/**
 * 直播电台账本(`filesDir/stations.json`)。
 *
 * **进手动备份,不进局域网同步**。理由与 Android `StationStore` 同一段:同步要传播删除就必须
 * 进 `SyncTombstones`,而那会把同步协议与面板一起扩一块;电台是"点选播放"的快捷方式,
 * 不像订阅那样两条设备各留一份会打架。这条边界是**有意**的,不是漏接。
 *
 * 删除即删除,不留墓碑:本地没有第二条路径会把它带回来(目录与精选是两个只读来源,
 * 只有用户点「加入」才会复制进本账本)。
 */
@Observed
export class StationStore {
  stations: Station[] = [];
  private static FILE = 'stations.json';
  private static SEED_FILE = 'radio_stations.json';
  private ctx: common.UIAbilityContext | null = null;
  private seedLoaded: boolean = false;
  private seeds: Station[] = [];

  /// 随包精选要读 rawfile,所以 boot 里先记下上下文(不读文件,首次进电台页才装载)。
  attach(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  load(): void {
    const arr = JsonFile.readArray(StationStore.FILE);
    const out: Station[] = [];
    for (let i = 0; i < arr.length; i++) {
      const s = StationJson.fromJson(J.asObj(arr[i]));
      if (s === null) continue;
      out.push(s);
    }
    this.stations = out;
    Log.i('Store', `电台加载 ${out.length} 条`);
  }

  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.stations.length; i++) arr.push(StationJson.toJson(this.stations[i]));
    JsonFile.writeJson(StationStore.FILE, arr);
  }

  containsUrl(url: string, exceptId: string = ''): boolean {
    const key = url.trim();
    return this.stations.some((s: Station) => s.url.trim() === key && s.id !== exceptId);
  }

  /// 新增(前置)。id 或 url 已存在时返回 false —— 调用方据此报「已在列表里」。
  add(s: Station): boolean {
    if (this.stations.some((x: Station) => x.id === s.id)) return false;
    if (this.containsUrl(s.url)) return false;
    const next = this.stations.slice();
    next.unshift(s);
    this.stations = next;
    this.persist();
    Log.i('Store', `新增电台 source=${s.source}`);
    return true;
  }

  /// 按 id 改一条。地址被改成另一条已有的地址时**不写入**,返回 false(与新增同一条判据)。
  update(s: Station): boolean {
    if (this.containsUrl(s.url, s.id)) return false;
    const idx = this.stations.findIndex((x: Station) => x.id === s.id);
    if (idx < 0) return false;
    const next = this.stations.slice();
    next[idx] = s;
    this.stations = next;
    this.persist();
    Log.i('Store', `编辑电台 ${s.id}`);
    return true;
  }

  remove(id: string): void {
    const next = this.stations.filter((s: Station) => s.id !== id);
    if (next.length === this.stations.length) return;
    this.stations = next;
    this.persist();
    Log.i('Store', `删除电台 ${id}`);
  }

  /**
   * 备份恢复用的并集:按 id、再按 url 去重,**本端已有优先**。
   * 重复恢复同一份备份不会翻倍,也不会把用户改过的名字盖回旧备份里的样子。
   */
  addAll(list: Station[]): number {
    const next = this.stations.slice();
    let added = 0;
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      if (next.some((x: Station) => x.id === s.id || x.url.trim() === s.url.trim())) continue;
      next.push(s);
      added += 1;
    }
    if (added > 0) {
      this.stations = next;
      this.persist();
    }
    return added;
  }

  /**
   * 随包精选(**只读**,不进本账本)。首次调用时从 rawfile 读 `radio_stations.json`;
   * 文件缺失或格式变化一律退化为空,不影响手动添加与在线目录。
   *
   * 合规口径:这份清单随包进商店时是"内置目录"的一种。若某个渠道要求包里不含目录内容,
   * 按 `shared/radio/sync.sh` 头注把该端拷进去的那份删掉即可 —— 代码不会因此报错。
   */
  seedStations(): Station[] {
    if (this.seedLoaded) return this.seeds;
    this.seedLoaded = true;
    const ctx = this.ctx;
    if (ctx === null) return this.seeds;
    try {
      const bytes = ctx.resourceManager.getRawFileContentSync(StationStore.SEED_FILE);
      const text = new util.TextDecoder('utf-8').decodeToString(bytes);
      const root = JSON.parse(text) as Record<string, Object>;
      const arr = J.arr(root, 'stations');
      const out: Station[] = [];
      for (let i = 0; i < arr.length; i++) {
        const o = J.asObj(arr[i]);
        if (o === null) continue;
        const url = J.str(o, 'url').trim();
        if (url.length === 0) continue;
        const name = J.str(o, 'name').trim();
        out.push({
          id: `seed:${url}`,
          name: name.length > 0 ? name : url,
          url: url,
          logo: J.str(o, 'logo'),
          group: StationMeta.normalizeGroup(J.str(o, 'group')),
          country: J.str(o, 'country'),
          source: StationMeta.SOURCE_SEED
        });
      }
      this.seeds = out;
      Log.i('Store', `精选电台就绪 ${out.length} 条`);
    } catch (e) {
      Log.w('Store', `精选电台装载失败 ${(e as Error).message}`);
    }
    return this.seeds;
  }
}
