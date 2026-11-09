import fs from '@ohos.file.fs';
import process from '@ohos.process';
import { Log } from '../util/Logger';

/// 应用私有目录下的 JSON 读写基座(对应 Android filesDir/*.json 与 macOS AppSupport)。
/// 一律"失败静默、不影响内存态"——持久化坏了也不能让 App 用不了。
/// ⚠️ 这里的"静默"只指**不抛给调用方**;写失败与读到的内容作废都会留日志,不无声吞掉。
export class JsonFile {
  private static dir: string = '';
  /// 临时文件后缀用的进程号,懒取一次(见 tmpPath 的注释)
  private static pidTag: string = '';

  static init(filesDir: string): void {
    JsonFile.dir = filesDir;
  }

  /** 应用私有目录。服务卡片的 UI 侧刷新(WidgetUpdater)要它来回算封面缓存路径。 */
  static root(): string {
    return JsonFile.dir;
  }

  private static path(name: string): string {
    return `${JsonFile.dir}/${name}`;
  }

  /**
   * 原子替换用的临时文件路径。
   *
   * **为什么带 pid 而不是就一个 `x.json.tmp`**:写这份文件的进程不止一个 —— UI 进程与
   * workScheduler 的 `FeedUpdateExtension`(见那里)同用 JsonFile 基座。两个进程若共用同一个
   * tmp 名,就是各自 `TRUNC` 同一个 inode、各写一半再各 rename,产物仍是半截 JSON ——
   * 这正好是本次要修的东西(见 REVIEW-2026-10-25 高-3)。按进程分名之后每条写链互不相干,
   * `rename` 本身原子,谁后写谁整份胜出(跨进程的"覆盖丢数据"是既有设计里就认下的账,见 H28)。
   *
   * 为什么用 pid 而不是随机数:随机名一旦"写完就死在 rename 前"就在目录里留一份不可复用的垃圾,
   * 而按 pid 定名时同一进程反复写同一文件复用同一个 tmp,最多留下"每进程每文件一份"残骸,有界。
   */
  private static tmpPath(target: string): string {
    if (JsonFile.pidTag.length === 0) {
      try {
        JsonFile.pidTag = `${process.pid}`;
      } catch (e) {
        // 取不到就退回"同名单 tmp"(仍然比原地 TRUNC 强),并让日志记住这件事发生过
        Log.w('JsonFile', `取进程号失败,临时文件按单名复用:${(e as Error).message}`);
        JsonFile.pidTag = '0';
      }
    }
    return `${target}.tmp.${JsonFile.pidTag}`;
  }

  /// rename 覆盖同名目标这条语义,见 replaceSync / replaceAsync 上的长注释。
  private static replaceSync(tmp: string, target: string, name: string): void {
    try {
      fs.renameSync(tmp, target);
      return;
    } catch (e) {
      // 见上面长注释:本端 SDK 的声明里 rename 同时列了 13900015 File exists,不能只赌覆盖成立。
      // 退路是先删目标再 rename,代价是重开一个"目标不存在"的窗口。
      Log.w('JsonFile', `原地 rename 覆盖失败 ${name}:${(e as Error).message},改用先删后 rename`);
      try {
        if (fs.accessSync(target)) fs.unlinkSync(target);
      } catch (e2) {
        // 目标本来就不存在或删不掉都交给下面那条 rename 去判
      }
      fs.renameSync(tmp, target);
    }
  }

  private static async replaceAsync(tmp: string, target: string, name: string): Promise<void> {
    try {
      await fs.rename(tmp, target);
      return;
    } catch (e) {
      Log.w('JsonFile', `原地 rename 覆盖失败 ${name}:${(e as Error).message},改用先删后 rename`);
      try {
        if (await fs.access(target)) await fs.unlink(target);
      } catch (e2) {
        // 同上
      }
      await fs.rename(tmp, target);
    }
  }

  private static unlinkQuiet(tmp: string): void {
    try {
      if (fs.accessSync(tmp)) fs.unlinkSync(tmp);
    } catch (e) {
      // 忽略:清不掉说明本来就没有
    }
  }

