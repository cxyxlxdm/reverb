import type common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { Podcast } from '../model/Models';
import { Codec } from './Codec';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 随包内置的精选清单(`resources/rawfile/seed_podcasts.json`,由 `shared/seed/gen-seed.py` 生成)。
///
/// 解决的问题:首次安装、清过缓存、或全程无网时,「发现」页各分类都是空白,只能干等。
/// 有了这份清单,磁盘缓存为空时先拿它顶上,首屏立刻有内容可看可点。
///
/// 它**只是兜底**:一旦 PopularCacheStore 有真实榜单就再也不用它,且**从不写入缓存**
/// —— 否则真假数据混在一起,之后无法区分"这是快照"还是"这是今天的榜"。
/// 读 rawfile 是同步的(getRawFileContentSync),50KB 量级,放在 boot 里一次读完即可。
export class SeedCatalog {
  private lists: Record<string, Podcast[]> = {};
  private generated: string = '';
  private loaded: boolean = false;
  private ctx: common.UIAbilityContext | null = null;

  /// boot 里只记下上下文,**不读文件** —— 真正装载推迟到第一次 get()。
  /// 原先在 boot 同步读 50KB + JSON.parse,和其他几个 store 的同步读叠在一起拖慢首帧;
  /// 而这份数据只在"热榜缓存为空"时才用得上,绝大多数启动压根不需要。
  attach(ctx: common.UIAbilityContext): void {
    this.ctx = ctx;
  }

  /// 从 rawfile 装载(惰性,首次 get 时触发)。失败一律退化为空,不影响发现页联网路径。
  private load(): void {
    if (this.loaded) return;
    this.loaded = true;
    const ctx = this.ctx;
    if (ctx === null) return;
    try {
      const bytes = ctx.resourceManager.getRawFileContentSync('seed_podcasts.json');
      const text = new util.TextDecoder('utf-8').decodeToString(bytes);
      const root = JSON.parse(text) as Record<string, Object>;
      this.generated = J.str(root, 'generatedAt');
      const listsObj = J.obj(root, 'lists');
      if (listsObj === null) {
        Log.w('Seed', '内置清单缺少 lists 段');
        return;
      }
      const keys = Object.keys(listsObj);
      let total = 0;
      for (let i = 0; i < keys.length; i++) {
        const raw = listsObj[keys[i]];
        if (!Array.isArray(raw)) continue;
        const a = raw as Object[];
        const list: Podcast[] = [];
        for (let j = 0; j < a.length; j++) {
          const p = Codec.podcastFromJson(J.asObj(a[j]));
          if (p.feedUrl.length > 0) list.push(p);
        }
        if (list.length > 0) {
          this.lists[keys[i]] = list;
          total += list.length;
        }
      }
      Log.i('Seed', `内置清单就绪 ${keys.length} 组 / ${total} 条 生成于 ${this.generated}`);
    } catch (e) {
      // rawfile 缺失或格式变化不该让发现页崩
      Log.w('Seed', `内置清单装载失败 ${(e as Error).message}`);
    }
  }

  /// 该地区+分类的内置清单;没有则空。genreId 为 0 表示综合推荐(与 repository 一致)。
  get(genreId: number, region: string): Podcast[] {
    this.load();
    const v = this.lists[`${SeedCatalog.seedRegion(region)}:${genreId > 0 ? genreId : 0}`];
    return v === undefined ? [] : v;
  }

  /// 清单生成日期(yyyy-MM-dd)。
  generatedAt(): string {
    this.load();
    return this.generated;
  }

  /// 种子只打包 cn / us 两份榜单(12 个地区全打进去没必要,它只是没网时的兜底)。
  /// 中文区落到 cn,其余一律落到 us。
  private static seedRegion(region: string): string {
    const r = region.toLowerCase();
    return (r === 'cn' || r === 'hk' || r === 'tw' || r === 'mo') ? 'cn' : 'us';
  }
}
