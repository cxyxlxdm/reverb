package com.yuyin.reverb.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.yuyin.reverb.data.local.HistoryStore
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.model.Episode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * 列表播放模式。顺序 = 播到列表末尾即停;单曲循环 = 本集播完原地重播;
 * 随机 = 把这个列表打乱播一遍(走完表就停)。
 *
 * 持久化存的是 **ordinal**(SettingsStore 的 `play_mode`),所以**新增项只能加在末尾** ——
 * 中间插一个位置,老用户存的数就会指向另一个模式。
 *
 * ⚠️ 2026-09-28 把 ordinal 1 从「列表循环」换成「单曲循环」(见 H118):这是**同一位置换含义**,
 * 老用户存过 1 的话升级后会直接进单曲循环。接受这个结果是因为按钮就在那儿、图标当场变了,
 * 用户看得见并能再点一下改回去;而"加第四个值 + 迁移表"要为一个已经没有 UI 出口的
 * 列表循环永久养一个状态。列表循环整条**删掉了**,不是藏起来。
 */
enum class PlayMode { SEQUENTIAL, REPEAT_ONE, SHUFFLE }

/**
 * 播放门面：UI 与后台 [PlaybackService] 之间通过 Media3 MediaController 通信。
 * 集成：离线下载优先本地播放、播放历史记录与续播、睡眠定时。
 */
object PlayerController {

    private const val TAG = "Player"
    private val log = com.yuyin.reverb.util.Logger

    /**
     * 网络/IO 类出错的自动重投上限与退避基数(500ms → 1s)。
     *
     * 为什么是 2 次: podcast 的音频 URL 经常是 CDN 上一份几小时的签名,真断网时重试一百次也没用,
     * 而瞬时抖动(切基站、Wi-Fi 掉一拍)基本都落在 1 秒以内。超过上限就**把失败态留给用户**,
     * 由 [togglePlayPause]/[retryNow] 那条路(用户明确再按一次)重新计数 —— 见 REVIEW-2026-10-25 中-1。
     */
    private const val MAX_ERROR_RETRIES = 2
    private const val RETRY_BASE_MS = 500L

    private var controller: MediaController? = null
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Episode? = null
    private var history: HistoryStore? = null
    private var settings: SettingsStore? = null
    private var listenStats: com.yuyin.reverb.data.local.ListenStatsStore? = null
    private var stateStore: com.yuyin.reverb.data.local.PlaybackStateStore? = null
    // 累计收听时长的基线：仅统计“同一集、播放中、合理正向增量”的内容毫秒
    private var lastCountedPosMs = 0L
    private var lastCountedEpId = ""
    private var pendingSeekMs: Long = 0
    /**
     * 本会话里这一集**是否真的响起过**。只给 [saveProgress] 当地闸用:
     * 预载(装载到就绪但保持暂停)会让「当前集」先于播放存在,那时进度还不该被回写。
     */
    private var playbackStarted = false
    /**
     * [playAt] 设的一次性起点覆盖(≥0 生效)。批注「跳回那一秒」用的是它 ——
     * 那条路径不能走默认的「按历史进度续播」，否则点哪一条都落回上次听到的位置。
     * 消费点在 [playEpisode] 取 pendingSeekMs 的那一刻：**不能提前清**，
     * controller 还没起来时 playEpisode 会走 pending 分支直接 return，
     * 那时清掉就等于冷启动进 App 点批注必然跳不过去。
     */
    private var startMsOverride = -1L
    /** pendingSeekMs 是「用户明确要跳到这一秒」还是「续播」——两者的容差规则不同，见 STATE_READY。 */
    private var pendingSeekExplicit = false
    private var tickCount = 0
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // 音频淡入淡出:新集播放音量渐入,睡眠定时结束前渐弱
    private val fadeInMs = 900L
    private val sleepFadeMs = 8_000L // 睡眠定时最后 8 秒渐弱

    // 随机电台:开启后本集播完自动接下一首(下一首由外部 provider 提供,与数据层解耦)
    private var radioNext: (suspend () -> Episode?)? = null
    private val _radioMode = MutableStateFlow(false)
    val radioMode: StateFlow<Boolean> = _radioMode

    // 播放队列(上下文):从哪个列表点开播放,该列表即为队列,决定上/下一集。
    private var queue: List<Episode> = emptyList()
    private var queueIndex = 0

    // **当前生效的**播放模式(顺序 / 单曲循环 / 随机):自动续播与手动切集都按它走。
    // 它是跨会话的偏好,但**不直接落盘** —— 落盘的是下面那张按列的表,这里只是
    // 「正在播的这一列」那一格(没有列身份时是回落值)。
    private val _playMode = MutableStateFlow(PlayMode.SEQUENTIAL)

    /**
     * **每一列自己的**播放模式(2026-09-28 从"全局一份"改过来,见 H119)。
     * key 是 `playQueue` 的 tag;`""` 这条是**回落值**(老版本那份全局设置,也是没有列身份时
     * 的走法)。这张表是 SettingsStore 那份的枚举视图,只给 UI 读。
     */
    private val _playModes = MutableStateFlow(mapOf("" to PlayMode.SEQUENTIAL))
    val playModes: StateFlow<Map<String, PlayMode>> = _playModes

    /** 某一列该按什么走法播;没设过的列用回落值。UI 读的是上面那张表,这个只给起播/切换用。 */
    private fun modeFor(tag: String): PlayMode = _playModes.value[tag] ?: _playModes.value.getValue("")

    private fun refreshPlayModes() {
        val s = settings ?: return
        _playModes.value = s.playModeByTag.value
            .entries.associate { (k, v) -> k to modeFromOrdinal(v) } + ("" to modeFromOrdinal(s.playModeDefault.value))
    }

    private fun modeFromOrdinal(v: Int) = PlayMode.entries.getOrNull(v) ?: PlayMode.SEQUENTIAL

    /**
     * 正在播的那一列的 tag(`""` = 不属于任何可见列)。**这次它是功能性的,不是观感补丁**:
     * 「改某一列的模式」只有在改的正是正在播那一列时才当场生效,判据就在这儿。
     *
     * 同一个名字上一轮被删过,那次它是为「一颗按钮扛两件事」服务的(点它=起播还是切模式),
     * 那件事已经不存在了(起播只走列表行)。别把它再当成按钮的点亮依据。
     */
    private val _activeListTag = MutableStateFlow("")

    // 这里原先还挂着一个**为那颗按钮而生的会话状态**,现在没了:
    //   · `_listPlayUsed`(H115):让未起播时画暂停图标,好让首点看得出变化 —— 那是全 App 图标口径的
    //     反面,2026-09-28 装机被报「弄反了」(H118)。
    // 根因是那颗按钮一颗扛两件事(起播 + 切模式),那个状态是在给它打补丁。
    // 2026-09-28 定稿:**一颗按钮只管播放模式**(顺序 / 单曲循环 / 随机),
    // 起播的入口回到「点列表里的某一集」这一条本来就有的路上 —— 补丁失去需求方。
    // `playQueue` 的 `tag` 参数**保留**:它既是日志里的列身份
    // (`playQueue count=… tag='inbox'`,装机验收一直靠这一行判断点的是哪一段),
    // 也是上面那张「按列存的播放模式」的 key。