  /**
   * 读回来的内容解析失败时,把原文件改名留证据。
   *
   * 为什么必须改名而不是只记日志:调用方紧接着就把"空态"读进内存,而**任何一次写**
   * (订阅变动、播放中 5 秒一次的 history)都会把这份空态永久落盘 —— 在原先的非原子写下,
   * 唯一残本随 TRUNC 一起没了,用户没有任何自救入口,装机侧也查不到当时盘上到底是什么
   * (见 REVIEW-2026-10-25 高-3)。改名成 `<name>.corrupt-<时间戳>` 之后残本还在。
   *
   * 代价写清楚:filesDir 里会留下残本且不自动清理。一次损坏事件一份,量级可控;
   * 而"顺手删掉证据"正是这条要避免的事。备份/恢复读的是用户选中的文件,不受影响。
   */
  private static quarantine(name: string, why: string): void {
    const p = JsonFile.path(name);
    const keep = `${p}.corrupt-${Date.now()}`;
    try {
      if (!fs.accessSync(p)) return;
      fs.renameSync(p, keep);
      Log.e('JsonFile', `${name} ${why},已留证改名 → ${keep.split('/').pop()}`);
    } catch (e) {
      Log.e('JsonFile', `${name} ${why},但留证改名失败:${(e as Error).message}`);
    }
  }

  static readText(name: string): string | null {
    if (JsonFile.dir.length === 0) return null;
    const p = JsonFile.path(name);
    try {
      if (!fs.accessSync(p)) return null;
      return fs.readTextSync(p);
    } catch (e) {
      Log.w('JsonFile', `读取失败 ${name}:${(e as Error).message}`);
      return null;
    }
  }

