import xml from '@ohos.xml';
import util from '@ohos.util';
import { Http } from './Http';
import { Log } from '../util/Logger';
import { htmlToText, parseDurationSec } from '../util/HtmlText';
import { Episode, Podcast, FeedResult, emptyPodcast } from '../model/Models';
import { Genres } from '../model/Genres';
import { FeedCredential } from '../model/FeedCredential';

/**
 * 一次取 feed 的结果。**401 必须与"传输/解析失败"分开**:前者要弹用户名密码输入框,
 * 后者只该显示加载失败 —— 混成一个 null 的话,用户看到的永远是「加载失败」,
 * 以为链接坏了(见 H253)。
 *
 * 用 interface 而不是带方法的类:它要跨 taskpool 边界回来(`FeedTask`),
 * 只有纯字段的普通对象才保证可序列化。
 */
export interface FeedOutcome {
  result: FeedResult | null;
  unauthorized: boolean;
}

/**
 * 播放核心:解析播客自身的 RSS/Atom,取出频道信息与每集音频直链。
 * 无论用哪个目录发现节目,最终都回到发布方原始 feed —— 版权安全、零成本的正规方式。
 *
 * 移植自 Android `RssParser.kt` 的状态机,但鸿蒙 XmlPullParser 是**回调式(push)**、
 * 且属性由独立回调给出,故结构相应重构;标签名同时匹配「带前缀」与「去前缀」两种形态,
 * 以规避 ignoreNameSpace 语义的不确定性。
 */
export class RssParser {
  static async fetch(feedUrl: string, timeoutMs: number): Promise<FeedResult | null> {
    const outcome = await RssParser.fetchOutcome(feedUrl, timeoutMs, '', '');
    return outcome.result;
  }

  /**
   * 带 HTTP Basic 凭据取 feed。`user` 为空 = 这个源还没有凭据。
   *
   * **先 ISO-8859-1、401 再 UTF-8**(与 Android `RssParser` / AntennaPod 同一条兜底):
   * RFC 7617 没有规定字符集,两种服务器都真实存在。门槛是「两串字节真的不同」
   * 而不是「有非 Latin-1 字符」—— `é` / `ß` 这类字符两串就不同,服务器按 UTF-8 解时
   * 只有第二发能过(见 H253)。
   */
  static async fetchOutcome(feedUrl: string, timeoutMs: number,
    user: string, pass: string): Promise<FeedOutcome> {
    const auth = user.length > 0 ? new FeedCredential(user, pass) : null;
    const first = await Http.fetchText(feedUrl, RssParser.authHeaders(auth, false), timeoutMs);
    if (first.ok) return { result: RssParser.parse(first.body, feedUrl), unauthorized: false };
    if (first.code !== 401 || auth === null) {
      return { result: null, unauthorized: first.code === 401 };
    }
    if (!auth.encodingDiffers) return { result: null, unauthorized: true };
    const second = await Http.fetchText(feedUrl, RssParser.authHeaders(auth, true), timeoutMs);
    if (second.ok) return { result: RssParser.parse(second.body, feedUrl), unauthorized: false };
    return { result: null, unauthorized: second.code === 401 };
  }

  private static authHeaders(auth: FeedCredential | null, utf8: boolean): Record<string, string> | undefined {
    if (auth === null) return undefined;
    const h: Record<string, string> = {};
    h['Authorization'] = auth.header(utf8);
    return h;
  }