    // 随机模式用的「打乱索引表」+ 指针。**不是每次抛骰子**:抛骰子会让上一集/下一集不对称
    // (点下一集之后再点上一集回不到刚才那集),而且同一集可能连着播两次。
    // 表在起播或切进随机模式时生成一次,正在播的这一集钉在第一位。
    private var shuffleOrder: List<Int> = emptyList()
    private var shufflePos = -1
    // 随机电台的播放历史:上一个=回退到刚听过的那期,超出末尾则抓新的随机。
    private val radioHistory = ArrayList<Episode>()
    private var radioPos = -1
    private val radioHistoryCap = 100

    // 用户播放队列(up next):手动排的「接下来播放」,优先于上下文队列的顺序推进。
    private val _userQueue = MutableStateFlow<List<Episode>>(emptyList())
    val userQueue: StateFlow<List<Episode>> = _userQueue

    private val _hasNext = MutableStateFlow(false)
    val hasNext: StateFlow<Boolean> = _hasNext
    private val _hasPrev = MutableStateFlow(false)
    val hasPrev: StateFlow<Boolean> = _hasPrev

    private fun updateNavFlags() {
        if (_radioMode.value) {
            _hasPrev.value = radioPos > 0
            _hasNext.value = true // 电台随时可抓下一个
        } else {
            // 用户队列非空,或上下文队列在**当前播放模式**下还有后续,都算「有下一集」。
            // 这里必须走 nextQueueIndex() 而不是自己算 +1:随机模式看的是表指针而不是列表下标,
            // 而单曲循环**不影响这个判据**(它只改自动续播那条路,见 advanceQueue)——
            // 手动「下一集」播到列表末尾就是没有下一集,按钮该灰。
            _hasNext.value = _userQueue.value.isNotEmpty() || nextQueueIndex() != null
            _hasPrev.value = prevQueueIndex() != null
        }
    }

    /**
     * 当前播放模式下,上下文队列里**手动下一集**要去的下标;没有下一集返回 null(调用方就此停下)。
     *
     * 顺序与单曲循环在这里是同一个走法:按下「下一集」就是要换一首,原地重播当前这集会被读成按钮坏了。
     * 「单曲循环播完自己再来一遍」那条特例只在 [advanceQueue] 的 `auto` 路径上生效。
     */
    private fun nextQueueIndex(): Int? = when (_playMode.value) {
        PlayMode.SEQUENTIAL, PlayMode.REPEAT_ONE ->
            if (queueIndex in 0 until queue.size - 1) queueIndex + 1 else null
        PlayMode.SHUFFLE ->
            if (shufflePos in 0 until shuffleOrder.lastIndex) shuffleOrder[shufflePos + 1] else null
    }

    /** 当前播放模式下,上下文队列里的上一集下标;没有返回 null。 */
    private fun prevQueueIndex(): Int? = when (_playMode.value) {
        PlayMode.SHUFFLE -> if (shufflePos > 0) shuffleOrder[shufflePos - 1] else null
        else -> (queueIndex - 1).takeIf { it >= 0 && it < queue.size }
    }

    /** 按当前模式重洗随机表:正在播的这一集钉在第一位,其余打乱。 */
    private fun rebuildShuffleOrder() {
        shuffleOrder = (queue.indices.toList() - queueIndex).shuffled().let { listOf(queueIndex) + it }
        shufflePos = 0
    }

    /** 丢掉随机表(切出随机模式、或队列整个换掉时)。留着过期表会让下标指到别的列表。 */
    private fun clearShuffleOrder() {
        shuffleOrder = emptyList()
        shufflePos = -1
    }

    /**
     * 沿当前播放模式走到队列的下一集并播它;走到头(顺序播完 / 随机走完表)返回 false,由调用方停下。
     *
     * @param auto 只有「本集自然播完」这条路径传真。**单曲循环只在自动推进时原地重播**;
     *   手动按「下一集」不传,于是走 [nextQueueIndex] 的顺序口径。
     *   注意这等于承认「单曲队列 + 单曲循环 = 这一集无限重播」—— 那正是这个模式的名字,
     *   以前列表循环时代刻意躲开的正是它(见本文件被删掉的那段 ⚠️ 与 H118)。
     */
    private fun advanceQueue(auto: Boolean = false): Boolean {
        if (auto && _playMode.value == PlayMode.REPEAT_ONE) {
            if (queue.isEmpty()) return false
            log.i(TAG, "advanceQueue repeat-one index=$queueIndex")
            updateNavFlags()
            playEpisode(queue[queueIndex])
            return true
        }
        val ni = nextQueueIndex() ?: return false
        if (_playMode.value == PlayMode.SHUFFLE) shufflePos++
        queueIndex = ni
        updateNavFlags()
        playEpisode(queue[queueIndex])
        return true
    }

    // ---- 用户播放队列(up next) ----
    /** 追加到队尾(已在队列则忽略)。 */
    fun enqueue(episode: Episode) {
        if (_userQueue.value.any { it.id == episode.id }) return
        _userQueue.value = _userQueue.value + episode
        log.i(TAG, "enqueue id=${episode.id} size=${_userQueue.value.size}")
        updateNavFlags()
        persistState()
    }

    /**
     * 批量追加到队尾:**一次**去重、**一次**换列表、**一次**落盘,返回真正新增的条数。
     *
     * 为什么不能让调用方循环 [enqueue]:那条路每条都要「扫一遍现有队列 + 复制一遍列表 +
     * 同步落一次盘」,而 [com.yuyin.reverb.data.local.PlaybackStateStore.save] 每次都要序列化
     * 最多 `UP_NEXT_CAP`(300)条并 `writeText` —— 循环 N 次就是 N 次全量写盘。
     * 实测「追更」全选 1994 集走循环时主线程被占满,系统弹「余音没有响应」
     * (`Input dispatching timed out … Waited 5006ms for MotionEvent`),见 H186。
     * 这里把成本压成一条:去重靠 HashSet,写盘只有最后一次。
     *
     * 去重口径与 [enqueue] 一致(同 id 只进一次),但对**入参内部**的重复 id 也成立 ——
     * 循环版是靠"后一条撞上前一条已入队"实现的,批量版必须自己守住这条不变式:
     * 队列里永远没有重复 id。
     */
    fun enqueueAll(episodes: List<Episode>): Int {
        val current = _userQueue.value
        val seen = HashSet<String>(current.size + episodes.size).apply { current.forEach { add(it.id) } }
        val fresh = ArrayList<Episode>(episodes.size)
        for (e in episodes) {
            if (seen.add(e.id)) fresh.add(e)
        }
        // 日志无条件打:`added=0` 这一种正是「全选一列但整列都已在队列里」的那一轮,
        // 装机时要靠它证明按钮确实按上了。放在提前 return 之后就成了静默路径。
        log.i(TAG, "enqueueAll added=${fresh.size} of=${episodes.size} size=${current.size + fresh.size}")
        if (fresh.isEmpty()) return 0
        _userQueue.value = current + fresh
        updateNavFlags()
        persistState()
        return fresh.size
    }

