/**
 * feed 抓取的「平台限制拦截页」识别。**纯函数、不碰网络**,单测直接覆盖
 * (见 `entry/src/test/FeedGuard.test.ets`)。
 *
 * 起因:小宇宙等站的 RSS 在部分网络下会被 302 到一个 `text/html` 拦截页。
 *鸿蒙 `@ohos.net.http` 默认自动跟随跳转,所以最终响应码是 **200** 而不是 302 ——
 * 光看 `HttpResult.ok` 会把一个 HTML 页面当成 RSS 交给 `XmlPullParser`,
 * 日志里只剩一句「解析失败」,而真因是平台限制。判据必须在**解析之前**落闸。
 *
 * 三条信号(任一命中即拦截,但真 RSS/Atom 优先放行):
 *  1. 3xx 且正文像网页;
 *  2. `Content-Type` 含 `html`;
 *  3. 正文以 `<!doctype html` / `<html` / `<head` 开头
 *     (且不是 `<?xml` / `<rss` / `<feed` 这些 XML 根)。
 */

/// 真 RSS/Atom 的根标签:即使 Content-Type 被错标成 html 也不能误杀正常源。
function startsWithXmlRoot(head: string): boolean {
  return head.startsWith('<?xml') || head.startsWith('<rss') || head.startsWith('<feed');
}

/**
 * @param code 最终响应码(系统可能已跟随跳转,所以 200 也要判)
 * @param contentType 响应头里的 Content-Type(大小写不敏感)
 * @param body 响应正文(只看开头一小段,避免把整份 HTML 扫一遍 —— 见硬规矩 6)
 */
export function looksLikeHtmlIntercept(code: number, contentType: string, body: string): boolean {
  // trimStart + 小写 + 只取前 512 字符:拦截页的 doctype 一定在开头,
  // 而几百 KB 的 RSS 不该在这里被整串复制一遍。
  const head = body.trimStart().substring(0, 512).toLowerCase();
  if (head.length === 0) return false;
  if (startsWithXmlRoot(head)) return false;

  const htmlBody = head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<head');
  const htmlType = contentType.toLowerCase().indexOf('html') >= 0;
  if (htmlBody || htmlType) return true;
  // 3xx 未跟随跳转时正文可能只是一段网页片段(没有 doctype),同样不能进 XML 解析。
  return code >= 300 && code < 400 && head.startsWith('<');
}
