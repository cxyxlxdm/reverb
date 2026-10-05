import { Episode } from '../model/Models';
import { Codec } from './Codec';
import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 一条批注:**某一集的某一秒 + 自己写的一句话**。
 *
 * 与 Android `data/local/NoteStore.kt` 同一形状、同一份 `notes.json` 格式(三端可互换备份)。
 *
 * 为什么存**整条 Episode 快照**而不是 `episodeId` 引用(印记 stamps.json 那种):
 * 引用式存储的前提是「被引用的对象还在原处可查」,这里不成立 —— 发布方随时从 RSS 删旧集,
 * 而本项目**零后端、无云同步**。那一集一旦不在任何订阅的 feed 里,批注就成一个指不到地方的
 * 时间戳:列表还能读出这句话,点回去什么都播不了,且用户没有自救入口。
 * 收藏与历史早就面对同一个问题,两者的答案都是存整条 Episode(`Codec.episodeToJson`),
 * 批注照这个口径走 —— 空间代价约每条 1 KB,换「三年后点开仍能跳回那一秒」。
 */
export interface EpisodeNote {
  /// 批注自己的 id。**在 JSON 里必须叫 `noteId`**,不能叫 `id` —— 见 persist 的注释(见 H127)。
  noteId: string;
  episode: Episode;
  /** 那一秒,毫秒。字段名带单位是刻意的:H86 那次的根因是 macOS 写秒、Android 写毫秒,
   *  而备份里没有单位信息可辨;新格式不再留这个口子,三端一律毫秒。 */
  positionMs: number;
  text: string;
  createdAt: number;
}

/**
 * 听觉批注:一集可以有很多条,新写的置顶,JSON 持久化(`notes.json`,纯数组,与 stamps.json 同构)。
 *
 * `@Observed` + 「复制后整体赋值」:ArkUI V1 的观察粒度是对象,字段重新赋值才触发重渲(见 H27)。
 * 批注列表在音阁第 6 段读它,所以调用方必须以 `@ObjectLink` 接收,不能裸读 `this.app.notes`。
 */
@Observed
export class NoteStore {
  notes: EpisodeNote[] = [];
  private static FILE = 'notes.json';

  load(): void {
    const arr = JsonFile.readArray(NoteStore.FILE);
    const out: EpisodeNote[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const ep = Codec.episodeFromJson(J.obj(o, 'episode'));
      // 缺 episode 体或没有可播的音频地址就跳过,而不是造一条「点不动」的批注 ——
      // 列表里躺一条永远播不了的记录,比少一条更让人怀疑是 bug。
      if (ep.audioUrl.length === 0) continue;
      out.push({
        noteId: J.str(o, 'noteId'),
        episode: ep,
        positionMs: J.num(o, 'positionMs'),
        text: J.str(o, 'text'),
        createdAt: J.num(o, 'createdAt')
      });
    }
    this.notes = NoteStore.normalize(out);
    Log.i('Store', `批注加载 ${out.length} 条`);
  }

  /**
   * 从盘上或备份里读来的批注过一次**归一**:按落笔时刻倒序,并把 `positionMs` 的负值归 0。
   *
   * 为什么补在「读盘 + 恢复」这一道:时间线和「点一句跳到那一秒」直接吃这个列表,而
   * `notes.json` 是**三端共用**的文件 —— 本端的写入点管不住它的前任(另一端写的顺序、
   * 手工编辑过的内容、系统级云备份还原那种**整份文件覆盖回来**的路径,压根不经过 `addAll`)。
   * 硬规矩 10 说的「不变式在数据出口一次性保证」,对读盘而言那个出口就是这份文件的**入口**。
   * 判负用三目而不是 `Math.max(0, x)`:`NaN > 0` 为假,于是这一句顺带把非数也归 0
   * (`J.num` 本身已把非数归 0,这里是把"不产生 NaN"写成代码而不是依赖调用方)。
   * `Array.prototype.sort` 是稳定排序(ES2019 起规范保证),同一毫秒写下的两条保持原有先后。
   *
   * **刻意不套用 `add` 那条「上限夹到该集时长」**:`add` 里那个夹成立,是因为按下「写批注」的
   * 那一刻手上有播放器实时位置作真值参照;而读盘时唯一可比的是 **RSS 元数据时长** ——
   * 它是发布方自报的近似值,常常比真实音频短。拿一个近似上限去改写用户早就写下的那一秒,
   * 比留着那个越界值更糟(界面上的时间戳自己跳了位,而用户无从知道是谁改的)。
   * 越界值走到播放那一步,由播放器按真实时长夹。与 Android / macOS 同一口径,三端逐字对齐。
   */
  private static normalize(list: EpisodeNote[]): EpisodeNote[] {
    const out: EpisodeNote[] = [];
    for (let i = 0; i < list.length; i++) {
      const n = list[i];
      if (n.positionMs > 0) {
        out.push(n);
      } else {
        const fixed: EpisodeNote = {
          noteId: n.noteId, episode: n.episode, positionMs: 0, text: n.text, createdAt: n.createdAt
        };
        out.push(fixed);
      }
    }
    out.sort((a: EpisodeNote, b: EpisodeNote) => b.createdAt - a.createdAt);
    return out;
  }