  static parse(xmlText: string, feedUrl: string): FeedResult | null {
    try {
      // 正常路径在 TaskPool 中解析；只有 TaskPool 调度异常的回落路径会占用 UI 线程。
      // 把耗时打出来是为了能判断"卡"到底出在网络还是解析 —— 一个 1000 集的源
      // 光 htmlToText 就要跑一千遍十来道正则。见 H64 与 ROADMAP 里的后续项。
      const t0 = Date.now();
      const st = new ParseState(feedUrl);
      const buf = new util.TextEncoder().encodeInto(xmlText).buffer as ArrayBuffer;
      const parser = new xml.XmlPullParser(buf, 'utf-8');
      parser.parseXml({
        supportDoctype: true,
        ignoreNameSpace: false,
        tokenValueCallbackFunction: (evt: xml.EventType, info: xml.ParseInfo): boolean => {
          st.onToken(evt, info);
          return true;
        },
        attributeWithTagCallbackFunction: (tagName: string, key: string, value: string): boolean => {
          st.onAttribute(tagName, key, value);
          return true;
        }
      });
      const result = st.finish();
      Log.i('Rss', `解析完成 title="${result.podcast.title}" 集数=${result.episodes.length} `
        + `解析耗时=${Date.now() - t0}ms 字节=${xmlText.length} host=${Http.host(feedUrl)}`);
      // 频道标题不是可用内容。没有任何单集时详情页无东西可播,预检也不能把它标成「可用」。
      if (result.episodes.length === 0) return null;
      return result;
    } catch (e) {
      Log.e('Rss', `解析失败 host=${Http.host(feedUrl)} err=${(e as Error).message}`);
      return null;
    }
  }
}

/// 去掉命名空间前缀并小写,如 `itunes:image` → `image`。
function localName(raw: string): string {
  const n = raw.toLowerCase();
  const i = n.indexOf(':');
  return i >= 0 ? n.substring(i + 1) : n;
}

/**
 * `podcast:transcript` 的取舍等级:**JSON > VTT > SRT**,认不出的格式给 -1(不用)。
 * JSON 排第一是因为那种稿一词一条、**带词级时间**,逐字高亮最准;VTT/SRT 只有句级时间。
 * 与 Android `RssParser.transcriptRank` 同一张表。
 */
function transcriptRank(type: string): number {
  const t = type.toLowerCase();
  if (t.indexOf('json') >= 0) return 3;
  if (t.indexOf('vtt') >= 0) return 2;
  if (t.indexOf('srt') >= 0 || t.indexOf('subrip') >= 0) return 1;
  return -1;
}

/**
 * `podcast:chapters` 的取舍等级。**负数表示不要**。
 *
 * 章节规范只定义了 JSON 一种载体:`application/json+chapters` 是标准写法,不少源写成
 * `application/json`,这两种都收,前者优先。XML 之类的章表本端不解析 ——
 * 宣告"有章节"却点开报错,比根本不出现入口更糟(与 Android `chaptersRank` 同一张表)。
 */
function chaptersRank(type: string): number {
  const t = type.toLowerCase();
  if (t.indexOf('json+chapters') >= 0) return 2;
  if (t.indexOf('json') >= 0) return 1;
  return -1;
}

/// 解析状态机。channel 级与 item 级字段分层,均「首个非空胜出」。
class ParseState {
  private feedUrl: string;

  private channelTitle = '';
  private channelAuthor = '';
  private channelImage = '';
  private channelDesc = '';
  private channelCategory = '';
  private channelFundingUrl = '';
  private channelFundingLabel = '';

  private inItem = false;
  private inImage = false;      // RSS 频道 <image><url> 块
  private iTitle = '';
  private iDesc = '';
  private iAudio = '';
  private iImage = '';
  private iGuid = '';
  private iDate = '';
  private iDur = '';
  /**
   * `podcast:transcript` —— 发布方给的逐字稿。一集可以给**多条**(不同格式/语言),
   * 所以要挑:JSON > VTT > SRT。JSON 排第一是因为那种稿**一词一条,带词级时间**,
   * 逐字高亮最准;VTT/SRT 只有句级时间。
   */
  private iTrUrl = '';
  private iTrType = '';
  private iTrRank = -1;
  /// `podcast:chapters`:只收一条.JSON,按 type 打分取最优(见 `chaptersRank`)
  private iChUrl = '';
  private iChType = '';
  private iChRank = -1;

  private textBuf = '';
  private episodes: Episode[] = [];

  constructor(feedUrl: string) {
    this.feedUrl = feedUrl;
  }

