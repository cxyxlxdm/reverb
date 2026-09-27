package com.yuyin.reverb.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
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
 * 列表播放模式。顺序 = 播到列表末尾即停;循环 = 末尾回到开头接着播;
 * 随机 = 把这个列表打乱播一遍(走完表就停)。
 *
 * 持久化存的是 **ordinal**(SettingsStore 的 `play_mode`),所以**新增项只能加在末尾** ——
 * 中间插一个位置,老用户存的数就会指向另一个模式。
 */
enum class PlayMode { SEQUENTIAL, REPEAT, SHUFFLE }

/**
 * 播放门面：UI 与后台 [PlaybackService] 之间通过 Media3 MediaController 通信。
 * 集成：离线下载优先本地播放、播放历史记录与续播、睡眠定时。
 */
object PlayerController {

    private const val TAG = "Player"
    private val log = com.yuyin.reverb.util.Logger

    private var controller: MediaController? = null
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Episode? = null
    private var history: HistoryStore? = null
    private var settings: SettingsStore? = null
    private var listenStats: com.yuyin.reverb.data.local.ListenStatsStore? = null
    // 累计收听时长的基线：仅统计“同一集、播放中、合理正向增量”的内容毫秒
    private var lastCountedPosMs = 0L
    private var lastCountedEpId = ""
    private var pendingSeekMs: Long = 0
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

    // 播放模式:顺序 / 循环 / 随机。它是**跨会话的偏好**(存 SettingsStore),
    // 不是本次播放的临时状态 —— 用户选了循环,下次从列表起播还要按它走。
    private val _playMode = MutableStateFlow(PlayMode.SEQUENTIAL)
    val playMode: StateFlow<PlayMode> = _playMode

