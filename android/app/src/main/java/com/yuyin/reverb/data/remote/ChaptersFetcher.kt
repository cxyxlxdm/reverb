package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Chapter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * 取发布方的**章节表**(RSS `podcast:chapters` → 一个 JSON),解析成 [Chapter] 列表。
 *
 * 章表是发布方自己维护的,本机只做两件事:读 JSON、按时间跳。不推断、不切分、
 * 不拿逐字稿去猜 —— 猜出来的章节会在用户跳过去之后"讲的是别的事",比没有更糟。
 *
 * 格式按 Podcasting 2.0 chapters 规范:
 * ```json
 * { "version": "1.2.0",
 *   "chapters": [ { "startTime": 0, "title": "开场", "img": "https://…", "url": "https://…" } ] }
 * ```
 * 实际见到的两种变体都要认:
 * - `startTime` 是**秒**,可能带小数;老一点的 Podlove 写法用 `start: "00:01:23.500"`;
 * - 顶层偶尔直接是数组(不带 `{"chapters": …}` 包装)。
 *
 * **失败与空是两回事**:返回 `null` = 取不到/解析不了(界面给"重试"),空列表 = 这集确实没有章节
 * (界面说"没有章节")。两者混成一个空列表,用户就只能对着一个永远重试不好的按钮点。
 */
class ChaptersFetcher(
    private val client: OkHttpClient,
    /** 按地址查私有源凭据(同主机才给),与逐字稿同一条口径。 */
    private val authHeader: (String) -> String? = { null }
) {
    private val TAG = "Chapters"

    /** 上限 1 MB:章表就是几十条标题,超过这个量级的一定不是章表(多半是标错 type 的音频)。 */
    private val MAX_BYTES = 1L shl 20

    suspend fun fetch(url: String): List<Chapter>? = withContext(Dispatchers.IO) {
        val text = download(url) ?: return@withContext null
        val chapters = parseChapters(text)
        when {
            chapters == null -> {
                com.yuyin.reverb.util.Logger.w(
                    TAG,
                    "章节解析失败 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                null
            }
            chapters.isEmpty() -> {
                com.yuyin.reverb.util.Logger.i(
                    TAG,
                    "章节表为空 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                chapters
            }
            else -> {
                com.yuyin.reverb.util.Logger.i(
                    TAG,
                    "章节 ${chapters.size} 条 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                chapters
            }
        }
    }

    private fun download(url: String): String? = try {
        val builder = Request.Builder()
            .url(url)
            .header("User-Agent", "Reverb/1.0 (Android podcast client)")
        authHeader(url)?.let { builder.header("Authorization", it) }
        client.newCall(builder.build()).execute().use { resp ->
            if (!resp.isSuccessful) {
                com.yuyin.reverb.util.Logger.w(
                    TAG,
                    "http ${resp.code} endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                null
            } else {
                val body = resp.body ?: return@use null
                // 读之前先看声明长度 —— 与逐字稿同一条防线
                val len = body.contentLength()
                if (len > MAX_BYTES) {
                    com.yuyin.reverb.util.Logger.w(
                        TAG,
                        "章表过大($len 字节),跳过 endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
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

    companion object {
        /**
         * 解析章表正文。`null` = 不是可识别的章表;空列表 = 是章表但没有可用章节。
         *
         * 排序与去重在这里做(**数据出口**):界面按"从后往前找第一个 `startMs <= now`"判断当前章,
         * 与逐字稿同一条不变式 —— 起点必须单调且 ≥0(硬规矩 10)。发布方给的顺序不能假定。
         */
        internal fun parseChapters(text: String): List<Chapter>? {
            val root: Any = try {
                JSONObject(text)
            } catch (_: Exception) {
                try {
                    JSONArray(text)
                } catch (_: Exception) {
                    return null
                }
            }
            val arr: JSONArray = when (root) {
                is JSONObject -> root.optJSONArray("chapters") ?: return emptyList()
                is JSONArray -> root
                else -> return null
            }

            val out = ArrayList<Chapter>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val startMs = startMsOf(o) ?: continue
                val title = o.optString("title").trim()
                // 没有标题的章在列表里是一行空白,点了也不知道跳到哪 —— 直接不收
                if (title.isEmpty()) continue
                out.add(
                    Chapter(
                        startMs = maxOf(startMs, 0),
                        title = title,
                        imageUrl = imageOf(o),
                        url = o.optString("url").trim()
                    )
                )
            }
            return out
                .sortedBy { it.startMs }
                .distinctBy { it.startMs }   // 同一秒只能有一章,否则"当前章"有两个答案
        }

        private fun startMsOf(o: JSONObject): Int? {
            if (o.has("startTime")) {
                val sec = o.optDouble("startTime", Double.NaN)
                if (!sec.isNaN() && sec.isFinite()) return (sec * 1000).roundToInt()
            }
            // 老写法 / Podlove 兼容:`start` 是时间串
            val start = o.optString("start").trim()
            if (start.isNotEmpty()) return parseTimecode(start)
            return null
        }

        private fun imageOf(o: JSONObject): String {
            val direct = o.optString("img").trim()
            if (direct.isNotEmpty()) return direct
            return o.optString("image").trim()
        }

        /**
         * `HH:MM:SS(.mmm)` / `MM:SS(.mmm)` / 纯秒数 → 毫秒。解析不了返回 null。
         *
         * 小数部分单独处理:不能 `"03.500".toDouble()` 之后乘 1000 再取整就完事 ——
         * 那是"3.5 秒",而 `HH:MM:SS` 里的 `03.500` 也是 3.5 秒,两种写法在这里恰好同义,
         * 但纯秒数 `83.5` 与 `01:23.5` 的进制不同,所以分情况更清楚。
         */
        private fun parseTimecode(s: String): Int? {
            return try {
                val parts = s.split(":")
                when (parts.size) {
                    1 -> (parts[0].toDouble() * 1000).roundToInt()
                    2 -> {
                        val m = parts[0].toLong()
                        val sec = parts[1].toDouble()
                        ((m * 60) * 1000 + (sec * 1000).roundToInt()).toInt()
                    }
                    3 -> {
                        val h = parts[0].toLong()
                        val m = parts[1].toLong()
                        val sec = parts[2].toDouble()
                        ((h * 3600 + m * 60) * 1000 + (sec * 1000).roundToInt()).toInt()
                    }
                    else -> null
                }
            } catch (_: Exception) {
                null
            }
        }
    }
}
