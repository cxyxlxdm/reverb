import workScheduler from '@ohos.resourceschedule.workScheduler';
import notificationManager from '@ohos.notificationManager';
import type common from '@ohos.app.ability.common';
import { Prefs } from '../store/Prefs';
import { Podcast, Episode } from '../model/Models';
import { PodcastRepository } from '../net/PodcastRepository';
import { Log } from '../util/Logger';
import { L } from '../util/L';

/**
 * 订阅更新提醒:周期性检查订阅是否有新集,有则发本地通知。
 *
 * 与 Android 的 WorkManager(每 6 小时)对齐;鸿蒙用 workScheduler 注册延迟任务。
 * 「哪一集算新」靠 UpdateStore 的语义:每个 feed 记住上次见过的最新一集 id,
 * 变了才提醒 —— 否则每次检查都会重复打扰。
 */
const WORK_ID = 1001;
const SEEN_PREFIX = 'seen_';

export class UpdateNotifier {
  /// 注册周期任务(6 小时,需联网)。设置里关掉提醒时调 cancel。
  ///
  /// **全应用只注册这一个 work**,而且这是一个前提而不是风格:cancel() 用的是「清掉本应用
  /// 全部延迟任务」那一条接口(见下面注释),再加第二个 work 就会连带把它清掉。
  static schedule(): void {
    try {
      const info: workScheduler.WorkInfo = {
        workId: WORK_ID,
        bundleName: 'com.yuyin.reverb',
        abilityName: 'FeedUpdateExtension',
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        repeatCycleTime: 6 * 60 * 60 * 1000,
        isRepeat: true,
        isPersisted: true
      };
      workScheduler.startWork(info);
      Log.i('Update', '已注册订阅更新检查(6 小时)');
    } catch (e) {
      const msg: string = (e as Error).message;
      // 9700005「The work has been already added」:同一个 workId 重复注册。任务本来就在那儿,
      // 不是失败 —— 恢复一份「提醒=开」的备份就会走到这里,报成失败会让看日志的人以为功能坏了。
      if (msg.indexOf('already added') >= 0) {
        Log.i('Update', '订阅更新检查已在册,无需重复注册');
      } else {
        Log.w('Update', `注册失败 ${msg}`);
      }
    }
  }

  /**
   * 取消周期任务。
   *
   * **为什么不是 `stopWork`**:本机 SDK(6.0.2(22))上 `stopWork` 对任何参数形状都抛
   * `401 The workinfo condition cannot be empty`,而任务原样留在册 —— 五种写法在真机上
   * 逐个跑过(只带 workId+bundle+ability / 加 isPersisted / needCancel=false /
   * 加 parameters 且与注册时那份一致 / 再加 needCancel=true),全部同一个 401;
   * 客户端原生层每次都报 `[GetWorkInfo] Set none conditions`(它建不出匹配条件,
   * 与文档说的"按 workId 停"不符,见 H152)。**症状是用户看得见的**:关掉「订阅更新提醒」
   * 之后,那个 6 小时一次的联网检查照旧在跑。
   *
   * `stopAndClearWorks()` 是唯一真的把任务摘掉的调用(实测在册 1 → 0),代价是它不带条件、
   * 清的是**本应用全部**延迟任务 —— 所以它只在"本端只有这一个 work"的前提下成立,
   * 前提写在 schedule() 上面。
   */
  static cancel(): void {
    try {
      workScheduler.stopAndClearWorks();
      Log.i('Update', '已取消订阅更新检查');
    } catch (e) {
      Log.w('Update', `取消失败 ${(e as Error).message}`);
    }
  }

  /// 立即检查一次(App 在前台时也可手动触发)。返回发现的新集数。
  static async checkNow(subs: Podcast[], repo: PodcastRepository): Promise<number> {
    let found = 0;
    for (let i = 0; i < subs.length; i++) {
      const p = subs[i];
      if (p.feedUrl.length === 0) continue;
      const feed = await repo.feed(p.feedUrl);
      if (feed === null || feed.episodes.length === 0) continue;
      const latest: Episode = feed.episodes[0];
      const key = `${SEEN_PREFIX}${UpdateNotifier.hash(p.feedUrl)}`;
      const seen = Prefs.seenGet(key);
      if (seen.length === 0) {
        // 首次记录:只登记不提醒(否则一开就轰炸)
        Prefs.seenPut(key, latest.id);
        continue;
      }
      if (seen === latest.id) continue;
      Prefs.seenPut(key, latest.id);
      found += 1;
      await UpdateNotifier.notify(p.title, latest.title);
    }
    Log.i('Update', `检查完成 订阅=${subs.length} 新集=${found}`);
    return found;
  }

  private static async notify(showTitle: string, episodeTitle: string): Promise<void> {
    try {
      await notificationManager.publish({
        id: Date.now() % 100000,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: L.f('update_new_episode', showTitle),
            text: episodeTitle
          }
        }
      });
    } catch (e) {
      Log.w('Update', `发通知失败(可能未授权通知)${(e as Error).message}`);
    }
  }

  /// feedUrl → 稳定短键(与 Android 的 hashCode 同思路)。
  private static hash(s: string): string {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return h < 0 ? `n${-h}` : `${h}`;
  }

  /// 请求通知授权(首次开启提醒时调用)。
  /// 无参重载自 API 12 废弃,要传 UIAbilityContext(弹窗需要挂在具体界面上)。
  static async requestAuth(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (enabled) return true;
      await notificationManager.requestEnableNotification(ctx);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      Log.w('Update', `通知授权失败 ${(e as Error).message}`);
      return false;
    }
  }
}
