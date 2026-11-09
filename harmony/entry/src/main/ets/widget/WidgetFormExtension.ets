import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import formProvider from '@ohos.app.form.formProvider';
import formInfo from '@ohos.app.form.formInfo';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import type Want from '@ohos.app.ability.Want';
import type common from '@ohos.app.ability.common';
import { JsonFile } from '../store/JsonFile';
import { L } from '../util/L';
import { WidgetFormBuilder } from './WidgetFormBuilder';
import { WidgetFormNames } from './WidgetFormData';
import { Log } from '../util/Logger';

/**
 * 「继续收听」服务卡片的提供方。
 *
 * 与 `update/FeedUpdateExtension` 同一条边界:扩展跑在**独立进程**,拿不到 UI 侧的 AppContainer,
 * 所以这里自行最小化装配(`JsonFile.init` + 直接读两份 JSON),只做「读状态 → 拼字段 → 交出去」。
 *
 * 数据进卡片有两条路:
 *  - `onAddForm` 返回 FormBindingData(用户从卡片中心拖上桌面的那一次);
 *  - `onUpdateForm` 走 `formProvider.updateForm`(系统定时刷新,以及 App 侧播放态变化时触发的那条,
 *    后者见 `WidgetUpdater`)。两条都走同一个 `WidgetFormBuilder.build`,不各写一遍。
 */
export default class WidgetFormExtension extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const built = WidgetFormBuilder.build(WidgetFormExtension.dimFromWant(want),
      WidgetFormExtension.initStatics(this.context));
    // 图片 fd 要等系统读完才能关;onAddForm 没有回包回调,给一个宽裕的延时再收。
    setTimeout(() => { built.release(); }, 3000);
    return built.data;
  }

  onUpdateForm(formId: string): void {
    // 尺寸不在回调参数里,只能反查(三档各是一个 form 条目,见 WidgetFormNames)。
    const dark = WidgetFormExtension.initStatics(this.context);
    formProvider.getPublishedRunningFormInfoById(formId)
      .then((info: formInfo.RunningFormInfo) => {
        const built = WidgetFormBuilder.build(WidgetFormNames.dimOfDimension(info.dimension), dark);
        return formProvider.updateForm(formId, built.data)
          .then(() => Log.i('Widget', `卡片定时刷新 formId=${formId}`))
          .catch((e: Error) => Log.w('Widget', `卡片定时刷新失败 formId=${formId} ${e.message}`))
          .then(() => { built.release(); });
      })
      .catch((e: Error) => Log.w('Widget', `卡片信息查询失败 formId=${formId} ${e.message}`));
  }

  /**
   * 扩展进程里没有 AppContainer.boot 那一套装配,静态单例都是空的 —— 这里补上两份 JSON 的底座
   * 和多语言,顺带把深色判定带出去(卡片自己拿不到系统主题)。
   */
  private static initStatics(ctx: common.ExtensionContext): boolean {
    JsonFile.init(ctx.filesDir);
    L.init(ctx);
    return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private static dimFromWant(want: Want): string {
    const p = want.parameters;
    if (p === undefined) return '2*2';
    const raw: Object | undefined = p[formInfo.FormParam.DIMENSION_KEY];
    if (raw === undefined) return '2*2';
    const n = typeof raw === 'number' ? raw as number : Number.parseInt(`${raw}`, 10);
    return WidgetFormNames.dimOfDimension(n);
  }
}
