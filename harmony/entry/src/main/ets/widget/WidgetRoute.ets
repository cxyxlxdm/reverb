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
}
