import type common from '@ohos.app.ability.common';
import i18n from '@ohos.i18n';
import { Prefs } from './store/Prefs';
import { JsonFile } from './store/JsonFile';
import { SettingsStore } from './store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore, PopularCacheStore } from './store/Stores';
import { StationStore } from './store/StationStore';
import { InboxStore } from './store/InboxStore';
import { SeedCatalog } from './store/SeedCatalog';
import { FeedCacheStore } from './store/FeedCacheStore';
import { GuideEpisode } from './store/GuideEpisode';
import { ListenStatsStore } from './store/ListenStatsStore';
import { DownloadStore } from './store/DownloadStore';
import { AudioCacheStore } from './store/AudioCacheStore';
import { ArtworkCache } from './store/ArtworkCache';
import { StampStore } from './store/StampStore';
import { NoteStore } from './store/NoteStore';
import { PlaybackStateStore } from './store/PlaybackStateStore';
import { CategoryStore } from './store/CategoryStore';
import { TranscriptStore } from './store/TranscriptStore';
import { ChapterStore } from './store/ChapterStore';
import { WidgetUpdater } from './widget/WidgetUpdater';
import { SpeechTranscriber } from './playback/SpeechTranscriber';
import { SenseVoiceTranscriber } from './playback/asr/SenseVoiceTranscriber';
import { DownloadManager } from './playback/DownloadManager';
import { AudioCacheManager } from './playback/AudioCacheManager';
import { PodcastRepository } from './net/PodcastRepository';
import { BilibiliSource, ResolvedStream } from './net/BilibiliSource';
import { Episode } from './model/Models';
import { PlayerController } from './playback/PlayerController';
import { AvSessionBridge } from './playback/AvSessionBridge';
import { RadioStation } from './playback/RadioStation';
import { Features } from './Features';
import { Log } from './util/Logger';
import { L } from './util/L';

/// 手写依赖容器(与 Android AppContainer / macOS AppEnvironment 同一形态,不引 DI 框架)。
/// 全局单例:UI 直接取用,避免 per-page ViewModel 的样板代码。
export class AppContainer {
  private static instance: AppContainer | null = null;

  readonly settings: SettingsStore = new SettingsStore();
  readonly subscriptions: SubscriptionStore = new SubscriptionStore();
  /// 直播电台账本:**进手动备份,不进局域网同步**(边界写在 `StationStore` 类注释)
  readonly stations: StationStore = new StationStore();
  readonly favorites: FavoriteStore = new FavoriteStore();
  readonly history: HistoryStore = new HistoryStore();
  readonly inbox: InboxStore = new InboxStore();
  readonly popularCache: PopularCacheStore = new PopularCacheStore();
  readonly seedCatalog: SeedCatalog = new SeedCatalog();
  readonly feedCache: FeedCacheStore = new FeedCacheStore();
  readonly listenStats: ListenStatsStore = new ListenStatsStore();
  readonly stamps: StampStore = new StampStore();
  /// 听觉批注:「那一秒 + 我那句话」(notes.json,与 Android 同格式)
  readonly notes: NoteStore = new NoteStore();
  /// 会话态:`playback_state.json` —— 排好的队列 + 正在播的那一集 + 它来自哪一列(与 Android 同格式)
  readonly playbackState: PlaybackStateStore = new PlaybackStateStore();
  /// 发现页分类的自定义顺序(与 Android `categoryStore` 同义;备份里叫 `categoryOrder`)
  readonly categoryStore: CategoryStore = new CategoryStore();
  /// 逐字稿:状态机 + 缓存。识别实现由 boot 注入(见下)
  readonly transcripts: TranscriptStore = new TranscriptStore();
  /// 章节表(podcast:chapters):状态机 + 缓存;章表取回后离线也能跳(与 Android 同名同职责)
  readonly chapters: ChapterStore = new ChapterStore();
  readonly downloads: DownloadStore = new DownloadStore();
  readonly downloadManager: DownloadManager = DownloadManager.get();
  /// 「播过即缓存」的账本与执行者(与 downloads 分目录、分账本、分清理入口)
  readonly audioCacheStore: AudioCacheStore = new AudioCacheStore();
  readonly audioCache: AudioCacheManager = AudioCacheManager.get();
  /// 封面磁盘缓存:本端 `Image(url)` 没有可依赖的离线缓存,断网时图片全空,所以自己落一份
  readonly artwork: ArtworkCache = ArtworkCache.get();
  readonly repository: PodcastRepository;
  readonly player: PlayerController = PlayerController.get();
  readonly radio: RadioStation = RadioStation.get();

  private constructor() {
    this.repository = new PodcastRepository(this.popularCache, this.seedCatalog, this.feedCache);
  }

  static get(): AppContainer {
    if (AppContainer.instance === null) AppContainer.instance = new AppContainer();
    return AppContainer.instance;
  }

  private booted = false;

