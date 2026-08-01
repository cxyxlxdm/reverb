package com.yuyin.reverb.data.model

import com.yuyin.reverb.R

/**
 * 播客分类归一化：把 Apple/RSS 的分类名（英文，含大量子分类）以及旧版已存的中文标签，
 * 统一映射为稳定 key；再由 [labelRes] 取本地化显示名（随 UI 语言切换）。未收录的原样返回。
 */
object Genres {
    private val toKey: Map<String, String> = buildMap {
        group("arts", "arts", "design", "fashion & beauty", "food", "performing arts", "visual arts", "books")
        group("business", "business", "careers", "entrepreneurship", "investing", "management", "marketing", "non-profit", "business news")
        group("comedy", "comedy", "comedy interviews", "improv", "stand-up", "comedy fiction")
        group("education", "education", "courses", "how to", "language learning", "self-improvement")
        group("fiction", "fiction", "drama", "science fiction")
        group("government", "government")
        group("health", "health & fitness", "health", "fitness", "medicine", "mental health", "nutrition", "alternative health", "sexuality")
        group("history", "history")
        group("kids", "kids & family", "parenting", "pets & animals", "stories for kids", "education for kids")
        group("leisure", "leisure", "animation & manga", "automotive", "aviation", "crafts", "games", "hobbies", "home & garden", "video games")
        group("music", "music", "music commentary", "music history", "music interviews")
        group("news", "news", "daily news", "entertainment news", "news commentary", "politics", "sports news", "tech news")
        group("religion", "religion & spirituality", "buddhism", "christianity", "hinduism", "islam", "judaism", "religion", "spirituality")
        group("science", "science", "astronomy", "chemistry", "earth sciences", "life sciences", "mathematics", "natural sciences", "nature", "physics", "social sciences")
        group("society", "society & culture", "culture", "documentary", "personal journals", "philosophy", "places & travel", "relationships")
        group("sports", "sports", "baseball", "basketball", "cricket", "fantasy sports", "football", "golf", "hockey", "rugby", "running", "soccer", "swimming", "tennis", "volleyball", "wilderness", "wrestling")
        group("tech", "technology")
        group("truecrime", "true crime")
        group("tv", "tv & film", "after shows", "film history", "film interviews", "film reviews", "tv reviews")
        // 兼容旧版已存的中文标签
        put("艺术", "arts"); put("商业", "business"); put("喜剧", "comedy"); put("教育", "education")
        put("小说", "fiction"); put("时政", "government"); put("历史", "history"); put("健康", "health")
        put("亲子", "kids"); put("休闲", "leisure"); put("音乐", "music"); put("新闻", "news")
        put("宗教", "religion"); put("知识", "science"); put("文化", "society"); put("体育", "sports")
        put("科技", "tech"); put("犯罪纪实", "truecrime"); put("影视", "tv")
    }

    private val labels: Map<String, Int> = mapOf(
        "arts" to R.string.genre_arts,
        "business" to R.string.genre_business,
        "comedy" to R.string.genre_comedy,
        "education" to R.string.genre_education,
        "fiction" to R.string.genre_fiction,
        "government" to R.string.genre_government,
        "health" to R.string.genre_health,
        "history" to R.string.genre_history,
        "kids" to R.string.genre_kids,
        "leisure" to R.string.genre_leisure,
        "music" to R.string.genre_music,
        "news" to R.string.genre_news,
        "religion" to R.string.genre_religion,
        "science" to R.string.genre_science,
        "society" to R.string.genre_society,
        "sports" to R.string.genre_sports,
        "tech" to R.string.genre_tech,
        "truecrime" to R.string.genre_truecrime,
        "tv" to R.string.genre_tv
    )

    private fun MutableMap<String, String>.group(key: String, vararg raws: String) {
        for (r in raws) put(r, key)
    }

    /** 归一化为稳定 key；未知则原样返回（含首尾去空）。 */
    fun key(raw: String): String {
        if (raw.isBlank()) return ""
        val k = raw.trim()
        return toKey[k.lowercase()] ?: k
    }

    /** 稳定 key → 本地化字符串资源；未知 key 返回 null（调用方回退显示原文）。 */
    fun labelRes(key: String): Int? = labels[key]
}
