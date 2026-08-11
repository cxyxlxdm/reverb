import type common from '@ohos.app.ability.common';
import { Prefs } from './store/Prefs';
import { JsonFile } from './store/JsonFile';
import { SettingsStore } from './store/SettingsStore';
import { SubscriptionStore, FavoriteStore, HistoryStore, PopularCacheStore } from './store/Stores';
import { InboxStore } from './store/InboxStore';
import { PodcastRepository } from './net/PodcastRepository';
import { Log } from './util/Logger';

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
  readonly repository: PodcastRepository;

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

    this.settings.load();
    this.subscriptions.load();
    this.favorites.load();
    this.history.load();
    this.inbox.load();
    this.popularCache.load();

    Log.i('App', `本地数据就绪 订阅=${this.subscriptions.subscriptions.length} 收藏=${this.favorites.favorites.length} 历史=${this.history.history.length} 最新=${this.inbox.episodes.length}`);
  }

  /// 当前生效地区:设置覆盖优先,否则回落 us(与两端一致)。
  region(): string {
    const o = this.settings.regionOverride;
    return o.length > 0 ? o : 'us';
  }
}
