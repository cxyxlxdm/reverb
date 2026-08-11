import { Episode } from '../model/Models';
import { PodcastRepository } from '../net/PodcastRepository';
import { PlayerController } from './PlayerController';
import { Log } from '../util/Logger';

/// 电台模式。情境模式按当前时段挑贴合心境的分类。
export enum RadioMode {
  RANDOM = 0,
  CONTEXTUAL = 1
}

/**
 * 随机 / 情境电台:只负责「下一首从哪来」与最近去重;
 * 「是否在台、自动续播」由 PlayerController 统一持有(与 Android 的职责划分一致,
 * macOS 把这段内联进了 UI 且丢了最近去重,此处采用 Android 的模块化做法)。
 */
@Observed
export class RadioStation {
  private static inst: RadioStation | null = null;
  static get(): RadioStation {
    if (RadioStation.inst === null) RadioStation.inst = new RadioStation();
    return RadioStation.inst;
  }

  /// 当前在台模式;null 表示未开台。
  mode: RadioMode | null = null;
  /// 正在抓取中的模式(UI 转圈用)。
  preparing: RadioMode | null = null;

  private repo: PodcastRepository | null = null;
  private player: PlayerController | null = null;
  private region = 'us';
  /// 最近 40 首去重(避免刚听过的又被抓到)
  private recent: string[] = [];
  private readonly recentCap = 40;
  /// 随机模式的候选分类(null=综合榜,用 0 表示)
  private readonly randomGenreIds: number[] = [0, 1489, 1321, 1318, 1324, 1533, 1303, 1512, 1310];

  configure(repo: PodcastRepository, player: PlayerController, region: string): void {
    this.repo = repo;
    this.player = player;
    this.region = region;
  }

  /// 开台并立刻起播一首。返回是否成功。
  async start(mode: RadioMode): Promise<boolean> {
    const p = this.player;
    if (p === null) return false;
    this.mode = mode;
    Log.i('Radio', `开台 mode=${mode === RadioMode.CONTEXTUAL ? '情境' : '随机'}`);
    p.startRadio(() => this.fetchNext());
    const first = await this.fetchNext();
    if (first === null) {
      Log.w('Radio', '首次抓取失败,停台');
      this.stop();
      return false;
    }
    p.playRadioEpisode(first);
    return true;
  }

  /// 换下一首(等价于 next)。
  skip(): void {
    const p = this.player;
    if (p !== null && p.radioMode) p.next();
  }

  stop(): void {
    this.mode = null;
    this.preparing = null;
    const p = this.player;
    if (p !== null) p.stopRadio();
  }

  /// 抓一首没在最近列表里的随机单集(并记入最近列表)。
  private async fetchNext(): Promise<Episode | null> {
    const r = this.repo;
    if (r === null) return null;
    this.preparing = this.mode;
    try {
      const e = await r.randomEpisode(this.region, this.effectiveGenreIds(), this.recent);
      if (e !== null) this.remember(e.id);
      return e;
    } catch (err) {
      Log.e('Radio', `抓取失败 ${(err as Error).message}`);
      return null;
    } finally {
      this.preparing = null;
    }
  }

  private effectiveGenreIds(): number[] {
    return this.mode === RadioMode.CONTEXTUAL ? RadioStation.contextualGenreIds() : this.randomGenreIds;
  }

  /// 情境电台:按当前时段挑选贴合心境的分类(Apple genreId;与 Android 逐值一致)。
  static contextualGenreIds(): number[] {
    const hour = new Date().getHours();
    if (hour >= 5 && hour <= 8) return [1489, 1321, 1533];          // 清晨:新闻·商业·知识
    if (hour >= 9 && hour <= 11) return [1489, 1318, 1321];         // 上午:新闻·科技·商业
    if (hour >= 12 && hour <= 13) return [1303, 1324, 1306];        // 午间:喜剧·文化·美食
    if (hour >= 14 && hour <= 17) return [1318, 1533, 1324];        // 下午:科技·知识·文化
    if (hour >= 18 && hour <= 21) return [1303, 1310, 1517, 1324];  // 晚间:喜剧·音乐·情感·文化
    return [1512, 1310, 1324];                                      // 深夜:健康(助眠)·音乐·文化
  }

  /// 情境模式的时段图标(与 Android 的日出/白日/日落/月亮对应)。
  static contextualPhase(): string {
    const hour = new Date().getHours();
    if (hour >= 5 && hour <= 8) return '清晨';
    if (hour >= 9 && hour <= 17) return '白日';
    if (hour >= 18 && hour <= 21) return '日落';
    return '深夜';
  }

  private remember(id: string): void {
    this.recent.push(id);
    if (this.recent.length > this.recentCap) this.recent.shift();
  }
}
