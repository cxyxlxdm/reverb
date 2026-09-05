import http from '@ohos.net.http';
import { Log } from '../util/Logger';

/// 统一 HTTP 封装(仿 macOS `HTTPClient.swift`,替代 Android 侧 5 处重复的 get())。
/// 全链路零鉴权:所有接口都是公开免费的。
const UA = 'Reverb/1.0 (HarmonyOS podcast client)';
const CONNECT_TIMEOUT = 15000;
const READ_TIMEOUT = 20000;

export class Http {
  /**
   * GET 取文本。失败返回 null(不抛),由调用方走降级链。
   *
   * `readTimeout` 只是系统网络栈的读取超时,并不保证 Promise 一定按时结束。这里另设物理
   * 硬超时,到点主动 destroy 请求；所有出口都经 finish,保证只结算一次且清掉 timer / 请求。
   */
  static async text(url: string, timeoutMs: number = READ_TIMEOUT): Promise<string | null> {
    const req = http.createHttp();
    const host = Http.host(url);
    const startedAt = Date.now();
    const hardTimeout = Math.max(1, timeoutMs);
    return await new Promise<string | null>((resolve: (value: string | null) => void) => {
      let settled = false;
      let timerId: number = -1;
      const finish = (value: string | null, stage: string): void => {
        if (settled) return;
        settled = true;
        if (timerId >= 0) clearTimeout(timerId);
        try {
          req.destroy();
        } catch (_e) {
          // destroy 只负责释放系统请求；即使系统已先行回收,也不能影响 Promise 收尾。
        }
        const elapsed = Date.now() - startedAt;
        if (value === null) Log.w('Http', `host=${host} 阶段=${stage} 耗时=${elapsed}ms`);
        else Log.d('Http', `host=${host} 阶段=${stage} 耗时=${elapsed}ms`);
        resolve(value);
      };

      timerId = setTimeout(() => { finish(null, '硬超时'); }, hardTimeout);
      try {
        req.request(url, {
          method: http.RequestMethod.GET,
          header: { 'User-Agent': UA },
          connectTimeout: Math.min(CONNECT_TIMEOUT, hardTimeout),
          readTimeout: hardTimeout,
          expectDataType: http.HttpDataType.STRING
        }).then((resp: http.HttpResponse) => {
          if (resp.responseCode !== 200) {
            finish(null, `HTTP_${resp.responseCode}`);
            return;
          }
          const body = resp.result;
          if (typeof body !== 'string') {
            finish(null, '响应非文本');
            return;
          }
          finish(body, '完成');
        }).catch(() => { finish(null, '请求异常'); });
      } catch (_e) {
        finish(null, '启动异常');
      }
    });
  }

  static host(url: string): string {
    return Log.endpoint(url);
  }

  /// GET 取 JSON 对象。解析失败返回 null。
  static async json(url: string, timeoutMs: number = READ_TIMEOUT): Promise<Record<string, Object> | null> {
    const s = await Http.text(url, timeoutMs);
    if (s === null) return null;
    try {
      const o: Object = JSON.parse(s);
      return o as Record<string, Object>;
    } catch (e) {
      Log.w('Http', `JSON 解析失败 host=${Http.host(url)}`);
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
      Log.w('Http', `JSON 数组解析失败 host=${Http.host(url)}`);
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