    /** 插到队首:下一个就播它(去重后置顶)。 */
    fun playNext(episode: Episode) {
        _userQueue.value = listOf(episode) + _userQueue.value.filterNot { it.id == episode.id }
        log.i(TAG, "playNext id=${episode.id} size=${_userQueue.value.size}")
        updateNavFlags()
        persistState()
    }

    fun removeFromQueue(episodeId: String) {
        _userQueue.value = _userQueue.value.filterNot { it.id == episodeId }
        log.i(TAG, "removeFromQueue id=$episodeId size=${_userQueue.value.size}")
        updateNavFlags()
        persistState()
    }

    fun move(from: Int, to: Int) {
        val list = _userQueue.value.toMutableList()
        if (from !in list.indices || to !in list.indices || from == to) return
        list.add(to, list.removeAt(from))
        _userQueue.value = list
        log.i(TAG, "queue move $from -> $to")
        persistState()
    }

    fun clearQueue() {
        if (_userQueue.value.isEmpty()) return
        _userQueue.value = emptyList()
        log.i(TAG, "clearQueue")
        updateNavFlags()
        persistState()
    }

    /** 取出指定位置的一集并播放(队列上下文改为单曲,本集播完按剩余队列/上下文推进);索引无效返回 false。 */
    private fun playQueueAt(index: Int): Boolean {
        val head = _userQueue.value.getOrNull(index) ?: return false
        _userQueue.value = _userQueue.value.filterIndexed { i, _ -> i != index }
        log.i(TAG, "play from userQueue id=${head.id} remaining=${_userQueue.value.size}")
        // 队列上下文改为单曲:清空列表队列,导航标志据剩余用户队列刷新
        queue = listOf(head)
        queueIndex = 0
        if (_playMode.value == PlayMode.SHUFFLE) rebuildShuffleOrder() else clearShuffleOrder()
        // 上下文队列换成了这一条:此后自动续播按「用户队列优先」走,列表模式暂时管不到它。
        // **不动 `_activeListTag`** —— 生效的那格模式没变(还是原来那一列存的),
        // 在这里清成空串会让那一列的按钮当场失去"改了就生效",与用户的感受相反。
        updateNavFlags()
        playEpisode(head, isRadio = false)
        return true
    }

    /** 点击队列单集直接跳播:从队列摘出立即播,其余顺序不动。 */
    fun playFromQueue(episodeId: String) {
        playQueueAt(_userQueue.value.indexOfFirst { it.id == episodeId })
    }

    private val _current = MutableStateFlow<Episode?>(null)
    val current: StateFlow<Episode?> = _current

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying

    private val _position = MutableStateFlow(0L)
    val position: StateFlow<Long> = _position

    private val _duration = MutableStateFlow(0L)
    val duration: StateFlow<Long> = _duration

    private val _buffering = MutableStateFlow(false)
    val buffering: StateFlow<Boolean> = _buffering

    /**
     * 一次播放失败(给界面的那一份)。原先什么都不暴露:`onPlayerError` 只 `log.e` 就结束,
     * 于是流式播放断网之后的表现是"暂停键按下去没反应、进度线冻住、没有任何提示"
     * —— 用户只能杀掉 App。见 REVIEW-2026-10-25 中-1。
     *
     * ⚠️ **UI 挂载待后续**:这一份状态目前没有消费方(播放页没留错误位,也不该为它新造文案 ——
     * 五语字符串不能凭空塞没翻译的中文串)。当场能救回症状的是 [togglePlayPause] 里那条 IDLE 分支
     * (用户按播放键即整集重投),这一份 StateFlow 是给后续那一颗「重试」/一条提示用的数据出口。
     *
     * @param retrying 自动重投还在进行中(界面此刻不该报"失败",报"重试中"更准)
     * @param retriesUsed 本集已经自动重投过几次(上限 [MAX_ERROR_RETRIES])
     */
    data class PlaybackError(
        val episodeId: String,
        val code: Int,
        val codeName: String,
        val retrying: Boolean,
        val retriesUsed: Int
    )

    private val _playbackError = MutableStateFlow<PlaybackError?>(null)
    val playbackError: StateFlow<PlaybackError?> = _playbackError

    /**
     * 网络/IO 类出错的自动重投次数与归属那一集。
     *
     * 清零口径是**「起新一集」**,不是「调用 playEpisode」:两者必须分开,因为 [retryNow] 与
     * 睡眠/电台路径都会拿**同一集**再走一次 playEpisode —— 若按后者清零,这一集就能无限重试
     * (错误 → 重投 → 再错 → 计数被自己清掉)。见 [playEpisode] 里那段。
     */
    private var errorRetries = 0
    private var errorRetryEpisodeId = ""

    /**
     * 退避重投的动作本体(用 handler 排,和淡入淡出同一套法):
     * Media3 的控制器调用必须留在主线程,而这里要的只是"过一会儿再 prepare 一次"。
     */
    private val errorRetryRunnable = Runnable {
        val c = controller ?: return@Runnable
        val ep = _current.value ?: return@Runnable
        if (ep.id != errorRetryEpisodeId) return@Runnable   // 期间已换集,这次重投作废
        if (c.playbackState != Player.STATE_IDLE) {
            log.i(TAG, "自动重投跳过:播放器已不在 IDLE(state=${c.playbackState}) id=${ep.id}")
            return@Runnable
        }
        // IDLE 下 seekTo 的位置会在下次 prepare 时生效(Media3 文档口径),所以重投不掉进度。
        // 不这么做的后果不只是"从头播":播起来后 ticker 每约 5 秒把 currentPosition 写回历史,
        // 等于把用户上次听到的那一秒抹成 0 —— 那一集还会从「继续收听」里消失(按 10 秒筛)。
        val resumeAt = _position.value
        log.w(TAG, "自动重投 #$errorRetries/$MAX_ERROR_RETRIES id=${ep.id} resume=${resumeAt}ms")
        runCatching {
            if (resumeAt > 0) c.seekTo(resumeAt)
            c.prepare()
        }.onFailure { log.e(TAG, "自动重投失败 id=${ep.id}", it) }
    }

    val speedSteps = listOf(0.8f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f)
    private val _speed = MutableStateFlow(1.0f)
    val speed: StateFlow<Float> = _speed

    // 睡眠定时：剩余毫秒（0=关闭）、或「本集结束」模式
    private val _sleepRemainingMs = MutableStateFlow(0L)
    val sleepRemainingMs: StateFlow<Long> = _sleepRemainingMs
    private val _sleepEndOfEpisode = MutableStateFlow(false)
    val sleepEndOfEpisode: StateFlow<Boolean> = _sleepEndOfEpisode

    fun bindHistory(h: HistoryStore) { history = h }

    fun bindListenStats(s: com.yuyin.reverb.data.local.ListenStatsStore) { listenStats = s }

    /**
     * 跨启动的播放态存储(「正在播哪一集 / 它来自哪一列 / 排好的 up next」)。
     * 没绑上时持久化与恢复都静默跳过 —— 单测与预览场景不需要它。
     */
    fun bindState(s: com.yuyin.reverb.data.local.PlaybackStateStore) { stateStore = s }