  /**
   * 同步写。**原子版**:写临时文件 → fsync → close → rename 覆盖目标。
   *
   * 原先这里是 `open(target, TRUNC)` + `write` —— 打开即截断,进程死在写窗口内
   * (电池耗尽 / 系统回收 / 崩溃)就留下空文件或半截 JSON;半截 JSON 下一次读的时候解析失败,
   * 读侧当成空,于是一次正常写就把"空"永久落盘。订阅/收藏/批注是用户资产,不可再生
   * (见 REVIEW-2026-10-25 高-3)。
   *
   * 这个范式仓库里本来就有三份(DownloadManager / AudioCacheManager / ArtworkCache 的
   * `.part → rename`),这里只是把它铺到 JSON 底座上,12 个 JsonFile 系 store 一起受益。
   *
   * 为什么还要 `fsyncSync`:rename 只保证目录项原子替换,不保证数据已经离开页缓存;
   * 设备掉电时"目录里有新文件名、块里还是旧内容"同样是损坏。fsync 一次约几毫秒,
   * 而这条同步写本来就只给"小而关键"的数据用(订阅/收藏/设置/播放态),大份走异步版。
   * (完整做法还要 fsync 父目录,ArkTS 没有那个接口 —— 少这一道最坏是掉电后回退到旧版,
   * 而不是半截,可接受,记在这儿免得后人以为已经稳了。)
   */
  static writeText(name: string, text: string): void {
    if (JsonFile.dir.length === 0) return;
    const p = JsonFile.path(name);
    const tmp = JsonFile.tmpPath(p);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.fsyncSync(file.fd);
      fs.closeSync(file);
      file = null;
      JsonFile.replaceSync(tmp, p, name);
    } catch (e) {
      // 失败不静默:这条写丢了就是丢了,至少要能在日志里看见
      Log.e('JsonFile', `写入失败 ${name}:${(e as Error).message}`);
      JsonFile.unlinkQuiet(tmp);      // 别留一份半截 tmp 在目录里(它不会被任何人 rename 上去)
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /// 读出 JSON 数组;失败或非数组返回空数组(**并把原文件改名留证**,见 quarantine)。
  static readArray(name: string): Object[] {
    const s = JsonFile.readText(name);
    if (s === null || s.length === 0) return [];
    try {
      const o: Object = JSON.parse(s);
      if (Array.isArray(o)) return o as Object[];
      JsonFile.quarantine(name, '不是 JSON 数组');
      return [];
    } catch (e) {
      Log.w('JsonFile', `JSON 解析失败 ${name}:${(e as Error).message}`);
      JsonFile.quarantine(name, '解析失败');
      return [];
    }
  }

  /// 读出 JSON 对象;失败返回 null(同样留证,理由同 readArray)。
  static readObject(name: string): Record<string, Object> | null {
    const s = JsonFile.readText(name);
    if (s === null || s.length === 0) return null;
    try {
      const o: Object = JSON.parse(s);
      if (!Array.isArray(o)) return o as Record<string, Object>;
      JsonFile.quarantine(name, '不是 JSON 对象');
      return null;
    } catch (e) {
      Log.w('JsonFile', `JSON 解析失败 ${name}:${(e as Error).message}`);
      JsonFile.quarantine(name, '解析失败');
      return null;
    }
  }

  static writeJson(name: string, value: Object): void {
    try {
      JsonFile.writeText(name, JSON.stringify(value));
    } catch (e) {
      Log.w('JsonFile', `序列化失败 ${name}`);
    }
  }

  // ── 异步去抖写入 ──────────────────────────────────────────────────────────
  //
  // 为什么需要:`writeText` 用的是 `fs.writeSync`,**跑在 UI 线程上**。
  // 高频/大体积的持久化因此会直接卡界面:
  //   - 播放中每 5 秒 `history.updatePosition` → 整份 history.json 写回(可达几百 KB);
  //   - 每次解析 feed → 整份 feed_cache.json 写回(上限 ~1MB 量级);
  //   - 每个分类刷新 → 整份 popular_cache.json 写回。
  // 叠起来足以触发 THREAD_BLOCK_6S(外部反馈第 1 项)。
  //
  // 这里把这类写入改成「去抖 + 异步」:同一文件在 DEBOUNCE_MS 内的多次写入只落最后一次,
  // 且落盘走 fs 的 Promise 接口,不占 UI 线程。
  // **代价**:进程被杀时最多丢 DEBOUNCE_MS 内的一次写入,所以退到后台/退出前必须
  // 调 `flushPending()`(见 EntryAbility.onBackground)。

  private static readonly DEBOUNCE_MS = 400;
  /// name → 待写文本(只保留最新一份)
  private static pendingText: Map<string, string> = new Map();
  /// name → 待序列化的**取值函数**(见 writeJsonDebouncedLazy)
  private static pendingBuild: Map<string, () => Object> = new Map();
  /// name → 去抖定时器
  private static pendingTimer: Map<string, number> = new Map();

  /// 去抖异步写。适用于高频或大体积的持久化;小而关键的数据(订阅/收藏/设置)仍用同步版。
  static writeJsonDebounced(name: string, value: Object): void {
    let text: string;
    try {
      text = JSON.stringify(value);
    } catch (e) {
      Log.w('JsonFile', `序列化失败 ${name}`);
      return;
    }
    JsonFile.pendingText.set(name, text);
    JsonFile.pendingBuild.delete(name);      // 后来的明确值胜过先前登记的取值函数
    const old = JsonFile.pendingTimer.get(name);
    if (old !== undefined) clearTimeout(old);
    JsonFile.pendingTimer.set(name, setTimeout(() => {
      JsonFile.pendingTimer.delete(name);
      const t = JsonFile.takePending(name);
      if (t !== null) JsonFile.writeTextAsync(name, t);
    }, JsonFile.DEBOUNCE_MS));
  }

  /**
   * 去抖异步写的**惰性版**:传"怎么取值",不传值。
   *
   * 为什么需要:`writeJsonDebounced` 去抖掉的只是**写盘**,`JSON.stringify` 仍在每次调用时
   * 当场跑掉 —— 而调用方通常还要先把内存结构逐条转成 JSON 对象。频道缓存正是这样:
   * 一次「最新」刷新有 15 个源,每个源解析完都 put 一次,于是**整份 20×50 集的缓存
   * 被重建并序列化 15 遍**(约 600KB × 15),全在 UI 线程上,下拉刷新的转圈就卡在这里。
   *
   * 惰性版把取值也推迟到去抖到期时,同一文件的连续 N 次写只做**一次**序列化。
   * 代价:落盘的是到期那一刻的状态(而不是调用那一刻)—— 对"整份写回"的缓存来说
   * 正是想要的语义。
   */
  static writeJsonDebouncedLazy(name: string, build: () => Object): void {
    JsonFile.pendingBuild.set(name, build);
    JsonFile.pendingText.delete(name);       // 惰性优先:别让旧的 eager 文本盖回来
    const old = JsonFile.pendingTimer.get(name);
    if (old !== undefined) clearTimeout(old);
    JsonFile.pendingTimer.set(name, setTimeout(() => {
      JsonFile.pendingTimer.delete(name);
      const text = JsonFile.takePending(name);
      if (text !== null) JsonFile.writeTextAsync(name, text);
    }, JsonFile.DEBOUNCE_MS));
  }

  /// 取出某文件的待写文本(必要时才序列化),并清掉待写记录。
  private static takePending(name: string): string | null {
    const eager = JsonFile.pendingText.get(name);
    if (eager !== undefined) {
      JsonFile.pendingText.delete(name);
      return eager;
    }
    const build = JsonFile.pendingBuild.get(name);
    if (build === undefined) return null;
    JsonFile.pendingBuild.delete(name);
    try {
      return JSON.stringify(build());
    } catch (e) {
      Log.w('JsonFile', `序列化失败 ${name}`);
      return null;
    }
  }

  /// 立即把所有待写内容落盘(同步,用于退到后台/退出这类"必须写成"的时机)。
  static flushPending(): void {
    const names = Array.from(JsonFile.pendingText.keys());
    const lazy = Array.from(JsonFile.pendingBuild.keys());
    for (let i = 0; i < lazy.length; i++) {
      if (names.indexOf(lazy[i]) < 0) names.push(lazy[i]);
    }
    for (let i = 0; i < names.length; i++) {
      const timer = JsonFile.pendingTimer.get(names[i]);
      if (timer !== undefined) {
        clearTimeout(timer);
        JsonFile.pendingTimer.delete(names[i]);
      }
      const t = JsonFile.takePending(names[i]);
      if (t !== null) JsonFile.writeText(names[i], t);
    }
    if (names.length > 0) Log.i('JsonFile', `退出前落盘 ${names.length} 个文件`);
  }

  /// 异步写文本。原子版,理由与同步版一致(见 writeText);失败留日志不静默。
  private static async writeTextAsync(name: string, text: string): Promise<void> {
    if (JsonFile.dir.length === 0) return;
    const p = JsonFile.path(name);
    const tmp = JsonFile.tmpPath(p);
    let file: fs.File | null = null;
    try {
      file = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, text);
      await fs.fsync(file.fd);
      await fs.close(file);
      file = null;
      await JsonFile.replaceAsync(tmp, p, name);
    } catch (e) {
      Log.e('JsonFile', `异步写入失败 ${name}:${(e as Error).message}`);
      JsonFile.unlinkQuiet(tmp);
    } finally {
      if (file !== null) {
        try {
          await fs.close(file);
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /**
   * 文件占用字节(设置页展示缓存用量)。**异步版** ——
   * `statSync` 单次只有几毫秒,但设置页一进来要对若干缓存文件 + 每个逐字稿 + 每个下载各来一次,
   * 是 O(N) 的同步 IO 摊在首帧上。用 Promise 版把它挪出关键路径(见 H65 的教训)。
   */
  static async sizeBytesAsync(name: string): Promise<number> {
    if (JsonFile.dir.length === 0) return 0;
    try {
      const p = JsonFile.path(name);
      if (!await fs.access(p)) return 0;
      const st = await fs.stat(p);
      return st.size;
    } catch (e) {
      return 0;
    }
  }

  /// 同步版:只留给"必须当场拿到"的场合(目前无调用方,保留以免以后重复实现)。
  static sizeBytes(name: string): number {
    if (JsonFile.dir.length === 0) return 0;
    try {
      const p = JsonFile.path(name);
      if (!fs.accessSync(p)) return 0;
      return fs.statSync(p).size;
    } catch (e) {
      return 0;
    }
  }

  static remove(name: string): void {
    if (JsonFile.dir.length === 0) return;
    const p = JsonFile.path(name);
    try {
      if (fs.accessSync(p)) fs.unlinkSync(p);
    } catch (e) {
      Log.w('JsonFile', `删除失败 ${name}`);
    }
    // 原子写之后目录里会多出 `x.json.tmp.<pid>`;clear() 的语义是「这份数据没有了」,
    // 所以临时文件一并清 —— 留着它,下次这条链不再发生就是纯残留。
    // (.corrupt-* 残本**故意不清**:那是留证,清了就是高-3 要避免的事。)
    JsonFile.unlinkQuiet(JsonFile.tmpPath(p));
  }
}
