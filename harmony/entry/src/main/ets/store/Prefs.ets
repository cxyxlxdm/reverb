import preferences from '@ohos.data.preferences';
import type common from '@ohos.app.ability.common';
import { Log } from '../util/Logger';

/// 轻量键值存储(对应 Android SharedPreferences / macOS UserDefaults)。
/// 同步读:启动时一次性 getSync 拉起,之后读内存;写入异步 flush。
export class Prefs {
  private static store: preferences.Preferences | null = null;

  static init(ctx: common.UIAbilityContext): void {
    if (Prefs.store !== null) return;
    try {
      Prefs.store = preferences.getPreferencesSync(ctx, { name: 'reverb_settings' });
    } catch (e) {
      Log.e('Prefs', `初始化失败 ${(e as Error).message}`);
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
}