  onToken(evt: xml.EventType, info: xml.ParseInfo): void {
    const full = info.getName().toLowerCase();
    const name = localName(full);
    if (evt === xml.EventType.START_TAG) {
      // 每次 START 清空,避免空元素继承兄弟节点文本
      this.textBuf = '';
      if (name === 'item' || name === 'entry') {
        this.inItem = true;
        this.iTitle = ''; this.iDesc = ''; this.iAudio = '';
        this.iImage = ''; this.iGuid = ''; this.iDate = ''; this.iDur = '';
        this.iTrUrl = ''; this.iTrType = ''; this.iTrRank = -1;
        this.iChUrl = ''; this.iChType = ''; this.iChRank = -1;
      } else if (name === 'image') {
        this.inImage = true;
      }
    } else if (evt === xml.EventType.TEXT || evt === xml.EventType.CDSECT) {
      // CDATA 必须计入:大量中文播客的简介用 CDATA 包裹
      this.textBuf += info.getText();
    } else if (evt === xml.EventType.END_TAG) {
      const text = this.textBuf.trim();
      if (this.inItem) {
        if (name === 'title') {
          if (this.iTitle.length === 0) this.iTitle = text;
        } else if (name === 'description' || name === 'summary' || name === 'encoded') {
          if (this.iDesc.length === 0) this.iDesc = text;
        } else if (name === 'guid' || name === 'id') {
          if (this.iGuid.length === 0) this.iGuid = text;
        } else if (name === 'pubdate' || name === 'published') {
          if (this.iDate.length === 0) this.iDate = text;
        } else if (name === 'duration') {
          if (this.iDur.length === 0) this.iDur = text;
        } else if (name === 'item' || name === 'entry') {
          this.flushItem();
          this.inItem = false;
        }
      } else {
        if (name === 'title') {
          // 防护:channel 的 <image><title> 不能覆盖频道标题(macOS 侧的修正)
          if (this.channelTitle.length === 0 && !this.inImage) this.channelTitle = text;
        } else if (name === 'author') {
          if (this.channelAuthor.length === 0) this.channelAuthor = text;
        } else if (name === 'description' || name === 'summary') {
          if (this.channelDesc.length === 0) this.channelDesc = text;
        } else if (name === 'url') {
          if (this.inImage && this.channelImage.length === 0) this.channelImage = text;
        } else if (name === 'image') {
          this.inImage = false;
        } else if (name === 'funding') {
          if (this.channelFundingLabel.length === 0 && this.channelFundingUrl.length > 0) {
            this.channelFundingLabel = text;
          }
        }
      }
    }
  }

  onAttribute(tagRaw: string, keyRaw: string, value: string): void {
    const tag = localName(tagRaw);
    const key = keyRaw.toLowerCase();
    const v = value.trim();
    if (v.length === 0) return;

    if (tag === 'enclosure') {
      // <enclosure url> 优先级最高,无条件覆盖
      if (this.inItem && key === 'url') this.iAudio = v;
      return;
    }
    if (tag === 'content') {
      // <media:content>:仅在尚无音频且明确是 audio 时采用,避免误取图片
      if (this.inItem && key === 'url' && this.iAudio.length === 0) this.pendingMediaUrl = v;
      if (this.inItem && (key === 'type' || key === 'medium')) {
        if (v.startsWith('audio') || v === 'audio') this.mediaIsAudio = true;
      }
      if (this.inItem && this.iAudio.length === 0 && this.mediaIsAudio && this.pendingMediaUrl.length > 0) {
        this.iAudio = this.pendingMediaUrl;
      }
      return;
    }
    if (tag === 'link') {
      // Atom:<link rel="enclosure" type="audio/..." href="..."/>
      if (!this.inItem || this.iAudio.length > 0) return;
      if (key === 'href') this.pendingLinkHref = v;
      if (key === 'rel' && v === 'enclosure') this.linkIsEnclosure = true;
      if (key === 'type' && v.startsWith('audio')) this.linkIsEnclosure = true;
      if (this.linkIsEnclosure && this.pendingLinkHref.length > 0) this.iAudio = this.pendingLinkHref;
      return;
    }
    if (tag === 'image' && key === 'href') {
      // itunes:image
      if (this.inItem) {
        if (this.iImage.length === 0) this.iImage = v;
      } else if (this.channelImage.length === 0) {
        this.channelImage = v;
      }
      return;
    }
    if (tag === 'category' && key === 'text') {
      if (!this.inItem && this.channelCategory.length === 0) this.channelCategory = v;
      return;
    }
    if (tag === 'funding' && key === 'url') {
      if (!this.inItem && this.channelFundingUrl.length === 0) this.channelFundingUrl = v;
      return;
    }
    if (tag === 'transcript' && this.inItem) {
      // 只有属性的空元素,属性**分多次回调到齐**,所以边攒边评比(同 media:content 的写法)
      if (key === 'url') this.pendingTrUrl = v;
      if (key === 'type') this.pendingTrType = v;
      if (this.pendingTrUrl.length > 0) {
        const rank = transcriptRank(this.pendingTrType);
        // `>=` 而不是 `>`:同一个元素的 url 先到、type 后到时,要允许用同一 url 把等级补上来
        if (rank > this.iTrRank || (rank === this.iTrRank && this.pendingTrUrl === this.iTrUrl)) {
          this.iTrUrl = this.pendingTrUrl;
          this.iTrType = this.pendingTrType;
          this.iTrRank = rank;
        }
      }
      return;
    }
    if (tag === 'chapters' && this.inItem) {
      // 与 transcript 同形:空元素的属性分多次回调,url 先到、type 后到时也要能把等级补上来
      if (key === 'url') this.pendingChUrl = v;
      if (key === 'type') this.pendingChType = v;
      if (this.pendingChUrl.length > 0) {
        const rank = chaptersRank(this.pendingChType);
        if (rank > this.iChRank || (rank === this.iChRank && this.pendingChUrl === this.iChUrl)) {
          this.iChUrl = this.pendingChUrl;
          this.iChType = this.pendingChType;
          this.iChRank = rank;
        }
      }
    }
  }

