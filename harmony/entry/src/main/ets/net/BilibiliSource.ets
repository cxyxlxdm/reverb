import { Http, J, RedirectProbe } from './Http';
import { Episode, FeedResult, Podcast, emptyPodcast } from '../model/Models';
import { htmlToText } from '../util/HtmlText';
import { Log } from '../util/Logger';

/**
 * 把一段视频当成一集播客来播。与 Android `BilibiliSource.kt` 同一个口径、同一套伪地址,
 * 三端可互相读对方的备份/历史。
 *
 * **不建任何中转**:解析与取流都由设备直连视频站的公开接口完成。这一条是本方案能进本仓库的
 * 前提 —— 它保住"零后端",也让 `docs/PRIVACY.md` 里「不转存或代理节目内容」继续成立。
 *
 * 三条实测结论(2026-10-28,Android 侧匿名请求、无 Cookie;本端接口形状一致):
 *  1. `x/web-interface/view` 与 `x/player/playurl` 都不需要签名、不需要 Cookie。
 *     `x/web-interface/wbi/search/type` 路径里带 `wbi` 但**也不校验签名**,它要的是 Referer(第 3 条)。
 *     ⚠️ **`view` 现在要 Cookie**(2026-10-31 复测,见 H236):不带 `buvid3` 会被风控回
 *     **HTTP 412**,而用户看到的就是「这一集暂时播不了」。见 `ensureCookie`。
 *     ⚠️ 但**搜索反而不能带**:同一天三端同一个出口的对照里,带上就从 20 条变成
 *     `v_voucher` 零条 ⇒ 风控是**按端点分别判的**,别推成一条通则。
 *  2. 直链的 `deadline` 是**请求时刻 + 2 小时** ⇒ **绝不能把直链持久化**。
 *     历史、队列、播放态快照、备份里存的都是 `bilibili://` 伪地址,播放前才解析。
 *  3. ⚠️ **搜索必须带 `Referer: https://www.bilibili.com/`**,缺了会被风控软拦:
 *     回 `code=0` + `data:{"v_voucher": …}` + 零条结果 —— 看起来完全像"没搜到"。
 *     view / playurl 带不带 Referer 都通,但这里**一律带**,省掉逐接口分叉。
 *  4. `dash.audio` 排第一的那条常落在 PCDN 上,同一视频换一轮取链,三条候选的可用性会**互换**
 *     (一轮 #0 通、备份 403;另一轮 #0 直接 503)。所以解析后必须**探活**再交给播放器,
 *     并按游标轮换起点,否则表现是"点了没反应"。
 *  5. 音频流是 `.m4s` 分片 MP4,`Range` 回 206 ⇒ 播放器按普通渐进流处理、拖动可用。
 *  6. ⚠️ **充电专属视频没有 `dash.audio`**:playurl 对它们只回旧的 `durl`(混流
 *     `video/mp4`),`fetchCandidates` 拿到空数组 ⇒ 解析必然失败。而**搜索接口不带任何
 *     标记**(实测两条确认的充电视频:`is_charge_video=0`、`badgepay` / `corner` 全空),
 *     唯一判据是 `view` 的 `data.is_upower_exclusive` ⇒ 只能在搜到之后补一次 view 再筛,
 *     见 `isCharging` 与 H231。
 *
 * ⚠️ `x/space/<mid>/arc/search`(UP 主投稿列表)是整条链路上唯一被风控挡住的部分
 * (`-352` / `-412` / `-799`),所以**「订阅 UP 主」不做**(2026-10-28 拍板)。这里没有
 * 任何代码去碰它 —— 别再顺手加回来。
 *
 * 本端与 Android 唯一的实现差异在**短链跟随**:Android 读 `Location` 头,本端走
 * `Http.redirectProbe`,两种系统行为(自动跟随 / 不跟随)都兜住,见 `bvidOf`。
 */
export class BilibiliSource {
  private static readonly SCHEME: string = 'bilibili';
  private static readonly API: string = 'https://api.bilibili.com/x';
  private static readonly REFERER: string = 'https://www.bilibili.com/';
  /// ⚠️ **这一串是两个相反约束的交点,不是随便挑的**(2026-10-28 同一台机器逐组实测):
  ///  - **搜索接口**要"像移动端":桌面 Chrome 串 ⇒ `code=0` + `v_voucher` + **零条**
  ///    (软拦,看起来像"没搜到");iPhone / Android 串 ⇒ 20 条。两次重测都稳定复现。
  ///  - **取流(CDN)**反过来不要 `Android`:UA 含 `Android` ⇒ 三条候选**全 403**;
  ///    iPhone / 桌面串 ⇒ 全 206。两边都还必须带 `Referer`,缺了同样 403。
  /// ⇒ **只有 iPhone 串两头都过**。本端曾照抄 Android 那串(含 `Android`),症状是
  /// 探活三条全灭(`all candidates probe failed`)、播放器拿到 403 响应体后报
  /// `Unsupported Format: CONTAINER_ERR` —— 一个和真因(UA)完全无关的错误名。
  private static readonly UA_BROWSER: string =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 ' +
      '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
  private static readonly BV_RE: RegExp = new RegExp('BV[0-9A-Za-z]{10}');
  /**
   * 标题强相关过滤的停用词。搜「怎么做一个播客」时,「怎么/做一个」不承担检索语义,
   * 留着会把 2 字片段切碎(见 [isTitleRelevant])。长的放前面,避免短词先把长词拆坏。
   */
  private static readonly RELEVANCE_STOP_WORDS: string[] = [
    '以及', '怎么', '如何', '为什么', '什么', '居然', '竟然', '原来是', '居然是',
    '的', '了', '也', '都', '是', '在', '与', '和', '或', '并', '而', '及', '啊', '呀', '吧', '呢', '吗'
  ];

