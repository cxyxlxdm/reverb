import type common from '@ohos.app.ability.common';
import i18n from '@ohos.i18n';
import { Prefs } from './store/Prefs';
import { JsonFile } from './store/JsonFile';
import { SettingsStore } from './store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore, PopularCacheStore } from './store/Stores';
import { InboxStore } from './store/InboxStore';
import { SeedCatalog } from './store/SeedCatalog';
import { FeedCacheStore } from './store/FeedCacheStore';
import { GuideEpisode } from './store/GuideEpisode';
import { ListenStatsStore } from './store/ListenStatsStore';
import { DownloadStore } from './store/DownloadStore';
import { StampStore } from './store/StampStore';
import { NoteStore } from './store/NoteStore';
import { PlaybackStateStore } from './store/PlaybackStateStore';
import { TranscriptStore } from './store/TranscriptStore';
import { SpeechTranscriber } from './playback/SpeechTranscriber';
import { DownloadManager } from './playback/DownloadManager';
import { PodcastRepository } from './net/PodcastRepository';
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
  /// 逐字稿:状态机 + 缓存。识别实现由 boot 注入(见下)
  readonly transcripts: TranscriptStore = new TranscriptStore();
  readonly downloads: DownloadStore = new DownloadStore();
  readonly downloadManager: DownloadManager = DownloadManager.get();
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
    this.favorites.load();
    this.history.load();
    this.inbox.load();
    this.popularCache.load();
    // 内置精选清单:这里只记上下文,真正读 rawfile 推迟到第一次用(见 SeedCatalog.attach)
    this.seedCatalog.attach(ctx);
    this.feedCache.load();
    // 内置引导音频:把 rawfile 拷到 filesDir 一份,随后复用已有的本地文件播放路径。
    // 异步进行,不阻塞首帧;未就绪时引导卡不显示(见 GuideEpisode.available)。
    GuideEpisode.prepare(ctx);
    this.stamps.load();
    this.notes.load();
    // 会话态(队列 + 正在播那一集)。**纯本地读**,和上面几个 store 同一性质;
    // 真正会联网的预载排在同意后(见 startGated 末尾的 restoreFromState)。
    this.playbackState.load();
    /**
     * 逐字稿:这里装配的只是**状态机与本地缓存**(私有目录读写),不联网、不碰权限,
     * 所以放在同意隐私政策之前没有问题(与上面几个 store 同一性质)。
     * 唯一联网的动作是"取发布方的官方稿",那一步由用户点了才发生。
     */
    this.transcripts.init(ctx.filesDir);
    // 本机识别当前关着(系统识别质量不够用,见 Features.LOCAL_ASR 的长注释)。
    // 不装配识别器 ⇒ store 只走"发布方提供的逐字稿"那一条路。
    if (Features.LOCAL_ASR) {
      this.transcripts.transcriber = new SpeechTranscriber(ctx);
    }
    this.downloads.load();
    this.downloadManager.init(ctx.filesDir, this.downloads, this.settings);
    this.listenStats.load();
    this.listenStats.seedFromHistory(this.history.history);

    Log.i('App', `本地数据就绪 订阅=${this.subscriptions.subscriptions.length} 收藏=${this.favorites.favorites.length} 历史=${this.history.history.length} 最新=${this.inbox.episodes.length} 批注=${this.notes.notes.length}`);
    // 会话态单独一行:装机验收「重启后队列与正在播的那一集还在」靠的就是这两格
    // (与 Android AppContainer 的启动日志同口径)。只报 id 与条数,不落标题。
    const snap = this.playbackState.snapshot;
    Log.i('App', `会话态 upNext=${snap.upNext.length} 上次在播=${snap.current === null ? '-' : snap.current.id}`);

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
    // 已下载优先本地播放(闭包注入,解耦下载模块)。
    // 引导音频也走这条路:它的"本地文件"是从 rawfile 拷出来的那一份。
    this.player.localFileProvider = (e: Episode) => {
      const guide = GuideEpisode.pathFor(e.id);
      if (guide !== null) return guide;
      return this.downloadManager.localPath(e.id);
    };
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