    /**
     * 把当前播放态写下去。**电台模式例外:那一档没有可恢复的身份** —— 电台的「上一集/下一集」
     * 走的是内存里的 radioHistory(随机抓来的节目序列,退出即弃),把它写成上下文队列
     * 会让重启后的「下一集」跳进一个毫不相干的列表。所以电台期间只留 up next、清空 current。
     */
    private fun persistState() {
        val st = stateStore ?: return
        if (_radioMode.value) st.save(null, "", emptyList(), 0, _userQueue.value)
        else st.save(_current.value, _activeListTag.value, queue, queueIndex, _userQueue.value)
    }

    fun bindSettings(s: SettingsStore) {
        settings = s
        _speed.value = s.defaultSpeed.value // 启动即套用默认倍速
        // 各列的模式是老用户存过的偏好,起来就恢复;存的 ordinal 越界(降级安装)按默认处理。
        // 生效值先取**回落值**:此刻还没有任何列在播。
        refreshPlayModes()
        _playMode.value = _playModes.value.getValue("")
    }

    fun skipForward() = seekBy((settings?.skipForwardSec?.value ?: 30) * 1000L)
    fun skipBackward() = seekBy(-((settings?.skipBackSec?.value ?: 10) * 1000L))

    fun init(context: Context) {
        if (controller != null) return
        val appCtx = context.applicationContext
        val token = SessionToken(appCtx, ComponentName(appCtx, PlaybackService::class.java))
        val future = MediaController.Builder(appCtx, token).buildAsync()
        future.addListener({
            try {
                val c = future.get()
                controller = c
                c.addListener(playerListener)
                log.i(TAG, "controller connected")
                // 控制器还没起来时用户已经点了某一集:这里只补播那一集,**不要动队列**。
                // 原先这里跟着写了 `queue = listOf(ep); queueIndex = 0`,于是"从追更列表第 20 集点开、
                // 冷启动第一次点"这种场景下整列上下文被抹成单曲 —— 上一集/下一集当场变灰,
                // 播完也不会自动接下一集。pending 只可能由 playEpisode 设置,而它的每个调用方
                // (playQueue / playQueueAt / advanceQueue / previous / restoreState / playRadioEpisode)
                // 都已经**在自己那一处把 queue 摆好了**,这里再盖一次纯属多余且是错的。
                // 见 REVIEW-2026-10-25 低·族 C-2。
                pending?.let { ep -> pending = null; updateNavFlags(); playEpisode(ep) }
                // **syncOnce 要排在恢复之前**:它用播放器的 currentPosition 刷进度线,而预载那一刻
                // currentPosition 还是 0 —— 排在后面的话它会把 restoreState 里"先按历史画"那一笔覆盖掉,
                // 界面读到的是 0:00,正是那条注释里说要防的"看着像进度丢了"。
                syncOnce()
                // 恢复要排在「连上控制器之后」,且**只在服务里真的没挂着东西时做**:
                // currentMediaItem 非空说明这是同一次会话里的重连(或后台服务还活着),
                // 那时拿旧快照覆盖会把正在播的现场改掉 —— 比丢队列更糟。
                if (_current.value == null && c.currentMediaItem == null) restoreState()
            } catch (e: Exception) {
                log.e(TAG, "controller connect failed", e)
            }
        }, ContextCompat.getMainExecutor(appCtx))
    }

