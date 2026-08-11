import WorkSchedulerExtensionAbility from '@ohos.WorkSchedulerExtensionAbility';
import type workScheduler from '@ohos.resourceschedule.workScheduler';
import { Prefs } from '../store/Prefs';
import { JsonFile } from '../store/JsonFile';
import { L } from '../util/L';
import { SubscriptionStore, PopularCacheStore } from '../store/Stores';
import { PodcastRepository } from '../net/PodcastRepository';
import { UpdateNotifier } from './UpdateNotifier';
import { Log } from '../util/Logger';

/**
 * 订阅更新检查的后台执行体(workScheduler 周期任务的落点)。
 *
 * 注意:扩展跑在**独立的 ability 上下文**里,拿不到 UI 侧的 AppContainer 单例,
 * 所以这里自行最小化装配(Prefs / JsonFile / 订阅 / repository),只做「查更新 + 发通知」。
 */
export default class FeedUpdateExtension extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    Log.i('Update', `后台任务启动 id=${work.workId}`);
    this.run();
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    Log.i('Update', `后台任务结束 id=${work.workId}`);
  }

  private async run(): Promise<void> {
    try {
      const ctx = this.context;
      L.init(ctx);
      Prefs.init(ctx);
      JsonFile.init(ctx.filesDir);
      const subs = new SubscriptionStore();
      subs.load();
      if (subs.subscriptions.length === 0) return;
      const cache = new PopularCacheStore();
      const repo = new PodcastRepository(cache);
      await UpdateNotifier.checkNow(subs.subscriptions, repo);
    } catch (e) {
      Log.e('Update', `后台检查失败 ${(e as Error).message}`);
    }
  }
}
