/**
 * 直播电台(用户自己整理的一份快捷方式)。
 *
 * 与 Android `data/model/Station.kt` / macOS `Station` **字段逐一对齐**,备份里的键名同为
 * `stations`,七项:`id` / `name` / `url` / `logo` / `group` / `country` / `source`。
 *
 * 为什么单独一个模型、不塞进 `Podcast` 或 `Episode`:电台没有分集、没有 RSS、没有时长,
 * 它只在播放时被**现场合成**成一条 `isLive=true` 的 `Episode`(见 `RadioPage.play`)。
 * 塞进 `Podcast` 会让订阅列表里多出一种"点进去空白"的条目。
 */
export interface Station {
  /** `local:<uuid>` / `rb:<stationuuid>` / `seed:<url>` —— 与另三端同一条命名口径 */
  id: string;
  name: string;
  /** 直播流地址。**去重键就是它**(trim 后逐字比较,不做路径归一化) */
  url: string;
  /** 台标地址,可空 */
  logo: string;
  /** 分组:`news` / `music` / `talk` / `retro`,空串 = 未分组。显示名由界面按语种取 */
  group: string;
  /** ISO 国家码(目录来源给的),可空 */
  country: string;
  /** `manual`(用户加的) / `directory`(从在线目录收的) / `seed`(随包精选) */
  source: string;
}

export class StationMeta {
  static readonly SOURCE_MANUAL: string = 'manual';
  static readonly SOURCE_DIRECTORY: string = 'directory';
  static readonly SOURCE_SEED: string = 'seed';

  /** 支持的分组键。顺序即界面上的排列顺序。 */
  static readonly GROUPS: string[] = ['news', 'music', 'talk', 'retro'];

  /**
   * 分组键归一。认不出的键一律落空串(未分组),**不把未知值原样写回** ——
   * 备份跨端之后两端都只认这四个键,留一个 `"News "` 会在界面上变成一片没有名字的空格。
   */
  static normalizeGroup(raw: string): string {
    const g = raw.trim().toLowerCase();
    return StationMeta.GROUPS.indexOf(g) >= 0 ? g : '';
  }
}