  /// 首次进入界面时装配:初始化存储路径,再把各 store 从磁盘拉起。
  boot(ctx: common.UIAbilityContext): void {
    if (this.booted) return;
    this.booted = true;
    Prefs.init(ctx);
    JsonFile.init(ctx.filesDir);
    // 文案必须在任何 UI 取串之前装配。漏了这一句的后果不是崩溃,而是界面**原样显示键名**
    // (L.s 取不到 rm 就返回 name),且 workScheduler 扩展那边单独 init 过,
    // 于是通知文案正常、主界面全是 nav_discover / search_placeholder 之类。
    L.init(ctx);

    this.settings.load();
    this.subscriptions.load();
    // 电台:纯本地读 + 记下 rawfile 上下文(精选清单首次进电台页才装)
    this.stations.attach(ctx);
    this.stations.load();
    this.favorites.load();
    this.history.load();
    this.inbox.load();
    this.popularCache.load();
    // 内置精选清单:这里只记上下文,真正读 rawfile 推迟到第一次用(见 SeedCatalog.attach)
    this.seedCatalog.attach(ctx);
    this.feedCache.load();
    // 私有订阅的凭据账本(feed_auth.json)。**纯本地读**,与上面几个 store 同一性质;
    // 不放进备份 —— 口令只留在本机,换机要重新输入(见 docs/FEATURES.md 私有订阅一节)。
    this.repository.authStore.load();
    // 退订即作废凭据:链接都没了,留一份口令在磁盘上只有坏处。
    this.subscriptions.onRemoved = (p) => this.repository.forgetAuth(p.feedUrl);
    // 内置引导音频:把 rawfile 拷到 filesDir 一份,随后复用已有的本地文件播放路径。
    // 异步进行,不阻塞首帧;未就绪时引导卡不显示(见 GuideEpisode.available)。
    GuideEpisode.prepare(ctx);
    this.stamps.load();
    this.notes.load();
    // 会话态(队列 + 正在播那一集)。**纯本地读**,和上面几个 store 同一性质;
    // 真正会联网的预载排在同意后(见 startGated 末尾的 restoreFromState)。
    this.playbackState.load();
    // 分类顺序同样是纯本地读一个键,首屏 chips 要用它排序,必须在 UI 装配前就绪。
    this.categoryStore.load();
    /**
     * 逐字稿:这里装配的只是**状态机与本地缓存**(私有目录读写),不联网、不碰权限,
     * 所以放在同意隐私政策之前没有问题(与上面几个 store 同一性质)。
     * 唯一联网的动作是"取发布方的官方稿",那一步由用户点了才发生。
     */
    this.transcripts.init(ctx.filesDir);
    // 章表缓存同样是**纯本地读**(不联网)。真正取章表由用户点开弹层触发,排在同意门之后。
    this.chapters.load();
    // 本机识别(1.0.8 起 sherpa-onnx + SenseVoice,见 Features.LOCAL_ASR 的长注释)。
    // 这里只**装配**一个外壳:模型到第一次转写才拷贝/加载,不占启动时间、不联网。
    // 旧实现 `SpeechTranscriber`(系统 Core Speech Kit)留着对照,不再装配。
    if (Features.LOCAL_ASR) {
      this.transcripts.transcriber = new SenseVoiceTranscriber(ctx, this.settings);
    }
    this.downloads.load();
    this.downloadManager.init(ctx.filesDir, this.downloads, this.settings);
    // 缓存这一组同样是**纯本地**(建目录 + 读账本 + 扫一遍自己的目录),不起播就不联网,
    // 所以放在同意门之前装配;真正拉音频/图片的那一步在 startGated 注入的通知里,由用户点播触发。
    this.audioCacheStore.load();
    this.audioCache.init(ctx.filesDir, this.audioCacheStore, this.settings);
    this.artwork.init(ctx.filesDir);
    this.listenStats.load();
    this.listenStats.seedFromHistory(this.history.history);

    Log.i('App', `本地数据就绪 订阅=${this.subscriptions.subscriptions.length} 收藏=${this.favorites.favorites.length} 历史=${this.history.history.length} 最新=${this.inbox.episodes.length} 批注=${this.notes.notes.length}`);
    // 会话态单独一行:装机验收「重启后队列与正在播的那一集还在」靠的就是这两格
    // (与 Android AppContainer 的启动日志同口径)。只报 id 与条数,不落标题。
    const snap = this.playbackState.snapshot;
    Log.i('App', `会话态 upNext=${snap.upNext.length} 上次在播=${snap.current === null ? '-' : snap.current.id}`);

    // 冷启动把桌面卡片对齐一次(纯本地:只读历史/会话两份 JSON,不联网、不碰权限)。
    WidgetUpdater.request(this.settings, true);

    // 以上全是**本地读写**,不联网、不读系统网络信息,可以在同意隐私政策之前做。
    // 联网相关的装配一律推到 startGated(同意后由 Index 调用)。
    if (this.settings.privacyAccepted) this.startGated(ctx);
  }

  private gatedStarted = false;