  /** 去掉停用词、空白、标点与符号,只留字母/数字(含汉字),再转小写。 */
  private static relevanceKey(raw: string): string {
    let s = raw.toLowerCase();
    for (let i = 0; i < BilibiliSource.RELEVANCE_STOP_WORDS.length; i++) {
      s = s.split(BilibiliSource.RELEVANCE_STOP_WORDS[i]).join('');
    }
    let out = '';
    for (let i = 0; i < s.length; i++) {
      const c = s.charAt(i);
      if (/[0-9a-z\u4e00-\u9fff]/.test(c)) out += c;
    }
    return out;
  }

  /**
   * 标题是否与关键词强相关。
   *
   * 为什么需要这一层:B 站搜索是**模糊匹配**,`title` / `description` / `tag` 任一处命中
   * 都会返回;短词或泛词(「播客」「美食教程」「学习资料」)的返回里因此混着大量标题
   * 与关键词无关的视频,用户看起来就是「搜索结果掺了推荐流」。2026-11-04 用真实接口
   * 复测:20 条里标题命中关键词的只有 8~13 条。
   *
   * 规则借自 `houliabc/bilibili-search-purify` 的 strict match,但**只借最保守的一条**:
   * 清洗后整词包含,或关键词的任意 2 字连续片段出现在标题里,就算相关。
   * 该项目的黑名单词库(擦边 / 标题党)是主观词表,不适合塞进客户端,没有采用。
   *
   * 2 字片段是「美食教程」还能留下「家常菜做法」这类近义标题的折中;整词命中要求
   * 太严会把语义相近的结果全删掉。**全删空时调用方要退回原列表**(见 [searchEpisodes]),
   * 宁可留杂音也不要给用户一屏空白。
   */
  private static isTitleRelevant(title: string, keyword: string): boolean {
    const k = BilibiliSource.relevanceKey(keyword);
    if (k.length === 0) return true;
    const t = BilibiliSource.relevanceKey(title);
    if (t.indexOf(k) >= 0) return true;
    if (k.length >= 2) {
      for (let i = 0; i <= k.length - 2; i++) {
        if (t.indexOf(k.substring(i, i + 2)) >= 0) return true;
      }
    }
    return false;
  }

  /// 接口超时。比 Http 默认的 20s 短:这一串请求挡在"点播放"与出声之间,
  /// 超时该判失败让用户重试,而不是让播放页转 20 秒。
  private static readonly API_TIMEOUT_MS: number = 10000;
  private static readonly PROBE_TIMEOUT_MS: number = 8000;
  /// 见 [getJson]:只有**快于这个数**的失败才补一次。慢失败(真超时)重试等于把等待翻倍。
  private static readonly RETRY_FAST_MS: number = 3000;
  private static readonly RETRY_DELAY_MS: number = 400;

  private static headers(): Record<string, string> {
    return { 'User-Agent': BilibiliSource.UA_BROWSER, 'Referer': BilibiliSource.REFERER };
  }

  /**
   * 取流(播放/缓存)要带的那一份头。与接口头**必须是同一套** —— CDN 认 UA + `Referer`,
   * 缺一个就 403;UA 含 `Android` 也全 403(矩阵见 `UA_BROWSER` 的注释)。
   * 播放器若不带这份头,拿到的就是 403 响应体,而 `AVPlayer` 把它报成 `CONTAINER_ERR` ——
   * 一个和真因完全无关的错误名。
   */
  static streamHeaders(): Record<string, string> {
    return BilibiliSource.headers();
  }

  /** 一次解析出来的候选流地址 + 它的失效时刻(毫秒)。只在内存里,不落盘。 */
  private tracks: Map<string, Track> = new Map<string, Track>();
  /** 每集下次从第几个候选开始试。重试(换一个 503 的 PCDN 节点)靠它生效。 */
  private cursor: Map<string, number> = new Map<string, number>();
  /**
   * bvid → 是不是「充电专属」。只缓存**判定了的**结论(取不到就放行、不落缓存),
   * 只在内存里、有上限 —— 它是搜索结果过滤的中间结果,不是持久数据。见 H231。
   */
  private charging: Map<string, boolean> = new Map<string, boolean>();