  // media:content / atom link / podcast:transcript 的属性跨回调到齐,故需暂存
  private pendingMediaUrl = '';
  private mediaIsAudio = false;
  private pendingLinkHref = '';
  private linkIsEnclosure = false;
  private pendingTrUrl = '';
  private pendingTrType = '';
  private pendingChUrl = '';
  private pendingChType = '';

  private flushItem(): void {
    // 仅当拿到音频直链才产出一集(没音频的条目对播放毫无意义)
    if (this.iAudio.length === 0) {
      this.resetPending();
      return;
    }
    const ep: Episode = {
      id: this.iGuid.length > 0 ? this.iGuid : this.iAudio,
      title: this.iTitle,
      description: htmlToText(this.iDesc),
      audioUrl: this.iAudio,
      artworkUrl: this.iImage.length > 0 ? this.iImage : this.channelImage,
      podcastTitle: this.channelTitle,
      durationSec: parseDurationSec(this.iDur),
      pubDate: this.iDate,
      feedUrl: this.feedUrl,
      transcriptUrl: this.iTrUrl,
      transcriptType: this.iTrType,
      chaptersUrl: this.iChUrl,
      chaptersType: this.iChType
    };
    this.episodes.push(ep);
    this.resetPending();
  }

  private resetPending(): void {
    this.pendingMediaUrl = '';
    this.mediaIsAudio = false;
    this.pendingLinkHref = '';
    this.linkIsEnclosure = false;
    this.pendingTrUrl = '';
    this.pendingTrType = '';
    this.pendingChUrl = '';
    this.pendingChType = '';
  }

  finish(): FeedResult {
    const p: Podcast = emptyPodcast();
    p.id = this.feedUrl;
    p.title = this.channelTitle;
    p.author = this.channelAuthor;
    p.artworkUrl = this.channelImage;
    p.feedUrl = this.feedUrl;
    p.description = htmlToText(this.channelDesc);
    p.genre = Genres.key(this.channelCategory);
    p.fundingUrl = this.channelFundingUrl;
    p.fundingLabel = this.channelFundingLabel;
    // 频道封面兜底:channel 无图时用第一集的图
    if (p.artworkUrl.length === 0 && this.episodes.length > 0) {
      p.artworkUrl = this.episodes[0].artworkUrl;
    }
    return { podcast: p, episodes: this.episodes };
  }
}
