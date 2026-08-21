import type resourceManager from '@ohos.resourceManager';
import type common from '@ohos.app.ability.common';
import { Log } from './Logger';

/// 文案取用。按名取 resources/*/element/string.json 里的串,
/// 语言切换(i18n.System.setAppPreferredLanguage)后 resourceManager 会按新语言解析。
/// 之所以不用 `$r()` + Resource 类型:界面里大量位置(Prop、模板串、菜单项)需要的是 string,
/// 统一走这里比到处做 Resource↔string 转换更省事,也便于带参格式化。
export class L {
  private static rm: resourceManager.ResourceManager | null = null;

  static init(ctx: common.Context): void {
    L.rm = ctx.resourceManager;
  }

  /// 取一条文案;取不到时返回键名本身(便于在界面上直接看出漏配)。
  static s(name: string): string {
    const rm = L.rm;
    if (rm === null) return name;
    try {
      return rm.getStringByNameSync(name);
    } catch (e) {
      Log.w('L', `缺文案 ${name}`);
      return name;
    }
  }

  /**
   * 取一条带占位符(%s / %d / %1$s …)的文案。
   *
   * `getStringByNameSync` 对**占位符与实参类型不符**极其严格:`%s` 传 number 直接抛
   * (不像 Java 的 String.format 会照常输出),而它抛出来的错和"压根没这条文案"长得一样。
   * 踩过一次:新首屏的 `import_done` / `starter_have_subs` 文案从 Android 移过来时把
   * `%1$d` 写成了 `%s`,于是导入成功后界面上明晃晃显示两行 **`import_done`**、
   * **`starter_have_subs`** —— 键名当文案给用户看了。
   *
   * 所以这里失败后不再直接返回键名,而是**自己把占位符填一遍**:最坏情况是格式不那么讲究,
   * 也不会把键名摆到界面上。真正的问题仍然记在日志里(下面这句 warn),不是掩盖。
   */
  static f(name: string, ...args: (string | number)[]): string {
    const rm = L.rm;
    if (rm === null) return name;
    try {
      return rm.getStringByNameSync(name, ...args);
    } catch (e) {
      const raw = L.s(name);
      Log.w('L', `文案带参取用失败 ${name}(占位符与实参类型不符?),改用手工填充`);
      return raw === name ? name : L.fill(raw, args);
    }
  }

  /// 手工填充占位符:先处理带序号的 `%1$s` / `%2$d`,再按出现顺序处理裸 `%s` / `%d`。
  private static fill(template: string, args: (string | number)[]): string {
    let out = template;
    for (let i = 0; i < args.length; i++) {
      const v = `${args[i]}`;
      out = out.replace(`%${i + 1}$s`, v).replace(`%${i + 1}$d`, v);
    }
    let i = 0;
    // replace 收函数版本可以一次扫完,且不会把刚填进去的内容再当占位符匹配
    out = out.replace(/%[sd]/g, (): string => {
      const v = i < args.length ? `${args[i]}` : '';
      i = i + 1;
      return v;
    });
    return out;
  }
}