  /**
   * `view` 要带的 `buvid3` / `buvid4`。见 [ensureCookie] 与 H236。
   *
   * 只放内存、不落盘:进程重启后换一个新的没有任何副作用,而落盘会白白在用户设备上
   * 留一个用不上的标识。
   */
  private cookie: string = '';
  /** 正在取 Cookie 的那一次请求。搜索一进来就是 20 条并发的 `isCharging`,不合并就会发 20 次 spi。 */
  private cookieFetching: Promise<string> | null = null;

  // ---------------------------------------------------------------- 伪地址

  /// 这一集是不是需要播放前解析。三端同口径(Android / macOS 用同一个前缀判断)。
  static isPseudo(url: string): boolean {
    return url.startsWith('bilibili://');
  }

  static audioUri(bvid: string, cid: number): string {
    return `bilibili://audio/${bvid}/${cid}`;
  }

  static videoUri(bvid: string): string {
    return `bilibili://video/${bvid}`;
  }

  /**
   * 用户输入看起来是不是「某一条视频」。
   *
   * 单认 BV 号就够:分享文案里的完整链接、`?p=` 参数、`b23.tv` 短链后面都藏着它。
   * 这是**廉价的字符串判断**,所以可以放在搜索框的同步路径上;真正的网络动作在 `resolveInput`。
   */
  static looksLikeVideo(input: string): boolean {
    return BilibiliSource.BV_RE.test(input) || input.indexOf('b23.tv') >= 0
      || input.indexOf('bili2233.cn') >= 0;
  }

  /// `bilibili://video/<bvid>` → bvid;不是这个形态就空串。
  static videoIdOf(feedUrl: string): string {
    const prefix = 'bilibili://video/';
    if (!feedUrl.startsWith(prefix)) return '';
    return feedUrl.substring(prefix.length).trim();
  }

  /// `bilibili://audio/<bvid>/<cid>` → (bvid, cid)。形态不对回 null。
  static parseAudioUri(url: string): AudioRef | null {
    const prefix = 'bilibili://audio/';
    if (!url.startsWith(prefix)) return null;
    const parts = url.substring(prefix.length).split('/');
    if (parts.length !== 2) return null;
    const cid = parseInt(parts[1], 10);
    if (isNaN(cid) || cid <= 0) return null;
    return new AudioRef(parts[0], cid);
  }

  // ---------------------------------------------------------------- 粘链接

  /**
   * 用户在搜索框里贴了一个视频地址(或干脆只贴了 BV 号)。
   *
   * 认三种形态:BV 号本体、`bilibili.com/video/BV…`(可带 `?p=`)、`b23.tv` 短链。
   * 短链要**跟随一次跳转**才能拿到 BV —— 不跟随的话用户看到的是"没搜到",
   * 而分享出来最常见的正是短链形态。
   */
  async resolveInput(input: string): Promise<FeedResult | null> {
    const q = input.trim();
    if (q.length === 0) return null;
    const bvid = await this.bvidOf(q);
    if (bvid.length === 0) return null;
    const result = await this.view(bvid);
    if (result !== null) Log.i('Bilibili', `resolve ok parts=${result.episodes.length}`);
    return result;
  }

  private async bvidOf(input: string): Promise<string> {
    const direct = input.match(BilibiliSource.BV_RE);
    if (direct !== null) return direct[0];
    // 短链只认 b23.tv / bili2233.cn 这两种;别的短链不猜,免得把无关 URL 当视频解析。
    if (input.indexOf('b23.tv') < 0 && input.indexOf('bili2233.cn') < 0) return '';
    const probe: RedirectProbe = await Http.redirectProbe(input, BilibiliSource.headers());
    // 自动跟随了跳转 ⇒ 头里没有 Location,要落到正文里找;没跟随 ⇒ 正文是空的、头里有。
    // 两处都找一遍,顺序无所谓(只有一个会有)。
    const fromHead = probe.head.match(BilibiliSource.BV_RE);
    if (fromHead !== null) return fromHead[0];
    const fromBody = probe.body.match(BilibiliSource.BV_RE);
    if (fromBody !== null) return fromBody[0];
    Log.w('Bilibili', `短链未取到 BV code=${probe.code}`);
    return '';
  }

  /**
   * 频道页的入口:`bilibili://video/<bvid>` → `FeedResult`。
   *
   * 与 `resolveInput` 的唯一区别是入参形态 —— 一个是用户贴的原文,一个是上一次已经归一过的
   * 伪地址。分 P、封面、作者都重新取一次:标题改了、视频被删了,这里要跟着变。
   */
  async feedOf(feedUrl: string): Promise<FeedResult | null> {
    const bvid = BilibiliSource.videoIdOf(feedUrl);
    if (bvid.length === 0) return null;
    return await this.view(bvid);
  }

