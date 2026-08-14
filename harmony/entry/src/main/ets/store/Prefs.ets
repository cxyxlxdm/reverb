import preferences from '@ohos.data.preferences';
import type common from '@ohos.app.ability.common';
import { Log } from '../util/Logger';

/// 轻量键值存储(对应 Android SharedPreferences / macOS UserDefaults)。
/// 同步读:启动时一次性 getSync 拉起,之后读内存;写入异步 flush。
export class Prefs {
  private static store: preferences.Preferences | null = null;
  /// 订阅更新的「已见最新一集」专用文件(与设置分开,理由见 seenPut)
  private static seen: preferences.Preferences | null = null;

  static init(ctx: common.Context): void {
    if (Prefs.store !== null) return;
    try {
      Prefs.store = preferences.getPreferencesSync(ctx, { name: 'reverb_settings' });
    } catch (e) {
      Log.e('Prefs', `初始化失败 ${(e as Error).message}`);
    }
    try {
      Prefs.seen = preferences.getPreferencesSync(ctx, { name: 'reverb_updates' });
    } catch (e) {
      Log.w('Prefs', `更新记录初始化失败 ${(e as Error).message}`);
    }
  }

  static getNumber(key: string, def: number): number {
    if (Prefs.store === null) return def;
    try {
      const v = Prefs.store.getSync(key, def);
      return typeof v === 'number' ? v : def;
    } catch (e) {
      Log.w('Prefs', `读取失败 key=${key}`);
      return def;
    }
  }

  static getString(key: string, def: string): string {
    if (Prefs.store === null) return def;
    try {
      const v = Prefs.store.getSync(key, def);
      return typeof v === 'string' ? v : def;
    } catch (e) {
      Log.w('Prefs', `读取失败 key=${key}`);
      return def;
    }
  }

  static getBool(key: string, def: boolean): boolean {
    if (Prefs.store === null) return def;
    try {
      const v = Prefs.store.getSync(key, def);
      return typeof v === 'boolean' ? v : def;
    } catch (e) {
      Log.w('Prefs', `读取失败 key=${key}`);
      return def;
    }
  }

  static put(key: string, value: number | string | boolean): void {
    if (Prefs.store === null) return;
    try {
      Prefs.store.putSync(key, value);
      Prefs.store.flush();
    } catch (e) {
      Log.w('Prefs', `写入失败 key=${key}`);
    }
  }

  static seenGet(key: string): string {
    if (Prefs.seen === null) return '';
    try {
      const v = Prefs.seen.getSync(key, '');
      return typeof v === 'string' ? v : '';
    } catch (e) {
      return '';
    }
  }

  /**
   * 记录某个 feed「已见的最新一集」。**必须写在独立文件里,不能混进 reverb_settings。**
   *
   * 这条记录唯一的写入方是 `FeedUpdateExtension`,而它跑在**独立进程**:
   * 两个进程各自 `getPreferencesSync` 持有一份快照,`flush()` 又是**整份写回**
   * (鸿蒙 preferences 并非多进程安全)。混在一起时,扩展进程写 `seen_*` 落盘,
   * 就可能把 UI 进程之后改的主题/配色等一并盖回它快照里的旧值 —— 属静默数据丢失,
   * 排查时只会看到「设置自己变回去了」。分文件后两个进程不再写同一份,从根上避免。
   */
  static seenPut(key: string, value: string): void {
    if (Prefs.seen === null) return;
    try {
      Prefs.seen.putSync(key, value);
      Prefs.seen.flush();
    } catch (e) {
      Log.w('Prefs', `更新记录写入失败 key=${key}`);
    }
  }
}
