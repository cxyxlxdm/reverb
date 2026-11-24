package com.yuyin.reverb.playback.asr

import android.content.Context
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizerResult
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord
import com.yuyin.reverb.util.ShortHash
import com.yuyin.reverb.util.TranscriptLines
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * sherpa-onnx + **SenseVoiceSmall int8** 的封装。1.0.8 起替换了原来的 whisper.cpp 引擎
 * (选型与实测数据见 `docs/research/2026-11-11-offline-asr-engine.md`)。
 *
 * 为什么换:同一段真实中文播客上,SenseVoice 的中文文本明显更准(whisper base 的同音字与
 * 断句错误更多),速度也更快,还**自带标点与词级时刻** —— 换过来之后"逐字高亮"不再需要
 * 任何额外计算。代价有两个,都在界面上如实说了:
 * 1. **模型大一个量级**(228 MB vs 57 MB),包从约 65 MB 涨到约 270 MB;
 * 2. **只认 zh / en / ja / ko / yue 五种语言**。法语、西语界面没有本机识别,只能看
 *    发布方给的官方稿(`AsrFactory.supports` 负责这条判定,界面据此显示原因)。
 *
 * 与 whisper 那一版的另一个结构差别:**分块必须在 30 秒以内**。SenseVoice 是非自回归的
 * 30 秒窗模型,喂 120 秒不会多转出字;而 whisper 那版是"块越大跨窗上下文越完整"。
 * 块长定义在 `PcmDecoder.CHUNK_SEC_RAMP`。
 *
 * 为什么直接用 sherpa-onnx 的 Java API、不再自己写 JNI:上游 AAR 里已经带了
 * `classes.jar`(Kotlin API)与 arm64 的 `.so`,那份 JNI 胶水既省了交叉编译(不再需要 NDK),
 * 也少了一处"崩溃时没有栈可看"的 C++ 代码。产物由 `tools/build-asr.sh` 备齐,不入库。
 */
class SenseVoiceEngine(context: Context) : AsrEngine {

    private val appCtx = context.applicationContext
    private var recognizer: OfflineRecognizer? = null
    /// 当前 recognizer 是按哪种语言建的。SenseVoice 的 `language` 是**模型级**配置,
    /// 不是每次调用的参数 —— 换了界面语言必须重建,不能只改一个变量。
    private var recognizerLang: String? = null
    private val TAG = "SenseVoice"

    override fun supports(localeId: String): Boolean =
        AsrFactory.engineLanguage(localeId) != null

