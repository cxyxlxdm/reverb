/**
 * 卡片点击的路由契约。
 *
 * 单独一个文件而不是放进 `WidgetFormData`:卡片(`WidgetCard`)也要引这几个常量,
 * 而 `WidgetFormData` 连带 `PlaybackStateStore` / `Http` / `Codec` 一大串 —— 卡片进程
 * 只该拿到"点一下要跳哪"这一条信息,不该把整条数据链一起拖进卡片包。
 */
export class WidgetRoute {
  /// Want.parameters 里的键
  static readonly PARAM_KEY: string = 'reverbWidget';
  /// 卡片要求打开播放页时该参数的值
  static readonly PLAYER: string = 'player';
  /// AppStorage 键:每次点击 +1。用计数而不是布尔,是为了"连点两次也要各触发一次"。
  static readonly OPEN_PLAYER: string = 'widgetOpenPlayer';

  /**
   * 卡片上三颗播放键走 `postCardAction` 的 **`call`** 动作(后台拉起 EntryAbility、不弹界面),
   * 不跟"点卡片进播放页"的 `router` 混在一起:前者只动播放态,后者才换界面。
   *
   * 值同时是 `params.method` 与 `EntryAbility` 里 `callee.on(方法名, …)` 注册的键 ——
   * 两边必须逐字一致,写错不报错,症状是"点了没反应"。
   */
  static readonly ACTION_TOGGLE: string = 'widgetToggle';
  static readonly ACTION_PREV: string = 'widgetPrev';
  static readonly ACTION_NEXT: string = 'widgetNext';
  /// `postCardAction({action:'call'})` 里"调哪个方法"的键
  static readonly METHOD_KEY: string = 'method';
}
