import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type Want from '@ohos.app.ability.Want';
import { Log } from '../util/Logger';

/// 入口 Ability。负责建窗、铺满全屏(内容自行避让状态栏),并把 context 交给存储层。
export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    Log.i('App', '启动 余音 Reverb(鸿蒙端)');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Log.e('App', `loadContent 失败 code=${err.code}`);
        return;
      }
      // 沉浸式:内容延伸到状态栏/导航栏下,由页面自行 padding 避让
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((e: Error) => {
        Log.w('App', `全屏布局设置失败 ${e.message}`);
      });
    });
  }

  onDestroy(): void {
    Log.i('App', '退出');
  }
}
