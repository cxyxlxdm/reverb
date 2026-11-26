package com.yuyin.reverb.cast

import android.content.Context
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * 投播(DLNA)的应用级状态机。放进程里而不是 ViewModel:
 * 关掉播放页、弹层消失之后,电视那边仍在播 —— 状态不能随界面销毁。
 *
 * 投播成功后会**暂停本机播放**:同一路音频从手机和电视一起响,听感上是回声。
 * 本机队列不动(暂停而已),用户点「停止投放」后可以按本机播放键接着听。
 */
class CastController(
    context: Context,
    baseClient: OkHttpClient,
    private val settingsStore: SettingsStore
) {

    sealed interface State {
        data object Idle : State
        data object Scanning : State
        data class Found(val devices: List<CastDevice>) : State
        data class Connecting(val device: CastDevice) : State
        data class Casting(val device: CastDevice, val episodeId: String, val title: String) : State
        data object Failed : State
    }

    /** 发现与 SOAP 都走独立的短超时客户端:投播是"点一下等结果"的动作,不该挨网络默认的 30 秒。 */
    private val client = baseClient.newBuilder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(6, TimeUnit.SECONDS)
        .callTimeout(8, TimeUnit.SECONDS)
        .build()
    private val discovery = SsdpDiscovery(context.applicationContext, client)
    private val dlna = DlnaClient(client) { settingsStore.thirdPartyContentEnabled.value }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    /** 连续「重新查找」时只认最后一次(与发现页 / 电台页的 generation 守卫同一条)。 */
    private var scanGen = 0
    private var castGeneration = 0
    private var metadataGeneration = 0
    private var op: Job? = null
    private var metadataOp: Job? = null
    private var currentEpisode: Episode? = null
    private var castArtworkEnabled = false

    init {
        scope.launch {
            settingsStore.thirdPartyContentEnabled.collect { enabled ->
                refreshCastArtwork(enabled)
            }
        }
    }

    /** 弹层每次打开调一次:已经有结果就不重扫,失败过或还没扫过才扫。 */
    fun ensureScan() {
        when (_state.value) {
            State.Idle, State.Failed -> scan()
            else -> Unit
        }
    }

    fun scan() {
        val gen = ++scanGen
        _state.value = State.Scanning
        scope.launch {
            val list = discovery.discover()
            if (gen != scanGen) return@launch
            _state.value = State.Found(list)
        }
    }

    fun cast(device: CastDevice, episode: Episode) {
        val generation = ++castGeneration
        metadataGeneration++
        op?.cancel()
        metadataOp?.cancel()
        dlna.cancelSetUri()
        currentEpisode = null
        _state.value = State.Connecting(device)
        op = scope.launch {
            try {
                val sentArtwork = settingsStore.thirdPartyContentEnabled.value
                dlna.setUri(device, episode)
                dlna.play(device)
                if (generation != castGeneration) return@launch
                PlayerController.pauseIfPlaying()
                currentEpisode = episode
                castArtworkEnabled = sentArtwork
                _state.value = State.Casting(device, episode.id, episode.title)
                refreshCastArtwork(settingsStore.thirdPartyContentEnabled.value)
                Logger.i(TAG, "casting id=${episode.id} live=${episode.isLive}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != castGeneration) return@launch
                currentEpisode = null
                Logger.w(TAG, "cast failed ${e.javaClass.simpleName}")
                _state.value = State.Failed
            }
        }
    }

    /** 停止投放。设备可能已经离线 —— 停不下来也照样回到 Idle,本机不再处于"以为在投放"的状态。 */
    fun stop() {
        val cur = _state.value as? State.Casting ?: run {
            _state.value = State.Idle
            return
        }
        castGeneration++
        metadataGeneration++
        op?.cancel()
        metadataOp?.cancel()
        dlna.cancelSetUri()
        currentEpisode = null
        op = scope.launch {
            runCatching { dlna.stop(cur.device) }
                .onFailure { Logger.w(TAG, "stop failed ${it.javaClass.simpleName}") }
            _state.value = State.Idle
        }
    }

    /** 已投会话的封面策略也要当场变；关闭时重发不带 albumArtURI 的同一 URI。 */
    private fun refreshCastArtwork(enabled: Boolean) {
        val cur = _state.value as? State.Casting ?: return
        val episode = currentEpisode ?: return
        // 策略值相同也可能是「旧请求还在飞」:快速开→关时设备仍可能是相反策略,
        // 必须让最后一次设置接管,不能只比对上一份已确认值。
        if (enabled == castArtworkEnabled && metadataOp?.isActive != true) return
        val generation = ++metadataGeneration
        metadataOp?.cancel()
        dlna.cancelSetUri()
        metadataOp = scope.launch {
            try {
                dlna.setUri(cur.device, episode)
                if (generation != metadataGeneration || _state.value !== cur || currentEpisode !== episode) return@launch
                val currentEnabled = settingsStore.thirdPartyContentEnabled.value
                if (currentEnabled != enabled) {
                    refreshCastArtwork(currentEnabled)
                    return@launch
                }
                castArtworkEnabled = enabled
                Logger.i(TAG, "cast artwork enabled=$enabled")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != metadataGeneration || _state.value !== cur || currentEpisode !== episode) return@launch
                Logger.w(TAG, "cast artwork refresh failed ${e.javaClass.simpleName}")
                if (!enabled) {
                    runCatching { dlna.stop(cur.device) }
                    currentEpisode = null
                    _state.value = State.Idle
                }
            }
        }
    }

    /**
     * 换集了。投出去的那一路没有跟着换的能力(也没做远端队列),继续维持只会让
     * 界面显示 A、电视放着 B —— 发现已切换就直接收尾,并在日志里留一行。
     */
    fun onEpisodeChanged(episodeId: String?) {
        val cur = _state.value as? State.Casting ?: return
        if (cur.episodeId != episodeId) {
            Logger.i(TAG, "episode changed, stopping cast")
            stop()
        }
    }

    private companion object {
        const val TAG = "DLNA"
    }
}
