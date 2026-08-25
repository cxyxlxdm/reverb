import fs from '@ohos.file.fs';
import { Log } from '../util/Logger';

/// 应用私有目录下的 JSON 读写基座(对应 Android filesDir/*.json 与 macOS AppSupport)。
/// 一律"失败静默、不影响内存态"——持久化坏了也不能让 App 用不了。
export class JsonFile {
  private static dir: string = '';

  static init(filesDir: string): void {
    JsonFile.dir = filesDir;
  }

  private static path(name: string): string {
    return `${JsonFile.dir}/${name}`;
  }

  static readText(name: string): string | null {
    if (JsonFile.dir.length === 0) return null;
    const p = JsonFile.path(name);
    try {
      if (!fs.accessSync(p)) return null;
      return fs.readTextSync(p);
    } catch (e) {
      Log.w('JsonFile', `读取失败 ${name}`);
      return null;
    }
  }

  static writeText(name: string, text: string): void {
    if (JsonFile.dir.length === 0) return;
    const p = JsonFile.path(name);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
    } catch (e) {
      Log.w('JsonFile', `写入失败 ${name}`);
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

  /// 读出 JSON 数组;失败或非数组返回空数组。
  static readArray(name: string): Object[] {
    const s = JsonFile.readText(name);
    if (s === null || s.length === 0) return [];
    try {
      const o: Object = JSON.parse(s);
      return Array.isArray(o) ? o as Object[] : [];
    } catch (e) {
      Log.w('JsonFile', `JSON 解析失败 ${name}`);
      return [];
    }
  }

  /// 读出 JSON 对象;失败返回 null。
  static readObject(name: string): Record<string, Object> | null {
    const s = JsonFile.readText(name);
    if (s === null || s.length === 0) return null;
    try {
      const o: Object = JSON.parse(s);
      return Array.isArray(o) ? null : o as Record<string, Object>;
    } catch (e) {
      Log.w('JsonFile', `JSON 解析失败 ${name}`);
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

  /// 异步写文本。失败静默(与同步版一致:持久化坏了不能影响使用)。
  private static async writeTextAsync(name: string, text: string): Promise<void> {
    if (JsonFile.dir.length === 0) return;
    const p = JsonFile.path(name);
    let file: fs.File | null = null;
    try {
      file = await fs.open(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(file.fd, text);
    } catch (e) {
      Log.w('JsonFile', `异步写入失败 ${name}`);
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
    try {
      const p = JsonFile.path(name);
      if (fs.accessSync(p)) fs.unlinkSync(p);
    } catch (e) {
      Log.w('JsonFile', `删除失败 ${name}`);
    }
  }
}
