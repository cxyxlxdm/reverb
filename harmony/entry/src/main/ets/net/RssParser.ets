import xml from '@ohos.xml';
import util from '@ohos.util';
import { Http } from './Http';
import { Log } from '../util/Logger';
import { htmlToText, parseDurationSec } from '../util/HtmlText';
import { Episode, Podcast, FeedResult, emptyPodcast } from '../model/Models';
import { Genres } from '../model/Genres';

/**
 * 播放核心:解析播客自身的 RSS/Atom,取出频道信息与每集音频直链。
 * 无论用哪个目录发现节目,最终都回到发布方原始 feed —— 版权安全、零成本的正规方式。
 *
 * 移植自 Android `RssParser.kt` 的状态机,但鸿蒙 XmlPullParser 是**回调式(push)**、
 * 且属性由独立回调给出,故结构相应重构;标签名同时匹配「带前缀」与「去前缀」两种形态,
 * 以规避 ignoreNameSpace 语义的不确定性。
 */
export class RssParser {
  static async fetch(feedUrl: string): Promise<FeedResult | null> {
    const text = await Http.text(feedUrl);
    if (text === null) return null;
    return RssParser.parse(text, feedUrl);
  }

  static parse(xmlText: string, feedUrl: string): FeedResult | null {
    try {
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
      Log.i('Rss', `解析完成 title="${result.podcast.title}" 集数=${result.episodes.length} url=${feedUrl}`);
      // 与 macOS 一致:空结果视为失败,让上层继续降级
      if (result.episodes.length === 0 && result.podcast.title.length === 0) return null;
      return result;
    } catch (e) {
      Log.e('Rss', `解析失败 url=${feedUrl} err=${(e as Error).message}`);
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
    }
  }

  // media:content / atom link 的属性跨回调到齐,故需暂存
  private pendingMediaUrl = '';
  private mediaIsAudio = false;
  private pendingLinkHref = '';
  private linkIsEnclosure = false;

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
      feedUrl: this.feedUrl
    };
    this.episodes.push(ep);
    this.resetPending();
  }

  private resetPending(): void {
    this.pendingMediaUrl = '';
    this.mediaIsAudio = false;
    this.pendingLinkHref = '';
    this.linkIsEnclosure = false;
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