  /**
   * 装配「同意隐私政策之后才允许存在」的部分。
   *
   * 平台合规指引:同意之前不得申请个人信息或权限。这里涉及的是:
   *  - 系统媒体会话(AVSession):会向系统注册播控身份;
   *  - 电台配置 / 播放层:一旦起播即产生网络请求;
   *  - 订阅更新的 workScheduler 周期任务:带 networkType 条件,由系统读取网络状态。
   * Android 端就是因为在同意前连了 PlaybackService(→ 创建 ExoPlayer → 读系统网络信息)
   * 被判定「同意前获取 SSID」不通过,鸿蒙这边提前对齐,别再吃一轮。
   *
   * 幂等:同意后由 Index 调用一次,已同意的老用户则在 boot 里直接调用。
   */
  startGated(ctx: common.UIAbilityContext): void {
    if (this.gatedStarted) return;
    this.gatedStarted = true;
    Log.i('App', '已同意隐私政策,装配联网相关组件');

    // 播放层装配:注入历史/设置,并把状态变化同步给系统媒体会话
    this.player.bind(this.history, this.settings);
    this.player.bindState(this.playbackState);
    /**
     * 单集上下文补全用的一列:`播放队列里只有一集`时按它把同一个节目的缓存列表接上,
     * 否则「上一集 / 下一集」(桌面卡片、迷你条)会变成点得到的死键。
     * **只读本地频道缓存** —— 按一下就联网取 RSS 不是这个动作该有的代价。
     */
    this.player.bindFeedEpisodes((feedUrl: string): Episode[] => {
      const hit = this.feedCache.get(feedUrl);
      return hit === null ? [] : hit.episodes;
    });
    // 选源四级:**引导 > 下载 > 缓存 > 网络**(Android 那边没有"引导走本地文件"这一级,
    // 它的引导音频用 asset URI 直接起播,所以是 下载 > 缓存 > 网络)。
    // 下载排在缓存前是因为它是用户点名留下的那一份;缓存命中时 AudioCacheManager
    // 顺手记一次访问 —— LRU 靠它。
    this.player.localFileProvider = (e: Episode) => {
      const guide = GuideEpisode.pathFor(e.id);
      if (guide !== null) return guide;
      const dl = this.downloadManager.localPath(e.id);
      if (dl !== null) return dl;
      // url 一起传进去:命中时要与账本记的地址回验一次(见 AudioCacheManager.localPathForPlay,
      // 低·族A ②)
      return this.audioCache.localPathForPlay(e.id, e.audioUrl);
    };
    // 走网络起播时排一次「整集落缓存」(fire-and-forget,不影响这次起播)
    this.player.networkPlayNotice = (e: Episode, headers: Record<string, string> | null) => {
      this.audioCache.cache(e, headers);
    };
    /**
     * 私有订阅的凭据查询。**只交"该不该带"的判断结果,不交凭据本身** ——
     * 播放 / 下载 / 官方稿三处都从这里取,主机匹配(同域或父子域)统一落在
     * `PodcastRepository.authHeader` 里,免得三处各写一份判据而慢慢分叉。
     */
    const authOf = (url: string): string | null => this.repository.authHeader(url);
    this.player.authHeaderProvider = authOf;
    this.downloadManager.authHeaderProvider = authOf;
    this.transcripts.authHeaderProvider = authOf;
    this.chapters.authHeaderProvider = authOf;
    // 视频源的伪地址在起播前现取直链。注入的是**同一个** `bilibili` 实例(repository 里那一个),
    // 候选流缓存与探活游标都在它身上 —— 换实例等于每次起播重新摸一遍 PCDN。
    // 回来的是 `{ url, durationSec }`:时长是**这一次解析的那个 cid** 的真值,见 `ResolvedStream`。
    this.player.resolvePseudoUrl = (url: string): Promise<ResolvedStream | null> =>
      this.repository.bilibili.resolvePlayback(url);
    this.player.bindListen(
      (e: Episode, delta: number) => { this.listenStats.add(e, delta); },
      () => { this.listenStats.flush(); });
    this.radio.configure(this.repository, this.player, () => this.region());
    const bridge = AvSessionBridge.get();
    bridge.setup(ctx, this.player);
    this.player.onStateChanged = () => { bridge.sync(this.player); };
    /**
     * 恢复上次退出时的播放态(队列 + 正在播那一集),排在**上面两行之后**:
     * 预载会立刻产生一次状态回调,而"预载到暂停态、不出声"这件事要在锁屏/控制中心
     * 正确显示成暂停 —— `onStateChanged` 还没挂上就装载,那一格就丢了。
     *
     * 这一步会向发布方拉一次音频流(装载到就绪、不自动开播),所以它在同意门之内,
     * 口径同步写在 `docs/PRIVACY.md` 第三节(与 Android 同一条)。
     */
    this.player.restoreFromState();
  }

  /// 当前生效地区:设置覆盖优先;自动模式跟随设备地区,无地区信息时才回落 us。
  region(): string {
    const override = this.settings.regionOverride;
    if (override.length > 0) return override.toLowerCase();
    try {
      const parts = i18n.System.getSystemLocaleInstance().toString().split('-');
      if (parts.length >= 2) {
        const country = parts[parts.length - 1];
        if (country.length === 2) return country.toLowerCase();
      }
    } catch (e) {
      Log.w('App', `读取设备地区失败:${(e as Error).message}`);
    }
    return 'us';
  }
}