    /**
     * 冷启动把上次退出时的播放态读回来。用户报的是「加入队列的节目下次打开 app 就消失」,
     * 而一起丢的其实是同一份内存里的三样东西:`up next`、**正在播哪一集**、
     * 以及**这一集来自哪一列**(后者决定上/下一集与「播完自动接下一集」)。
     * 只丢了它们中的任何一样,表现都是"重启后要回历史里凭标题把那一集再点一次"。
     *
     * 口径(2026-10-02 定):**恢复现场,不恢复意图** —— 不自动开播,但把这一集预载到就绪,
     * 于是迷你条上的进度是播放器真值、按下播放键即刻出声。
     */
    private fun restoreState() {
        val st = stateStore ?: return
        val snap = st.snapshot
        if (snap.isEmpty) return
        if (snap.upNext.isNotEmpty()) {
            _userQueue.value = snap.upNext
            log.i(TAG, "restore upNext=${snap.upNext.size}")
        }
        // 引导音频不是一集真正的节目,不该在重启后又冒出来占住播放条
        val saved = snap.current
        val cur = saved?.takeUnless { com.yuyin.reverb.data.model.GuideEpisode.isGuide(it.id) }
        if (cur == null) {
            // 读侧跳过之外还要**重写一次**:否则引导音频会一直留在文件里,
            // 每次冷启动都白跳一遍,而它占着的那格本可以放真正在播的那一集。
            if (saved != null) {
                log.i(TAG, "restore 忽略引导音频,重写播放态")
                persistState()
            }
            updateNavFlags()
            return
        }
        queue = if (snap.context.any { it.id == cur.id }) snap.context else listOf(cur)
        queueIndex = queue.indexOfFirst { it.id == cur.id }.coerceAtLeast(0)
        _activeListTag.value = snap.listTag
        // 先按那一列存着的模式建好随机表,再装载(顺序错了会让随机模式的下一集指回原列表)
        applyPlayMode(modeFor(snap.listTag))
        // **上/下一集的可点状态要在这里刷一次,不是"反正播起来会刷"**:恢复走的是直接装载
        // (不调 playQueue),而 `syncOnce` 只同步进度与播放态、不碰这两个 flag;
        // 预载又是暂停态,`onIsPlayingChanged` 也不会为它触发一次。
        // 少这一行的症状是"重启后那两颗按钮灰着,按下播放才亮" —— 而这一列的上下文明明已经读回来了。
        updateNavFlags()
        log.i(TAG, "restore cur='${cur.title}' ctx=${queue.size}@$queueIndex tag='${snap.listTag}' mode=${_playMode.value}")
        playEpisode(cur, autoplay = false)
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _isPlaying.value = isPlaying
            if (isPlaying) { playbackStarted = true; startTicker() } else { stopTicker(); saveProgress(); listenStats?.flush() }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            _buffering.value = playbackState == Player.STATE_BUFFERING
            val c = controller
            when (playbackState) {
                Player.STATE_BUFFERING -> log.d(TAG, "state BUFFERING id=${_current.value?.id}")
                Player.STATE_READY -> {
                    // 装载成功就是"已经恢复了",失败态(包括"重试中"那一档)到此作废。
                    // 不在这里清的话,自动重投成功后界面那份错误仍挂着,读起来像"还在失败",
                    // 而这一份状态将来是要点亮界面提示的 —— 见 REVIEW-2026-10-25 中-1。
                    _playbackError.value = null
                    log.d(TAG, "state READY dur=${c?.duration} id=${_current.value?.id}")
                }
                Player.STATE_ENDED -> log.i(TAG, "state ENDED id=${_current.value?.id}")
                Player.STATE_IDLE -> log.d(TAG, "state IDLE")
            }
            if (c != null && c.duration > 0) _duration.value = c.duration

            if (playbackState == Player.STATE_READY && pendingSeekMs > 0 && c != null) {
                val dur = c.duration
                // 两种起点，两套容差，**不能共用**：
                //  · 续播沿用原启发式 —— 距片尾 10 秒内不如从头播（那是"听完"而不是"听到一半"）；
                //  · 明确跳转(点批注)只受「别跳过片尾」约束。若让它也吃那条 10 秒规则，
                //    写在片尾 8 秒处的批注就永远点不开(点了落回 0:00)，而这是用户**指定**的位置。
                val ceiling = if (dur > 0) dur - 2_000 else Long.MAX_VALUE
                val ok = if (pendingSeekExplicit) {
                    pendingSeekMs < ceiling
                } else {
                    pendingSeekMs > 3_000 && (dur <= 0 || pendingSeekMs < dur - 10_000)
                }
                if (ok) {
                    c.seekTo(pendingSeekMs)
                    // 落位之后**自己记一次**:ticker 只在播放中跑,而预载(暂停态)永远不会播,
                    // 不记的话进度线就一直停在预载时画的近似值上。
                    _position.value = pendingSeekMs
                } else {
                    _position.value = 0
                    log.i(TAG, "跳点落空 seek=$pendingSeekMs dur=$dur explicit=$pendingSeekExplicit")
                }
                pendingSeekExplicit = false
                pendingSeekMs = 0
            }
            if (playbackState == Player.STATE_ENDED) {
                val stopAfterThis = _sleepEndOfEpisode.value // 睡眠「本集结束」优先于电台/队列续播
                _sleepEndOfEpisode.value = false
                // 自然听完:进度归零并标记已播完(引导音频除外 —— 它不进历史)
                _current.value?.let {
                    if (!com.yuyin.reverb.data.model.GuideEpisode.isGuide(it.id)) {
                        history?.updatePosition(it.id, 0, c?.duration ?: 0)
                        history?.markPlayed(it.id, true)
                    }
                }
                listenStats?.flush()
                when {
                    stopAfterThis -> Unit
                    // 电台模式:本集播完自动抓下一首随机节目续播
                    _radioMode.value -> advanceRadio()
                    // 用户队列非空:自动接上队首,连续收听
                    _userQueue.value.isNotEmpty() -> playQueueAt(0)
                    // 上下文队列(点某一集起播的):按播放模式接下一集。
                    // 这条分支是加播放按钮那轮补上的 —— 之前列表播完一集就停在这里,
                    // 只有手动按下一集会走。现在**随机与单曲循环两档全靠它成立**
                    // (单曲循环就是这里的 auto 路径,见 advanceQueue)。
                    else -> advanceQueue(auto = true)
                }
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            log.e(TAG, "onPlayerError code=${error.errorCode} name=${error.errorCodeName} id=${_current.value?.id}", error)
            // 原先这里只有一句 log.e(见 REVIEW-2026-10-25 中-1):流式播放一旦断网,播放器进 STATE_IDLE,
            // 之后按播放键走的是 `controller.play()` —— 而 IDLE 下 play() 是空操作(见 [togglePlayPause]),
            // 于是"这一集再也播不了",只能杀掉 App。现在分两件事:
            //  ① 瞬时类(网络/IO)自动重投有限几次(退避 500ms、1s),超出上限把失败态留给用户;
            //  ② 无论重试与否都**对外可见**([playbackError]),界面挂载待后续(见那里的注释)。
            //
            // 只把 `ERROR_CODE_IO_*` 里"重投一次有可能就好"的那几个算可重试:
            //  - FILE_NOT_FOUND / NO_PERMISSION 多为**本地文件被清掉了**(下载件或缓存件在播放器之外被删),
            //    重投同一个 URI 永远不会好,正确走法是重走一遍起播让源重新选(下载 > 缓存 > 流式),
            //    那正是 [retryNow] / [togglePlayPause] 那条路;
            //  - PARSING_* / DECODER_* 是这一份流本身解不出来,重投也是白投。
            val ep = _current.value
            val transient = when (error.errorCode) {
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                PlaybackException.ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE,
                PlaybackException.ERROR_CODE_IO_UNSPECIFIED -> true
                else -> false
            }
            // 只有"错的还是当前这一集"才允许重投:期间用户已经点了别的集的话,
            // 那次 prepare 会把新一集重新装载一遍,读起来像"点了没反应又从头播"。
            if (transient && ep != null && ep.id == errorRetryEpisodeId && errorRetries < MAX_ERROR_RETRIES) {
                errorRetries++
                val delayMs = RETRY_BASE_MS shl (errorRetries - 1)
                _playbackError.value = PlaybackError(ep.id, error.errorCode, error.errorCodeName, true, errorRetries)
                log.w(TAG, "播放出错 ${error.errorCodeName},第 $errorRetries/$MAX_ERROR_RETRIES 次自动重投(${delayMs}ms 后) id=${ep.id}")
                handler.removeCallbacks(errorRetryRunnable)
                handler.postDelayed(errorRetryRunnable, delayMs)
            } else {
                // 非瞬时类:记为"这一集没有可自动重投的失败",但**不清计数**,
                // 于是同一集反复出非瞬时错也不会形成循环。
                _playbackError.value = PlaybackError(
                    ep?.id ?: "", error.errorCode, error.errorCodeName, false, errorRetries
                )
                log.e(TAG, "播放失败不重投(transient=$transient) name=${error.errorCodeName} id=${ep?.id}")
            }
            // 出错时把已听到的位置立刻写回历史:之后的自动重投/暂停回写都以这一笔为基线,
            // 别让"卡在坏位置上"变成第二件事。saveProgress 自己有 playbackStarted 地闸。
            saveProgress()
        }
    }

    /** 播放单集(单条,无上下文):等价于队列只有它自己,无上/下一集。 */
    fun play(episode: Episode) = playQueue(listOf(episode), 0)

    /**
     * 从**指定那一秒**开始播某一集(批注列表「跳回那一句」用)。
     *
     * 与 [play] 的差别只有一处:起点。默认路径的起点来自历史进度(续播),
     * 这里由调用方指定 —— 所以它必须绕开 `history.positionFor`,否则列表里每一条
     * 都落到同一个位置(上次听到的那一秒),整个功能的表现就是"点了没反应"。
     *
     * 队列只放这一集(与 [play] 一致):批注是跨集的时间线,把整条列表塞进队列
     * 会让「下一集」跳出用户点的那一集，语义上不对，也与发现页/历史页的单播口径一致。
     */
    fun playAt(episode: Episode, startMs: Long) {
        log.i(TAG, "playAt ${startMs}ms id=${episode.id}")
        startMsOverride = startMs.coerceAtLeast(0L)
        play(episode)
    }

    /**
     * 从一个列表开始播放:该列表成为队列,决定上/下一集。startIndex 为起播位置。
     *
     * @param tag 队列身份("inbox" / "fav" / "dl" / 频道主页用 "podcast:<feedUrl>")。三个用途:
     *   ① 起播时按**这一列自己存着的播放模式**走(见 [modeFor]);② 日志里的列身份
     *   (`playQueue count=… tag='inbox'`,装机验收靠这一行判断点的是哪一段);
     *   ③ [setPlayModeFor] 判断"改的是不是正在播那一列"。
     *   不属于任何可见列表的入口(「下一个播放」摘出来单播、迷你条、发现页)不传(空串),
     *   空串走的是**回落值**。
     */
    fun playQueue(episodes: List<Episode>, startIndex: Int, tag: String = "") {
        if (episodes.isEmpty()) return
        if (_radioMode.value) stopRadio() // 进入列表上下文即退出电台
        queue = episodes
        queueIndex = startIndex.coerceIn(0, episodes.lastIndex)
        _activeListTag.value = tag
        // 先定模式再播:随机要在这一步把表洗出来(当前集钉在第一位)
        applyPlayMode(modeFor(tag))
        log.i(TAG, "playQueue count=${episodes.size} index=$queueIndex tag='$tag' mode=${_playMode.value}")
        playEpisode(episodes[queueIndex], isRadio = false)
    }