  /**
   * bvid → 频道元信息 + 全部分 P。
   *
   * 单 P 视频就是"一集";多 P 把每一 P 拆成一集(各有自己的 cid,而 playurl 按 cid 取)。
   * 合集(season)不做 —— 那要 space 接口,见类注释。
   */
  async view(bvid: string): Promise<FeedResult | null> {
    const root = await this.getJson(`${BilibiliSource.API}/web-interface/view?bvid=${bvid}`, true);
    const data = J.obj(root, 'data');
    if (data === null) {
      Log.w('Bilibili', `view failed bvid=${bvid}`);
      return null;
    }
    // 充电专属视频没有可播的音频流:playurl 对它们只回旧的 `durl`(混流 video/mp4),
    // `dash.audio` 是空的 ⇒ 播放必然失败。放它进来只会变成"播放条切走了、报错、
    // 重试也不会好"。频道页、粘贴链接、以及搜索结果点播放的兜底(见 `resolvePlayback`)
    // 都从这里过 ⇒ 这是唯一需要设闸的地方。见 H231。
    if (J.bool(data, 'is_upower_exclusive')) {
      this.charging.set(bvid, true);
      Log.w('Bilibili', `view skip charging bvid=${bvid}`);
      return null;
    }
    const title = J.str(data, 'title');
    const owner = J.obj(data, 'owner');
    const upName = J.str(owner, 'name');
    const cover = https(J.str(data, 'pic'));
    const desc = htmlToText(J.str(data, 'desc'));
    const pubDate = dateOf(J.num(data, 'pubdate'));

    const podcast: Podcast = emptyPodcast();
    podcast.id = `bilibili:${bvid}`;
    podcast.title = title;
    // 作者位写 UP 名。列表里同名频道很多,没有这一格用户分不清"这是一集播客"还是"这是一段视频";
    // 平台标记在应用内可以明写(商店文案那一侧不出现平台名,见 CHANGELOG 口径)。
    podcast.author = upName;
    podcast.artworkUrl = cover;
    podcast.feedUrl = BilibiliSource.videoUri(bvid);
    podcast.description = desc;

    const episodes: Episode[] = [];
    const pages = J.arr(data, 'pages');
    if (pages.length === 0) {
      // 兜底:老接口理论上总给 pages,真没有就按单集处理(cid 取 data.cid)
      const cid = J.num(data, 'cid');
      if (cid > 0) {
        episodes.push(this.episode(bvid, cid, title, desc, cover, upName,
          J.num(data, 'duration'), pubDate));
      }
    } else {
      for (let i = 0; i < pages.length; i++) {
        const p = J.asObj(pages[i]);
        if (p === null) continue;
        const cid = J.num(p, 'cid');
        if (cid <= 0) continue;
        const part = J.str(p, 'part').trim();
        const page = J.num(p, 'page') > 0 ? J.num(p, 'page') : i + 1;
        // 单 P 视频不给自己加「P1」前缀:那会让播放页标题与用户在视频站看到的不一样。
        const epTitle = pages.length === 1 ? title : (part.length > 0 ? part : `P${page}`);
        episodes.push(this.episode(bvid, cid, epTitle, desc, cover, upName,
          J.num(p, 'duration'), pubDate));
      }
    }
    if (episodes.length === 0) {
      Log.w('Bilibili', `view no playable cid bvid=${bvid}`);
      return null;
    }
    Log.i('Bilibili', `view ok parts=${episodes.length}`);
    return { podcast: podcast, episodes: episodes };
  }

  private episode(bvid: string, cid: number, title: string, desc: string, cover: string,
    upName: string, durationSec: number, pubDate: string): Episode {
    return {
      id: `bilibili:${bvid}:${cid}`,
      title: title,
      description: desc,
      audioUrl: BilibiliSource.audioUri(bvid, cid),
      artworkUrl: cover,
      podcastTitle: upName,
      durationSec: durationSec,
      pubDate: pubDate,
      feedUrl: BilibiliSource.videoUri(bvid),
      transcriptUrl: '',
      transcriptType: ''
    };
  }

  // ---------------------------------------------------------------- 关键词搜单集

