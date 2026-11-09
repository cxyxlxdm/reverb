import util from '@ohos.util';

/**
 * 私有订阅源的 HTTP Basic 凭据。与 Android `data/model/FeedCredential.kt` /
 * macOS `Data/FeedCredential.swift` 逐条对齐。
 *
 * **为什么有这个东西**:一部分 RSS 源(自建 / WordPress 会员站 / 有声书服务器)在
 * feed 与音频上都要求用户名密码,不带就一律 401。这类源与"URL 里带 token"的私密源
 * (Patreon 那一类)不是一回事 —— 后者不需要认证逻辑,我们的粘贴订阅本来就能用。
 *
 * 凭据只用于**用户点名的那一个源**:feed 请求,以及同一主机(或互为子域)上的音频 /
 * 逐字稿请求。刻意不做"任何地址都带上" —— 音频经常放在第三方 CDN 上,那样等于
 * 把用户口令交给一个与他无关的主机(见 `FeedAuthStore.headerForUrl` 与 H253)。
 */
export class FeedCredential {
  username: string;
  password: string;

  constructor(username: string, password: string) {
    this.username = username;
    this.password = password;
  }

  /**
   * `Authorization` 头。
   *
   * @param utf8 true = 按 UTF-8 编;false = 按 RFC 7617 的默认字节语义(ISO-8859-1)。
   *
   * 不传参数时按内容自动选:含 ISO-8859-1 表示不了的字符(中文口令)用 UTF-8,否则 ISO。
   * 这条规则只适用于**不能重试**的调用点(音频 / 逐字稿)。feed 请求走的是
   * `RssParser` 那套「先 ISO、401 再 UTF-8」,与 AntennaPod 同一条兜底 —— 因为
   * RFC 7617 没有规定字符集,两种服务器都真实存在。
   */
  header(utf8?: boolean): string {
    const useUtf8 = utf8 === undefined ? this.needsUtf8 : utf8;
    const raw = `${this.username}:${this.password}`;
    const bytes = useUtf8 ? new util.TextEncoder().encodeInto(raw) : FeedCredential.isoBytes(raw);
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(bytes);
  }

  get defaultHeader(): string {
    return this.header(this.needsUtf8);
  }

  /**
   * 默认按 UTF-8 编:含 ISO-8859-1 表示不了的字符(中文口令)。
   *
   * ⚠️ 它**不是**「两种编码是否不同」。`é` 这类 Latin-1 表示得了的字符,ISO 与 UTF-8
   * 编出来的字节并不一样(0xE9 vs 0xC3 0xA9),可这里仍是 false —— 拿它当重试门槛,
   * 服务器按 UTF-8 解口令时就永远试不到第二发。重试的门槛是 [`encodingDiffers`]。
   */
  get needsUtf8(): boolean {
    const raw = this.username + this.password;
    for (let i = 0; i < raw.length; i++) {
      if (raw.charCodeAt(i) > 255) return true;
    }
    return false;
  }

  /**
   * 两种编码出来的头是否**真的不同** —— 只有不同才值得在 401 之后重试一次。
   *
   * 纯 ASCII 两串完全一样,重试等于重发同一个头;中文口令的 ISO 编码落成一串 `?`,
   * 与 UTF-8 也不同,照旧会重试一次;`é` / `ß` 这类字符两串同样不同 ——
   * 服务器按 UTF-8 解时,第一发必然失败,这一发才是救回来的那发(见 H253)。
   */
  get encodingDiffers(): boolean {
    return this.header(false) !== this.header(true);
  }

  /// ISO-8859-1 表示不了的字符落成 `?`(0x3F)—— 与 Kotlin `toByteArray(ISO_8859_1)`
  /// 同一个行为,也正是"先 ISO 再 UTF-8 重试"那一套要兜住的失败形态。
  static isoBytes(raw: string): Uint8Array {
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) {
      const c = raw.charCodeAt(i);
      out[i] = c > 255 ? 0x3F : c;
    }
    return out;
  }

  /**
   * 把 `https://user:pass@host/feed.xml` 拆成(去掉 userinfo 的 URL, 凭据)。
   *
   * **必须把 userinfo 从 URL 里拿掉**,它有三个不该去的地方:
   *  - 订阅列表与导出备份(口令会跟着 JSON 走);
   *  - 运行日志(`url=…` 是全仓库通用的日志写法);
   *  - 频道/单集的持久字段(分享卡片、widget 快照都可能再读一次)。
   * 没有 userinfo 时原样返回(trim 之后),凭据为 null。
   *
   * 返回元组而不是对象字面量:ArkTS 不接受无类型对象字面量。
   */
  static splitUrl(raw: string): [string, FeedCredential | null] {
    const trimmed = raw.trim();
    const schemeAt = trimmed.indexOf('://');
    if (schemeAt <= 0) return [trimmed, null];
    const authStart = schemeAt + 3;
    let authEnd = trimmed.length;
    for (let i = authStart; i < trimmed.length; i++) {
      const ch = trimmed.charAt(i);
      if (ch === '/' || ch === '?' || ch === '#') { authEnd = i; break; }
    }
    const authority = trimmed.substring(authStart, authEnd);
    const at = authority.lastIndexOf('@');
    if (at < 0) return [trimmed, null];
    const userInfo = authority.substring(0, at);
    const colon = userInfo.indexOf(':');
    const user = FeedCredential.decode(colon >= 0 ? userInfo.substring(0, colon) : userInfo);
    const pass = colon >= 0 ? FeedCredential.decode(userInfo.substring(colon + 1)) : '';
    if (user.length === 0) return [trimmed, null];
    const clean = trimmed.substring(0, authStart) + authority.substring(at + 1) + trimmed.substring(authEnd);
    return [clean, new FeedCredential(user, pass)];
  }

  /// 主机:小写;解析不出来返回空串。
  static hostOf(url: string): string {
    const t = url.trim();
    const schemeAt = t.indexOf('://');
    if (schemeAt <= 0) return '';
    const start = schemeAt + 3;
    let end = t.length;
    for (let i = start; i < t.length; i++) {
      const ch = t.charAt(i);
      if (ch === '/' || ch === '?' || ch === '#') { end = i; break; }
    }
    let authority = t.substring(start, end);
    const at = authority.lastIndexOf('@');
    if (at >= 0) authority = authority.substring(at + 1);
    // IPv6 字面量 `[::1]:8080`:先剥方括号,方括号内的冒号不是端口分隔符
    if (authority.startsWith('[')) {
      const close = authority.indexOf(']');
      return close > 0 ? authority.substring(0, close + 1).toLowerCase() : '';
    }
    const port = authority.indexOf(':');
    if (port >= 0) authority = authority.substring(0, port);
    return authority.toLowerCase();
  }

  /// `a.example.com` 与 `example.com` 视为同源;`other.com` 不算。
  static hostMatches(a: string, b: string): boolean {
    if (a.length === 0 || b.length === 0) return false;
    return a === b || a.endsWith('.' + b) || b.endsWith('.' + a);
  }

  private static decode(s: string): string {
    try {
      return decodeURIComponent(s);
    } catch (_e) {
      return s;
    }
  }
}
