package com.yuyin.reverb.data.model

/**
 * 一台用户可管理的直播电台(与 `Episode.isLive` 的"正在播的那一路流"是两层东西:
 * 这里是**账本里的一条**,那里是**此刻合成出来的播放条目**)。
 *
 * 四端备份契约:字段名 `id / name / url / logo / group / country / source` 在三端
 * `reverb-backup.json` 的 `stations` 段里逐键对齐,细节见 `docs/ARCHITECTURE.md`
 * 「直播电台」一节。**新增字段要四端同改**,否则换机恢复会静默丢那一项。
 *
 * `group` 不是给人看的文案,而是稳定代码(`news|music|talk|retro`),由界面按五语种
 * 本地化;空串 = 未分组(在线目录收藏进来的条目通常没有分组)。
 *
 * `source` 只用于界面提示与去重口径,恢复时照原样保留:
 *  - `manual`    —— 用户手输地址;
 *  - `directory` —— 从在线目录收藏,`id` 为 `rb:<stationuuid>`;
 *  - `seed`      —— 从随包精选里加了一份,`id` 为 `seed:<url>`。
 */
data class Station(
    val id: String,
    val name: String,
    val url: String,
    val logo: String = "",
    val group: String = "",
    val country: String = "",
    val source: String = SOURCE_MANUAL
) {
    /**
     * 去重判据只用 **url(trim 后逐字)**:
     * 同一路流从目录收藏一次、再手输一次,`id` 会不同(一个 `rb:`、一个 `local:`),
     * 只有地址是共同身份。**不做路径归一化** —— 尾斜杠对某些 Icecast 服务是两条不同的流。
     */
    fun key(): String = url.trim()

    companion object {
        const val SOURCE_MANUAL = "manual"
        const val SOURCE_DIRECTORY = "directory"
        const val SOURCE_SEED = "seed"

        /** 内置清单与编辑器提供的分组代码;空串是"未分组"。 */
        val GROUPS = listOf("news", "music", "talk", "retro")

        fun normalizeGroup(raw: String): String {
            val g = raw.trim().lowercase()
            return if (g in GROUPS) g else ""
        }
    }
}
