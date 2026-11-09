import { Episode } from '../model/Models';
import { JsonFile } from '../store/JsonFile';
import { J } from '../net/Http';
import { Codec } from '../store/Codec';
import { PlaybackStateStore } from '../store/PlaybackStateStore';
import { L } from '../util/L';

/**
 * 卡片与提供方之间的字段名契约。
 *
 * 卡片侧用 `@LocalStorageProp(相同字符串)` 接,**两边必须逐字一致** —— 这类名字写错不会报错,
 * 症状是"卡片一片空、但数据其实送出去了"。
 */
export class ConfigKeys {
  static readonly LABEL = 'label';
  static readonly TITLE = 'title';
  static readonly PODCAST = 'podcast';
  static readonly TIME = 'time';
  static readonly PERCENT = 'percent';
  static readonly HAS_PROGRESS = 'hasProgress';
  static readonly EMPTY = 'empty';
  static readonly DIM = 'dim';
  static readonly DARK = 'dark';
  /** 封面:值是 formImages 里的键(`art`);没有本地封面时是空串,卡片退回应用图标。 */
  static readonly ART = 'art';
  static readonly ART_KEY = 'art';
}

/**
 * 服务卡片要画的那一集。与 Android `widget/WidgetState.kt` 的 `WidgetEpisode` 同口径:
 * **只读「App 已经在写的两份文件」**,不初始化播放器、不联网。
 *
 * 为什么不在卡片里复用 PlayerController:卡片的 FormExtensionAbility 跑在**独立进程**,
 * 拿不到 UI 侧的 AppContainer 单例(同 `update/FeedUpdateExtension` 的取舍);
 * 而它需要的只有「上次听到哪一集、听到第几秒」这两样,两份 JSON 就够了。
 */
export class WidgetSnapshot {
  id: string = '';
  title: string = '';
  podcast: string = '';
  artUrl: string = '';
  positionMs: number = 0;
  durationMs: number = 0;
  live: boolean = false;

  hasProgress(): boolean {
    return !this.live && this.durationMs > 0;
  }

  /// 0..100,与进度条直接对齐(Android 那边用 0..1000 给 ProgressBar,这里没有必要)。
  percent(): number {
    if (this.durationMs <= 0) return 0;
    const p = Math.round(this.positionMs * 100 / this.durationMs);
    return Math.max(0, Math.min(100, p));
  }
}

/// 卡片一屏要用的全部字段;`dark` 与 `dim` 是排版本体的输入,不是内容。
export class WidgetFormFields {
  label: string = '';
  title: string = '';
  podcast: string = '';
  time: string = '';
  percent: number = 0;
  hasProgress: boolean = false;
  empty: boolean = true;
  dim: string = '2*2';
  dark: boolean = false;
  artUrl: string = '';
}

export class WidgetFormData {
  /**
   * 读一份快照。优先级与 Android 一致:
   *  ① `playback_state.json` 的 `current` —— 跨启动恢复用的同一份口径;
   *  ② 退回历史里「10s..95% 且未播完」的第一条,与发现页「继续收听」横条一个门槛。
   * 两份都是只读;未同意隐私时它们本来就没内容,于是卡片显示空态,不产生任何外部请求。
   */
  static read(): WidgetSnapshot | null {
    const snap = PlaybackStateStore.readFromDisk();
    const history = WidgetFormData.readHistory();
    const cur: Episode | null = snap.current;
    if (cur !== null) return WidgetFormData.fromEpisode(cur, history);
    for (let i = 0; i < history.length; i++) {
      const h = history[i];
      if (h.played || h.durationMs <= 0) continue;
      if (h.positionMs < 10000 || h.positionMs > h.durationMs * 0.95) continue;
      return WidgetFormData.pick(h.episode, h.positionMs, h.durationMs);
    }
    return null;
  }

