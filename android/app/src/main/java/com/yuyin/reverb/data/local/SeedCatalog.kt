package com.yuyin.reverb.data.local

import android.content.Context
import com.yuyin.reverb.data.model.Podcast
import org.json.JSONObject

/**
 * 随包内置的精选清单（`assets/seed_podcasts.json`，由 `shared/seed/gen-seed.py` 生成）。
 *
 * 解决的问题：首次安装、清过缓存、或全程无网时，「发现」页各分类都是空白 —— 只能干等
 * 或看到"暂无内容"。有了这份清单，磁盘缓存为空时先拿它顶上，首屏立刻有东西可看可点。
 *
 * 它**只是兜底**：一旦 [PopularCacheStore] 有真实榜单（联网刷新成功过一次），就再也不用它；
 * 也**从不写入**缓存，否则真假数据混在一起，之后无法区分"这是快照"还是"这是今天的榜"。
 *
 * 首次访问时才解析，且只解析一次；文件缺失/损坏一律退化为空（等同没有这个功能）。
 */
class SeedCatalog(private val context: Context) {

    private val lock = Any()
    private var lists: Map<String, List<Podcast>>? = null

    /** 该地区+分类的内置清单；没有则空。genreId 为 null 表示综合推荐。 */
    fun get(genreId: Int?, region: String): List<Podcast> =
        load()["${seedRegion(region)}:${genreId ?: 0}"] ?: emptyList()

    /** 清单生成日期（yyyy-MM-dd），用于「内置精选」提示；缺失返回空串。 */
    fun generatedAt(): String {
        load()
        return generated
    }

    private var generated: String = ""

    /**
     * 种子只打包了 cn / us 两份榜单（12 个地区全打进去没必要，它只是没网时的兜底）。
     * 中文区落到 cn，其余一律落到 us。
     */
    private fun seedRegion(region: String): String =
        if (region.lowercase() in setOf("cn", "hk", "tw", "mo")) "cn" else "us"

    private fun load(): Map<String, List<Podcast>> {
        lists?.let { return it }
        synchronized(lock) {
            lists?.let { return it }
            val parsed = parse()
            lists = parsed
            return parsed
        }
    }

    private fun parse(): Map<String, List<Podcast>> {
        return try {
            val text = context.assets.open(ASSET).bufferedReader().use { it.readText() }
            val root = JSONObject(text)
            generated = root.optString("generatedAt")
            val listsObj = root.optJSONObject("lists") ?: return emptyMap()
            val out = HashMap<String, List<Podcast>>()
            val keys = listsObj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val arr = listsObj.optJSONArray(k) ?: continue
                val items = ArrayList<Podcast>(arr.length())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val feed = o.optString("feedUrl")
                    if (feed.isBlank()) continue
                    items.add(
                        Podcast(
                            id = o.optString("id").ifBlank { feed },
                            title = o.optString("title"),
                            author = o.optString("author"),
                            artworkUrl = o.optString("artworkUrl"),
                            feedUrl = feed,
                            genre = o.optString("genre")
                            // 生成脚本已排除付费节目（点开播不了比空白更糟），故无需 isPaid
                        )
                    )
                }
                if (items.isNotEmpty()) out[k] = items
            }
            com.yuyin.reverb.util.Logger.i(TAG, "seed loaded lists=${out.size} generatedAt=$generated")
            out
        } catch (e: Exception) {
            // 资源缺失/格式变化不该让发现页崩，退化成"没有内置清单"即可
            com.yuyin.reverb.util.Logger.w(TAG, "seed load failed: ${e.message}")
            emptyMap()
        }
    }

    private companion object {
        const val ASSET = "seed_podcasts.json"
        const val TAG = "Seed"
    }
}
