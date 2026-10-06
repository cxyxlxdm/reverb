package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.data.model.TranscribedWord
import com.yuyin.reverb.util.TranscriptLines
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * 取发布方**自己提供的逐字稿**(RSS `podcast:transcript`),解析成统一的 `TranscribedSegment`。
 *
 * 这条路优先于本机识别:时间轴是发布方给的,准确、免费、瞬间可用,还没有耗电与发热。
 * 大陆商店渠道**只有这一条路**(不含离线识别引擎)。
 *
 * 支持三种带时间轴的格式:Podcast Index JSON / WebVTT / SRT。HTML 与纯文本稿不收
 * (没有时间轴,做不了跟播放高亮,见 `RssParser.transcriptRank`)。
 */
class TranscriptFetcher(private val client: OkHttpClient) {

    private val TAG = "Transcript"

    suspend fun fetch(url: String, declaredType: String): List<TranscribedSegment>? =
        withContext(Dispatchers.IO) {
            val text = download(url) ?: return@withContext null
            val segs = parse(text, declaredType)
            if (segs.isNullOrEmpty()) {
                com.yuyin.reverb.util.Logger.w(
                    TAG,
                    "解析不出句子 type=$declaredType endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                null
            } else {
                com.yuyin.reverb.util.Logger.i(
                    TAG,
                    "官方稿 ${segs.size} 句 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                segs
            }
        }

    private fun download(url: String): String? = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
            .build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                com.yuyin.reverb.util.Logger.w(
                    TAG,
                    "http ${resp.code} endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                null
            } else {
                val body = resp.body ?: return@use null
                // 逐字稿是纯文本,再长也就几百 KB。**读之前**先看声明长度,
                // 免得遇到标错 type 的音频/视频链接把几十 MB 读进内存
                val len = body.contentLength()
                if (len > MAX_BYTES) {
                    com.yuyin.reverb.util.Logger.w(
                        TAG,
                        "稿子过大($len 字节),跳过 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                    )
                    null
                } else {
                    body.string()
                }
            }
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(
            TAG,
            "下载失败 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}",
            e
        )
        null
    }

    /**
     * 选解析器。**先嗅探内容,再看声明的 type** —— feed 里 type 标错的情况很常见
     * (把 VTT 标成 `text/plain`、把 JSON 标成 `application/octet-stream` 都见过),
     * 内容特征比声明可靠。
     */
    internal fun parse(raw: String, declaredType: String): List<TranscribedSegment>? {
        val text = raw.removePrefix("﻿").trim()   // 去 BOM,否则 "WEBVTT" 判断会失手
        return when {
            text.startsWith("WEBVTT") -> parseCues(text, vtt = true)
            // `[` 也要认:有些转写服务直接把数组当根吐出来(鸿蒙那边一直认,这边漏了 —— 见 H150)
            text.startsWith("{") || text.startsWith("[") -> parseJson(text)
            text.contains("-->") -> parseCues(text, vtt = false)
            declaredType.contains("json", true) -> parseJson(text)
            else -> null
        }
    }

    // ───────────────────────── SRT / WebVTT ─────────────────────────

    /**
     * SRT 与 VTT 用同一套解析:按空行切块,块里找带 `-->` 的那一行当时间,其余行拼成文本。
     * 两者的差别只有毫秒分隔符(SRT 用逗号、VTT 用点)与几样附加语法,
     * 分开写两份纯属重复 —— 差异都在下面几行注释标着的地方。
     */
    private fun parseCues(text: String, vtt: Boolean): List<TranscribedSegment> {
        val out = ArrayList<TranscribedSegment>()
        for (block in text.split(Regex("\\r?\\n[ \\t]*\\r?\\n"))) {
            val lines = block.trim().lines().filter { it.isNotBlank() }
            if (lines.isEmpty()) continue
            // VTT 的 NOTE / STYLE / REGION 块不是字幕,整块跳过
            if (vtt && lines[0].startsWith("NOTE")) continue
            if (vtt && (lines[0] == "STYLE" || lines[0] == "REGION")) continue

            val tIdx = lines.indexOfFirst { it.contains("-->") }
            if (tIdx < 0) continue
            val timeLine = lines[tIdx]
            // VTT 的时间行后面可能跟排版设置(align:start position:0%),取前两段就够
            val parts = timeLine.split("-->")
            if (parts.size < 2) continue
            val start = parseClock(parts[0]) ?: continue
            val end = parseClock(parts[1]) ?: continue

            // 时间行之前那行是序号(SRT)或 cue 标识(VTT),都不是正文;之后各行才是
            val body = lines.drop(tIdx + 1).joinToString(" ") { cleanCueText(it) }.trim()
            if (body.isBlank()) continue
            out.addAll(TranscriptLines.split(body, start, maxOf(end, start)))
        }
        // 也要并碎片:切长 cue 会剩下尾巴("…joins me and" / "he's"),而最后一条 cue
        // 本身就可能只有一个词("Review")。实测这份 VTT 两种都出现了。
        return TranscriptLines.glueOrphans(out)
    }

    /**
     * 去掉 VTT 的说话人标签与内联样式(`<v Alice>`、`<c.loud>`、`<00:00:01.000>`),
     * 以及 SRT 正文里**机器编号的说话人前缀**。
     *
     * 后者只删 `SPEAKER_02:` 这种自动分离出来的编号(实测 Buzzsprout 的 SRT 就长这样),
     * **人名前缀保留** —— 「James Cridland:」是有用信息,删了反而可惜。
     */
    private fun cleanCueText(line: String): String =
        line.replace(Regex("<[^>]*>"), "")
            .replace(Regex("(?i)^\\s*speaker[_ ]?\\d+\\s*:\\s*"), "")
            .replace("&nbsp;", " ")
            .trim()

    /**
     * `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm`(VTT 允许省略小时)→ 毫秒。
     * 时间行两侧可能带空格和排版设置,故先按空白切出第一段。
     */
    internal fun parseClock(s: String): Int? {
        val token = s.trim().split(Regex("\\s+")).firstOrNull()?.replace(',', '.') ?: return null
        val seg = token.split(":")
        // 只认 `HH:MM:SS` / `MM:SS`(鸿蒙那边也是这段要求)。原先允许单段数字,于是正文里
        // 混进的一行 "5" 会被当成 5 秒造出一个假 cue —— 那是凭空多出的一行(见 H150)
        if (seg.size < 2 || seg.size > 3) return null
        return try {
            var ms = 0.0
            for (p in seg) ms = ms * 60 + p.toDouble()   // 从高位往低位累乘,兼容 2 段与 3 段
            (ms * 1000).roundToInt()                     // 与鸿蒙的 Math.round 同口径
        } catch (e: NumberFormatException) {
            null
        }
    }

    // ───────────────────────── Podcast Index JSON ─────────────────────────

    /**
     * Podcast Index 的 JSON 稿:`{"segments":[{"startTime":0.0,"endTime":1.5,"body":"…"}]}`
     * (`startTime`/`endTime` 单位是**秒的浮点**)。
     *
     * 这个格式的粒度很不统一:有的一条就是一整句,有的**一条只有一两个词**
     * (转写服务直接把词级结果吐出来)。所以一律先合成"能读的一行",
     * 并把合并进来的原始条目留在 `words` 里 —— 于是词级稿能做逐词卡拉OK,
     * 句级稿退化成整句高亮,两种都不用调用方操心。
     */
    private fun parseJson(text: String): List<TranscribedSegment>? {
        val arr = try {
            if (text.startsWith("[")) JSONArray(text)                       // 根就是数组的稿
            else JSONObject(text).optJSONArray("segments") ?: return null   // Podcast Index 标准形
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.w(TAG, "JSON 稿格式不认:${e.message}")
            return null
        }
        val words = ArrayList<TranscribedWord>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val body = pickString(o, BODY_KEYS)
            if (body.isEmpty()) continue
            val s = pickMs(o, START_KEYS)
            val e = pickMs(o, END_KEYS)
            if (s < 0) continue
            words.add(TranscribedWord(body, s, if (e > s) e else s))
        }
        // 合并成可读行 + 保留词级时间,与 whisper 那条路共用同一份实现。
        // 这里的条目**不自带空格**(JSON 稿是纯词),所以 spaced = true
        return if (words.isEmpty()) null else TranscriptLines.mergeWords(words, spaced = true)
    }

    /**
     * 取第一个**有内容**的字符串键。转写服务给出的键名不统一(`body` 是 Podcast Index 的,
     * `text` 是几家自研接口的,`word` 是词级稿直接给单字的)。
     * 这层容错鸿蒙先做了、这边漏了 —— 同一个 feed 于是一端出稿、另一端解析失败(见 H150)。
     */
    private fun pickString(o: JSONObject, keys: Array<String>): String {
        for (k in keys) {
            val v = o.opt(k)
            if (v is String) {
                val t = v.trim()
                if (t.isNotEmpty()) return t
            }
        }
        return ""
    }

    /**
     * 取时间并统一成毫秒:键名以 `Ms` 结尾的当毫秒,其它当**秒(浮点)**;取不到返回 -1。
     *
     * 用四舍五入而不是早先的 `.toInt()`(截断):断句门是 400ms / 900ms 这种整数阈值,
     * 一端截断一端进位,同一份稿就会在临界值上分叉成不同的行。鸿蒙一直是 `Math.round`。
     */
    private fun pickMs(o: JSONObject, keys: Array<String>): Int {
        for (k in keys) {
            val n = when (val v = o.opt(k)) {
                is Number -> v.toDouble()
                is String -> v.trim().toDoubleOrNull()
                else -> null
            }
            if (n != null) return if (k.endsWith("Ms")) n.roundToInt() else (n * 1000).roundToInt()
        }
        return -1
    }

    private companion object {
        /// 8 MB:再离谱的逐字稿也到不了这个量级,超过就是链接指错了东西
        const val MAX_BYTES = 8L * 1024 * 1024

        val BODY_KEYS = arrayOf("body", "text", "word")
        val START_KEYS = arrayOf("startTime", "start", "startMs")
        val END_KEYS = arrayOf("endTime", "end", "endMs")
    }
}
