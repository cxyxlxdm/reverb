package com.yuyin.reverb.data.local

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
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
 * 但**同步写也必须走本类的 [writeAtomically]**(见下面那条「两件硬事」),
 * 否则这一层就只保护了五份文件,而用户资产最重的那几份(订阅 / 批注 / 印记)反而没被保护。
 */
object JsonWriter {

    private const val DEBOUNCE_MS = 400L
    private const val TAG = "JsonWriter"

    /** 临时文件后缀。写满这份再 rename 成正式名,所以正式名永远不会是半截的。 */
    private const val TMP_SUFFIX = ".part"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    /** 绝对路径 → 待执行的取值函数(只保留最新一份) */
    private val pending = HashMap<String, Pair<File, () -> String>>()
    /** 绝对路径 → 去抖任务 */
    private val timers = HashMap<String, Job>()
    /**
     * 绝对路径 → 该文件的落盘互斥体。
     *
     * 为什么需要:临时文件名由目标名派生(`x.json.part`),而**同一个文件的两次写可能真的并发**
     * —— 去抖任务在取出 pending 项之后才落盘,这期间又一次 persist 会排下第二个任务,
     * 两个任务同时往同一个 `.part` 里写就是交错字节,而 rename 之后那份就是坏文件。
     * 按文件分锁而不是全局一把:退到后台的 [flush] 在主线程上,不能被另一个线程正在写的
     * 某个不相干的大文件挡几十毫秒(硬规矩 6 那笔「调用次数 × 每次成本」的账同样适用于锁)。
     */
    private val gates = HashMap<String, Any>()

