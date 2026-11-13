import { JsonFile } from '../store/JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 桌面卡片要知道的「此刻是不是在播」这一位。
 *
 * **为什么不塞进 `playback_state.json`**:那份是与 Android 共用格式的文件(`VERSION 1`),
 * 加一个另两端不认识的字段等于让共享格式悄悄分叉;而这一位只有鸿蒙卡片的
 * 播放/暂停图标与按钮要用,单开一份极小的 `widget_state.json` 最省事。
 *
 * 谁写:UI 进程的 `PlayerController.refreshWidget`。它本来就每次真实状态变化被叫一次,
 * 播放中还会被 ticker 每 5 秒叫一次 —— 所以这里按「值没变就不写」去重,
 * 稳态下这张文件一个播放周期只写两次(起播 / 暂停)。
 * 谁读:`WidgetFormBuilder`(UI 进程与 FormExtension 两个进程都读它)。
 *
 * 只有一位、没有 VERSION:读失败就是 `false`(卡片画成暂停态),不存在"旧口径数据需要迁移"。
 *
 * ⚠️ 这一位没有「进程死掉」的兜底:进程被系统杀掉时没人去写 false,卡片会停在暂停键上,
 * 直到 App 下次启动。冷启动 `restoreFromState` 走 `notify` → `refreshWidget`,在那里
 * 用「恢复而不自动播」的意图(false)把这份文件纠回来 —— 2026-11-12 实测:强杀后重开,
 * 卡片在同一次启动里从暂停键翻回 ▶。
 */
export class WidgetRuntime {
  private static readonly FILE: string = 'widget_state.json';
  /// 本进程上一次写下去的值。跨进程不需要它:每个写者都是 UI 进程。
  private static last: boolean | null = null;

  static readPlaying(): boolean {
    const o = JsonFile.readObject(WidgetRuntime.FILE);
    return J.bool(o, 'playing');
  }

  static writePlaying(playing: boolean): void {
    if (WidgetRuntime.last === playing) return;
    WidgetRuntime.last = playing;
    const obj: Record<string, Object> = {};
    obj['playing'] = playing;
    JsonFile.writeJson(WidgetRuntime.FILE, obj);
    Log.i('Widget', `卡片播放态 → ${playing ? '播放中' : '暂停'}`);
  }
}
