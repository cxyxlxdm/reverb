import { describe, it, expect } from '@ohos/hypium';
import { looksLikeHtmlIntercept } from '../main/ets/net/FeedGuard';

/**
 * 平台限制拦截页识别。小宇宙 feed 在部分网络下 302 → text/html,
 * 而鸿蒙 http 会替我们跟随跳转(最终响应码 200),不先判掉就会被当 XML 解析。
 * 判据是纯函数,真机单测只覆盖它,不发网络请求(与仓库单测口径一致)。
 */
export default function feedGuardTest(): void {
  describe('FeedGuard', () => {

    it('200 + text/html + doctype 命中拦截', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'text/html; charset=utf-8',
        '<!DOCTYPE html><html><head><title>访问受限</title></head></html>')).assertTrue();
    });

    it('大写 doctype 与前置空白也能识别', 0, () => {
      expect(looksLikeHtmlIntercept(200, '', '\n\n  <!doctype HTML> ...')).assertTrue();
    });

    it('没有 Content-Type 时按正文 <html 开头识别', 0, () => {
      expect(looksLikeHtmlIntercept(200, '', '<html lang="zh"><body>拦截</body></html>')).assertTrue();
    });

    it('3xx 未跟随跳转的网页片段也拦截', 0, () => {
      expect(looksLikeHtmlIntercept(302, '', '<head><meta http-equiv="refresh"></head>')).assertTrue();
    });

    it('application/xhtml+xml 命中', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'APPLICATION/XHTML+XML', '<html/>')).assertTrue();
    });

    it('真 RSS 即使 Content-Type 被错标成 html 也放行', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'text/html',
        '<?xml version="1.0"?><rss version="2.0"><channel/></rss>')).assertFalse();
    });

    it('Atom feed 放行', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'text/plain',
        '<feed xmlns="http://www.w3.org/2005/Atom"><entry/></feed>')).assertFalse();
    });

    it('普通 XML 声明放行', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'application/xml',
        '<?xml version="1.0" encoding="UTF-8"?><rss/>')).assertFalse();
    });

    it('JSON 与非网页片段放行', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'application/json', '{"title":"x"}')).assertFalse();
      expect(looksLikeHtmlIntercept(200, 'text/plain', 'plain text')).assertFalse();
    });

    it('空正文放行(交给后续错误分支处理)', 0, () => {
      expect(looksLikeHtmlIntercept(200, 'text/html', '   ')).assertFalse();
    });
  });
}