    override suspend fun transcribe(
        episode: Episode,
        localPath: String?,
        localeId: String,
        wordTimestamps: Boolean,
        onStage: (AsrEngine.Stage) -> Unit,
        onVolatile: (String) -> Unit,
        onSegment: (TranscribedSegment) -> Unit
    ): Boolean = withContext(Dispatchers.Default) {
        val lang = AsrFactory.engineLanguage(localeId)
        if (lang == null) {
            com.yuyin.reverb.util.Logger.w(TAG, "这个界面语言没有可用的本机识别 locale=$localeId")
            return@withContext false
        }

        // 1) 音频:已下载/已缓存的直接用;否则先下到缓存目录(转完就删)
        var temp: File? = null
        val audio = if (!localPath.isNullOrBlank() && File(localPath).exists()) {
            localPath
        } else {
            /**
             * 蜂窝闸门(见 REVIEW-2026-10-25 中-3)。整集音频几十 MB,和「下载」「缓存」
             * 同一量级,必须接同一道闸门 —— 判据本体在 [com.yuyin.reverb.util.CellularGate]。
             * 已下载或已缓存到本地的这一集走上面那条分支,不会被拦。
             */
            if (blockedByCellular()) {
                com.yuyin.reverb.util.Logger.w(TAG, "识别前的音频下载被计费链路拦下 id=${episode.id}")
                onStage(AsrEngine.Stage.NeedUnmetered)
                return@withContext false
            }
            onStage(AsrEngine.Stage.DownloadingAudio)
            temp = downloadToCache(episode) ?: return@withContext false
            temp.absolutePath
        }

        try {
            // 2) 模型(首次:从 assets 拷到私有目录)
            onStage(AsrEngine.Stage.LoadingModel)
            val files = ensureModelFiles() ?: return@withContext false
            val rec = ensureRecognizer(files, lang) ?: return@withContext false

            // 3) 分块识别
            onStage(AsrEngine.Stage.Running)
            var lastText = ""
            var emitted = 0
            com.yuyin.reverb.util.Logger.i(TAG, "开始转写 lang='$lang' audio=$audio")
            val ok = PcmDecoder.decodeInChunks(audio) { samples, startMs ->
                if (!currentCoroutineContext().isActive) return@decodeInChunks
                val t0 = System.currentTimeMillis()
                val result = try {
                    // 显式 try/finally 而不是依赖 sherpa 的 `use` 扩展:那个成员函数返回
                    // Unit,拿不到识别结果(它的签名是 use(Function1<OfflineStream, Unit>))。
                    val stream = rec.createStream()
                    try {
                        stream.acceptWaveform(samples, PcmDecoder.TARGET_RATE)
                        rec.decode(stream)
                        rec.getResult(stream)
                    } finally {
                        stream.release()
                    }
                } catch (e: Throwable) {
                    // 单块失败不该让整集作废:块边界坏掉、某段纯噪声都可能让 native 侧
                    // 抛一个运行时异常。记下来,继续下一块 —— 少一句比整份稿没了强。
                    com.yuyin.reverb.util.Logger.w(TAG, "块识别异常 startMs=$startMs:${e.message}")
                    return@decodeInChunks
                }
                val text = result.text.trim()
                com.yuyin.reverb.util.Logger.i(
                    TAG,
                    "块 startMs=$startMs 样本=${samples.size} 字=${text.length} 用时=${System.currentTimeMillis() - t0}ms"
                )
                if (!keep(text, lastText)) return@decodeInChunks
                lastText = text

                val chunkEndMs = startMs + samples.size * 1000 / PcmDecoder.TARGET_RATE
                /**
                 * **按 token 重新组行**:SenseVoice 的 token 就是汉字 / 英文子词,自带
                 * 起点时刻(见 `wordsFrom`),组行规则与官方稿共用同一份
                 * `TranscriptLines.mergeWords`。一步拿到两个结果:屏幕上能读的一行,
                 * 以及逐字高亮要用的词级时间。
                 *
                 * 关了「逐字高亮」时**只把 words 置空、不改变切行方式** —— 用 token 时刻
                 * 切出来的行边界比按字数插值准,而少存 words 已经省下了缓存体积。
                 */
                val words = wordsFrom(result, startMs, chunkEndMs)
                val lines = if (words.size > 1) {
                    val merged = TranscriptLines.mergeWords(words, spaced = false)
                    if (wordTimestamps) merged else merged.map { it.copy(words = null) }
                } else {
                    TranscriptLines.split(text, startMs, chunkEndMs)
                }
                for (line in lines) {
                    emitted++
                    onSegment(line)
                }
            }
            com.yuyin.reverb.util.Logger.i(TAG, "转写结束 ok=$ok 已出 $emitted 句")
            ok
        } finally {
            temp?.delete()
        }
    }

    override suspend fun transcribeSamples(samples: FloatArray, localeId: String): String? =
        withContext(Dispatchers.Default) {
            val lang = AsrFactory.engineLanguage(localeId) ?: return@withContext null
            if (samples.isEmpty()) return@withContext null
            val files = ensureModelFiles() ?: return@withContext null
            val rec = ensureRecognizer(files, lang) ?: return@withContext null
            try {
                val stream = rec.createStream()
                try {
                    stream.acceptWaveform(samples, PcmDecoder.TARGET_RATE)
                    rec.decode(stream)
                    rec.getResult(stream).text.trim()
                } finally {
                    stream.release()
                }
            } catch (e: Throwable) {
                com.yuyin.reverb.util.Logger.w(TAG, "短语音识别异常:${e.message}")
                null
            }
        }

