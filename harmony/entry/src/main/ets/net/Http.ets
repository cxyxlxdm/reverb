import http from '@ohos.net.http';
import { Log } from '../util/Logger';

/// 统一 HTTP 封装(仿 macOS `HTTPClient.swift`,替代 Android 侧 5 处重复的 get())。
/// 全链路零鉴权:所有接口都是公开免费的。
const UA = 'Reverb/1.0 (HarmonyOS podcast client)';
const CONNECT_TIMEOUT = 15000;
const READ_TIMEOUT = 20000;

export class Http {
  /// GET 取文本。失败返回 null(不抛),由调用方走降级链。
  static async text(url: string, timeoutMs: number = READ_TIMEOUT): Promise<string | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA },
        connectTimeout: CONNECT_TIMEOUT,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        Log.w('Http', `http ${resp.responseCode} url=${url}`);
        return null;
      }
      const body = resp.result;
      return typeof body === 'string' ? body : null;
    } catch (e) {
      Log.w('Http', `请求失败 url=${url} err=${(e as Error).message}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /// GET 取 JSON 对象。解析失败返回 null。
  static async json(url: string, timeoutMs: number = READ_TIMEOUT): Promise<Record<string, Object> | null> {
    const s = await Http.text(url, timeoutMs);
    if (s === null) return null;
    try {
      const o: Object = JSON.parse(s);
      return o as Record<string, Object>;
    } catch (e) {
      Log.w('Http', `JSON 解析失败 url=${url}`);
      return null;
    }
  }

  /// GET 取 JSON 数组(gpodder 的搜索结果是顶层数组)。
  static async jsonArray(url: string, timeoutMs: number = READ_TIMEOUT): Promise<Object[] | null> {
    const s = await Http.text(url, timeoutMs);
    if (s === null) return null;
    try {
      const o: Object = JSON.parse(s);
      return Array.isArray(o) ? o as Object[] : null;
    } catch (e) {
      Log.w('Http', `JSON 数组解析失败 url=${url}`);
      return null;
    }
  }

  static encode(s: string): string {
    return encodeURIComponent(s);
  }
}

/// 从 JSON 值里安全取字段(ArkTS 禁 any,统一在这里做窄化)。
export class J {
  static obj(src: Record<string, Object> | null, key: string): Record<string, Object> | null {
    if (src === null) return null;
    const v = src[key];
    if (v === undefined || v === null) return null;
    return Array.isArray(v) ? null : v as Record<string, Object>;
  }

  static arr(src: Record<string, Object> | null, key: string): Object[] {
    if (src === null) return [];
    const v = src[key];
    return Array.isArray(v) ? v as Object[] : [];
  }

  static str(src: Record<string, Object> | null, key: string): string {
    if (src === null) return '';
    const v = src[key];
    if (typeof v === 'string') return v;
    if (typeof v === 'number') return `${v}`;
    return '';
  }

  static num(src: Record<string, Object> | null, key: string): number {
    if (src === null) return 0;
    const v = src[key];
    if (typeof v === 'number') return v;
    if (typeof v === 'string') {
      const n = parseFloat(v);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  static asObj(v: Object): Record<string, Object> | null {
    if (v === undefined || v === null) return null;
    return Array.isArray(v) ? null : v as Record<string, Object>;
  }
}
