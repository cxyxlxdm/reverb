import http from '@ohos.net.http';
import { BusinessError } from '@ohos.base';
import { Episode } from '../model/Models';
import { Http } from './Http';
import { Log } from '../util/Logger';

/**
 * 直播流(A 档):用户把一路音频流的地址直接粘进搜索框。
 *
 * 这一档**不做目录、不做收录、不需要后端**:用户给什么地址就放什么地址,
 * 与「粘 RSS」「粘视频链接」同一性质 —— 用户点名的那一条,不是下拉就能翻到的目录。
 *
 * 判据只有一条:**响应必须自己表明它是音频流**。收三种信号:
 *  ① `Content-Type` 落在 `audio` 大类下(或 `application/ogg`)—— 绝大多数 Icecast/Shoutcast 的 MP3/AAC 流;
 *  ② `Content-Type` 是 HLS 的 MIME 或路径以 `.m3u8` 结尾 —— 那是播放列表,不是网页;
 *  ③ 带 `icy-*` 响应头 —— ICY 协议自己的身份,有的电台 Content-Type 写得很随意,这条兜住。
 * `text/html` 一律拒绝:粘一个普通网页或一条失效的 RSS 地址,不该被当成直播播出去。
 *
 * 返回的 `Episode` 是**合成出来的**,`isLive = true` 是它唯一的特殊之处 ——
 * 播放侧据此关掉历史/缓存/收听时长/断点续播/播完续播(见 `PlayerController` 里以 isLive 为闸的几处)。
 *
 * ⚠️ **探测必须走 `requestInStream`,不能用 `Http.probeCode`**。后者是 `req.request()`,
 * 它要等**整个响应体**读完才结算 —— 而一条无限的直播流永远读不完,只会一直挂到超时,
 * 于是「网络栈没连通」与「这就是一条正在推的流」拿到同一个读数(0)。视频短链那边
 * `Http.redirectProbe` 能直接用,是因为那些接口的响应体是有限的一小段 JSON。
 */

/// 一次"只收响应头"的探测读数。`head` 是响应头 stringify 后的文本 ——
/// 与 `Http.redirectProbe` 同一个理由:`http` 的头类型是 Object,取具体键要过类型关卡,
/// 而这里只要一 stringify 就能用正则找。
export class LiveHead {
  readonly code: number;
  readonly head: string;

  constructor(code: number, head: string) {
    this.code = code;
    this.head = head;
  }
}

export class LiveStream {
  private static readonly PROBE_TIMEOUT_MS: number = 8000;
  private static readonly HLS_TYPES: string[] = [
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl'
  ];

  /**
   * 只用来给界面做"这可能是直播"的廉价预判(不发请求);真正的判据在 [resolve] 的探测。
   *
   * 故意**不**只看扩展名:大量电台地址根本没有扩展名(或挂着一串查询参数),
   * 反过来一个 `.mp3` 也可能是一个普通音频文件。所以这里只排除明显不是的单播资源,
   * 其余交给探测 —— 探测只取响应头,代价是一次几百字节的往返。
   */
  static looksLikeStream(raw: string): boolean {
    const s = raw.trim();
    return s.startsWith('http://') || s.startsWith('https://');
  }

  static async resolve(rawUrl: string): Promise<Episode | null> {
    const url = rawUrl.trim();
    if (!LiveStream.looksLikeStream(url)) return null;
    const probe = await LiveStream.probe(url);
    if (probe === null) return null;

    const host = Http.host(url);
    if (!LiveStream.streamLike(url, probe)) {
      const type = LiveStream.headerOf(probe.head, 'content-type')
        .split(';')[0].trim().toLowerCase();
      const hasIcy = new RegExp('"icy-', 'i').test(probe.head);
      Log.i('Live', `不是直播流 code=${probe.code} type='${type}' icy=${hasIcy} host=${host}`);
      return null;
    }
    const type = LiveStream.headerOf(probe.head, 'content-type')
      .split(';')[0].trim().toLowerCase();
    const hasIcy = new RegExp('"icy-', 'i').test(probe.head);
    const name = LiveStream.headerOf(probe.head, 'icy-name').trim();
    Log.i('Live', `直播流确认 type='${type}' icy=${hasIcy} hls=${LiveStream.isHls(url, type)}`
      + ` host=${host} name='${name}'`);
    const ep: Episode = {
      // id 带上地址:同一路流的两次粘贴视为同一集,重复点不会在队列里堆两条
      id: 'live:' + url,
      title: name.length > 0 ? name : host,
      description: '',
      audioUrl: url,
      artworkUrl: '',
      // 有台名时把主机名放到副标题,不然两行写的是同一句话
      podcastTitle: name.length > 0 ? host : '',
      durationSec: 0,
      pubDate: '',
      feedUrl: '',
      transcriptUrl: '',
      transcriptType: '',
      // 直播没有"整段"这个边界,章表也就没有意义(播放页的章节入口按 liveNoTimeline 藏掉)
      chaptersUrl: '',
      chaptersType: '',
      isLive: true
    };
    return ep;
  }