  /// 历史里这一集的进度(播放中每约 5 秒落一次);没有就按 0 处理。
  private static fromEpisode(ep: Episode, history: HistoryRow[]): WidgetSnapshot {
    let position = 0;
    let duration = ep.durationSec > 0 ? ep.durationSec * 1000 : 0;
    for (let i = 0; i < history.length; i++) {
      if (history[i].episode.id !== ep.id) continue;
      position = history[i].positionMs;
      if (history[i].durationMs > 0) duration = history[i].durationMs;
      break;
    }
    return WidgetFormData.pick(ep, position, duration);
  }

  private static pick(ep: Episode, positionMs: number, durationMs: number): WidgetSnapshot {
    const s = new WidgetSnapshot();
    s.id = ep.id;
    s.title = ep.title;
    s.podcast = ep.podcastTitle;
    s.artUrl = ep.artworkUrl;
    s.positionMs = Math.max(0, positionMs);
    s.durationMs = Math.max(0, durationMs);
    s.live = ep.isLive === true;
    return s;
  }

  private static readHistory(): HistoryRow[] {
    const arr = JsonFile.readArray('history.json');
    const out: HistoryRow[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const h = Codec.historyFromJson(o);
      if (h.episode.id.length === 0 || h.episode.audioUrl.length === 0) continue;
      const row = new HistoryRow();
      row.episode = h.episode;
      row.positionMs = h.positionMs;
      row.durationMs = h.durationMs;
      row.played = h.played;
      out.push(row);
    }
    return out;
  }

  /// 卡片要显示的全部字段(本地化在这里做完,卡片本体只认字符串)。
  static fields(snap: WidgetSnapshot | null, dim: string, dark: boolean): WidgetFormFields {
    const f = new WidgetFormFields();
    f.dim = dim;
    f.dark = dark;
    f.label = L.s('widget_continue');
    if (snap === null) {
      f.empty = true;
      f.title = L.s('widget_empty_title');
      f.podcast = L.s('widget_empty_sub');
      return f;
    }
    f.empty = false;
    f.title = snap.title;
    f.podcast = snap.podcast.length > 0 ? snap.podcast : L.s('unknown_channel');
    f.hasProgress = snap.hasProgress();
    f.percent = snap.percent();
    f.artUrl = snap.artUrl;
    f.time = snap.live ? L.s('widget_live')
      : (f.hasProgress ? `${WidgetFormData.clock(snap.positionMs)} / ${WidgetFormData.clock(snap.durationMs)}` : '');
    return f;
  }

  static clock(ms: number): string {
    const total = Math.floor(Math.max(0, ms) / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }
}

class HistoryRow {
  episode: Episode = {
    id: '', title: '', description: '', audioUrl: '', artworkUrl: '', podcastTitle: '',
    durationSec: 0, pubDate: '', feedUrl: '', transcriptUrl: '', transcriptType: ''
  };
  positionMs: number = 0;
  durationMs: number = 0;
  played: boolean = false;
}

/**
 * 三档卡片各是一个 form 条目(`form_config.json`),表单名与尺寸的对应关系只写在这里。
 *
 * 为什么不是一个条目支持三档:更新接口 `onUpdateForm(formId)` **不给尺寸**,
 * 而 `RunningFormInfo` 里唯一能反查身份的就是 `formName`;条目分开之后
 * 「这一次该按哪一档画」是确定信息,不必依赖一张 formId→尺寸的映射表。
 */
export class WidgetFormNames {
  static readonly SMALL = 'reverb_small';
  static readonly MEDIUM = 'reverb_medium';
  static readonly LARGE = 'reverb_large';

  static dimOf(formName: string): string {
    if (formName === WidgetFormNames.LARGE) return '4*4';
    if (formName === WidgetFormNames.MEDIUM) return '2*4';
    return '2*2';
  }

  /// 把 `RunningFormInfo.dimension`(formInfo.FormDimension 的数值)转成卡片认的 'a*b'。
  /// 比 formName 更准:用户在桌面上把 2×2 拉大之后,只有这一格会跟着变。
  static dimOfDimension(dimension: number): string {
    if (dimension === 4) return '4*4';
    if (dimension === 3) return '2*4';
    return '2*2';
  }
}
