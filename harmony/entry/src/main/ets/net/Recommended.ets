import { Podcast } from '../model/Models';
import { AppContainer } from '../AppContainer';
import { BackupManager } from '../store/BackupManager';
import { Http } from './Http';
import { L } from '../util/L';
import { Log } from '../util/Logger';

/**
 * 「导入推荐订阅」。
 *
 * 清单是一份挂在**官网**的静态 OPML,不打进安装包 —— 合规口径把「内置内容目录」判定为
 * 提供视听节目服务(需前置审批),而"用户主动导入一份订阅清单"属于工具行为。
 * 同理这里是**整份导入**,不返回列表给界面渲染 —— 那等于把目录又搬回应用里。
 */
export class Recommended {
  /**
   * 拉清单并整份订阅。
   * @returns 成功订阅的条数;网络或解析失败返回 -1(由调用方给出可见提示 —— 这是用户
   *          主动触发的动作,静默失败不可接受)。
   */
  static async importAll(app: AppContainer): Promise<number> {
    const url = L.s('recommended_opml_url');
    const opml = await Http.text(url);
    if (opml === null || opml.length === 0) {
      Log.w('Recommended', `拉取清单失败 ${url}`);
      return -1;
    }
    const urls = BackupManager.extractFeedUrls(opml);
    if (urls.length === 0) {
      Log.w('Recommended', '清单里没有可用的 xmlUrl');
      return -1;
    }
    // 逐个解析 RSS 是为了拿到完整频道信息(封面/作者),否则订阅列表是一排占位图。
    // **解析失败的直接跳过**,不像 BackupManager.importOpml 那样拿地址当标题兜底 ——
    // 推荐清单里冒出一条以 URL 为名的条目,比少一条更糟。
    const list: Podcast[] = [];
    for (let i = 0; i < urls.length; i++) {
      const feed = await app.repository.feed(urls[i]);
      if (feed !== null) list.push(feed.podcast);
    }
    if (list.length > 0) app.subscriptions.addAll(list);
    Log.i('Recommended', `导入推荐订阅 ${list.length}/${urls.length}`);
    return list.length;
  }
}