    // ---- 播放模式 ----
    /** 顺序 → 单曲循环 → 随机 → 顺序。某一列右端那颗模式按钮点一下就走这一列自己的那一格。 */
    fun cyclePlayMode(tag: String) {
        val entries = PlayMode.entries
        val cur = modeFor(tag)
        setPlayModeFor(tag, entries[(entries.indexOf(cur) + 1) % entries.size])
    }

    /**
     * 设定**某一列**的播放模式并落盘。
     *
     * 只有改的正是**正在播那一列**时才当场生效;改别的列只是记下它以后的走法 ——
     * 否则「看着收藏但正在播最新」时点一下就把正在播的走法改掉了,那才是真的串。
     */
    fun setPlayModeFor(tag: String, mode: PlayMode) {
        settings?.setPlayModeFor(tag, mode.ordinal)
        refreshPlayModes()
        log.i(TAG, "playMode tag='$tag' -> $mode${if (tag == _activeListTag.value) " (生效)" else " (未生效:正在播 '${_activeListTag.value}')"}")
        if (tag == _activeListTag.value) applyPlayMode(mode)
    }

    /**
     * 让某个模式**当场生效**:切进随机要重洗一次表并把当前集钉在第一位
     * (否则从顺序切进随机后「下一集」还按列表顺序走,等于没切);切出随机则丢掉表。
     * 落盘不在这里 —— 模式按列存,见 [setPlayModeFor]。
     */
    private fun applyPlayMode(mode: PlayMode) {
        _playMode.value = mode
        if (mode == PlayMode.SHUFFLE) rebuildShuffleOrder() else clearShuffleOrder()
        updateNavFlags()
    }

    /** 电台首集/续播用:计入电台历史后播放。 */
    fun playRadioEpisode(episode: Episode) {
        log.i(TAG, "playRadioEpisode id=${episode.id} title='${episode.title}'")
        radioHistory.add(episode)
        while (radioHistory.size > radioHistoryCap) radioHistory.removeAt(0)
        radioPos = radioHistory.lastIndex
        updateNavFlags()
        playEpisode(episode, isRadio = true)
    }

