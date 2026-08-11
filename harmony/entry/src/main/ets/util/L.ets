import type resourceManager from '@ohos.resourceManager';
import type common from '@ohos.app.ability.common';
import { Log } from './Logger';

/// 文案取用。按名取 resources/*/element/string.json 里的串,
/// 语言切换(i18n.System.setAppPreferredLanguage)后 resourceManager 会按新语言解析。
/// 之所以不用 `$r()` + Resource 类型:界面里大量位置(Prop、模板串、菜单项)需要的是 string,
/// 统一走这里比到处做 Resource↔string 转换更省事,也便于带参格式化。
export class L {
  private static rm: resourceManager.ResourceManager | null = null;

  static init(ctx: common.UIAbilityContext): void {
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

  /// 取一条带占位符(%s / %d)的文案。
  static f(name: string, ...args: (string | number)[]): string {
    const rm = L.rm;
    if (rm === null) return name;
    try {
      return rm.getStringByNameSync(name, ...args);
    } catch (e) {
      Log.w('L', `缺文案(带参) ${name}`);
      return name;
    }
  }
}