    /**
     * 本次进程里**顶层解析失败**过的文件(绝对路径)。
     * 命中的文件在下一次成功落盘之前,不接受「空态整份覆盖回去」(见 [writeAtomically])。
     */
    private val loadFailed = HashSet<String>()

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
                item?.let { (f, b) -> writeOrDrop(f, b) }
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
            writeOrDrop(f, b)
        }
        if (items.isNotEmpty()) {
            com.yuyin.reverb.util.Logger.i("JsonWriter", "退到后台前落盘 ${items.size} 个文件")
        }
    }

    /**
     * 落盘的**唯一出口**:先写 `<文件名>.part`,成功后 rename 覆盖正式名。
     *
     * 两件硬事,都是 2026-10-25 体检「高-3」那条(见 `docs/REVIEW-2026-10-25.md`):
     *
     * 1. **不能截断重写。** 原先这里是 `file.writeText(...)`,即"先把正式文件清空,再往里写"。
     *    进程死在中间(系统回收 / 崩溃 / 电池耗尽)留下的就是**一份被截断的 JSON**,
     *    下次启动解析必失败,于是订阅 / 批注 / 印记这些用户资产在读取侧被当成"空"
     *    —— 而"空"只要被任何一次 persist 写回去就永久成立,谁也补不回来。
     *    rename 在同一目录内是一次目录项替换:要么看到旧内容,要么看到新内容,没有中间态。
     * 2. **读坏过的文件不接受"空态覆盖"。** [markLoadFailed] 记下这类文件并把原始字节改名留证,
     *    这里再拦一道:内存里那份"其实是被解析失败清空的"列表**不许**整份写回磁盘。
     *    判据只看"内容是不是空态",不看调用方是谁 —— 靠 12 个 store 各自自律必然漏
     *    (那是体检总结的「靠调用点自律的规矩必漏」第 2 条模式)。
     *    ⚠️ 副作用:这一期间用户**显式清空**(如 `HistoryStore.clear()`)也会被挡住。
     *    方向是刻意的:那一刻盘上那份文件本来就解析不出来,清空与否无法验证,
     *    而留证文件里的字节是唯一还有价值的东西 —— 宁可"没清干净",不可"顺手毁证"。
     *
     * ⚠️ **没做 fsync,这是有意的取舍不是遗漏。** rename 防的是"进程死在写入窗口内"
     *    —— 这是本项目实际会遇到的方向(系统杀进程、崩溃、升级到新包重启)。
     *    整机掉电要防的是另一件事,那需要 fsync 文件**和父目录**,
     *    代价是播放中每约 5 秒那次 history 全量写(几百 KB)多两次同步等待。
     *    真要做到掉电安全,应该在 [flush] 那一条路径上补 fsync(只在那一处才划得来)。
     *
     * @return true = 正式文件已经是 [text] 的内容。false = 被空态闸挡下或落盘失败(都已记日志)。
     */
    fun writeAtomically(file: File, text: String): Boolean {
        val key = file.absolutePath
        if (isMarkedFailed(key) && isEmptyStateJson(text)) {
            com.yuyin.reverb.util.Logger.e(
                TAG,
                "${file.name} 本次进程内读到过坏内容,拒绝把空态整份写回(用户资产宁可留在原文件里)"
            )
            return false
        }
        val gate = synchronized(lock) { gates.getOrPut(key) { Any() } }
        return synchronized(gate) {
            val tmp = File(file.parentFile, file.name + TMP_SUFFIX)
            try {
                tmp.writeText(text)
                if (renameOrFallback(tmp, file, key)) {
                    synchronized(lock) { loadFailed.remove(key) }
                    true
                } else {
                    // 字节已经完整落在 tmp 里,删掉等于把最后一份内容也扔掉 —— 留着,日志给出手动救援的路径
                    com.yuyin.reverb.util.Logger.e(TAG, "落盘失败:rename 不成,完整内容暂存 ${tmp.absolutePath}")
                    false
                }
            } catch (e: Exception) {
                runCatching { if (tmp.exists()) tmp.delete() }
                com.yuyin.reverb.util.Logger.e(TAG, "落盘失败 ${file.name}(正式文件未被改动)", e)
                false
            }
        }
    }

    /**
     * 由 store 在**顶层解析失败**时调用:记下这个文件、并把原始字节改名留证。
     *
     * 为什么留证而不是删掉:截断的 JSON 里通常还有大部分用户资产(只有尾部坏了),
     * 有人手动修得回来;一旦被下一次写入原地覆盖,那部分就真的没了。
     * 留证之后读取侧仍然是空态(内存该是什么就什么),但"空态被写回去"这一条由
     * [writeAtomically] 挡住。改名成功的话正式名已经不存在,下次 persist 写的是新文件。
     */
    fun markLoadFailed(file: File) {
        val key = file.absolutePath
        synchronized(lock) { loadFailed.add(key) }
        val kept = File(file.parentFile, "${file.name}.corrupt-${System.currentTimeMillis()}")
        val ok = runCatching { file.exists() && file.renameTo(kept) }.getOrDefault(false)
        com.yuyin.reverb.util.Logger.e(
            TAG,
            if (ok) "${file.name} 读坏了,原始字节已留证为 ${kept.name}"
            else "${file.name} 读坏了(留证改名失败,原文件按原样留着)"
        )
    }

    private fun isMarkedFailed(key: String): Boolean = synchronized(lock) { key in loadFailed }

    /** 先落 [text] 再原子写:构造 JSON 本身也可能抛,不能让它的异常吃掉落盘的结果。 */
    private fun writeOrDrop(file: File, build: () -> String) {
        val text = try {
            build()
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e(TAG, "${file.name} 序列化失败,本次写入跳过", e)
            return
        }
        writeAtomically(file, text)
    }

    /**
     * rename 覆盖目标。绝大多数机型在同一目录内 rename 会直接顶掉旧文件(POSIX 语义),
     * 少数文件系统不允许目标已存在 —— 那种情况下**先删再改名**:
     * 此刻完整内容已经在 tmp 里了,中间那个"空档"比"截断重写"短三个数量级,
     * 而且失败方向是"下次读到空文件",不是"读到半截 JSON"。
     */
    private fun renameOrFallback(tmp: File, target: File, key: String): Boolean {
        if (tmp.renameTo(target)) return true
        com.yuyin.reverb.util.Logger.w(TAG, "${target.name} rename 需先删旧文件(该文件系统不允许覆盖)")
        if (runCatching { target.exists() && !target.delete() }.getOrDefault(false)) return false
        return tmp.renameTo(target)
    }

    /**
     * 「这份内容等于什么都没了吗」。只在文件被标记为读坏时才会被调用,所以解析一次的开销可以接受。
     *
     * 口径:**只把"有记录的容器"算作有内容。** 数组看长度;对象看它的每个值是不是空容器/空串;
     * 数字与布尔**不算**内容 —— 账本文件顶部那些 `{"v":1,"items":[]}`、`{"version":1,…}`
     * 里的版本位就是这类"格式标记",它们不能代表"用户还有东西"。
     */
    private fun isEmptyStateJson(text: String): Boolean = try {
        val t = text.trim()
        when {
            t.isEmpty() -> true
            t.startsWith("[") -> JSONArray(t).length() == 0
            t.startsWith("{") -> {
                val o = JSONObject(t)
                val keys = o.keys()
                var hasContent = false
                while (keys.hasNext()) {
                    if (isMeaningful(o.get(keys.next()))) { hasContent = true; break }
                }
                !hasContent
            }
            else -> false     // 不是 JSON:不认识,当作"有内容"放行(这条闸只该管空态,不该管别的)
        }
    } catch (e: Exception) {
        false   // 连解析都不过的内容不是"空态",不该被这条闸挡下
    }

    private fun isMeaningful(v: Any?): Boolean = when (v) {
        null, JSONObject.NULL -> false
        is JSONArray -> v.length() > 0
        is JSONObject -> v.length() > 0
        is String -> v.isNotBlank()
        else -> false     // Number / Boolean:格式标记(版本号、开关位),不当作用户资产
    }
}
