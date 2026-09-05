import { RssParser } from './RssParser';
import { FeedResult } from '../model/Models';

/**
 * 在 **TaskPool 子线程**里取一个 feed 并解析。
 *
 * 为什么必须挪出 UI 线程(H64):ArkTS 没有协程,`Http` 的等待是异步的没错,但
 * **`XmlPullParser` 的逐 token 回调、每集一遍的 `htmlToText`、上千个对象的构造
 * 全是同步 JS**,谁调用就占谁的线程。真机实测最大的一个订阅源(8.5 MB / 1026 集)
 * 一次解析 **1833 ms**,一轮 15 源刷新里约 4.5 秒是纯解析 ——
 * 下拉刷新的转圈就卡死在这段时间里,与在不在播放无关。
 *
 * 连网络一起放进子线程(而不是只搬解析):这样 8.5 MB 的 XML 字符串**压根不会出现在
 * UI 线程的堆上**,跨线程只传一个 url 进去、传解析结果出来。
 *
 * 两个已知代价,写在这里免得后来者困惑:
 *  1. **日志分叉**。子线程里的 `Log` 走 hilog 照常可见(`hdc shell hilog`),
 *     但 `Log` 的内存环形缓冲是每线程一份 —— 设置页「分享日志」拿不到这些行。
 *  2. **首次有线程启动开销**(要在子线程里加载一遍模块图),几十毫秒量级,一次性。
 *
 * 参数与返回值都必须可序列化:`feedUrl` 是 string、`timeoutMs` 是 number,
 * `FeedResult` 是纯对象(interface + 数组),不要往里塞类实例或函数。
 */
@Concurrent
export async function fetchFeedConcurrent(feedUrl: string, timeoutMs: number): Promise<FeedResult | null> {
  return await RssParser.fetch(feedUrl, timeoutMs);
}