  /**
   * 搜"单集",不搜频道。路径带 `wbi` 但实测免签(类注释第 1 条)—— 别看到路径名就去
   * 实现签名,那是原始调研里最贵的一块,而且并不需要。
   *
   * 结果天然是视频粒度,正好对上"单集";每个视频各自成一个 `bilibili://video/<bvid>` 频道,
   * 进频道页会重新取元信息(见 `PodcastRepository.feed`)。
   */
  async searchEpisodes(keyword: string, page: number = 1): Promise<Episode[]> {
    const kw = keyword.trim();
    if (kw.length === 0) return [];
    const url = `${BilibiliSource.API}/web-interface/wbi/search/type?search_type=video` +
      `&keyword=${Http.encode(kw)}&page=${page}&page_size=20`;
    const root = await this.getJson(url);
    const data = J.obj(root, 'data');
    const arr = J.arr(data, 'result');
    if (arr.length === 0) {
      // 风控软拦的指纹是 `v_voucher`(code 仍是 0,没有 result)。单独报一句,否则日志里
      // 只剩 "search failed",下一个人会去怀疑关键词或网络(见类注释第 3 条)。
      if (data !== null && data['v_voucher'] !== undefined) {
        Log.w('Bilibili', 'search soft-blocked (v_voucher) — 检查 Referer(且确认这里没带 Cookie)');
      } else {
        Log.w('Bilibili', 'search failed');
      }
      return [];
    }
    const out: Episode[] = [];
    const bvids: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const bvid = J.str(o, 'bvid');
      if (bvid.length === 0) continue;
      const author = htmlToText(J.str(o, 'author'));
      bvids.push(bvid);
      out.push({
        // 搜索结果是"一个视频",分 P 要等进频道页才知道 ⇒ id 先用 bvid 占位。
        // 播放路径不靠 id 认视频(它解析 audioUrl),所以这个 id 稳定就够;但它与频道页的
        // `bilibili:<bvid>:<cid>` **不是同一个 id** —— 同一视频两个入口各播一次会留两条历史、
        // 两份缓存(见 H226 教训④与 ROADMAP 技术债)。
        id: `bilibili:search:${bvid}`,
        title: htmlToText(J.str(o, 'title')),
        description: htmlToText(J.str(o, 'description')),
        // 搜索结果里没有 cid,**这里刻意不给可播地址**:构造一个假 cid 会让播放请求打到
        // 别人那一集。用户点进频道页拿到的才是真 cid —— 真在这里点播放,由
        // `resolvePlayback` 自己补一次 view(见那里)。
        audioUrl: BilibiliSource.videoUri(bvid),
        artworkUrl: https(J.str(o, 'pic')),
        podcastTitle: author,
        // ⚠️ 多 P 视频这个数是**整条视频的总和**(实测 `BV1MN4dewEQZ`:26 个 P,这里回
        // `457:6` = 27426 秒),而点开播放只给 P1(1127 秒)。搜索接口没有任何字段能
        // 分辨多 P(`episode_count_text` 对它们也是空),所以列表这一行只能照它显示;
        // 真值的纠正发生在解析处 —— `resolvePlayback` 会把那个 cid 的时长带回来
        // 覆盖掉它(见 `ResolvedStream`)。
        durationSec: hhmmToSec(J.str(o, 'duration')),
        pubDate: dateOf(J.num(o, 'pubdate')),
        feedUrl: BilibiliSource.videoUri(bvid),
        transcriptUrl: '',
        transcriptType: ''
      });
    }
    // 先按标题相关性剔掉模糊命中的无关条目(见 [isTitleRelevant])。放在充电判定**之前**:
    // 既让用户看到的列表干净,也把逐条 `view` 请求从 20 个降到实际候选数。
    // 全滤空时退回原列表 —— 语义搜索(标题不含任何关键词片段)宁可留杂音也不白屏。
    const relevantIdx: number[] = [];
    for (let i = 0; i < out.length; i++) {
      if (BilibiliSource.isTitleRelevant(out[i].title, kw)) relevantIdx.push(i);
    }
    const droppedIrrelevant = relevantIdx.length === 0 ? 0 : out.length - relevantIdx.length;
    const allIdx: number[] = [];
    for (let i = 0; i < out.length; i++) allIdx.push(i);
    const poolIdx: number[] = relevantIdx.length === 0 ? allIdx : relevantIdx;
    // 充电专属视频要在这里就剔掉(见类注释第 6 条):用户点它只会看到播放条切走、
    // 然后「播放失败」,而重试永远不会成功 —— 看起来完全是播放器的 bug。
    // 搜索接口不带判据,只能逐条补一次 view(`isCharging` 有内存缓存,同一视频不重复问)。
    // 并发发、顺序收:20 条约 0.5 s,实测没有触发风控;一条失败就放行,不误删正常视频。
    const flags: boolean[] = await Promise.all(
      poolIdx.map((i: number): Promise<boolean> => this.isCharging(bvids[i])));
    const kept: Episode[] = [];
    for (let j = 0; j < poolIdx.length; j++) if (!flags[j]) kept.push(out[poolIdx[j]]);
    const dropped = poolIdx.length - kept.length;
    Log.i('Bilibili',
      `search count=${kept.length}` +
      (droppedIrrelevant > 0 ? ` dropped_irrelevant=${droppedIrrelevant}` : '') +
      (dropped > 0 ? ` dropped_charge=${dropped}` : ''));
    return kept;
  }

  /**
   * 这条视频是不是「充电专属」(UP 主设了付费门槛)。见类注释第 6 条与 H231。
   *
   * 只认 `view` 的 `data.is_upower_exclusive`:搜索接口对这类视频**不带任何标记**
   * (实测 `is_charge_video` 恒 0,`badgepay` / `corner` 全空)。
   *
   * 取不到一律返回 false(**放行**):一次超时或风控不该把一条正常视频从结果里抹掉;
   * 漏过滤的代价只是回到修之前那个「切条 + 报错」,可看见、可重试。只缓存判定出来的结论。
   */
  private async isCharging(bvid: string): Promise<boolean> {
    const cached = this.charging.get(bvid);
    if (cached !== undefined) return cached;
    const data = J.obj(await this.getJson(
      `${BilibiliSource.API}/web-interface/view?bvid=${bvid}`, true), 'data');
    if (data === null) return false;
    const exclusive = J.bool(data, 'is_upower_exclusive');
    // 条目本身很小(bvid + 一个布尔),但搜索是长期入口:不设上限迟早堆起来。
    if (this.charging.size > 512) this.charging.clear();
    this.charging.set(bvid, exclusive);
    return exclusive;
  }

  // ---------------------------------------------------------------- 播放前解析

  /**
   * `bilibili://audio/<bvid>/<cid>` → 一条**已经探通**的音频直链 + 这一 P 的真实时长;
   * 失败回 null。
   *
   * 失败不在这里重试:播放器的重投由 `PlayerController` 统一管,两处各自重试会变成
   * "用户在等,两边都在等"。
   */
  async resolvePlayback(audioUrl: string): Promise<ResolvedStream | null> {
    // 搜索结果的 audioUrl 是 `bilibili://video/<bvid>`(那时还拿不到 cid)。用户直接在
    // 搜索结果里点播放走的就是这条 —— 这里必须自己补一次 view,否则表现是
    // "搜索结果点播放永远失败",而列表看起来完全正常。
    //
    // 顺带接住 view 里那条**准确的**分 P 时长:搜索给多 P 视频的是整条总和,见 `ResolvedStream`。
    let hint = 0;
    let ref = BilibiliSource.parseAudioUri(audioUrl);
    if (ref === null) {
      const id = BilibiliSource.videoIdOf(audioUrl);
      if (id.length === 0) return null;
      const feed = await this.view(id);
      if (feed === null || feed.episodes.length === 0) return null;
      hint = feed.episodes[0].durationSec;
      ref = BilibiliSource.parseAudioUri(feed.episodes[0].audioUrl);
      if (ref === null) return null;
    }
    const bvid = ref.bvid;
    const cid = ref.cid;
    const key = `${bvid}:${cid}`;
    const now = Date.now();
    let urls: string[] = [];
    let fetchedDuration = 0;
    const cached = this.tracks.get(key);
    if (cached !== undefined && cached.expiresAt > now) {
      urls = cached.urls;
      fetchedDuration = cached.durationSec;
    } else {
      const found = await this.fetchCandidates(bvid, cid);
      if (found === null) {
        Log.w('Bilibili', `resolve failed bvid=${bvid} cid=${cid}`);
        return null;
      }
      urls = found.urls;
      fetchedDuration = found.durationSec;
      this.tracks.set(key, new Track(found.urls, found.expiresAt, found.durationSec));
      // 缓存条数不设上限没有意义:只有正在听的那几集才可能被重试,而条目本身很小。
      if (this.tracks.size > 64) this.tracks.clear();
      Log.i('Bilibili',
        `resolve candidates=${found.urls.length} ttlMin=${Math.round((found.expiresAt - now) / 60000)}`);
    }
    // 直链接口没给时长时退到 view 那条(它同样是"这一 P"的口径);都没有就留 0,
    // 由调用方保留原元数据 —— 不猜。
    const durationSec = fetchedDuration > 0 ? fetchedDuration : hint;

    // 从游标处开始**逐个探通**:排第一的 PCDN 节点会回 503(类注释第 4 条)。
    // 探测只用 1 字节 Range,代价一次 RTT;不探的代价是用户点开一集没反应。
    //
    // 每个候选的码都打出来(三端同口径,见 H225):只记「全失败」时,探针本身坏掉
    // 与节点真的不给流在日志里长得一样。
    const start = (this.cursor.get(key) ?? 0) % urls.length;
    this.cursor.set(key, (start + 1) % urls.length);
    const codes: number[] = [];
    for (let i = 0; i < urls.length; i++) {
      const candidate = urls[(start + i) % urls.length];
      const code = await this.probe(candidate);
      codes.push(code);
      if (code === 200 || code === 206) {
        Log.i('Bilibili', `probe ok #${i} code=${code}${i > 0 ? ' fell back' : ''}`);
        return { url: candidate, durationSec: durationSec };
      }
      Log.w('Bilibili', `probe #${i} code=${code}`);
    }
    // 全部探不通也让第一条去试:探测本身可能被网络抖动误伤,而播放器至少还会走一次
    // 自动重投(见 PlayerController 的重试口径)。
    Log.w('Bilibili', `all candidates probe failed, using #0 codes=${JSON.stringify(codes)}`);
    return urls.length > 0 ? { url: urls[0], durationSec: durationSec } : null;
  }

  private async fetchCandidates(bvid: string, cid: number): Promise<Candidates | null> {
    const url = `${BilibiliSource.API}/player/playurl?bvid=${bvid}&cid=${cid}&fnval=16&fnver=0&fourk=0`;
    const data = J.obj(await this.getJson(url), 'data');
    if (data === null) return null;
    const audio = J.arr(J.obj(data, 'dash'), 'audio');
    if (audio.length === 0) return null;
    // 取码率最高的一条。匿名也能拿到全部三档(30216/30232/30280),所以"匿名只有默认码率"
    // 那条调研结论在本端不成立。
    let best: Record<string, Object> | null = null;
    for (let i = 0; i < audio.length; i++) {
      const o = J.asObj(audio[i]);
      if (o === null) continue;
      if (best === null || J.num(o, 'bandwidth') > J.num(best, 'bandwidth')) best = o;
    }
    if (best === null) return null;
    const urls: string[] = [];
    const base = J.str(best, 'baseUrl');
    if (base.length > 0) urls.push(base);
    const backups = J.arr(best, 'backupUrl');
    for (let i = 0; i < backups.length; i++) {
      const b = J.asStr(backups[i]);
      if (b.length > 0) urls.push(b);
    }
    if (urls.length === 0) return null;
    // 这一段(这个 cid)的真实时长:`dash.duration` 秒 / `timelength` 毫秒,实测一致
    // (`BV1MN4dewEQZ` P1:1127 / 1126143)。优先取秒,免得四舍五入。
    const dashSec = J.num(J.obj(data, 'dash'), 'duration');
    const durationSec = dashSec > 0 ? dashSec : Math.floor(J.num(data, 'timelength') / 1000);
    return new Candidates(urls, expiryOf(urls[0]), durationSec);
  }

  /**
   * 1 字节 Range 探活。只认 200/206 —— 503/403 都说明这个节点这会儿不给流。
   * 回状态码而不是 boolean:日志里要能看见码(见 H225)。
   */
  private async probe(url: string): Promise<number> {
    return await Http.probeCode(url, {
      'User-Agent': BilibiliSource.UA_BROWSER,
      'Referer': BilibiliSource.REFERER,
      'Range': 'bytes=0-0'
    }, BilibiliSource.PROBE_TIMEOUT_MS);
  }

  // ---------------------------------------------------------------- 底层

  /**
   * 取一次 `buvid3` / `buvid4` 并留在 [cookie] 里。**这是 `view` 现在能不能用的前置条件**(H236)。
   *
   * 2026-10-31 的现场:装了最新包的手机点开一集,`view` 回 **HTTP 412**,界面上就是
   * 「这一集暂时播不了」,而同一条视频几秒后又能成功 ⇒ 不是视频坏了,是接口在被风控。
   * 同一台手机、同一个出口的受控实验(只换请求头):UA 换成 Chrome / iPhone 都不改变结论,
   * **带不带 `buvid3`/`buvid4` 才改变** —— 不带 412,带上 200。
   * `x/frontend/finger/spi` 自己不拦匿名请求(实测 200),所以先取它、再拿回下发的值当 Cookie。
   *
   * ⚠️ **只给 `view` 带,别给搜索带**:Android 那边的第一版是"一律带",结果搜索当场变成
   * `v_voucher` 软拦、零条;同一台手机上的 curl / Chrome 用同一组头却是 20 条。
   * 判据是**端点**,不是"顺手"。
   *
   * 失败(超时 / 接口变了)回空串,调用方照旧不带 Cookie 发,让真正的失败原因露出来。
   */
  private async ensureCookie(): Promise<string> {
    if (this.cookie.length > 0) return this.cookie;
    if (this.cookieFetching !== null) return await this.cookieFetching;
    this.cookieFetching = this.fetchCookie();
    try {
      return await this.cookieFetching;
    } finally {
      this.cookieFetching = null;
    }
  }

  private async fetchCookie(): Promise<string> {
    const root = await Http.json(
      `${BilibiliSource.API}/frontend/finger/spi`,
      BilibiliSource.API_TIMEOUT_MS, BilibiliSource.headers());
    if (root === null) return '';
    const data = J.obj(root, 'data');
    if (data === null) return '';
    const b3 = J.str(data, 'b_3');
    const b4 = J.str(data, 'b_4');
    if (b3.length === 0) return '';
    this.cookie = b4.length === 0 ? `buvid3=${b3}` : `buvid3=${b3}; buvid4=${b4}`;
    return this.cookie;
  }

  /** 接口头。`withCookie` 只在 `view` 打开 —— 搜索带上它反而被软拦(见 [ensureCookie])。 */
  private async apiHeaders(withCookie: boolean): Promise<Record<string, string>> {
    const h = BilibiliSource.headers();
    if (!withCookie) return h;
    const c = await this.ensureCookie();
    if (c.length === 0) return h;
    h['Cookie'] = c;
    return h;
  }

  /**
   * 接口族的统一 GET。**网络层快速失败补一次**(见 H233)。
   *
   * 2026-10-31 的现场:队列里唯一一集,`view` 在 **14ms / 17ms** 里被网络栈拒掉,
   * H232 又已经把"解析失败"改成不提交、只提示一句 ⇒ 用户看到的是「这一集暂时播不了」,
   * 点几次几次播不了;而同一个 bvid 几分钟后正常起播(406 秒)。
   * 一次瞬时拒连不该被判成永久失败,所以这里补一次。
   *
   * 三个边界:
   *  - **只在快失败时补**:超过 [RETRY_FAST_MS] 的失败通常是真的超时,再等一轮只会把
   *    播放页的转圈翻倍;
   *  - **`code≠0` 不补**:那是接口在说话(下架 / 风控),再来一次不会变,反而可能加重风控;
   *  - 补的这一次**也**走 [API_TIMEOUT_MS],总等待上限约 20 秒,由调用方的 generation
   *    判据兜住"用户已经切走了"那种情况。
   */
  private async getJson(url: string, withCookie: boolean = false): Promise<Record<string, Object> | null> {
    let root: Record<string, Object> | null = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      const startedAt = Date.now();
      const headers = await this.apiHeaders(withCookie);
      root = await Http.json(url, BilibiliSource.API_TIMEOUT_MS, headers);
      if (root !== null) {
        const code = J.num(root, 'code');
        if (code !== 0) {
          Log.w('Bilibili', `api code=${code} msg='${J.str(root, 'message')}'`);
          return null;
        }
        return root;
      }
      const elapsed = Date.now() - startedAt;
      if (attempt === 1 || elapsed >= BilibiliSource.RETRY_FAST_MS) return null;
      Log.w('Bilibili', `retry after fast failure elapsed=${elapsed}ms endpoint=${Log.endpoint(url)}`);
      await sleep(BilibiliSource.RETRY_DELAY_MS);
    }
    return null;
  }
}

