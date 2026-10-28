import http from '@ohos.net.http';
import { Log } from '../util/Logger';

/// 统一 HTTP 封装(仿 macOS `HTTPClient.swift`,替代 Android 侧 5 处重复的 get())。
/// 全链路零鉴权:所有接口都是公开免费的。
const UA = 'Reverb/1.0 (HarmonyOS podcast client)';
const CONNECT_TIMEOUT = 15000;
const READ_TIMEOUT = 20000;

/// 一次"跳转探查"的读数。`head` 是响应头 stringify 后的文本 —— 只为在里面找 `Location`,
/// 不做结构化解析(ArkTS 侧 `http` 的 header 类型是 Object,取具体键要过一层类型关卡,
/// 而这里只要一 stringify 就能搜到)。
export class RedirectProbe {
  readonly code: number;
  readonly body: string;
  readonly head: string;

  constructor(code: number, body: string, head: string) {
    this.code = code;
    this.body = body;
    this.head = head;
  }
}

export class Http {
  /**
   * GET 取文本。失败返回 null(不抛),由调用方走降级链。
   *
   * `readTimeout` 只是系统网络栈的读取超时,并不保证 Promise 一定按时结束。这里另设物理
   * 硬超时,到点主动 destroy 请求；所有出口都经 finish,保证只结算一次且清掉 timer / 请求。
   */
  static async text(url: string, timeoutMs: number = READ_TIMEOUT,
    headers?: Record<string, string>): Promise<string | null> {
    const req = http.createHttp();
    const header = Http.headersOf(headers);
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
          header: header,
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

  /**
   * 合并默认 UA 与调用方自带的头。**调用方可覆盖 UA** —— 播客 CDN 认本应用 UA,
   * 而视频站的接口族要一个浏览器 UA(见 `BilibiliSource`),两边各交各的。
   */
  private static headersOf(headers?: Record<string, string>): Record<string, string> {
    const h: Record<string, string> = { 'User-Agent': UA };
    if (headers === undefined) return h;
    const keys = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) h[keys[i]] = headers[keys[i]];
    return h;
  }

  /**
   * 1 字节探活:只认 **200 / 206**,其余(403 / 503 / 超时)都判为此刻取不到流。
   *
   * 调用方自己把 `Range: bytes=0-0` 放进 headers,不在这里替它加 —— 有的 CDN 对小 Range
   * 回 200 + 整个 body,而这是"通不通"的探针,不是取数据。所以拿到响应码就立刻 destroy,
   * 正文不读。与 `text()` 的硬超时同一个口径:Promise 不保证按时结束,这里靠请求超时 + catch。
   */
  static async probeOk(url: string, headers: Record<string, string>,
    timeoutMs: number = 8000): Promise<boolean> {
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: Http.headersOf(headers),
        connectTimeout: Math.min(CONNECT_TIMEOUT, timeoutMs),
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      return resp.responseCode === 200 || resp.responseCode === 206;
    } catch (_e) {
      return false;
    } finally {
      try {
        req.destroy();
      } catch (_e) {
        // 释放失败不影响判定
      }
    }
  }

  /**
   * 跟随一次跳转,取回"最终落到的地址里那段文本"(短链解析用)。
   *
   * 两条路都要兜住:系统网络栈若自动跟随 3xx,响应里就没有 `Location`,只能从正文找;
   * 若不跟随,`Location` 就在响应头里,而正文是空的。把头和正文一起交回去,调用方
   * 自己在里面抠 id —— 所以返回的是**两个候选文本**,不是一个 URL,不要在别处复用。
   */
  static async redirectProbe(url: string, headers: Record<string, string>,
    timeoutMs: number = 10000): Promise<RedirectProbe> {
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: Http.headersOf(headers),
        connectTimeout: Math.min(CONNECT_TIMEOUT, timeoutMs),
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      const body = typeof resp.result === 'string' ? resp.result as string : '';
      let hdr = '';
      try {
        hdr = JSON.stringify(resp.header);
      } catch (_e) {
        hdr = '';
      }
      return new RedirectProbe(resp.responseCode, body, hdr);
    } catch (e) {
      Log.w('Http', `跳转探查失败 host=${Http.host(url)}`);
      return new RedirectProbe(0, '', '');
    } finally {
      try {
        req.destroy();
      } catch (_e) {
      }
    }
  }

  /// GET 取 JSON 对象。解析失败返回 null。
  static async json(url: string, timeoutMs: number = READ_TIMEOUT,
    headers?: Record<string, string>): Promise<Record<string, Object> | null> {
    const s = await Http.text(url, timeoutMs, headers);
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
  static async jsonArray(url: string, timeoutMs: number = READ_TIMEOUT,
    headers?: Record<string, string>): Promise<Object[] | null> {
    const s = await Http.text(url, timeoutMs, headers);
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

  /// 数组元素取字符串(只认真正的 string;数字与对象都当空串)。
  static asStr(v: Object): string {
    return typeof v === 'string' ? v as string : '';
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
