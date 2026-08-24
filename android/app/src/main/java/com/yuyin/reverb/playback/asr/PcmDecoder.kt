package com.yuyin.reverb.playback.asr

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import java.nio.ByteOrder

/**
 * 把 m4a / mp3 解成识别引擎要的 **16 kHz 单声道 float PCM**,并**分块交出**。
 *
 * 为什么分块而不是一次解完:1 小时音频的 16k float 是 **230 MB**
 * (3600 × 16000 × 4 字节)—— 整段进内存在手机上不可接受。最大 2 分钟一块交出,
 * 峰值降到约 7.7 MB,顺带让界面能**边转边出**(每块识别完就有新句子),
 * 而不是转完十几分钟才一次性出现。块长**开头小、之后放大**(见 `CHUNK_SEC_RAMP`):
 * 首字快出来,后面换识别质量。
 *
 * 块边界会**往静音处挪**(在目标点前后 3 秒内找能量最低的位置):正好切在词中间会让
 * 那个词两边都识别错。挪到静音处并不能完全消除边界损失,但比硬切好得多。
 *
 * 纯 Kotlin,不需要 NDK —— Android 的 `MediaExtractor` + `MediaCodec` 就够。
 * (鸿蒙那端没有这么好的运气:ArkTS 层完全没有解封装/解码 API,只能走 Native。)
 */
object PcmDecoder {

    const val TARGET_RATE = 16000

    /**
     * 每块的目标长度,**逐块放大**:30 → 60 → 120 秒,之后维持 120。
     *
     * 为什么不一律 120 秒:那是"点了生成之后要盯着空白等二十多秒"的直接原因 ——
     * 第一句要等整个首块识别完才出现,120 秒的块在真机上要算十几秒(还没算解码与加载模型)。
     * 首块缩到 30 秒,首字大约 5~6 秒就出来,**观感差别很大**。
     *
     * 为什么起点是 30 秒而不是更小:whisper 内部一律按 **30 秒窗**处理,喂 10 秒和喂 30 秒
     * 的编码器开销几乎一样 —— 再小只是浪费,换不来更快。
     *
     * 为什么后面要放大回 120 秒:一次 `whisper_full` 内部的多个 30 秒窗之间是带上下文的,
     * 块越大跨窗上下文越完整、识别越准;而块边界处必然有损失。所以只在开头用小块换响应速度,
     * 之后回到大块换质量。
     */
    private val CHUNK_SEC_RAMP = intArrayOf(30, 60, 120)
    /// 找静音的搜索半径
    private const val SEEK_SILENCE_SEC = 3

    private const val TAG = "PcmDecoder"