    override fun close() {
        recognizer?.release()
        recognizer = null
        recognizerLang = null
    }

    // ── 内部 ──

    /**
     * 语音模型的语言是**建 recognizer 时定的**。同一份 App 里换界面语言之后,
     * 旧 recognizer 会把英语音频当中文解,所以这里按语言缓存一份,变了就重建。
     */
    private fun ensureRecognizer(files: Pair<File, File>, lang: String): OfflineRecognizer? {
        recognizer?.let { if (recognizerLang == lang) return it }
        recognizer?.release()
        recognizer = null
        return try {
            val config = OfflineRecognizerConfig()
            config.featConfig.sampleRate = PcmDecoder.TARGET_RATE
            config.featConfig.featureDim = 80
            config.modelConfig.tokens = files.second.absolutePath
            config.modelConfig.senseVoice.model = files.first.absolutePath
            config.modelConfig.senseVoice.language = lang
            // 标点与文本正则化(数字、日期)。关掉的话输出是一串没有断句的汉字,
            // 组行只能按字数硬切,读起来差很多。
            config.modelConfig.senseVoice.useInverseTextNormalization = true
            config.modelConfig.numThreads = THREADS
            config.modelConfig.provider = "cpu"
            config.modelConfig.debug = false
            config.decodingMethod = "greedy_search"
            // 传 null 表示"模型在真实文件路径上"(已拷到 filesDir),不走 AssetManager ——
            // assets 里的文件没有路径,而 228 MB 的模型也不该让 native 再从压缩包里解一遍。
            val created = OfflineRecognizer(null, config)
            recognizer = created
            recognizerLang = lang
            com.yuyin.reverb.util.Logger.i(TAG, "模型已加载 lang=$lang threads=$THREADS")
            created
        } catch (e: Throwable) {
            com.yuyin.reverb.util.Logger.e(TAG, "模型加载失败(是否漏跑 tools/build-asr.sh?)", Exception(e))
            null
        }
    }

    /**
     * 把 token 流变成带时刻的词单元。
     *
     * sherpa-onnx 给的 `timestamps` 是**相对这一块**的秒数(浮点)。终点取**下一条的起点** ——
     * 比用 durations 更稳:模型给的 duration 在句尾可能超出块尾,而下一条起点天然单调。
     * 最后一条用块尾兜底。起点单调与 ≥0 这两条不变式在这里就成立(渲染侧依赖它们,
     * 见 `TranscriptLines.monotonic` 的注释)。
     *
     * 文本首尾的空格要削掉:中文 token 没有空格,英文 token **自带前导空格**(第一个除外,
     * 但模型有时也会给)。不削的话每行开头会多一个空格。
     */
    private fun wordsFrom(
        result: OfflineRecognizerResult,
        offsetMs: Int,
        chunkEndMs: Int
    ): List<TranscribedWord> {
        val toks = result.tokens
        val ts = result.timestamps
        if (toks.isEmpty() || ts.size != toks.size) return emptyList()
        val out = ArrayList<TranscribedWord>(toks.size)
        for (i in toks.indices) {
            val raw = toks[i]
            if (raw.isEmpty()) continue
            // 特殊标记(`<|zh|>`、`<|BGM|>` 这类)不是内容
            if (raw.length >= 3 && raw.startsWith("<|") && raw.endsWith("|>")) continue
            val s = offsetMs + (ts[i] * 1000f).toInt()
            val e = if (i + 1 < toks.size) offsetMs + (ts[i + 1] * 1000f).toInt() else chunkEndMs
            val text = if (out.isEmpty()) raw.trimStart() else raw
            if (text.isEmpty()) continue
            out.add(TranscribedWord(text, maxOf(s, 0), maxOf(e, s)))
        }
        // 末尾那条把尾随空格也削掉,维持"words 拼接 == 行文本"且行尾干净
        if (out.isNotEmpty()) {
            val last = out.last()
            val trimmed = last.text.trimEnd()
            if (trimmed.isEmpty()) out.removeAt(out.size - 1)
            else out[out.size - 1] = last.copy(text = trimmed)
        }
        return out
    }

