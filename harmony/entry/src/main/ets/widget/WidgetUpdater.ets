import formProvider from '@ohos.app.form.formProvider';
import type formInfo from '@ohos.app.form.formInfo';
import { WidgetFormBuilder } from './WidgetFormBuilder';
import { WidgetFormNames } from './WidgetFormData';
import { Theme } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { Log } from '../util/Logger';

/**
 * App 侧把「继续收听」推上桌面卡片(Android 对应物是 `widget/WidgetRefresh.kt`)。
 *
 * 节流口径与 Android 一致:播放中**最多 20 秒推一次**,播放/暂停/换集/seek 这类真实状态变化
 * 走 `force`,立刻排一次。为什么需要节流:播放中每 500ms 有一个 tick、每 5 秒落一次历史进度,
 * 每次落盘都推一遍等于每分钟十几次进程间更新,而卡片上的时间只精确到秒。
 *
 * force 也**不是同步执行**,而是延后 700ms:进度写盘是 400ms 去抖(JsonFile.writeJsonDebounced),
 * 立刻推会读到上一份 —— 卡片上的进度会比实际落后一跳(Android 那边 seek/暂停路径的
 * `delayMs = 900` 是同一件事的同一个解)。
 *
 * 进程边界:本类跑在 **UI 进程**,与 `WidgetFormExtension` 那个独立进程不是同一套
 * `JsonFile`/`L` 单例;两边共用 `WidgetFormBuilder`,保证字段与取值口径一致。
 */
export class WidgetUpdater {
  private static readonly MIN_MS: number = 20_000;
  private static readonly FORCE_DELAY_MS: number = 700;
  private static lastRunAt: number = 0;
  private static timer: number = -1;
  private static busy: boolean = false;

  /// 推一次。`force=false` 时按 20 秒节流(到点补推一次,不丢最后一次)。
  static request(settings: SettingsStore, force: boolean = false): void {
    if (force) {
      WidgetUpdater.schedule(settings, WidgetUpdater.FORCE_DELAY_MS);
      return;
    }
    const since = Date.now() - WidgetUpdater.lastRunAt;
    if (since >= WidgetUpdater.MIN_MS) {
      WidgetUpdater.run(settings, Date.now());
      return;
    }
    WidgetUpdater.schedule(settings, WidgetUpdater.MIN_MS - since);
  }

  /// 同一时刻只留一个待执行的定时器:连续的状态变化合成一次推送。
  private static schedule(settings: SettingsStore, delayMs: number): void {
    if (WidgetUpdater.timer >= 0) clearTimeout(WidgetUpdater.timer);
    WidgetUpdater.timer = setTimeout(() => {
      WidgetUpdater.timer = -1;
      WidgetUpdater.run(settings, Date.now());
    }, delayMs);
  }

  private static async run(settings: SettingsStore, now: number): Promise<void> {
    WidgetUpdater.lastRunAt = now;
    // 上一轮还在等系统回包就跳过:紧接着还会有 force,不会把最后一次变化丢掉。
    if (WidgetUpdater.busy) return;
    WidgetUpdater.busy = true;
    try {
      const infos: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
      if (infos.length === 0) return;
      const dark = WidgetUpdater.isDark(settings);
      for (let i = 0; i < infos.length; i++) {
        const info = infos[i];
        const built = WidgetFormBuilder.build(WidgetFormNames.dimOfDimension(info.dimension), dark);
        try {
          await formProvider.updateForm(info.formId, built.data);
        } catch (e) {
          Log.w('Widget', `卡片更新失败 formId=${info.formId} ${(e as Error).message}`);
        } finally {
          built.release();
        }
      }
    } catch (e) {
      Log.w('Widget', `取卡片列表失败 ${(e as Error).message}`);
    } finally {
      WidgetUpdater.busy = false;
    }
  }

  /**
   * 卡片该用深色还是浅色。
   *
   * 与外壳 `Index.scheme()` 同一套档位(0 跟随系统 / 1 浅色 / 2 深色 / 3 纯白),但系统深浅态
   * 只能从 AppStorage 取 —— 卡片进程读不到它,所以必须在 UI 进程里算好、随数据送过去。
   */
  private static isDark(settings: SettingsStore): boolean {
    const mode = settings.themeMode;
    if (mode === 2) return true;
    if (mode === 1 || mode === 3) return false;
    return AppStorage.get<boolean>(Theme.SYSTEM_DARK_KEY) === true;
  }
}