    /**
     * 解码并逐块回调。
     *
     * @param path 本地文件路径(已下载的单集,或先下到临时文件的流式单集)
     * @param onChunk (samples, startMs) —— samples 是 16k 单声道 float([-1,1]),
     *   startMs 是这一块在整集里的起始毫秒。**回调是挂起的**,识别慢就自然背压,
     *   不会一路解码把内存堆满。
     * @return 是否完整解完(false = 被取消或出错)
     */
    suspend fun decodeInChunks(path: String, onChunk: suspend (FloatArray, Int) -> Unit): Boolean {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull { i ->
                extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: run {
                com.yuyin.reverb.util.Logger.w(TAG, "文件里没有音频轨 path=$path")
                return false
            }
            extractor.selectTrack(track)
            val inFormat = extractor.getTrackFormat(track)
            val mime = inFormat.getString(MediaFormat.KEY_MIME)!!
            var srcRate = inFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var srcChannels = inFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inFormat, null, null, 0)
            codec.start()

            // 累积缓冲:攒够一块(含静音搜索余量)再交出去。块长按 ramp 逐块放大
            var chunkIndex = 0
            var chunkTarget = CHUNK_SEC_RAMP[0] * TARGET_RATE
            val searchSpan = SEEK_SILENCE_SEC * TARGET_RATE
            val maxTarget = CHUNK_SEC_RAMP.last() * TARGET_RATE
            var buf = FloatArray(maxTarget + searchSpan * 2)
            var used = 0
            /**
             * 已交出的总样本数 → 用来算 startMs。**必须是 Long**:
             * `样本数 × 1000` 在 Int 里放不下 —— 1 小时是 3.6M 样本,乘 1000 就 36 亿,
             * 早过了 Int 上限,结果是第三块起 startMs 变负数,整份稿的时间轴全废。
             */
            var emittedSamples = 0L
            var resampleCarry = 0.0       // 重采样的小数相位,跨 buffer 保留

            val info = MediaCodec.BufferInfo()
            var sawInputEos = false
            var sawOutputEos = false

            while (!sawOutputEos) {
                if (!currentCoroutineContext().isActive) return false

                if (!sawInputEos) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val ib = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(ib, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEos = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // 实际输出格式可能与轨道声明的不同,以这里为准
                        val f = codec.outputFormat
                        srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        srcChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        com.yuyin.reverb.util.Logger.i(TAG, "解码输出 ${srcRate}Hz ${srcChannels}ch")
                    }
                    outIdx >= 0 -> {
                        val ob = codec.getOutputBuffer(outIdx)!!
                        if (info.size > 0) {
                            val shorts = ob.order(ByteOrder.nativeOrder()).asShortBuffer()
                            val n = info.size / 2
                            // 下混单声道 + 线性重采样到 16k。线性插值对语音识别够用 ——
                            // 引擎自己会做梅尔谱,重采样的微小失真远小于模型本身的误差。
                            val step = srcRate.toDouble() / TARGET_RATE
                            val frames = n / srcChannels
                            var pos = resampleCarry
                            while (pos < frames) {
                                val i0 = pos.toInt()
                                if (i0 >= frames) break
                                var acc = 0f
                                for (c in 0 until srcChannels) {
                                    acc += shorts.get(i0 * srcChannels + c) / 32768f
                                }
                                if (used >= buf.size) buf = buf.copyOf(buf.size * 2)
                                buf[used++] = acc / srcChannels
                                pos += step
                            }
                            resampleCarry = pos - frames
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEos = true

                        // 攒够一块就切:边界挪到静音处
                        while (used >= chunkTarget + searchSpan) {
                            val cut = quietestNear(buf, chunkTarget, searchSpan, used)
                            onChunk(buf.copyOfRange(0, cut), (emittedSamples * 1000 / TARGET_RATE).toInt())
                            emittedSamples += cut
                            System.arraycopy(buf, cut, buf, 0, used - cut)
                            used -= cut
                            chunkIndex++
                            chunkTarget = CHUNK_SEC_RAMP[minOf(chunkIndex, CHUNK_SEC_RAMP.size - 1)] * TARGET_RATE
                        }
                    }
                }
            }

            if (used > 0) onChunk(buf.copyOfRange(0, used), (emittedSamples * 1000 / TARGET_RATE).toInt())
            return true
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e(TAG, "解码失败 path=$path", e)
            return false
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }

    /**
     * 在 `center ± span` 里找 20ms 窗能量最低的位置当切点。
     * 找不到更安静的地方就返回 center —— 宁可硬切,也不要把块拉得过长。
     *
     * `used` 是缓冲里**真实有效的样本数**。上界必须按它算而不是按 `buf.size`:
     * buf 是按最大块长预分配的,尾部要么是零、要么是上一块搬移后的残留 ——
     * 那片区域"能量最低",不排除掉就会一直被选成切点。
     */
    private fun quietestNear(buf: FloatArray, center: Int, span: Int, used: Int): Int {
        val win = TARGET_RATE / 50            // 20ms
        var best = center
        var bestEnergy = Float.MAX_VALUE
        var at = (center - span).coerceAtLeast(win)
        val end = (center + span).coerceAtMost(used - win)
        while (at < end) {
            var e = 0f
            var i = at
            while (i < at + win) { e += buf[i] * buf[i]; i++ }
            if (e < bestEnergy) { bestEnergy = e; best = at }
            at += win
        }
        return best
    }
}