  /**
   * 在线目录筛选用:与 [resolve] 同一份判据,但不构造 Episode。
   *
   * 超时由调用方给(默认 5 s):一整页要探 20~30 条,用 resolve 的 8 s,只要有一条
   * 黑洞地址(不回包也拒连)整页就多等一轮。2026-11-22 实测中国区热门 30 条里 7 条连不上,
   * 它们大多在几秒内失败,5 s 足够分开「慢但活着」与「根本连不上」。
   */
  static async isPlayable(rawUrl: string, timeoutMs: number = 5000): Promise<boolean> {
    const url = rawUrl.trim();
    if (!LiveStream.looksLikeStream(url)) return false;
    const probe = await LiveStream.probe(url, timeoutMs, false);
    if (probe === null) return false;
    return LiveStream.streamLike(url, probe);
  }

  /// 判据本体。路径判据自己切掉查询串:电台常见 `.m3u8?token=…` 这种形态。
  private static streamLike(url: string, probe: LiveHead): boolean {
    const type = LiveStream.headerOf(probe.head, 'content-type')
      .split(';')[0].trim().toLowerCase();
    const hasIcy = new RegExp('"icy-', 'i').test(probe.head);
    const isHls = LiveStream.isHls(url, type);
    const isAudio = type.startsWith('audio/') || type === 'application/ogg';
    // 拿不到状态码时(只有 `headersReceive` 有读数)按 0 处理 = 不否决:
    // 判据的主语是"响应头自己说不说它是音频",状态码只是额外一道。
    const okStatus = probe.code === 0 || (probe.code >= 200 && probe.code <= 299) || probe.code === 416;
    return okStatus && (isHls || isAudio || hasIcy);
  }

  private static isHls(url: string, type: string): boolean {
    const lower = url.toLowerCase();
    const qIdx = lower.indexOf('?');
    const pathPart = qIdx >= 0 ? lower.substring(0, qIdx) : lower;
    return LiveStream.HLS_TYPES.indexOf(type) >= 0 || pathPart.endsWith('.m3u8');
  }

  /**
   * 只要响应头,拿到就 `destroy`。
   *
   * `headersReceive` 在**第一段数据到达前**就会回调,这正是无限流唯一能拿到的时刻:
   * `requestInStream` 的 Promise 要等流结束才结算,对直播等于永不结算。
   * 所以这里靠事件 + 硬超时两条出口,谁先到谁说话,`finish` 保证只结算一次。
   *
   * 探测本身也带 `Range: bytes=0-0`(只要一个字节)与 `Icy-MetaData: 1`
   * (让支持 ICY 的服务器把 `icy-*` 头带回来,尤其是 icy-name,拿它当标题)。
   */
  private static async probe(url: string, timeoutMs: number = LiveStream.PROBE_TIMEOUT_MS,
    logHost: boolean = true): Promise<LiveHead | null> {
    const req = http.createHttp();
    const host = Http.host(url);
    // 目录批量探活一次 20~30 条,不落主机名(只记条数与错误类,见 RadioBrowserSource);
    // 用户自己粘的地址仍带 host,便于排障。
    const who = logHost ? ` host=${host}` : '';
    const startedAt = Date.now();
    return await new Promise<LiveHead | null>((resolve: (v: LiveHead | null) => void) => {
      let settled = false;
      let timerId: number = -1;
      const finish = (head: LiveHead | null, stage: string): void => {
        if (settled) return;
        settled = true;
        if (timerId >= 0) clearTimeout(timerId);
        try {
          req.destroy();
        } catch (_e) {
          // 释放失败不影响判定
        }
        Log.d('Live', `探测 ${stage}${who} 耗时=${Date.now() - startedAt}ms`);
        resolve(head);
      };

      req.on('headersReceive', (h: Object) => {
        let text = '';
        try {
          text = JSON.stringify(h);
        } catch (_e) {
          text = '';
        }
        finish(new LiveHead(0, text), '完成');
      });
      timerId = setTimeout(() => { finish(null, '硬超时'); }, timeoutMs);
      try {
        req.requestInStream(url, {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)',
            'Icy-MetaData': '1',
            'Range': 'bytes=0-0'
          },
          connectTimeout: timeoutMs,
          readTimeout: timeoutMs
        }).then((code: number) => {
          // 走到这里说明响应体已经读完 —— 对直播不可能,只有"其实是有限文件"才会。
          // 状态码这时候才有读数,补交给判据。
          finish(new LiveHead(code, ''), `完成 code=${code}`);
        }).catch((e: BusinessError) => {
          // destroy 之后自己抛的那一条也走这里;settled 已经为真,finish 会自动忽略。
          if (!settled) Log.w('Live', `探测失败${who} code=${e.code} msg=${e.message}`);
          finish(null, '请求异常');
        });
      } catch (_e) {
        finish(null, '启动异常');
      }
    });
  }

  /// 从 stringify 后的响应头里取一个键(大小写不敏感,取第一个)。
  private static headerOf(head: string, name: string): string {
    const re = new RegExp('"' + name + '"\\s*:\\s*"([^"]*)"', 'i');
    const m = re.exec(head);
    return m === null ? '' : m[1];
  }
}
