import http from '@ohos.net.http';
import { BusinessError } from '@ohos.base';
import { Log } from '../util/Logger';
import { looksLikeHtmlIntercept } from './FeedGuard';

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

/// `fetchText` 的读数:状态码 + 正文。**非 2xx 也回**,由调用方自己分辨 401(要问口令)
/// 与其余失败 —— 混成一个 null 的话,用户看到的永远是「加载失败」,以为链接坏了(见 H253)。
export class HttpResult {
  readonly code: number;
  readonly body: string;
  /// 响应头里的 Content-Type 与最终地址。SDK 的 HttpResponse 不直接给 finalUrl:
  /// 有 Location 就记跳转目标,没有就记请求地址(系统已自动跟随 3xx)。
  readonly contentType: string;
  readonly finalUrl: string;

  constructor(code: number, body: string, contentType: string = '', finalUrl: string = '') {
    this.code = code;
    this.body = body;
    this.contentType = contentType;
    this.finalUrl = finalUrl;
  }

  get ok(): boolean {
    return this.code >= 200 && this.code <= 299;
  }

  /// 平台限制拦截页:200 也可能是 HTML(系统跟随了 302),必须先看这个再看 ok。
  get platformBlocked(): boolean {
    return looksLikeHtmlIntercept(this.code, this.contentType, this.body);
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
      /**
       * @param detail 失败原因的**系统侧读数**(`code=… msg=…`)。只打 `阶段` 时,
       *   「网络栈拒连」与「对端拒绝」在日志里是同一句话 —— 2026-10-31 那次
       *   `阶段=请求异常 耗时=14ms` 就是这么失去根因的(见 H233)。
       */
      const finish = (value: string | null, stage: string, detail?: string): void => {
        if (settled) return;
        settled = true;
        if (timerId >= 0) clearTimeout(timerId);
        try {
          req.destroy();
        } catch (_e) {
          // destroy 只负责释放系统请求；即使系统已先行回收,也不能影响 Promise 收尾。
        }
        const elapsed = Date.now() - startedAt;
        const tail = detail === undefined ? '' : ` ${detail}`;
        if (value === null) Log.w('Http', `host=${host} 阶段=${stage} 耗时=${elapsed}ms${tail}`);
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
        }).catch((e: BusinessError) => {
          finish(null, '请求异常', `code=${e.code} msg=${e.message}`);
        });
      } catch (_e) {
        finish(null, '启动异常');
      }
    });
  }

  /**
   * GET 取"状态码 + 正文"。与 [`text`] 的区别只有一处:**非 2xx 的响应也交回来**。
   *
   * 私有源(HTTP Basic)要能分辨两件事:「401 = 该问用户要口令」与「其余失败 = 真取不到」。
   * 传输层失败(超时 / 拒连)仍回 `code = 0`,与 `probeCode` 同一个口径。
   *
   * 硬超时与 `text` 同式:系统网络栈不保证 Promise 按时结束,到点主动 destroy。
   */
  static async fetchText(url: string, headers?: Record<string, string>,
    timeoutMs: number = READ_TIMEOUT): Promise<HttpResult> {
    const req = http.createHttp();
    const host = Http.host(url);
    const startedAt = Date.now();
    return await new Promise<HttpResult>((resolve: (value: HttpResult) => void) => {
      let settled = false;
      let timerId: number = -1;
      const finish = (value: HttpResult, stage: string): void => {
        if (settled) return;
        settled = true;
        if (timerId >= 0) clearTimeout(timerId);
        try {
          req.destroy();
        } catch (_e) {
          // 释放失败不影响结果
        }
        if (!value.ok) {
          Log.w('Http', `host=${host} http=${value.code} 阶段=${stage} 耗时=${Date.now() - startedAt}ms`);
        }
        // 平台拦截页通常是 200(系统已跟随 302),光靠 `!ok` 的日志看不见根因。
        // 这里把 host / 状态码 / Content-Type / 最终 URL 一次打全,不进 XML 解析。
        if (value.platformBlocked) {
          Log.w('Http', `平台限制拦截 host=${host} http=${value.code} `
            + `type=${value.contentType.length > 0 ? value.contentType : '?'} final=${value.finalUrl}`);
        }
        resolve(value);
      };

      timerId = setTimeout(() => { finish(new HttpResult(0, ''), '硬超时'); }, Math.max(1, timeoutMs));
      try {
        req.request(url, {
          method: http.RequestMethod.GET,
          header: Http.headersOf(headers),
          connectTimeout: Math.min(CONNECT_TIMEOUT, timeoutMs),
          readTimeout: timeoutMs,
          expectDataType: http.HttpDataType.STRING
        }).then((resp: http.HttpResponse) => {
          const body = typeof resp.result === 'string' ? resp.result as string : '';
          const hdr = J.asObj(resp.header);
          const contentType = Http.header(hdr, 'content-type');
          // 未跟随跳转时 Location 就是下一跳;已跟随时 header 没有 Location,退回请求 URL。
          const location = Http.header(hdr, 'location');
          finish(new HttpResult(resp.responseCode, body, contentType,
            location.length > 0 ? location : url), '完成');
        }).catch((e: BusinessError) => {
          Log.w('Http', `host=${host} 请求异常 code=${e.code} msg=${e.message}`);
          finish(new HttpResult(0, ''), '请求异常');
        });
      } catch (_e) {
        finish(new HttpResult(0, ''), '启动异常');
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

  /// 从响应头里取一个字符串字段。ARK 的 header 键大小写不统一,两种都试一次。
  private static header(hdr: Record<string, Object> | null, key: string): string {
    const lower = J.str(hdr, key.toLowerCase());
    return lower.length > 0 ? lower : J.str(hdr, key);
  }

  /**
   * 1 字节探活,**返回服务端状态码**;拿不到(超时 / 连接失败)回 0,由调用方按 200/206 判通。
   *
   * 回码不回 boolean 是为了日志能读出「节点给了什么」(见 H225):只回 Bool 时,
   * 「探针坏了」与「节点真的不给流」在日志里是同一句话。
   *
   * 调用方自己把 `Range: bytes=0-0` 放进 headers,不在这里替它加 —— 有的 CDN 对小 Range
   * 回 200 + 整个 body,而这是"通不通"的探针,不是取数据。所以拿到响应码就立刻 destroy,
   * 正文不读。与 `text()` 的硬超时同一个口径:Promise 不保证按时结束,这里靠请求超时 + catch。
   */
  static async probeCode(url: string, headers: Record<string, string>,
    timeoutMs: number = 8000): Promise<number> {
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: Http.headersOf(headers),
        connectTimeout: Math.min(CONNECT_TIMEOUT, timeoutMs),
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      return resp.responseCode;
    } catch (e) {
      // 探针本来就是"回码不回 Bool"的判据:拿不到码时也要说清是**哪一层**拿不到,
      // 否则「探针被网络栈拒了」与「节点真的不给流」都是 0(见 H233)。
      const err = e as BusinessError;
      Log.w('Http', `探活失败 host=${Http.host(url)} code=${err.code} msg=${err.message}`);
      return 0;
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

  /// 只认真正的 boolean。接口偶尔给 0/1,这里**不**把它们当真假 ——
  /// 判据必须严格(见 BilibiliSource 的充电过滤:把 0 当 false 没问题,但把"缺字段"
  /// 猜成 true 会把正常视频全删掉)。
  static bool(src: Record<string, Object> | null, key: string): boolean {
    if (src === null) return false;
    return src[key] === true;
  }

  static asObj(v: Object): Record<string, Object> | null {
    if (v === undefined || v === null) return null;
    return Array.isArray(v) ? null : v as Record<string, Object>;
  }
}
