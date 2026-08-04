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
    // 随机电台的播放历史:上一个=回退到刚听过的那期,超出末尾则抓新的随机。
    private val radioHistory = ArrayList<Episode>()
    private var radioPos = -1
    private val radioHistoryCap = 100

    private val _hasNext = MutableStateFlow(false)
    val hasNext: StateFlow<Boolean> = _hasNext
    private val _hasPrev = MutableStateFlow(false)
    val hasPrev: StateFlow<Boolean> = _hasPrev

    private fun updateNavFlags() {
        if (_radioMode.value) {
            _hasPrev.value = radioPos > 0
            _hasNext.value = true // 电台随时可抓下一个
        } else {
            _hasPrev.value = queueIndex > 0
            _hasNext.value = queueIndex in 0 until (queue.size - 1)
        }
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

    fun bindSettings(s: SettingsStore) {
        settings = s
        _speed.value = s.defaultSpeed.value // 启动即套用默认倍速
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
            if (isPlaying) startTicker() else { stopTicker(); saveProgress() }
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
                val stopAfterThis = _sleepEndOfEpisode.value // 睡眠「本集结束」优先于电台续播
                _sleepEndOfEpisode.value = false
                _current.value?.let { history?.updatePosition(it.id, 0, c?.duration ?: 0) }
                // 电台模式:本集播完自动抓下一首随机节目续播
                if (_radioMode.value && !stopAfterThis) advanceRadio()
            }
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            log.e(TAG, "onPlayerError code=${error.errorCode} name=${error.errorCodeName} id=${_current.value?.id}", error)
        }
    }

    /** 播放单集(单条,无上下文):等价于队列只有它自己,无上/下一集。 */
    fun play(episode: Episode) = playQueue(listOf(episode), 0)

    /** 从一个列表开始播放:该列表成为队列,决定上/下一集。startIndex 为起播位置。 */
    fun playQueue(episodes: List<Episode>, startIndex: Int) {
        if (episodes.isEmpty()) return
        if (_radioMode.value) stopRadio() // 进入列表上下文即退出电台
        queue = episodes
        queueIndex = startIndex.coerceIn(0, episodes.lastIndex)
        log.i(TAG, "playQueue count=${episodes.size} index=$queueIndex")
        updateNavFlags()
        playEpisode(episodes[queueIndex], isRadio = false)
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

    /** 下一集:列表按顺序,电台优先回放历史前进、到末尾则抓新的随机。 */
    fun next() {
        log.i(TAG, "next radio=${_radioMode.value} queueIndex=$queueIndex radioPos=$radioPos")
        if (_radioMode.value) {
            if (radioPos in 0 until radioHistory.lastIndex) {
                radioPos++; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio = true)
            } else advanceRadio()
        } else if (queueIndex in 0 until (queue.size - 1)) {
            queueIndex++; updateNavFlags(); playEpisode(queue[queueIndex], isRadio = false)
        }
    }

    /** 上一集:列表回退一集;电台回退到刚听过的那期。 */
    fun previous() {
        log.i(TAG, "previous radio=${_radioMode.value} queueIndex=$queueIndex radioPos=$radioPos")
        if (_radioMode.value) {
            if (radioPos > 0) { radioPos--; updateNavFlags(); playEpisode(radioHistory[radioPos], isRadio = true) }
        } else if (queueIndex > 0) {
            queueIndex--; updateNavFlags(); playEpisode(queue[queueIndex], isRadio = false)
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
        history?.record(episode, System.currentTimeMillis())
        pendingSeekMs = history?.positionFor(episode.id) ?: 0L

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

    /** 队列版:同一集则暂停/继续,否则以该列表为队列从此集起播。 */
    fun playOrToggle(episode: Episode, queue: List<Episode>) {
        if (_current.value?.id == episode.id && controller != null) togglePlayPause()
        else playQueue(queue, queue.indexOfFirst { it.id == episode.id }.coerceAtLeast(0))
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
        history?.updatePosition(ep.id, c.currentPosition.coerceAtLeast(0), if (c.duration > 0) c.duration else 0)
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
            tickCount++
            if (tickCount % 10 == 0) saveProgress() // 每约 5 秒落一次进度
            if (c.isPlaying) handler.postDelayed(this, 500)
        }
    }
}
