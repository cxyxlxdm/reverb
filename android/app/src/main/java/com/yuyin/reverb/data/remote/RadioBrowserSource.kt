package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Station
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray

/**
 * 在线电台目录:radio-browser.info(公共社区数据库,数据 CC0,无需 Key)。
 *
 * 这一路只解决「找得到」:用户搜一个台名、或先看一屏热门,点「+」收藏进本机账本。
 * 播放与收藏之后的地址校验仍走 `LiveStreamSource` 的探针 —— 目录里的 `lastcheckok`
 * 是别人最近一次的结果,不是此刻的保证。
 *
 * 两个镜像按序尝试:`de1` 与 `de2`(2026-11-22 本机实测可达)。`at1`/`nl1` 当时不可达,
 * 不放进表里 —— 放进去只会让每次失败多等一轮超时。
 *
 * **只记结果条数与镜像名,不记用户输入的原词**(隐私政策第二节:日志不落完整 URL 与检索词)。
 */
class RadioBrowserSource(private val client: OkHttpClient) {

    /**
     * @return 成功时返回目录条目(已过滤掉 url 为空 / 最近一次检查失败的),全镜像失败返回空列表。
     *         调用方用「空 + 有没有抛」区分不了失败与真没结果 —— 这里统一按空处理,
     *         界面文案是"没找到/连不上",不承诺是哪一种。
     */
    // limit 不是越大越好:目录的耗时随它**超线性**增长(2026-11-22 本机实测同一关键词:
    // limit=50 要 31.8 s、20 只要 2.5 s;热门 40 要 9.4 s、30 只要 2.6 s)。50 会稳定撞上
    // OkHttp 的 20 s 读超时,用户看到的是"目录连不上"。要更多结果只能加翻页,不能再加 limit。
    suspend fun popular(limit: Int = 30): List<Station> = request { host ->
        endpoint(
            host,
            listOf(
                "countrycode" to "CN",
                "limit" to limit.toString(),
                "hidebroken" to "true",
                "order" to "clickcount",
                "reverse" to "true"
            )
        )
    }

    suspend fun search(query: String, limit: Int = 20): List<Station> = request { host ->
        endpoint(
            host,
            listOf(
                "name" to query.trim(),
                "limit" to limit.toString(),
                "hidebroken" to "true",
                "order" to "clickcount",
                "reverse" to "true"
            )
        )
    }

    private suspend fun request(build: (String) -> HttpUrl): List<Station> = withContext(Dispatchers.IO) {
        for (host in MIRRORS) {
            try {
                val req = Request.Builder()
                    .url(build(host))
                    .header("User-Agent", "Reverb/1.0 (Android podcast client)")
                    .build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        Logger.w(TAG, "mirror http ${resp.code} host=$host")
                        return@use
                    }
                    val body = resp.body?.string().orEmpty()
                    val list = parseStations(body)
                    Logger.i(TAG, "ok host=$host n=${list.size}")
                    return@withContext list
                }
            } catch (e: Exception) {
                Logger.w(TAG, "mirror failed host=$host: ${e.javaClass.simpleName}")
            }
        }
        emptyList()
    }

    companion object {
        private const val TAG = "RadioDir"

        /** 按序尝试;新增镜像前先在本机实测可达性,别把超时写进正常路径。 */
        internal val MIRRORS = listOf("de1.api.radio-browser.info", "de2.api.radio-browser.info")

        internal fun endpoint(host: String, params: List<Pair<String, String>>): HttpUrl {
            val b = (("https://$host").toHttpUrlOrNull() ?: error("bad host $host")).newBuilder()
                .addPathSegments("json/stations/search")
            for ((k, v) in params) b.addQueryParameter(k, v)
            return b.build()
        }

        /**
         * 解析 `/json/stations/search` 的数组。抽成纯函数是为了单测:
         * 网络那一层只负责取字节,字段口径(过滤与兜底)全在这里。
         *
         * - `url_resolved` 优先,空则退 `url`(老记录里后者才有值);
         * - `lastcheckok == 0` 的条目丢掉 —— 收藏下来也是一个点了没反应的按钮;
         * - 同一 URL 在结果里重复出现时只留第一条(目录里同名同流的多条记录很常见)。
         */
        internal fun parseStations(json: String): List<Station> {
            val arr = try {
                JSONArray(json)
            } catch (e: Exception) {
                Logger.w(TAG, "parse failed bytes=${json.length}")
                return emptyList()
            }
            val out = ArrayList<Station>(arr.length())
            val seen = HashSet<String>()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optInt("lastcheckok", 1) == 0) continue
                val url = o.optString("url_resolved").trim().ifBlank { o.optString("url").trim() }
                val name = o.optString("name").trim()
                if (url.isBlank() || name.isBlank() || !seen.add(url)) continue
                val uuid = o.optString("stationuuid").trim()
                out.add(
                    Station(
                        id = if (uuid.isBlank()) "rb:$url" else "rb:$uuid",
                        name = name,
                        url = url,
                        logo = o.optString("favicon").trim(),
                        group = "",
                        country = o.optString("country").trim(),
                        source = Station.SOURCE_DIRECTORY
                    )
                )
            }
            return out
        }
    }
}