/** `bilibili://audio/<bvid>/<cid>` 拆出来的两段。 */
class AudioRef {
  readonly bvid: string;
  readonly cid: number;

  constructor(bvid: string, cid: number) {
    this.bvid = bvid;
    this.cid = cid;
  }
}

class Track {
  readonly urls: string[];
  readonly expiresAt: number;
  readonly durationSec: number;

  constructor(urls: string[], expiresAt: number, durationSec: number) {
    this.urls = urls;
    this.expiresAt = expiresAt;
    this.durationSec = durationSec;
  }
}

class Candidates {
  readonly urls: string[];
  readonly expiresAt: number;
  readonly durationSec: number;

  constructor(urls: string[], expiresAt: number, durationSec: number) {
    this.urls = urls;
    this.expiresAt = expiresAt;
    this.durationSec = durationSec;
  }
}

/**
 * 一次解析的结果:探通的直链 + **这一 P 的真实时长(秒)**。
 *
 * 为什么要把时长一起带出来:搜索接口给的 `duration` 对**多 P 视频是整条视频的总和**
 * (实测 `BV1MN4dewEQZ`:26 个 P,搜索回 `457:6` = 27426 秒),而播放这一路只解析
 * **P1**(1127 秒)。这个数还进历史行、进批注的位置上限。`playurl` 的 `dash.duration`
 * (秒)/ `timelength`(毫秒)给的正是**这个 cid** 的长度。见 H226。
 */