  /**
   * 落一条批注,返回它的 noteId;文字为空时返回空串并**不落盘**。
   *
   * 空批注不弹「请输入内容」:`NoteStore` 视作"这条不要",界面上关掉弹层即可 ——
   * 用户点了保存却什么也没写,最自然的意图就是取消;而列表里出现一条空白批注,
   * 以后无从分辨它是不是误触(并且删除确认框会显示成空)。
   *
   * `positionMs` 在**这里**夹到 `[0, 该集时长]`(硬规矩 10:不变式在数据出口一次性保证):
   * 界面上的时间戳要能代表「那一秒真的在那一集里」,而取值来自播放器的当前位置 ——
   * 拖动进度条与装载之间有窗口,那一刻它可能是上一集的时长或一个超出本集的值。
   */
  add(episode: Episode, positionMs: number, text: string, now: number): string {
    const body = text.trim();
    if (body.length === 0) return '';
    const cap = episode.durationSec > 0 ? episode.durationSec * 1000 : Number.MAX_SAFE_INTEGER;
    // 形态与 ListenStatsStore 的安装随机标识一致(时间戳 + 随机段)。它只是本地去重用的
    // 不透明串,不跨端比对,所以不必引 UUID 库。
    const noteId = `${now}-${Math.floor(Math.random() * 1e9)}`;
    const note: EpisodeNote = {
      noteId: noteId,
      episode: episode,
      positionMs: Math.max(0, Math.min(positionMs, cap)),
      text: body,
      createdAt: now
    };
    this.notes = [note].concat(this.notes);
    Log.i('Store', `加批注 id=${noteId} pos=${note.positionMs}ms len=${body.length} total=${this.notes.length}`);
    this.persist();
    return noteId;
  }

  remove(noteId: string): void {
    this.notes = this.notes.filter((x: EpisodeNote) => x.noteId !== noteId);
    Log.i('Store', `删批注 id=${noteId} total=${this.notes.length}`);
    this.persist();
  }

  /**
   * 备份恢复:按 noteId 去重(重复恢复同一份备份不会写出两份),再走同一条 `normalize`
   * —— 与 `load()` 一个口径,这样"从备份恢复出来的列表"和"下次冷启动从盘上读到的列表"是同一份内容。
   */
  addAll(items: EpisodeNote[]): void {
    const next = this.notes.slice();
    for (let i = 0; i < items.length; i++) {
      if (!next.some((x: EpisodeNote) => x.noteId === items[i].noteId)) next.push(items[i]);
    }
    this.notes = NoteStore.normalize(next);
    this.persist();
  }

  /**
   * 单条 = `{noteId, positionMs, text, createdAt, episode:{…}}`,episode 用 `Codec.episodeToJson`
   * 整条嵌进去(与 history.json 同构)。
   *
   * ⚠️ 批注自己的 id **必须叫 `noteId`**:episode 体里已经有一个 `id`(= `Episode.id`,guid),
   * 若把两者摊平在同一个对象里,后写的键会静默盖掉前一个 —— 表现是"跳回那一秒"点了没反应
   * (下载状态、历史进度全按 `Episode.id` 查,而它变成了那个随机串),且读回来看不出来。
   * 这条对三端都成立,Android 侧的同名约束与事故记录见 TROUBLESHOOTING H127。
   */
  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.notes.length; i++) {
      const n = this.notes[i];
      arr.push({
        'noteId': n.noteId,
        'positionMs': n.positionMs,
        'text': n.text,
        'createdAt': n.createdAt,
        'episode': Codec.episodeToJson(n.episode)
      } as Record<string, Object>);
    }
    // **同步写**:一次批注是用户的一次手工操作、数据量小(几百字节),
    // 而去抖异步写意味着"进程被杀就丢刚写的那条"。与 stamps/favorites 同口径(见 JsonFile 注释)。
    JsonFile.writeJson(NoteStore.FILE, arr);
  }
}