    /** 下一集:列表按当前播放模式走(顺序/循环/随机),电台优先回放历史前进、到末尾则抓新的随机。 */
    fun next() {
        log.i(TAG, "next radio=${_radioMode.value} queueIndex=$queueIndex radioPos=$radioPos mode=${_playMode.value}")
        if (_radioMode.value) {
            if (radioPos in 0 until radioHistory.lastIndex) {
                radioPos++; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio = true)
            } else advanceRadio()
        } else if (_userQueue.value.isNotEmpty()) {
            playQueueAt(0) // 用户队列优先:取队首播放
        } else advanceQueue()
    }

    /** 上一集:列表回退一集(随机模式沿随机表回退);电台回退到刚听过的那期。 */
    fun previous() {
        log.i(TAG, "previous radio=${_radioMode.value} queueIndex=$queueIndex radioPos=$radioPos mode=${_playMode.value}")
        if (_radioMode.value) {
            if (radioPos > 0) { radioPos--; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio = true) }
        } else {
            val pi = prevQueueIndex() ?: return
            if (_playMode.value == PlayMode.SHUFFLE) shufflePos--
            queueIndex = pi
            updateNavFlags()
            playEpisode(queue[queueIndex], isRadio = false)
        }
    }

    private fun playEpisode(episode: Episode, isRadio: Boolean = false, autoplay: Boolean = true) {
        log.i(TAG, "play id=${episode.id} title='${episode.title}' radio=$isRadio auto=$autoplay")
        // 手动播放任意单集即退出电台;电台内部续播/换台传 isRadio=true 保持在台
        if (!isRadio && _radioMode.value) stopRadio()
        _current.value = episode
        // 起**新一集**才清失败计数与失败态。口径必须是"换集",不能是"调用 playEpisode":
        // [retryNow] 和睡眠/电台路径都会拿**同一集**再走一次这里,若按调用清零就成了
        // 「出错 → 重投 → 计数被自己清掉 → 再出错」的死循环。见 REVIEW-2026-10-25 中-1。
        if (episode.id != errorRetryEpisodeId) {
            errorRetries = 0
            errorRetryEpisodeId = episode.id
            _playbackError.value = null
            handler.removeCallbacks(errorRetryRunnable)   // 上一集排着的自动重投作废
        }
        playbackStarted = false   // 换集即重新计数:见 saveProgress 那道地闸
        persistState()
        val c = controller
        if (c == null) {
            log.w(TAG, "controller not ready, pending id=${episode.id}")
            pending = episode
            return
        }
        _position.value = 0
        _duration.value = 0
        // 内置引导音频不是一集真正的播客：不进历史、不计收听时长，
        // 否则"收听时长"榜首会是引导音频，「继续收听」里也会挂着它。
        val isGuide = com.yuyin.reverb.data.model.GuideEpisode.isGuide(episode.id)
        if (!isGuide) history?.record(episode, System.currentTimeMillis())
        pendingSeekMs = if (startMsOverride >= 0) {
            val s = startMsOverride
            startMsOverride = -1L
            pendingSeekExplicit = true
            s
        } else if (isGuide) {
            0L
        } else {
            pendingSeekExplicit = false
            history?.positionFor(episode.id) ?: 0L
        }
        listenStats?.flush()   // 结算上一集残余
        lastCountedEpId = episode.id     // 统计基线对齐续播起点，避免把 resume 跳转记成收听
        lastCountedPosMs = pendingSeekMs

        // 选源三级:**下载 > 缓存 > 流式**。
        // 下载排在最前是因为它是用户点名留下的那一份,语义上比 App 自作主张的缓存更"该被用"。
        // 落到流式那一路才排后台整集缓存 —— 这里是「播过就不要再联网」的唯一触发点,
        // 放在播放而不是列表/详情页,是因为只有这一处代表用户真的要听这一集。
        val downloaded = DownloadManager.localPath(episode.id)?.takeIf { File(it).exists() }
        val cached = if (downloaded == null) AudioCacheManager.localPath(episode.id) else null
        val local = downloaded ?: cached
        log.d(TAG, "source ${if (local != null) if (downloaded != null) "local" else "cache" else "stream"} " +
            "seekTo=$pendingSeekMs id=${episode.id}")
        if (cached != null) AudioCacheManager.onPlayFromCache(episode.id)  // LRU 要记"这次真的听了它"
        // **电台那一路不缓存**:它是"无限随机换台",每一台都触发一次几十 MB 的整集拉取,
        // 用户听着玩一小时就能把预算刷爆。判据用调用点传进来的 isRadio,而不是 _radioMode,
        // 因为手动播放会先 stopRadio 再进来 —— 到这儿时那个字段已经是 false。
        if (local == null && !isRadio) AudioCacheManager.cache(episode)
        val uri = if (local != null) Uri.fromFile(File(local)) else Uri.parse(episode.audioUrl)

        val item = MediaItem.Builder()
            .setUri(uri)
            .setMediaId(episode.id)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(episode.title)
                    .setArtist(episode.podcastTitle)
                    .apply {
                        if (episode.artworkUrl.isNotBlank()) setArtworkUri(Uri.parse(episode.artworkUrl))
                    }
                    .build()
            )
            .build()
        c.setMediaItem(item)
        if (!autoplay) {
            // 恢复路径:装载到「就绪但没播」。**playWhenReady 必须在 prepare 之前按下去** ——
            // MediaController 的 playWhenReady 会保留上一次的值(默认 true),
            // 先 prepare 再置 false 会听到一集开头自己响起来,那正是"没经同意就自动播"。
            c.volume = 1f
            c.playWhenReady = false
            c.prepare()
            c.setPlaybackSpeed(_speed.value)
            // 进度线先按历史位置画出来:真正的位置要等 READY 那次 seek,而 READY 之前
            // 这一格是 0 —— 播放条上"0:00 / 42:10"会被读成进度丢了(而它其实只是还没落位)。
            _position.value = pendingSeekMs
            log.i(TAG, "预载(暂停) id=${episode.id} seek=$pendingSeekMs")
            return
        }
        c.prepare()
        c.setPlaybackSpeed(_speed.value)
        c.volume = 0f
        c.play()
        fadeVolume(from = 0f, to = 1f, durationMs = fadeInMs)
    }

    // 分步渐变音量(主线程 handler 驱动),用于淡入淡出
    private val fadeStepMs = 50L
    private fun fadeVolume(from: Float, to: Float, durationMs: Long, onEnd: (() -> Unit)? = null) {
        val c = controller ?: return
        handler.removeCallbacks(fadeRunnable)
        val steps = (durationMs / fadeStepMs).coerceAtLeast(1)
        var i = 0
        fadeRunnable = object : Runnable {
            override fun run() {
                i++
                val t = (i.toFloat() / steps).coerceIn(0f, 1f)
                c.volume = (from + (to - from) * t).coerceIn(0f, 1f)
                if (i < steps) handler.postDelayed(this, fadeStepMs) else onEnd?.invoke()
            }
        }
        c.volume = from.coerceIn(0f, 1f)
        handler.postDelayed(fadeRunnable, fadeStepMs)
    }
    private var fadeRunnable: Runnable = Runnable {}

    fun playOrToggle(episode: Episode) {
        if (_current.value?.id == episode.id && controller != null) togglePlayPause() else play(episode)
    }

    /**
     * 队列版:同一集则暂停/继续,否则以该列表为队列从此集起播。
     *
     * @param tag 与 [playQueue] 同一个队列身份,行内点起播也照传(它只进日志,见那边)。
     */
    fun playOrToggle(episode: Episode, queue: List<Episode>, tag: String = "") {
        if (_current.value?.id == episode.id && controller != null) togglePlayPause()
        else playQueue(queue, queue.indexOfFirst { it.id == episode.id }.coerceAtLeast(0), tag)
    }

    // ---- 随机电台 ----
    /** 开启电台:登记「下一首」provider 并进入电台模式,清空上次电台历史。 */
    fun startRadio(next: suspend () -> Episode?) {
        log.i(TAG, "radio start")
        radioNext = next
        radioHistory.clear()
        radioPos = -1
        _radioMode.value = true
    }

    fun stopRadio() {
        log.i(TAG, "radio stop")
        radioNext = null
        _radioMode.value = false
        updateNavFlags()
    }

    /**
     * 关闭播放条(迷你条上那枚 X):停止播放并清掉「正在播」的上下文。
     *
     * 语义上它是「把这一场关掉」,不是暂停 —— 所以 [current] 置空(迷你条的显隐门就是它,
     * `ReverbRoot.MiniPlayerBar` 的 AnimatedVisibility 与让位量都挂在这上面),上下文队列
     * ([queue] / [queueIndex])一并清掉;但 **[userQueue] 保留**:用户排的队是用户数据,
     * 「关掉正在播的」不该把它抹掉,持久化也写「无 current、留 upNext」而不是 `clear()`
     * (后者会把 upNext 一起删)。下次起播任何一集,条子带着队列照常回来。
     *
     * [cancelSleep] 与 [stopRadio] 必须显式调:睡眠定时到点只 pause(不再有正在播的内容,
     * 那个 ticker 空转);电台模式留着的话,持久化会走「只存 upNext」那条电台口径。
     * 播放器回 IDLE 用 [Player.stop] —— 之后 `playEpisode` 本来就重新 setMediaItem+prepare,
     * 不会有残留状态的路径。
     */
    fun close() {
        log.i(TAG, "close id=${_current.value?.id}")
        if (_radioMode.value) stopRadio()
        cancelSleep()
        val c = controller
        if (c != null) {
            c.pause()
            c.stop()
        }
        _playbackError.value = null
        _current.value = null
        _isPlaying.value = false
        queue = emptyList()
        queueIndex = 0
        persistState()
        updateNavFlags()
    }

    /** 本集播完:抓下一首随机节目续播;抓不到则自动关台。 */
    private fun advanceRadio() {
        val next = radioNext ?: return
        log.i(TAG, "radio advance")
        scope.launch {
            val ep = try { next() } catch (e: Exception) { log.e(TAG, "radio advance fetch failed", e); null }
            if (ep != null && _radioMode.value) playRadioEpisode(ep)
            else { log.w(TAG, "radio advance no episode, stopping"); stopRadio() }
        }
    }

    fun togglePlayPause() {
        val c = controller ?: return
        log.i(TAG, "togglePlayPause wasPlaying=${c.isPlaying} id=${_current.value?.id}")
        // 播放器在 STATE_IDLE 时 `play()` 是**空操作**(Media3 的口径:IDLE 不响应 play)。
        // 出错之后播放器正是 IDLE,于是"按播放键永远没反应"—— 这条就是那条反馈的本体,
        // 也是中-1 里"永久无法播"的实际手感。所以 IDLE + 暂停态这一路不走 play(),
        // 而是整集重投:重选源(下载 > 缓存 > 流式)、按历史续播、顺带清失败态与重试计数。
        // 这样界面**一个新按钮都不用加**,现有的播放键就是重试入口(playbackError 留给后续做提示)。
        if (!c.isPlaying && c.playbackState == Player.STATE_IDLE) {
            if (_current.value != null) {
                log.w(TAG, "IDLE 下按播放 → 整集重投 id=${_current.value?.id}")
                retryNow()
                return
            }
            // 没有当前集(IDLE 且内存里也没东西):按下就是不动,与改动前一致。
            log.w(TAG, "IDLE 且无当前集,播放键无动作")
            return
        }
        if (c.isPlaying) c.pause() else c.play()
    }

    /**
     * 完整重投当前这一集(用户侧的"重试")。**与自动重投的区别**是这条会重走一遍选源与续播:
     *  - 本地文件被清掉(ERROR_CODE_IO_FILE_NOT_FOUND)时,prepare() 重投同一个坏 URI 永远不会好,
     *    而这里会退到下一级源(缓存 → 流式);
     *  - 也顺带把 [errorRetries] 与 [playbackError] 归零,否则第二次再按就再也走不到自动那条路。
     *
     * ⚠️ UI 挂载待后续:目前没有"重试"按钮调它,播放键在 IDLE 下已经等价于它(见 [togglePlayPause]);
     * 留这个出口是给后续那条错误提示用的。见 REVIEW-2026-10-25 中-1。
     */
    fun retryNow(): Boolean {
        val ep = _current.value ?: return false
        log.i(TAG, "retryNow id=${ep.id} retriesResetFrom=$errorRetries")
        handler.removeCallbacks(errorRetryRunnable)
        errorRetries = 0
        _playbackError.value = null
        playEpisode(ep)
        return true
    }

    fun seekTo(ms: Long) {
        val target = ms.coerceAtLeast(0)
        val c = controller ?: return
        // IDLE(出错后 / 还没装载)时 `seekTo` 不会真的动,而原先这里无条件把 `_position` 改成目标值
        // —— 进度线滑过去、播放器原地不动,读起来就是"进度条被搞坏了",还会让下一次自动重投
        // 拿着这个假位置去 seek(见 errorRetryRunnable)。所以 IDLE 下**不更新 _position**,直接返回。
        // 见 REVIEW-2026-10-25 中-1 ③。
        if (c.playbackState == Player.STATE_IDLE) {
            log.w(TAG, "STATE_IDLE 下忽略拖动 ${target}ms(播放器没装载东西,动了也是假的)")
            return
        }
        log.d(TAG, "seekTo ${target}ms")
        c.seekTo(target)
        _position.value = target
    }

    fun seekBy(deltaMs: Long) {
        val c = controller ?: return
        // 与 [seekTo] 同一族的 IDLE 症状:IDLE 下 `currentPosition` 是 C.TIME_UNSET(Long.MIN_VALUE),
        // 加完增量再钳到 [0, …] 就得到"跳到 0:00"这个假结果(而且下一次进度回写会真的把历史抹成 0)。
        if (c.playbackState == Player.STATE_IDLE) {
            log.w(TAG, "STATE_IDLE 下忽略快进/快退 $deltaMs ms")
            return
        }
        val target = (c.currentPosition + deltaMs)
            .coerceIn(0, if (c.duration > 0) c.duration else Long.MAX_VALUE)
        log.d(TAG, "seekBy $deltaMs -> ${target}ms")
        c.seekTo(target)
        _position.value = target
    }

    fun cycleSpeed() {
        val idx = speedSteps.indexOfFirst { kotlin.math.abs(it - _speed.value) < 0.01f }
        setSpeed(speedSteps[(idx + 1).mod(speedSteps.size)])
    }

    fun setSpeed(s: Float) {
        log.i(TAG, "setSpeed $s")
        _speed.value = s
        controller?.setPlaybackSpeed(s)
    }

    // ---- 睡眠定时 ----
    fun setSleepTimer(minutes: Int) {
        log.i(TAG, "sleep timer set $minutes min")
        _sleepEndOfEpisode.value = false
        _sleepRemainingMs.value = minutes * 60_000L
        handler.removeCallbacks(sleepTicker)
        handler.postDelayed(sleepTicker, 1000)
    }

    fun setSleepEndOfEpisode() {
        log.i(TAG, "sleep timer set: end of episode")
        handler.removeCallbacks(sleepTicker)
        _sleepRemainingMs.value = 0
        _sleepEndOfEpisode.value = true
    }

    fun cancelSleep() {
        log.i(TAG, "sleep timer cancel")
        handler.removeCallbacks(sleepTicker)
        handler.removeCallbacks(fadeRunnable)
        _sleepRemainingMs.value = 0
        _sleepEndOfEpisode.value = false
        controller?.volume = 1f // 取消定时后恢复音量,避免停在渐弱中途
    }

    private val sleepTicker = object : Runnable {
        override fun run() {
            val remain = _sleepRemainingMs.value - 1000
            if (remain <= 0) {
                log.i(TAG, "sleep timer fired, pausing")
                _sleepRemainingMs.value = 0
                // 最后阶段已渐弱到接近 0,这里收尾:暂停并恢复音量供下次播放
                controller?.pause()
                controller?.volume = 1f
            } else {
                _sleepRemainingMs.value = remain
                // 进入最后 sleepFadeMs 窗口:按剩余比例线性渐弱
                if (remain <= sleepFadeMs) {
                    controller?.volume = (remain.toFloat() / sleepFadeMs).coerceIn(0f, 1f)
                }
                handler.postDelayed(this, 1000)
            }
        }
    }

    private fun saveProgress() {
        val c = controller ?: return
        val ep = _current.value ?: return
        // 引导音频不写历史：playEpisode 已跳过 record，这里若还写就会又建出一条
        if (com.yuyin.reverb.data.model.GuideEpisode.isGuide(ep.id)) return
        // **这一集在本会话里真的播出过声音,才允许回写进度。**
        // 冷启动预载(暂停态)会让"当前集"存在而播放器还没开始,此时 currentPosition 是 0
        // 或尚未落位的近似值,而 `onIsPlayingChanged(false)` 与退后台都可能触发这一次回写 ——
        // 那会把用户上次听到的位置**静默抹成 0**,而「继续收听」按 10 秒为门槛筛,
        // 抹零等于让那一集从列表里消失。症状正是本次要修的那条反馈的反面。
        if (!playbackStarted) return
        history?.updatePosition(ep.id, c.currentPosition.coerceAtLeast(0), if (c.duration > 0) c.duration else 0)
    }

    /**
     * 累计“实际播放过的内容毫秒”：仅当同一集、播放中、且增量为合理正向值(1..3000ms)时计入。
     * 快进/快退的大跳变(越界)与暂停(增量≈0)自然被剔除；倍速下按内容时长计。
     */
    private fun countListening() {
        val ep = _current.value ?: run { lastCountedEpId = ""; return }
        if (com.yuyin.reverb.data.model.GuideEpisode.isGuide(ep.id)) return   // 引导音频不计时长
        val pos = _position.value
        if (ep.id == lastCountedEpId) {
            val delta = pos - lastCountedPosMs
            if (_isPlaying.value && delta in 1L..3000L) listenStats?.add(ep, delta)
        }
        lastCountedPosMs = pos
        lastCountedEpId = ep.id
    }

    private fun syncOnce() {
        val c = controller ?: return
        _isPlaying.value = c.isPlaying
        _position.value = c.currentPosition.coerceAtLeast(0)
        if (c.duration > 0) _duration.value = c.duration
        if (c.isPlaying) startTicker()
    }

    private fun startTicker() {
        handler.removeCallbacks(ticker)
        handler.post(ticker)
    }

    private fun stopTicker() {
        handler.removeCallbacks(ticker)
    }

    private val ticker = object : Runnable {
        override fun run() {
            val c = controller ?: return
            _position.value = c.currentPosition.coerceAtLeast(0)
            if (c.duration > 0) _duration.value = c.duration
            countListening()
            tickCount++
            if (tickCount % 10 == 0) saveProgress() // 每约 5 秒落一次进度
            if (c.isPlaying) handler.postDelayed(this, 500)
        }
    }
}
