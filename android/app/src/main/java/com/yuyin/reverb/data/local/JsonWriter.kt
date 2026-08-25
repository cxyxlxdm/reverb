package com.yuyin.reverb.data.local

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

/**
 * 大体积 / 高频持久化的**去抖异步写**。
 *
 * 为什么需要:这些 store 的 `persist()` 原先在**调用方线程**上同步做
 * 「建整份 JSON + `file.writeText`」,而最要紧的两个调用方都在主线程上:
 *  - `PlayerController.ticker` 用的是 `Handler(Looper.getMainLooper())`,
 *    每 10 跳(约 5 秒)`saveProgress()` → `HistoryStore.updatePosition()` → 整份写回;
 *  - 同一个 ticker 里 `countListening()` → `ListenStatsStore.add()` 攒到阈值就 `commit()`。
 * 本机上 history.json 实测 **270 KB**(macOS 侧同一份数据,Android 数据量相当),
 * 也就是播放中每 5 秒在主线程上固定烧掉一次几百 KB 的 JSON 构造 + 写盘。
 *
 * 三端同一形状(见 TROUBLESHOOTING H65):
 *  - **去抖要连"生成数据"一起去抖** —— 只把写盘挪到 IO、JSON 还在主线程建等于没解决,
 *    所以这里收的是 `build: () -> String`(取值函数),而不是已经拼好的字符串;
 *  - 同一文件在 [DEBOUNCE_MS] 内的多次请求只落最后一次;
 *  - **代价**:进程被杀时最多丢窗口内的一次写入,所以退到后台必须 [flush]
 *    (见 `MainActivity.onStop`;鸿蒙对应 `JsonFile.flushPending()`)。
 *
 * 只给"整份写回且频繁/大"的数据用(history / listen_stats / inbox / feed_cache / popular_cache)。
 * 订阅、收藏、印记这类**用户单次操作触发**的小数据仍走同步写:一次点按几毫秒看不出来,
 * 而同步写没有"进程被杀丢一次"的窗口 —— 那些是用户明确做出的动作,丢了更难解释。
 */
object JsonWriter {

    private const val DEBOUNCE_MS = 400L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    /** 绝对路径 → 待执行的取值函数(只保留最新一份) */
    private val pending = HashMap<String, Pair<File, () -> String>>()
    /** 绝对路径 → 去抖任务 */
    private val timers = HashMap<String, Job>()

    /** 登记一次写入。[build] 会在**去抖到期后、IO 线程上**才被调用。 */
    fun write(file: File, build: () -> String) {
        val key = file.absolutePath
        synchronized(lock) {
            pending[key] = file to build
            timers.remove(key)?.cancel()
            timers[key] = scope.launch {
                delay(DEBOUNCE_MS)
                val item = synchronized(lock) {
                    timers.remove(key)
                    pending.remove(key)
                }
                item?.let { (f, b) -> runCatching { f.writeText(b()) } }
            }
        }
    }

    /**
     * 立刻把待写内容落盘(**在调用方线程上同步完成**)。
     * 用于退到后台/退出这类"必须写成"的时机 —— 此时宁可占用主线程几十毫秒,
     * 也不能丢掉用户刚听到的位置。
     */
    fun flush() {
        val items = synchronized(lock) {
            timers.values.forEach { it.cancel() }
            timers.clear()
            val copy = pending.toMap()
            pending.clear()
            copy
        }
        for ((_, v) in items) {
            val (f, b) = v
            runCatching { f.writeText(b()) }
        }
        if (items.isNotEmpty()) {
            com.yuyin.reverb.util.Logger.i("JsonWriter", "退到后台前落盘 ${items.size} 个文件")
        }
    }
}