export interface ResolvedStream {
  url: string;
  durationSec: number;
}

/**
 * 直链里的 `deadline`(十进制 epoch 秒)就是失效时刻。解析不出来时按"1.5 小时后"保守估;
 * 解析出来也要**提前 5 分钟作废** —— 拿着一条还剩 20 秒的链接去起播,等于必然失败一次。
 */
function expiryOf(url: string): number {
  const now = Date.now();
  const at = url.indexOf('deadline=');
  if (at < 0) return now + 90 * 60 * 1000;
  const tail = url.substring(at + 'deadline='.length);
  const end = tail.indexOf('&');
  const raw = end < 0 ? tail : tail.substring(0, end);
  const sec = parseInt(raw, 10);
  if (isNaN(sec)) return now + 90 * 60 * 1000;
  const expireAt = sec * 1000;
  return expireAt - now > 10 * 60 * 1000 ? expireAt - 5 * 60 * 1000 : now + 60 * 1000;
}

/** 封面/头像是 `http://` 或协议相对的 `//host/…`,统一升 https:明文在两端都会被拦。 */
function https(url: string): string {
  if (url.startsWith('//')) return `https:${url}`;
  if (url.startsWith('http://')) return `https://${url.substring('http://'.length)}`;
  return url;
}

/// 搜索结果里的时长是 `mm:ss`(超过一小时会变成 `hh:mm:ss`,那时直接放弃,回 0)。
const HHMM_RE: RegExp = new RegExp('^(\\d+):(\\d+)$');

function hhmmToSec(raw: string): number {
  const m = raw.trim().match(HHMM_RE);
  return m === null ? 0 : parseInt(m[1], 10) * 60 + parseInt(m[2], 10);
}

/** epoch 秒 → `yyyy-MM-dd`(本机时区)。0 / 非法值回空串。 */
function dateOf(epochSec: number): string {
  if (epochSec <= 0) return '';
  const d = new Date(epochSec * 1000);
  const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 重试前的等待(见 [BilibiliSource.getJson])。ArkTS 没有现成的 sleep。
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => { resolve(); }, ms);
  });
}