    /**
     * 识别前那一步整集音频下载该不该被拦。判据与「下载」「缓存」共用同一份
     * (见 [com.yuyin.reverb.util.CellularGate])。上下文拿不到设置时按「不允许蜂窝」处理。
     */
    private fun blockedByCellular(): Boolean {
        val st = runCatching { (appCtx as ReverbApp).container.settingsStore }.getOrNull()
        return com.yuyin.reverb.util.CellularGate.blocked(st, appCtx)
    }

    /**
     * 该不该留这一句。挡掉两类东西:
     * - **复读**:片头音乐/口号上模型可能把同一句吐几遍,连续相同就丢(跨块也管用);
     * - **音乐/掌声/字幕署名**:`[音乐]`、`(Music)`、`(字幕:J Chong)` 这类不是内容。
     *   SenseVoice 自己会把 BGM / 掌声放进 `event` 字段而不是文本,但片尾静音处仍可能
     *   串出一句括号署名 —— 这一道与 whisper 那版一样保留。
     */
    private fun keep(text: String, lastText: String): Boolean {
        if (text.isEmpty()) return false
        if (text == lastText) return false
        if (text.length <= 24 && MARKER.matches(text)) return false
        return true
    }

    /**
     * 把内置的模型与词表拷到私有目录(只做一次)。
     *
     * 模型按**大小**判断是否已就绪:拷贝中途被杀会留下半个文件,大小不对就重拷。
     * 词表只有 300 KB,直接逐字节比对 —— 它没有 openFd 可用(压缩过的 txt 在 assets 里
     * 拿不到文件描述符),而读一遍 300 KB 的成本可以忽略。
     */
    private fun ensureModelFiles(): Pair<File, File>? = try {
        val dir = File(appCtx.filesDir, "sensevoice").apply { mkdirs() }
        val model = File(dir, MODEL_FILE)
        val expected = appCtx.assets.openFd("$ASSET_DIR/$MODEL_FILE").use { it.length }
        if (!model.exists() || model.length() != expected) {
            com.yuyin.reverb.util.Logger.i(TAG, "首次拷贝模型 ${expected / 1024 / 1024} MB")
            appCtx.assets.open("$ASSET_DIR/$MODEL_FILE").use { input ->
                model.outputStream().use { out -> input.copyTo(out, 1 shl 16) }
            }
        }
        val tokens = File(dir, TOKENS_FILE)
        val tokensBytes = appCtx.assets.open("$ASSET_DIR/$TOKENS_FILE").use { it.readBytes() }
        val same = tokens.exists() && tokens.length() == tokensBytes.size.toLong() &&
            tokens.readBytes().contentEquals(tokensBytes)
        if (!same) tokens.writeBytes(tokensBytes)
        model to tokens
    } catch (e: Exception) {
        // openFd 失败通常意味着模型被压缩了(打包时漏了 noCompress),这是构建配置问题
        com.yuyin.reverb.util.Logger.e(TAG, "模型准备失败(检查 noCompress 配置)", e)
        null
    }

    private fun downloadToCache(episode: Episode): File? = try {
        val client = (appCtx as ReverbApp).container.httpClient
        // 临时音频名用短哈希而不是 String.hashCode(),理由见 REVIEW-2026-10-25 低·族 A。
        val dest = File(appCtx.cacheDir, "asr-${ShortHash.hex16(episode.id)}.audio")
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

    companion object {
        private const val ASSET_DIR = "sensevoice"
        private const val MODEL_FILE = "model.int8.onnx"
        private const val TOKENS_FILE = "tokens.txt"
        /**
         * 4 个线程。SenseVoice 的编码器是卷积+注意力的整段前向,4 线程在手机上
         * 已经能跑到十几倍实时;再多只会抢核降频(与 whisper 那版同一个经验值)。
         */
        private const val THREADS = 4
        private val MARKER = Regex("^[\\[(（【][^\\])）】]{0,20}[\\])）】]$")
    }
}
