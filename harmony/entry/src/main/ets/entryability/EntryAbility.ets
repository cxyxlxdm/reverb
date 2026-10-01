import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type { Configuration } from '@ohos.app.ability.Configuration';
import type Want from '@ohos.app.ability.Want';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { SettingsStore } from '../store/SettingsStore';
import { JsonFile } from '../store/JsonFile';
import { Theme } from '../theme/Theme';
import { Log } from '../util/Logger';

/// 入口 Ability。负责建窗、铺满全屏(内容自行避让状态栏),并把 context 交给存储层。
export default class EntryAbility extends UIAbility {
  private stage: window.WindowStage | null = null;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    Log.i('App', '启动 余音 Reverb(鸿蒙端)');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    // 深浅态要在 loadContent **之前**种好:外壳第一帧就要读到它,
    // 否则深色设备上会先闪一帧浅色(与 H112 那类"首帧从错误的态起步"同因)
    this.syncSystemDark(this.context.config);
    this.loadUi();
    // 沉浸式:内容延伸到状态栏/导航栏下,由页面自行 padding 避让
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((e: Error) => {
        Log.w('App', `全屏布局设置失败 ${e.message}`);
      });
    } catch (e) {
      Log.w('App', `取主窗失败 ${(e as Error).message}`);
    }
    // 切换界面语言后重建整棵界面树(理由见 SettingsStore.onLanguageChanged)
    SettingsStore.onLanguageChanged = () => { this.loadUi(); };
  }

  /**
   * 系统环境变化(深浅色、语言、方向…)。**这里只取深浅色那一格。**
   *
   * 这是本 App 唯一的深浅态来源,理由见 `Theme.SYSTEM_DARK_KEY`:外壳原先只在
   * `aboutToAppear` 读一次 `config.colorMode`,于是运行期间切深浅要重进应用才生效。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.syncSystemDark(newConfig);
  }

  /**
   * 把系统 colorMode 写进 AppStorage 供外壳观察。
   *
   * 只在**真的解析得出**时写:`COLOR_MODE_NOT_SET`(-1)与 undefined 都不当浅色处理 ——
   * 把"读不出"当成"浅色"会让深色界面凭空闪一次浅色,而保持原值最坏只是没跟上。
   * 值相同就不写:写了会触发 @StorageLink 的 @Watch,而主题重建是整树的代价。
   */
  private syncSystemDark(config: Configuration | undefined): void {
    const cm: ConfigurationConstant.ColorMode | undefined = config?.colorMode;
    if (cm === undefined || cm === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) return;
    const dark: boolean = cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (AppStorage.get<boolean>(Theme.SYSTEM_DARK_KEY) === dark) return;
    AppStorage.setOrCreate(Theme.SYSTEM_DARK_KEY, dark);
    Log.i('UI', `设备深色态 → ${dark}`);
  }

  private loadUi(): void {
    const st = this.stage;
    if (st === null) return;
    st.loadContent('pages/Index', (err) => {
      if (err.code) Log.e('App', `loadContent 失败 code=${err.code}`);
    });
  }

  /**
   * 退到后台。**必须把去抖中的写入落盘**:历史进度/收听时长/缓存都走
   * `JsonFile.writeJsonDebounced`(400ms 去抖 + 异步写,为的是不卡 UI 线程),
   * 若此时进程被系统回收,未落盘的那一次就丢了 —— 表现会是"续播位置退回几秒"。
   */
  onBackground(): void {
    JsonFile.flushPending();
  }

  onDestroy(): void {
    JsonFile.flushPending();
    SettingsStore.onLanguageChanged = null;
    this.stage = null;
    Log.i('App', '退出');
  }
}
