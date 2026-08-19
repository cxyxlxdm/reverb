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
    const old = JsonFile.pendingTimer.get(name);
    if (old !== undefined) clearTimeout(old);
    JsonFile.pendingTimer.set(name, setTimeout(() => {
      JsonFile.pendingTimer.delete(name);
      const t = JsonFile.pendingText.get(name);
      if (t === undefined) return;
      JsonFile.pendingText.delete(name);
      JsonFile.writeTextAsync(name, t);
    }, JsonFile.DEBOUNCE_MS));
  }

  /// 立即把所有待写内容落盘(同步,用于退到后台/退出这类"必须写成"的时机)。
  static flushPending(): void {
    const names = Array.from(JsonFile.pendingText.keys());
    for (let i = 0; i < names.length; i++) {
      const t = JsonFile.pendingText.get(names[i]);
      const timer = JsonFile.pendingTimer.get(names[i]);
      if (timer !== undefined) {
        clearTimeout(timer);
        JsonFile.pendingTimer.delete(names[i]);
      }
      JsonFile.pendingText.delete(names[i]);
      if (t !== undefined) JsonFile.writeText(names[i], t);
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

  /// 文件占用字节(设置页展示缓存用量)。
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
