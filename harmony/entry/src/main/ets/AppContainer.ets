import type common from '@ohos.app.ability.common';
import { Prefs } from './store/Prefs';
import { JsonFile } from './store/JsonFile';
import { SettingsStore } from './store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore, PopularCacheStore } from './store/Stores';
import { InboxStore } from './store/InboxStore';
import { ListenStatsStore } from './store/ListenStatsStore';
import { DownloadStore } from './store/DownloadStore';
import { StampStore } from './store/StampStore';
import { DownloadManager } from './playback/DownloadManager';
import { PodcastRepository } from './net/PodcastRepository';
import { Episode } from './model/Models';
import { PlayerController } from './playback/PlayerController';
import { AvSessionBridge } from './playback/AvSessionBridge';
import { RadioStation } from './playback/RadioStation';
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
  readonly listenStats: ListenStatsStore = new ListenStatsStore();
  readonly stamps: StampStore = new StampStore();
  readonly downloads: DownloadStore = new DownloadStore();
  readonly downloadManager: DownloadManager = DownloadManager.get();
  readonly repository: PodcastRepository;
  readonly player: PlayerController = PlayerController.get();
  readonly radio: RadioStation = RadioStation.get();

  private constructor() {
    this.repository = new PodcastRepository(this.popularCache);
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
    this.stamps.load();
    this.downloads.load();
    this.downloadManager.init(ctx.filesDir, this.downloads);
    this.listenStats.load();
    this.listenStats.seedFromHistory(this.history.history);

    Log.i('App', `本地数据就绪 订阅=${this.subscriptions.subscriptions.length} 收藏=${this.favorites.favorites.length} 历史=${this.history.history.length} 最新=${this.inbox.episodes.length}`);

    // 播放层装配:注入历史/设置,并把状态变化同步给系统媒体会话
    this.player.bind(this.history, this.settings);
    // 已下载优先本地播放(闭包注入,解耦下载模块)
    this.player.localFileProvider = (e: Episode) => this.downloadManager.localPath(e.id);
    this.player.bindListen(
      (e: Episode, delta: number) => { this.listenStats.add(e, delta); },
      () => { this.listenStats.flush(); });
    this.radio.configure(this.repository, this.player, this.region());
    const bridge = AvSessionBridge.get();
    bridge.setup(ctx, this.player);
    this.player.onStateChanged = () => { bridge.sync(this.player); };
  }

  /// 当前生效地区:设置覆盖优先,否则回落 us(与两端一致)。
  region(): string {
    const o = this.settings.regionOverride;
    return o.length > 0 ? o : 'us';
  }
}
