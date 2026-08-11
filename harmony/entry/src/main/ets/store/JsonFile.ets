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
