import { TranscriptFetcher } from './TranscriptFetcher';
import { TranscribedSegment } from '../model/Models';

/**
 * 在 **TaskPool 子线程**里取并解析发布方的官方逐字稿。
 *
 * 为什么要搬:JSON 格式的官方稿是**一词一条**,真机验过的那一集有 10245 条词级条目,
 * 解析 + 断行合并(`TranscriptLines`)是纯同步 JS。留在 UI 线程上,
 * 第三页出现的那一刻会明显顿一下(同 H65 的道理:ArkTS 没有协程,同步就是占调用线程)。
 *
 * 与 `FeedTask` 一样连网络一起搬:大稿的字符串(上限 8 MB)因此不出现在 UI 线程的堆上。
 */
@Concurrent
export async function fetchTranscriptConcurrent(url: string, declaredType: string): Promise<TranscribedSegment[]> {
  return await TranscriptFetcher.fetch(url, declaredType);
}
