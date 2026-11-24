package com.yuyin.reverb.playback.asr

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/**
 * 语音搜索:录一小段麦克风 → 交给本机 `SenseVoice` 识别 → 回给调用方填进搜索框。
 *
 * 交互是「点一下开始、再点一下结束」。**整条链路都在设备上**:录音只活在内存里
 * (`ShortArray` 累加),不落盘、不上传,识别完即丢。与逐字稿共用同一个模型与
 * [AsrEngine.transcribeSamples],只是输入从"整集文件"换成"几秒钟的采样"。
 *
 * 为什么每次新建一个引擎实例而不是共用容器里的 `asrEngine`:那一个被逐字稿占用,
 * 而 `SenseVoiceEngine` 的 recognizer 不是线程安全的。模型文件已拷到私有目录,
 * 新建实例不会再复制那 228 MB(见 `ensureModelFiles` 按大小判就绪)。
 *
 * 麦克风权限由界面先申请(`RECORD_AUDIO` 已是既有权限,频谱那个功能在用);
 * 这里只**检查**、不申请 —— 后台线程里弹系统框是不成立的。
 */
class VoiceSearchController(context: Context) {

    sealed interface State {
        data object Idle : State
        data object Recording : State
        data object Transcribing : State
    }

    enum class StartResult { Started, PermissionDenied, Unsupported, Failed }

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val generation = AtomicInteger(0)
    private var recordJob: Job? = null
    @Volatile
    private var record: AudioRecord? = null
    /** 已录到的样本,按块累加;2 万样本/秒,几秒钟的量级不用担心装箱。 */
    private var chunks = ArrayList<ShortArray>()

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    /** 起录音。权限被拒 / 引擎不可用时如实返回原因,由界面决定提示什么。 */
    fun start(): StartResult {
        if (_state.value != State.Idle) return StartResult.Failed
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) return StartResult.PermissionDenied

        val minBuf = AudioRecord.getMinBufferSize(
            PcmDecoder.TARGET_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) return StartResult.Failed
        val bufferSize = maxOf(minBuf * 2, PcmDecoder.TARGET_RATE)   // 至少半秒
        val ar = try {
            @Suppress("MissingPermission")
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                PcmDecoder.TARGET_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize
            )
        } catch (e: Exception) {
            Logger.w("Voice", "AudioRecord 创建失败:${e.message}")
            return StartResult.Failed
        }
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            return StartResult.Failed
        }
        val session = generation.incrementAndGet()
        recordJob?.cancel()
        recordJob = null
        val sessionChunks = ArrayList<ShortArray>()
        chunks = sessionChunks
        record = ar
        try {
            ar.startRecording()
        } catch (e: Exception) {
            Logger.w("Voice", "startRecording 失败:${e.message}")
            releaseRecord(ar)
            return StartResult.Failed
        }
        _state.value = State.Recording
        Logger.i("Voice", "开始录音 $PcmDecoder.TARGET_RATE Hz 单声道")
        recordJob = scope.launch {
            val buf = ShortArray(PcmDecoder.TARGET_RATE / 5)   // 200ms
            var total = 0
            val cap = PcmDecoder.TARGET_RATE * MAX_SECONDS
            try {
                while (isActive && generation.get() == session && total < cap) {
                    val n = try {
                        ar.read(buf, 0, buf.size)
                    } catch (e: Exception) {
                        Logger.w("Voice", "read 失败:${e.message}")
                        -1
                    }
                    if (n <= 0 || generation.get() != session || record !== ar) break
                    sessionChunks.add(buf.copyOf(n))
                    total += n
                }
            } finally {
                // 异常、取消与正常到顶都走这里;只释放这一次会话的采集器,
                // 免得旧协程的 finally 误关用户已经新开的一次录音。
                releaseRecord(ar)
                if (generation.get() == session && total >= cap) {
                    Logger.i("Voice", "到达 ${MAX_SECONDS}s 上限,麦克风已释放")
                }
            }
        }
        return StartResult.Started
    }

    /** 停止并识别。返回识别文本;nil 表示没录到内容、语言不支持或识别失败。 */
    suspend fun stopAndTranscribe(localeId: String): String? {
        if (_state.value != State.Recording) return null
        val session = generation.get()
        val job = recordJob
        // 先锁住状态再等待采集协程;否则用户第二下会重入,旧调用恢复后还会清掉新会话的 Job。
        _state.value = State.Transcribing
        releaseRecord()
        job?.cancelAndJoin()
        if (session != generation.get()) return null
        if (recordJob === job) recordJob = null
        val captured = chunks
        chunks = ArrayList()
        try {
            val samples = toFloatSamples(captured)
            if (samples.isEmpty()) return null
            val engine = AsrFactory.create(appContext) ?: return null
            try {
                val text = engine.transcribeSamples(samples, localeId)?.trim()
                if (session != generation.get()) return null
                Logger.i("Voice", "识别完成 字=${text?.length ?: 0}")
                return text?.ifEmpty { null }
            } finally {
                engine.close()
            }
        } catch (e: Throwable) {
            Logger.w("Voice", "识别失败:${e.message}")
            return null
        } finally {
            if (session == generation.get()) {
                if (recordJob === job) recordJob = null
                _state.value = State.Idle
            }
        }
    }

    /** 放弃这次录音(离开页面 / 视图销毁)。不识别、不留数据。 */
    fun cancel() {
        generation.incrementAndGet()
        releaseRecord()
        recordJob?.cancel()
        recordJob = null
        chunks = ArrayList()
        _state.value = State.Idle
    }

    private fun releaseRecord(expected: AudioRecord? = null) {
        val ar = expected ?: record ?: return
        if (record !== ar) return
        record = null
        try {
            ar.stop()
        } catch (_: Exception) {
        }
        try {
            ar.release()
        } catch (e: Exception) {
            Logger.w("Voice", "release 失败:${e.message}")
        }
    }

    private fun toFloatSamples(list: List<ShortArray>): FloatArray {
        val total = list.sumOf { it.size }
        val out = FloatArray(total)
        var i = 0
        for (c in list) for (s in c) {
            out[i++] = s / 32768f
            if (i >= total) break
        }
        return out
    }

    companion object {
        /**
         * 30 秒上限。SenseVoice 本身就是 30 秒窗模型,再长也只是把同一段重复解码;
         * 而语音搜索的正常长度是两三秒的一句话。
         */
        private const val MAX_SECONDS = 30
    }
}
