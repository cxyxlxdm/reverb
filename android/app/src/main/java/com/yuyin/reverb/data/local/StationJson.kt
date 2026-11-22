package com.yuyin.reverb.data.local

import com.yuyin.reverb.data.model.Station
import org.json.JSONObject

/**
 * [Station] 的 JSON 序列化,供本地账本与备份 `stations` 段复用。
 *
 * 键集是四端契约的一部分(见 `docs/ARCHITECTURE.md`「直播电台」):
 * **不要为了本端方便改名**;缺键按空串/默认值读,坏条目由调用方逐条丢掉,
 * 不让一条坏数据把整份电台账本读空。
 */
object StationJson {
    fun toJson(s: Station): JSONObject = JSONObject()
        .put("id", s.id)
        .put("name", s.name)
        .put("url", s.url)
        .put("logo", s.logo)
        .put("group", s.group)
        .put("country", s.country)
        .put("source", s.source)

    /** 没有 url 的条目没有播放价值,直接算坏条目返回 null。 */
    fun fromJson(o: JSONObject): Station? {
        val url = o.optString("url").trim()
        if (url.isBlank()) return null
        val name = o.optString("name").trim()
        return Station(
            id = o.optString("id").trim().ifBlank { "local:$url" },
            name = name.ifBlank { url },
            url = url,
            logo = o.optString("logo").trim(),
            group = Station.normalizeGroup(o.optString("group")),
            country = o.optString("country").trim(),
            source = o.optString("source").trim().ifBlank { Station.SOURCE_MANUAL }
        )
    }
}
