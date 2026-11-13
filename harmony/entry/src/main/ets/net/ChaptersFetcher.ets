import { Http } from './Http';
import { Chapter } from '../model/Models';
import { Log } from '../util/Logger';

/**
 * 取发布方的**章节表**(RSS `podcast:chapters` → 一个 JSON),解析成 [Chapter] 列表。
 * 对应 Android `data/remote/ChaptersFetcher.kt`,解析口径逐条对齐。
 *
 * 章表是发布方自己维护的,本机只做两件事:读 JSON、按时间跳。**不推断、不切分、
 * 不拿逐字稿去猜** —— 猜出来的章节会在用户跳过去之后"讲的是别的事",比没有更糟。
 *
 * 格式按 Podcasting 2.0 chapters 规范:
 * ```json
 * { "version": "1.2.0",
 *   "chapters": [ { "startTime": 0, "title": "开场", "img": "https://…", "url": "https://…" } ] }
 * ```
 * 实际见到的两种变体都要认:
 * - `startTime` 是**秒**,可能带小数;老一点的 Podlove 写法用 `start: "00:01:23.500"`;
 * - 顶层偶尔直接是数组(不带 `{"chapters": …}` 包装)。
 *
 * **失败与空是两回事**:返回 `null` = 取不到/解析不了(界面给"重试"),空数组 = 这集确实没有章节
 * (界面说"没有章节")。两者混成一个空数组,用户就只能对着一个永远重试不好的按钮点。
 */
export class ChaptersFetcher {

  /**
   * 正文上限。Android 判的是响应声明字节数(1 MiB),本端 `Http.text` 只回正文,
   * 拿不到 Content-Length —— 这里按**字符数**兜一道同量级的闸,最坏约 3 MiB(中文 UTF-8)。
   * 章表就是几十条标题,超过这个量级的一定不是章表(多半是标错 type 的音频)。
   */
  private static readonly MAX_CHARS: number = 1024 * 1024;
  private static readonly TAG: string = 'Chapters';

  /**
   * @param authHeader 私有源的 `Authorization` 头;null = 公开源。判断该不该带(主机匹配)
   *   在调用方 —— 这里只负责发出去,与逐字稿/播放同一口径。
   */
  static async fetch(url: string, authHeader: string | null = null): Promise<Chapter[] | null> {
    if (url.length === 0) return null;
    const body = await Http.text(url, undefined,
      authHeader === null ? undefined : { 'Authorization': authHeader });
    if (body === null) {
      Log.w(ChaptersFetcher.TAG, `下载失败 host=${Http.host(url)}`);
      return null;
    }
    if (body.length > ChaptersFetcher.MAX_CHARS) {
      Log.w(ChaptersFetcher.TAG, `章表过大(${body.length} 字符),跳过 host=${Http.host(url)}`);
      return null;
    }
    const list = ChaptersFetcher.parse(body);
    if (list === null) {
      Log.w(ChaptersFetcher.TAG, `章节解析失败 host=${Http.host(url)}`);
    } else {
      Log.i(ChaptersFetcher.TAG, `章节 ${list.length} 条 host=${Http.host(url)}`);
    }
    return list;
  }

  /**
   * 解析章表正文。`null` = 不是可识别的章表;空数组 = 是章表但没有可用章节。
   *
   * 排序、去重、夹零在这里做(**数据出口**):界面用"从后往前找第一个 `startMs <= now`"
   * 判断当前章,与逐字稿同一条不变式 —— 起点必须单调且 ≥0(硬规矩 10)。发布方给的顺序不能假定。
   */
  static parse(text: string): Chapter[] | null {
    let root: Object;
    try {
      root = JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
    let arr: Object[] | null = null;
    if (Array.isArray(root)) {
      arr = root as Object[];
    } else {
      const obj = root as Record<string, Object>;
      const v = obj['chapters'];
      // 是对象但没有 chapters 键:按"合法的空章表"处理(与 Android `optJSONArray ?: emptyList()` 一致)
      if (!Array.isArray(v)) return [];
      arr = v as Object[];
    }

    const out: Chapter[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = arr[i] as Record<string, Object>;
      if (o === null || o === undefined) continue;
      const rawStart = ChaptersFetcher.startMsOf(o);
      if (rawStart === null) continue;
      const title = ChaptersFetcher.strOf(o, 'title').trim();
      // 没有标题的章在列表里是一行空白,点了也不知道跳到哪 —— 直接不收
      if (title.length === 0) continue;
      out.push({
        startMs: rawStart < 0 ? 0 : rawStart,
        title: title,
        imageUrl: ChaptersFetcher.imageOf(o),
        url: ChaptersFetcher.strOf(o, 'url').trim()
      } as Chapter);
    }

    out.sort((a: Chapter, b: Chapter) => a.startMs - b.startMs);
    // 同一毫秒只能有一章,否则"当前章"有两个答案。排序后相邻比较即可。
    const dedup: Chapter[] = [];
    for (let i = 0; i < out.length; i++) {
      const c = out[i];
      if (dedup.length > 0 && dedup[dedup.length - 1].startMs === c.startMs) continue;
      dedup.push(c);
    }
    return dedup;
  }

  /// `startTime`(秒,数字或数字串)优先;取不到再看 `start` 时间串。解析不出来返回 null。
  private static startMsOf(o: Record<string, Object>): number | null {
    const v = o['startTime'];
    if (v !== undefined && v !== null) {
      let sec = NaN;
      if (typeof v === 'number') sec = v as number;
      else if (typeof v === 'string') sec = Number.parseFloat(v as string);
      if (Number.isFinite(sec)) return Math.round(sec * 1000);
    }
    // 老写法 / Podlove 兼容:`start` 是时间串
    const start = ChaptersFetcher.strOf(o, 'start').trim();
    if (start.length > 0) return ChaptersFetcher.parseTimecode(start);
    return null;
  }

  /// 封面:规范写 `img`,也有源写 `image`。
  private static imageOf(o: Record<string, Object>): string {
    const direct = ChaptersFetcher.strOf(o, 'img').trim();
    if (direct.length > 0) return direct;
    return ChaptersFetcher.strOf(o, 'image').trim();
  }

  private static strOf(o: Record<string, Object>, key: string): string {
    const v = o[key];
    return typeof v === 'string' ? v as string : '';
  }

  /**
   * `HH:MM:SS(.mmm)` / `MM:SS(.mmm)` / 纯秒数 → 毫秒。解析不了返回 null。
   *
   * 小数部分单独处理:纯秒数 `83.5` 与 `01:23.5` 的进制不同,所以按冒号分段数分情况读。
   */
  private static parseTimecode(s: string): number | null {
    try {
      const parts = s.split(':');
      if (parts.length === 1) {
        const v = Number.parseFloat(parts[0]);
        if (!Number.isFinite(v)) return null;
        return Math.round(v * 1000);
      } else if (parts.length === 2) {
        const m = Number.parseInt(parts[0], 10);
        const sec = Number.parseFloat(parts[1]);
        if (!Number.isFinite(m) || !Number.isFinite(sec)) return null;
        return Math.round(m * 60 * 1000 + sec * 1000);
      } else if (parts.length === 3) {
        const h = Number.parseInt(parts[0], 10);
        const m = Number.parseInt(parts[1], 10);
        const sec = Number.parseFloat(parts[2]);
        if (!Number.isFinite(h) || !Number.isFinite(m) || !Number.isFinite(sec)) return null;
        return Math.round((h * 3600 + m * 60) * 1000 + sec * 1000);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
