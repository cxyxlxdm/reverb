import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type Want from '@ohos.app.ability.Want';
import { SettingsStore } from '../store/SettingsStore';
import { JsonFile } from '../store/JsonFile';
import { Log } from '../util/Logger';

/// 入口 Ability。负责建窗、铺满全屏(内容自行避让状态栏),并把 context 交给存储层。
export default class EntryAbility extends UIAbility {
  private stage: window.WindowStage | null = null;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    Log.i('App', '启动 余音 Reverb(鸿蒙端)');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
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