    // 队列的身份标签(如 "inbox" / "fav" / "dl"):音阁分段条右端那颗播放按钮用它分辨
    // 「现在播的就是这一段吗」—— 是 → 这次点击切模式;否 → 这次点击起播这一段。
    // 列表项自己点出来的队列没有标签(空串),不参与这个判断。
    private val _activeListTag = MutableStateFlow("")
    val activeListTag: StateFlow<String> = _activeListTag

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
            // 这里必须走 nextQueueIndex() 而不是自己算 +1:循环模式永远有下一集,
            // 随机模式看的是表指针而不是列表下标。
            _hasNext.value = _userQueue.value.isNotEmpty() || nextQueueIndex() != null
            _hasPrev.value = prevQueueIndex() != null
        }
    }

    /**
     * 当前播放模式下,上下文队列里的下一集下标;没有下一集返回 null(调用方就此停下)。
     *
     * ⚠️ 循环模式只在**队列多于一集**时回绕:不少入口播的是「单曲队列」
     * (`play(episode)`、从「接下来播放」里点某一行 —— 那里 queue 被刻意换成一条),
     * 无条件回绕会让那一集无限重播,而用户要循环的是他点播放按钮的那个列表。
     */
    private fun nextQueueIndex(): Int? = when (_playMode.value) {
        PlayMode.SEQUENTIAL -> if (queueIndex in 0 until queue.size - 1) queueIndex + 1 else null
        PlayMode.REPEAT -> if (queue.size > 1) (queueIndex + 1).mod(queue.size) else null
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
     * 沿当前播放模式走到队列的下一集并播它;走到头(顺序播完 / 随机走完表 / 单曲队列)
     * 返回 false,由调用方停下。
     */
    private fun advanceQueue(): Boolean {
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
    }

    /** 插到队首:下一个就播它(去重后置顶)。 */
    fun playNext(episode: Episode) {
        _userQueue.value = listOf(episode) + _userQueue.value.filterNot { it.id == episode.id }
        log.i(TAG, "playNext id=${episode.id} size=${_userQueue.value.size}")
        updateNavFlags()
    }

    fun removeFromQueue(episodeId: String) {
        _userQueue.value = _userQueue.value.filterNot { it.id == episodeId }
        log.i(TAG, "removeFromQueue id=$episodeId size=${_userQueue.value.size}")
        updateNavFlags()
    }

    fun move(from: Int, to: Int) {
        val list = _userQueue.value.toMutableList()
        if (from !in list.indices || to !in list.indices || from == to) return
        list.add(to, list.removeAt(from))
        _userQueue.value = list
        log.i(TAG, "queue move $from -> $to")
    }

    fun clearQueue() {
        if (_userQueue.value.isEmpty()) return
        _userQueue.value = emptyList()
        log.i(TAG, "clearQueue")
        updateNavFlags()
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
        // 上下文队列换成了这一条,分段条那颗播放按钮不再「管着」正在播的列表
        // (按钮回到「点我起播这一段」的语义,见 _activeListTag)
        _activeListTag.value = ""
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

    fun bindSettings(s: SettingsStore) {
        settings = s
        _speed.value = s.defaultSpeed.value // 启动即套用默认倍速
        // 播放模式是老用户存过的偏好,起来就恢复;存的 ordinal 越界(降级安装)按默认处理
        _playMode.value = PlayMode.entries.getOrNull(s.playMode.value) ?: PlayMode.SEQUENTIAL
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
                pending?.let { ep -> pending = null; queue = listOf(ep); queueIndex = 0; updateNavFlags(); playEpisode(ep) }
                syncOnce()
            } catch (e: Exception) {
                log.e(TAG, "controller connect failed", e)
            }
        }, ContextCompat.getMainExecutor(appCtx))
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _isPlaying.value = isPlaying
            if (isPlaying) startTicker() else { stopTicker(); saveProgress(); listenStats?.flush() }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            _buffering.value = playbackState == Player.STATE_BUFFERING
            val c = controller
            when (playbackState) {
                Player.STATE_BUFFERING -> log.d(TAG, "state BUFFERING id=${_current.value?.id}")
                Player.STATE_READY -> log.d(TAG, "state READY dur=${c?.duration} id=${_current.value?.id}")
                Player.STATE_ENDED -> log.i(TAG, "state ENDED id=${_current.value?.id}")
                Player.STATE_IDLE -> log.d(TAG, "state IDLE")
            }
            if (c != null && c.duration > 0) _duration.value = c.duration

            if (playbackState == Player.STATE_READY && pendingSeekMs > 0 && c != null) {
                val dur = c.duration
                if (pendingSeekMs > 3_000 && (dur <= 0 || pendingSeekMs < dur - 10_000)) {
                    c.seekTo(pendingSeekMs)
                }
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
                    // 上下文队列(从一个列表起播的):按播放模式接下一集。
                    // 这条分支是加播放按钮时补上的 —— 之前列表播完一集就停在这里,
                    // 只有手动按下一集会走;「点一下播这个列表 + 循环/随机」不先补续播就不成立。
                    else -> advanceQueue()
                }
            }
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            log.e(TAG, "onPlayerError code=${error.errorCode} name=${error.errorCodeName} id=${_current.value?.id}", error)
        }
    }

    /** 播放单集(单条,无上下文):等价于队列只有它自己,无上/下一集。 */
    fun play(episode: Episode) = playQueue(listOf(episode), 0)

    /**
     * 从一个列表开始播放:该列表成为队列,决定上/下一集。startIndex 为起播位置。
     *
     * @param tag 队列身份("inbox" / "fav" / "dl" / 频道主页用 "podcast:<feedUrl>")。
     *   分段条与频道主页那两颗播放按钮传它,UI 据此判断「这颗按钮现在管的就是正在播的这一段」;
     *   不属于任何可见列表的入口(「下一个播放」摘出来单播、迷你条)不传(空串)。
     */
    fun playQueue(episodes: List<Episode>, startIndex: Int, tag: String = "") {
        if (episodes.isEmpty()) return
        if (_radioMode.value) stopRadio() // 进入列表上下文即退出电台
        queue = episodes
        queueIndex = startIndex.coerceIn(0, episodes.lastIndex)
        if (_playMode.value == PlayMode.SHUFFLE) rebuildShuffleOrder() else clearShuffleOrder()
        _activeListTag.value = tag
        log.i(TAG, "playQueue count=${episodes.size} index=$queueIndex tag='$tag' mode=${_playMode.value}")
        updateNavFlags()
        playEpisode(episodes[queueIndex], isRadio = false)
    }

    // ---- 播放模式 ----
    /** 顺序 → 循环 → 随机 → 顺序。分段条那颗播放按钮在「正在播这一段」时点它就走这里。 */
    fun cyclePlayMode() {
        val entries = PlayMode.entries
        setPlayMode(entries[(entries.indexOf(_playMode.value) + 1) % entries.size])
    }

    /**
     * 设定播放模式并落盘。**播放中切换当场生效**:切进随机要重洗一次表并把当前集钉在第一位
     * (否则从顺序切进随机后「下一集」还按列表顺序走,等于没切);切出随机则丢掉表。
     */
    fun setPlayMode(mode: PlayMode) {
        if (mode == _playMode.value) return
        log.i(TAG, "playMode ${_playMode.value} -> $mode")
        _playMode.value = mode
        settings?.setPlayMode(mode.ordinal)
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

    private fun playEpisode(episode: Episode, isRadio: Boolean = false) {
        log.i(TAG, "play id=${episode.id} title='${episode.title}' radio=$isRadio")
        // 手动播放任意单集即退出电台;电台内部续播/换台传 isRadio=true 保持在台
        if (!isRadio && _radioMode.value) stopRadio()
        _current.value = episode
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
        pendingSeekMs = if (isGuide) 0L else history?.positionFor(episode.id) ?: 0L
        listenStats?.flush()   // 结算上一集残余
        lastCountedEpId = episode.id     // 统计基线对齐续播起点，避免把 resume 跳转记成收听
        lastCountedPosMs = pendingSeekMs

        val local = DownloadManager.localPath(episode.id)
        val useLocal = local != null && File(local).exists()
        log.d(TAG, "source ${if (useLocal) "local" else "stream"} seekTo=$pendingSeekMs id=${episode.id}")
        val uri = if (useLocal) Uri.fromFile(File(local!!)) else Uri.parse(episode.audioUrl)

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
     * @param tag 与 [playQueue] 同一个队列身份。**列表行内点起播也要传它** —— 否则从某一集
     *   起播之后,段条/头部那颗播放按钮认不出「这颗按钮管的就是正在播的这一段」,
     *   点它会回到「从头播这一段」而不是切播放模式(频道主页那颗按钮就是这样被点第一集弄丢的)。
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
        if (c.isPlaying) c.pause() else c.play()
    }

    fun seekTo(ms: Long) {
        val target = ms.coerceAtLeast(0)
        log.d(TAG, "seekTo ${target}ms")
        controller?.seekTo(target)
        _position.value = target
    }

    fun seekBy(deltaMs: Long) {
        val c = controller ?: return
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
