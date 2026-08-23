package com.yuyin.reverb.playback.asr

import android.content.Context
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.util.TranscriptLines
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * whisper.cpp 的封装。**只在默认渠道存在**(本文件在 `src/default/`)。
 *
 * 模型随包内置(`assets/whisper-model.bin`,base-q5_1 约 57 MB),首次使用拷到私有目录 ——
 * whisper 要一个真实文件路径,而 assets 里的东西没有路径。拷贝只发生一次。
 *
 * 分块识别:解码器每交出 2 分钟就跑一次,句子带上块起点偏移后立即吐给界面,
 * 于是用户能**边转边看**,而不是等十几分钟一次性出现。内存也因此封在 10 MB 量级
 * (整集一次性解码是 230 MB,见 `PcmDecoder`)。
 *
 * 真机实测(SM8845 / 4 线程 / base-q5_1,真实中文播客):
 * - **应用内约 8 倍实时**(120.7 秒的块 14.2 秒、59.3 秒的块 8.1 秒)⇒ 1 小时约 7~8 分钟;
 * - 同机同模型的命令行(whisper-cli)只有 4.0~4.6 倍。**差别来自 `no_context = true`** ——
 *   分块识别必须关掉跨块上下文(否则复读),代价是少了上文提示、质量略降,
 *   收益是快了近一倍。这个取舍是刻意的,详见 TRANSCRIPT.md。
 *
 * 换模型或升级 whisper.cpp 之后**要重新量**,别照抄这个数(见 tools/build-asr.sh)。
 */
class WhisperEngine(context: Context) : AsrEngine {

    private val appCtx = context.applicationContext
    private var handle: Long = 0
    private val TAG = "Whisper"

    override suspend fun transcribe(
        episode: Episode,
        localPath: String?,
        localeId: String,
        onStage: (AsrEngine.Stage) -> Unit,
        onVolatile: (String) -> Unit,
        onSegment: (TranscribedSegment) -> Unit
    ): Boolean = withContext(Dispatchers.Default) {
        // 1) 音频:已下载的直接用;否则先下到缓存目录(转完就删)
        var temp: File? = null
        val audio = if (!localPath.isNullOrBlank() && File(localPath).exists()) {
            localPath
        } else {
            onStage(AsrEngine.Stage.DownloadingAudio)
            temp = downloadToCache(episode) ?: return@withContext false
            temp.absolutePath
        }

        try {
            // 2) 模型
            onStage(AsrEngine.Stage.LoadingModel)
            val model = ensureModel() ?: return@withContext false
            if (handle == 0L) handle = nativeInit(model.absolutePath)
            if (handle == 0L) {
                com.yuyin.reverb.util.Logger.e(TAG, "模型加载失败 path=${model.absolutePath}")
                return@withContext false
            }

            // 3) 分块识别
            onStage(AsrEngine.Stage.Running)
            val lang = whisperLang(localeId)
            var lastText = ""
            com.yuyin.reverb.util.Logger.i(TAG, "开始转写 lang='$lang' audio=$audio")
            var emitted = 0
            val ok = PcmDecoder.decodeInChunks(audio) { samples, startMs ->
                if (!currentCoroutineContext().isActive) return@decodeInChunks
                val t0 = System.currentTimeMillis()
                val n = nativeTranscribe(handle, samples, lang, promptFor(localeId), THREADS)
                com.yuyin.reverb.util.Logger.i(TAG, "块 startMs=$startMs 样本=${samples.size} → $n 句,耗时 ${System.currentTimeMillis() - t0}ms")
                if (n < 0) {
                    com.yuyin.reverb.util.Logger.w(TAG, "识别返回失败 startMs=$startMs")
                    return@decodeInChunks
                }
                for (i in 0 until n) {
                    val text = nativeSegmentText(handle, i).trim()
                    if (!keep(text, lastText)) continue
                    lastText = text
                    /**
                     * **一句还要再切**。给了带标点的提示词之后,whisper 会把一整段话当成一句吐出来
                     * (实测 3 分钟音频只有 21 句,一句能有两三百字)—— 那样跟读高亮的粒度就没了,
                     * 一段要亮二十多秒。切分与官方稿共用同一套规则(中文一行 24 字、西文 42),
                     * 时间按字符占比插值。
                     */
                    for (line in TranscriptLines.split(
                        text,
                        startMs + nativeSegmentStartMs(handle, i),
                        startMs + nativeSegmentEndMs(handle, i)
                    )) {
                        emitted++
                        onSegment(line)
                    }
                }
            }
            com.yuyin.reverb.util.Logger.i(TAG, "转写结束 ok=$ok 已出 $emitted 句")
            ok
        } finally {
            temp?.delete()
        }
    }

