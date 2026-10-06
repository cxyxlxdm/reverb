import { Prefs } from './Prefs';
import { Log } from '../util/Logger';
import { DISCOVER_CATEGORIES, DiscoverCategory } from '../model/Genres';

/**
 * 发现页分类的**用户自定义顺序**(与 Android `data/local/CategoryStore.kt` 同义、同键位语义)。
 *
 * 存的是 **key 的顺序**而不是显示名:key 是稳定标识(`recommend` / `news` / …),
 * 显示名随语言变。Android 那边用 `\u0001` 连接成一串存 SharedPreferences;
 * 本端 preferences 没有数组类型,索性存一段 JSON 数组 —— 两份数据不互通,
 * 但**跨端搬运走的是手动备份里的 `categoryOrder`(同样是 key 的 JSON 数组)**,
 * 那个才是契约,本地编码不是。
 *
 * `ordered()` 的口径与 Android `DiscoverViewModel.loadOrdered()` 逐项一致:
 * 没存过 → 原序;存过的按序取,**表里没有的 key 直接丢**(分类下线时不会留下一颗空 chip),
 * **新增的分类挂在末尾**(加了新分类不至于排在用户自定义顺序前面把他最看重的挤下去)。
 */
export class CategoryStore {
  private static readonly KEY: string = 'category_order';
  private order: string[] = [];

  /// 必须由 AppContainer.boot 调用(那时 Prefs 才 init 完)。
  load(): void {
    this.order = CategoryStore.readFromDisk();
    if (this.order.length > 0) Log.i('Category', `自定义顺序 ${this.order.length} 项`);
  }

  ordered(): DiscoverCategory[] {
    if (this.order.length === 0) return DISCOVER_CATEGORIES;
    const out: DiscoverCategory[] = [];
    for (let i = 0; i < this.order.length; i++) {
      const c = DISCOVER_CATEGORIES.find((x: DiscoverCategory) => x.key === this.order[i]);
      if (c !== undefined) out.push(c);
    }
    for (let i = 0; i < DISCOVER_CATEGORIES.length; i++) {
      const c = DISCOVER_CATEGORIES[i];
      if (out.find((x: DiscoverCategory) => x.key === c.key) === undefined) out.push(c);
    }
    // 上面两个循环把话说死了:表里的 key 全被下线时会剩一份空表,而空表等于"发现页没有分类"。
    // 与 Android 的 `.ifEmpty { DISCOVER_CATEGORIES }` 同一条兜底。
    return out.length === 0 ? DISCOVER_CATEGORIES : out;
  }

  /**
   * 写整份顺序(排序框「保存」与备份恢复都走这里)。**空数组直接返回,不落盘。**
   *
   * 这条早退是照 Android 抄的两处:DiscoverViewModel.kt:104 `if (newOrder.isEmpty()) return`、
   * BackupManager.kt 恢复段 `if (order.isNotEmpty()) …`。两端在"空"上的语义必须一致 ——
   * 如果这里改成"空 = 写空串 = 回默认序",那么备份里**没有**这个键(旧版本备份、
   * 或用户只勾了别的分区)就会在恢复时把用户排好的顺序**清空**,
   * 而 Android 恢复同一份备份是什么都不动。排序框那条路永远有 19 项,撞不到;
   * 撞得到的是 #88 之后的恢复路径,所以在这里先对齐。
   */
  save(keys: string[]): void {
    const next: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      if (k.length > 0 && next.indexOf(k) < 0) next.push(k);
    }
    if (next.length === 0) return;
    this.order = next;
    Prefs.put(CategoryStore.KEY, JSON.stringify(next));
    Log.i('Category', `保存顺序 ${next.length} 项`);
  }

  /**
   * 导出**原始**顺序(未排过 = 空数组),供手动备份写 `categoryOrder`。
   *
   * 刻意不返回 `ordered()`:Android 那侧导出的是 `categoryStore.loadOrder()` 原值,
   * 也就是"用户到底排没排过"。把默认序展平成 19 个 key 写出去,恢复端就分不出
   * "用户主动排成默认序"和"从没排过",而将来若允许"只勾 settings 分区、不覆盖顺序",
   * 这个区分是唯一的依据。
   */
  keys(): string[] {
    return this.order.slice();
  }

  private static readFromDisk(): string[] {
    const raw = Prefs.getString(CategoryStore.KEY, '');
    if (raw.length === 0) return [];
    try {
      const parsed = JSON.parse(raw) as string[];
      if (!Array.isArray(parsed)) return [];
      const out: string[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const v = parsed[i];
        if (typeof v === 'string' && v.length > 0) out.push(v);
      }
      return out;
    } catch (e) {
      Log.w('Category', `顺序解析失败,按默认序:${(e as Error).message}`);
      return [];
    }
  }
}
