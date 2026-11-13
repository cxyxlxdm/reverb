import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import rpc from '@ohos.rpc';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import type { Configuration } from '@ohos.app.ability.Configuration';
import type Want from '@ohos.app.ability.Want';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { SettingsStore } from '../store/SettingsStore';
import { JsonFile } from '../store/JsonFile';
import { AppContainer } from '../AppContainer';
import { Theme } from '../theme/Theme';
import { WidgetRoute } from '../widget/WidgetRoute';
import { WidgetFormData } from '../widget/WidgetFormData';
import { Log } from '../util/Logger';

/**
 * 卡片 call 事件的回包。
 *
 * SDK 把 `callee.on` 的回调签名定成"收 MessageSequence、回 **Parcelable**"(不是回
 * MessageSequence —— 直接回它编译期就报 `missing marshalling/unmarshalling`)。卡片侧不读回包,
 * 所以这里是一个空壳:方法都返回 true,不带任何字段。
 */
class WidgetCallResult implements rpc.Parcelable {
  marshalling(_dataOut: rpc.MessageSequence): boolean { return true; }
  unmarshalling(_dataIn: rpc.MessageSequence): boolean { return true; }
}

/// 入口 Ability。负责建窗、铺满全屏(内容自行避让状态栏),并把 context 交给存储层。
export default class EntryAbility extends UIAbility {
  private stage: window.WindowStage | null = null;

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    Log.i('App', '启动 余音 Reverb(鸿蒙端)');
    this.handleWidgetWant(want);
    this.registerWidgetActions();
  }

  /**
   * 热启动(应用已在后台 / 已在桌面)。服务卡片用 `router` 动作拉起 EntryAbility 时走这里,
   * 必须在 onNewWant 里也读一次 —— 只写 onCreate 的话,第二次点卡片什么都不会发生。
   */
  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.handleWidgetWant(want);
  }

  /**
   * 卡片点击:卡片侧带 `reverbWidget: 'player'`,这里往 AppStorage 写一个**递增计数**,
   * 外壳(Index)以 `@StorageLink` 观察它,变了就进播放页。
   *
   * 为什么走 AppStorage 而不是直接在这里导航:入口 Ability 拿不到外壳的 `NavPathStack`;
   * 而冷启动时 onCreate 早于 `loadContent`,写进 AppStorage 正好让外壳第一帧就能读到。
   * 用计数而不是布尔:连点两次要各触发一次(布尔第二次没有变化,@Watch 不响)。
   */
  private handleWidgetWant(want: Want): void {
    const p = want.parameters;
    if (p === undefined) return;
    if (p[WidgetRoute.PARAM_KEY] !== WidgetRoute.PLAYER) return;
    const cur = AppStorage.get<number>(WidgetRoute.OPEN_PLAYER);
    AppStorage.setOrCreate(WidgetRoute.OPEN_PLAYER, (cur === undefined ? 0 : cur) + 1);
    Log.i('App', '服务卡片要求打开播放页');
  }

  /**
   * 卡片上三颗播放键的入口。
   *
   * 卡片侧是 `postCardAction({action:'call', abilityName:'EntryAbility', params:{method:'widgetToggle'}})`,
   * 系统把本 Ability **在后台拉起**(不弹界面)再把消息投给这里注册的回调 —— 所以
   * 「点卡片上的播放键」与「点卡片进播放页」是两条路:前者只动播放态,后者才换界面。
   *
   * 回调必须返回一个 `MessageSequence`:这是 call 事件的协议要求,返回 undefined 时
   * 系统侧会报错,而卡片上看到的现象是"点了没反应"(与 `WidgetRoute` 里名字写错一样难查)。
   *
   * 注册只做一次(onCreate),方法名与 `WidgetRoute.ACTION_*` 逐字一致。
   */
  private registerWidgetActions(): void {
    this.callee.on(WidgetRoute.ACTION_TOGGLE, (_data: rpc.MessageSequence) => {
      this.runWidgetAction(WidgetRoute.ACTION_TOGGLE);
      return new WidgetCallResult();
    });
    this.callee.on(WidgetRoute.ACTION_PREV, (_data: rpc.MessageSequence) => {
      this.runWidgetAction(WidgetRoute.ACTION_PREV);
      return new WidgetCallResult();
    });
    this.callee.on(WidgetRoute.ACTION_NEXT, (_data: rpc.MessageSequence) => {
      this.runWidgetAction(WidgetRoute.ACTION_NEXT);
      return new WidgetCallResult();
    });
  }

  /**
   * 把卡片那一下点击交给播放器。
   *
   * `boot` 是幂等的:界面已经在跑时它什么都不做;冷启动时它只做本地读盘(不联网),
   * 联网相关装配由 `startGated` 自己按"是否已同意隐私"决定 —— 所以这里不需要再判权限,
   * 只需要在未同意时放弃动作(那时本来也没有可播的内容)。
   */
  private runWidgetAction(action: string): void {
    const box = AppContainer.get();
    box.boot(this.context);
    if (!box.settings.privacyAccepted) {
      Log.w('Widget', `卡片动作 ${action} 忽略:还没同意隐私政策`);
      return;
    }
    const waitSession = box.playbackState.snapshot.current !== null;
    this.actWhenReady(action, waitSession, 0);
  }

  /**
   * 等播放器把上次那一集装载出来再动手。
   *
   * 为什么要等:冷启动的恢复是**只预载不出声**,而 `current` 要等直链解析完才落下来
   * (见 `PlayerController.commitAndPlay`)。这段窗口里按 toggle 会把"想播"的意图写在
   * `startEpisode` 之前,随后被它按 autoplay=false 覆盖掉 —— 表现就是"点了播放没反应"。
   * 有会话态就等它(最多 10 秒,覆盖网络取流);没有会话态(卡片显示的是历史里的
   * 「继续收听」)则直接把那一集交给 `play(e)`,不能让它变成一下点空的按钮。
   */
  private actWhenReady(action: string, waitSession: boolean, attempt: number): void {
    const player = AppContainer.get().player;
    if (player.current === null && waitSession && attempt < 20) {
      setTimeout(() => this.actWhenReady(action, waitSession, attempt + 1), 500);
      return;
    }
    if (player.current === null) {
      const e = WidgetFormData.continueEpisode();
      if (e === null) {
        Log.w('Widget', `卡片动作 ${action} 放弃:没有可播的那一集`);
        return;
      }
      player.play(e);
      Log.i('Widget', `卡片动作 ${action} → 从历史起播 id=${e.id}`);
      return;
    }
    if (action === WidgetRoute.ACTION_TOGGLE) player.togglePlayPause();
    else if (action === WidgetRoute.ACTION_PREV) player.previous();
    else if (action === WidgetRoute.ACTION_NEXT) player.next();
    // 只记"已经交给播放器":toggle 之后 isPlaying 还没翻(`isPlaying` 是异步状态回调写的),
    // 在这行打印它会恒定落后一拍,读日志的人会以为开关没生效。
    Log.i('Widget', `卡片动作 ${action} → 已交给播放器`);
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

  /**
   * **这里刻意不调 `PlayerController.release()`,也不 destroy `AvSessionBridge`。**
   *
   * 看着像漏了(播放器实例、`timeUpdate` 监听、tick/fade/sleep 三张定时器都留着),
   * 但放进去比留着危险,两条理由:
   *
   * 1. **`release()` 是单向门**(`playback/PlayerController.ets:1356` 把 `released` 置真,
   *    全仓没有一处复位),而 `startEpisode` 第 316 行就 `if (this.released) return`。
   *    PlayerController 与 AvSessionBridge 都是**进程级单例**(`AppContainer.get()`),
   *    而 ability 销毁 ≠ 进程死亡:系统回收 ability 却留着进程、或用户划掉卡片后又热启动,
   *    复用的都是同一个已经 `released` 的对象 ⇒ **整个 App 再也播不出声音**,
   *    比"泄漏一个播放器"严重一个量级。
   * 2. **销毁 ability 时还在放音,恰恰是长时任务要的**。后台连续任务让进程活着、
   *    让音频继续跑;此时 release 等于"从任务中心划掉卡片就把正在听的这一集掐了"。
   *
   * 所以收敛靠进程死亡(系统会把 AVPlayer、监听、定时器一并回收),这是有意的边界。
   * 真要补一条显式释放路径,前提是**先给 `released` 一个复位入口**(并让重建播放器
   * 那段能重新起表),而且必须装机验「后台播放中划掉卡片」与「热启动后再播」两格 ——
   * 本机验不了,别顺手加。
   */
  onDestroy(): void {
    JsonFile.flushPending();
    SettingsStore.onLanguageChanged = null;
    this.stage = null;
    Log.i('App', '退出');
  }
}