    override fun close() {
        if (handle != 0L) {
            nativeFree(handle)
            handle = 0
        }
    }

    // ── 内部 ──

    /**
     * 该不该留这一句。挡掉两类东西:
     * - **复读**:模型在片头音乐/口号上会把同一句吐十几遍(实测「原来是这样」连出 6 次),
     *   连续相同就丢。跨块也管用 —— lastText 是跨块保留的;
     * - **音乐/掌声/字幕署名**:`[音乐]`、`(Music)`、`(字幕:J Chong)` 这类不是内容。
     *   末尾那种尤其常见 —— 片尾静音处模型会**幻觉**出一句字幕组署名(实测就撞上了),
     *   所以括号里的长度放宽到 20 字。
     */
    private fun keep(text: String, lastText: String): Boolean {
        if (text.isEmpty()) return false
        if (text == lastText) return false
        if (text.length <= 24 && MARKER.matches(text)) return false
        return true
    }

    /// `zh-CN` → `zh`。whisper 认的是两字母语言码;空串表示让它自己判断("auto")。
    private fun whisperLang(localeId: String): String =
        localeId.substringBefore('-').lowercase()

    /**
     * 提示词。**只为一件事:让中文出简体。**
     *
     * whisper 转中文时默认偏向繁体 —— 实测简体界面下整屏「原來是怎樣」「我們假設」,
     * 对简体用户就是坏的。给一句同字体的提示词即可把输出带过去;繁体界面反过来给繁体提示。
     * 其他语言不需要,给空串。
     */
    private fun promptFor(localeId: String): String = when {
        localeId.startsWith("zh-TW") || localeId.startsWith("zh-Hant") -> "以下是繁體中文的句子。"
        localeId.startsWith("zh") -> "以下是普通话的句子。"
        else -> ""
    }

    /**
     * 把内置模型拷到私有目录(只做一次)。
     * 用「目标文件大小与 assets 里一致」判断是否已就绪 —— 比存个 flag 可靠:
     * 拷贝中途被杀会留下半个文件,大小不对就会重拷。
     */
    private fun ensureModel(): File? = try {
        val dest = File(appCtx.filesDir, MODEL_FILE)
        val expected = appCtx.assets.openFd(MODEL_ASSET).use { it.length }
        if (!dest.exists() || dest.length() != expected) {
            com.yuyin.reverb.util.Logger.i(TAG, "首次拷贝模型 ${expected / 1024 / 1024} MB")
            appCtx.assets.open(MODEL_ASSET).use { input ->
                dest.outputStream().use { out -> input.copyTo(out, 1 shl 16) }
            }
        }
        dest
    } catch (e: Exception) {
        // openFd 失败通常意味着模型被压缩了(打包时漏了 noCompress),这是构建配置问题
        com.yuyin.reverb.util.Logger.e(TAG, "模型准备失败(检查 noCompress 配置)", e)
        null
    }

    private fun downloadToCache(episode: Episode): File? = try {
        val client = (appCtx as ReverbApp).container.httpClient
        val dest = File(appCtx.cacheDir, "asr-${kotlin.math.abs(episode.id.hashCode())}.audio")
        val req = Request.Builder().url(episode.audioUrl)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)").build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                com.yuyin.reverb.util.Logger.w(TAG, "音频下载失败 http ${resp.code}")
                return null
            }
            resp.body?.byteStream()?.use { input ->
                dest.outputStream().use { out -> input.copyTo(out, 1 shl 16) }
            } ?: return null
        }
        dest
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(TAG, "音频下载失败", e)
        null
    }

    private external fun nativeInit(modelPath: String): Long
    private external fun nativeFree(handle: Long)
    private external fun nativeTranscribe(
        handle: Long, pcm: FloatArray, language: String, initialPrompt: String, threads: Int
    ): Int
    private external fun nativeSegmentText(handle: Long, index: Int): String
    private external fun nativeSegmentStartMs(handle: Long, index: Int): Int
    private external fun nativeSegmentEndMs(handle: Long, index: Int): Int

    companion object {
        private const val MODEL_ASSET = "whisper-model.bin"
        private const val MODEL_FILE = "whisper-model.bin"
        /**
         * 4 个线程。手机上再多不划算:大核就那几个,线程数超过大核数会开始互相抢
         * 且更快触发降频(实测 4 线程时 base-q5_1 是 4.6 倍实时)。
         */
        private const val THREADS = 4
        private val MARKER = Regex("^[\\[(（【][^\\])）】]{0,20}[\\])）】]$")

        init {
            System.loadLibrary("reverb_asr")
        }
    }
}
