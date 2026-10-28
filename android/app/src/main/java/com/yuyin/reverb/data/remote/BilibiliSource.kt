package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.net.URLEncoder
import java.time.Instant
import java.time.ZoneId
import java.util.concurrent.ConcurrentHashMap

/**
 * 把一段 B 站视频当成一集播客来播。
 *
 * **不建任何中转**:解析与取流都由设备直连 B 站的公开接口完成。
 * 这一条是本方案能进本仓库的前提 —— 它保住了约束一(零后端),也让
 * `docs/PRIVACY.md` 里「不转存或代理节目内容 … 直接访问发布方或托管方提供的原始地址」
 * 这句已发布的承诺继续成立。原始调研(2026-09-15)想走 Cloudflare Worker,被否,
 * 理由与实测读数见 `docs/research/2026-09-15-bilibili-audio-proxy.md`。
 *
 * 三个实测结论决定了这里的写法(2026-10-28,匿名请求、无 Cookie):
 *  1. `x/web-interface/view` 与 `x/player/playurl` **都不需要签名**,也**不需要 Cookie**
 *     (早期调研说它们要 `buvid3` + wbi,实测不成立)。
 *     `x/web-interface/wbi/search/type` 的路径里带 `wbi`,但**也不校验签名**(实测:
 *     不带 `w_rid`、`wts` 随便填,照样 20 条)。它要的是**别的**东西,见第 4 条。
 *  2. 直链的 `deadline` 参数是**请求时刻 + 2 小时**,比「几小时」还紧 ⇒
 *     **绝不能把直链持久化**(历史、队列、备份里存的都是 `bilibili://` 伪地址,播放前才解析)。
 *  3. `dash.audio` 里排第一的那条常常落在 PCDN 上,实测同一个视频换一轮取链,
 *     三条候选的可用性还会**互换**(一轮是 #0 通、两条 backup 403;另一轮 #0 直接 503)。
 *     每条音轨另带两条 `backupUrl`。⇒ 解析后必须**探测**再交给播放器,并按游标轮换起点;
 *     否则表现是「点了没反应」,而日志里只有一个 503/403。
 *     探活与播放本身**都不需要 UA / Referer**(四种组合实测都是同样的码)。
 *  4. ⚠️ **搜索要 `Referer: https://www.bilibili.com/`**,缺了会被风控软拦:
 *     回 **`code=0` + `data:{"v_voucher": …}` + 零条结果** —— 看起来完全像「没搜到」,
 *     而不是报错。这一条踩过:本地用 curl 连试三次全 0 条,差点把「搜索做不了」写进结论;
 *     同一台机器只补一个 Referer 就出 20 条(2026-10-28,逐组对照记在
 *     `docs/TROUBLESHOOTING.md`)。所以下面 [getJson] 对所有请求都带 Referer。
 *  5. 音频流是 `.m4s` 分片 MP4(`ftyp`/`moov`/`sidx`/`moof`/`mdat`,实测头部),
 *     `Range` 请求回 206 ⇒ 播放器按普通渐进流处理、拖动进度条可用。
 *
 * ⚠️ `x/space/<mid>/arc/search`(UP 主投稿列表)是另一件事:实测 `-352` / `-412` / `-799`,
 * 是整条链路上唯一被风控挡住的部分,所以**「订阅 UP 主」这个功能不做**(2026-10-28 拍板)。
 * 这里没有任何代码去碰它 —— 别再顺手加回来。
 * (上面这条路径**不写通配星号**:Kotlin 的块注释可以嵌套,星号紧跟在斜杠后面
 * 会当场把注释吃掉 —— 第一版就是这么编不过的。)
 */
class BilibiliSource(private val client: OkHttpClient) {

    private val TAG = "Bilibili"

    /** 一次解析出来的候选流地址 + 它的失效时刻(毫秒)。只在内存里,不落盘。 */
    private class Track(val urls: List<String>, val expiresAt: Long)

    private val tracks = ConcurrentHashMap<String, Track>()
    /** 每集下次从第几个候选开始试。重试(换一个 503 的 PCDN 节点)靠它生效。 */
    private val cursor = ConcurrentHashMap<String, Int>()

    // ---------------------------------------------------------------- 伪地址

    /**
     * 播放前要解析的地址形态。
     *
     * 存这个而不是真直链的原因只有一个:**直链 2 小时就废**。历史记录、待播队列、
     * 播放态快照都会跨启动甚至跨设备走备份,一旦把签名直链写进去,第二天点开就是
     * 「这一集播不了」,而用户没有任何线索知道该重新搜一次。
     */
    private fun audioUri(bvid: String, cid: Long) = "$SCHEME://audio/$bvid/$cid"

    private fun videoUri(bvid: String) = "$SCHEME://video/$bvid"

    companion object {
        private const val SCHEME = "bilibili"
        // 注意这三条路径**不在同一个前缀下**:playurl 挂在 `/x/player/` 而不是 `/x/web-interface/`。
        private const val API = "https://api.bilibili.com/x"
        private const val REFERER = "https://www.bilibili.com/"
        private const val UA = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/126.0 Mobile Safari/537.36"
        private val BV_RE = Regex("BV[0-9A-Za-z]{10}")
        private val HHMM_RE = Regex("^(\\d+):(\\d+)$")

        /** 这一集是不是需要播放前解析。三端同口径(鸿蒙/ macOS 用同一个前缀判断)。 */
        fun isPseudo(url: String): Boolean = url.startsWith("$SCHEME://")

        /**
         * 用户输入看起来是不是「某一条视频」。
         *
         * 单认 BV 号就够:分享文案里的完整链接、`?p=` 参数、`b23.tv` 短链后面都藏着它。
         * 这一步是**廉价的字符串判断**,所以可以放在搜索框的同步路径上;
         * 真正的网络动作(短链跟随、view 接口)在 [resolveInput] 里。
         */
        fun looksLikeVideo(input: String): Boolean =
            BV_RE.containsMatchIn(input) || input.contains("b23.tv") || input.contains("bili2233.cn")

        /** `bilibili://video/<bvid>` → bvid;不是这个形态就 null。 */
        fun videoIdOf(feedUrl: String): String? =
            if (feedUrl.startsWith("$SCHEME://video/")) feedUrl.removePrefix("$SCHEME://video/").takeIf { it.isNotBlank() }
            else null

        /** `bilibili://audio/<bvid>/<cid>` → (bvid, cid)。 */
        fun parseAudioUri(url: String): Pair<String, Long>? {
            if (!url.startsWith("$SCHEME://audio/")) return null
            val parts = url.removePrefix("$SCHEME://audio/").split('/')
            if (parts.size != 2) return null
            val cid = parts[1].toLongOrNull() ?: return null
            return parts[0] to cid
        }
    }

    // ---------------------------------------------------------------- 粘链接

    /**
     * 用户在搜索框里贴了一个 B 站地址(或干脆只贴了 BV 号)。
     *
     * 认三种形态:BV 号本体、`bilibili.com/video/BV…`(可带 `?p=`)、`b23.tv` 短链。
     * 短链要**跟随一次重定向**才能拿到 BV —— 不跟随的话用户看到的是「没搜到」,
     * 而链接在市场分享里最常见的就是短链形态。
     */
    suspend fun resolveInput(input: String): FeedResult? = withContext(Dispatchers.IO) {
        val q = input.trim()
        if (q.isEmpty()) return@withContext null
        val bvid = bvidOf(q) ?: return@withContext null
        val result = view(bvid) ?: return@withContext null
        com.yuyin.reverb.util.Logger.i(TAG, "resolve ok parts=${result.episodes.size}")
        result
    }

    private fun bvidOf(input: String): String? {
        BV_RE.find(input)?.let { return it.value }
        // 短链:只有 b23.tv / bili2233.cn 这两种;别的短链不猜,免得把无关 URL 当视频解析
        if (!input.contains("b23.tv") && !input.contains("bili2233.cn")) return null
        return try {
            val resp = client.newCall(
                Request.Builder().url(input).header("User-Agent", UA).build()
            ).execute()
            resp.use {
                // 不 follow:OkHttp 默认会跟,但我们只要 Location 里的 BV;
                // 用 header 取比再读一次页面快得多(页面里有几十 KB 的 JSON-LD)。
                val loc = it.header("Location") ?: it.request.url.toString()
                BV_RE.find(loc)?.value
            }
        } catch (e: Exception) {
            com.yuyin.reverb.util.Logger.e(TAG, "short link failed", e)
            null
        }
    }

    /**
     * 频道页的入口:`bilibili://video/<bvid>` → [FeedResult]。
     *
     * 与 [resolveInput] 的唯一区别是入参形态 —— 一个是用户贴的原文,一个是上一次
     * 已经归一过的伪地址。分 P、封面、作者都重新取一次:标题改了、视频被 UP 删了,
     * 这里要跟着变,而不是让频道页永远停在第一次贴进来时的样子。
     */
    suspend fun feedOf(feedUrl: String): FeedResult? {
        val bvid = videoIdOf(feedUrl) ?: return null
        return view(bvid)
    }

    /**
     * bvid → 频道元信息 + 全部分 P。
     *
     * 单 P 视频就是「一集」;多 P 视频把每一 P 拆成一集(它们各有自己的 cid,
     * 而 playurl 是按 cid 取的)。合集(season)不做 —— 那要 space 接口,见类注释。
     */
    suspend fun view(bvid: String): FeedResult? = withContext(Dispatchers.IO) {
        val data = getJson("$API/web-interface/view?bvid=$bvid")?.optJSONObject("data") ?: run {
            com.yuyin.reverb.util.Logger.w(TAG, "view failed bvid=$bvid")
            return@withContext null
        }
        val title = data.optString("title")
        val owner = data.optJSONObject("owner")
        val mid = owner?.optString("mid").orEmpty()
        val upName = owner?.optString("name").orEmpty()
        val cover = https(data.optString("pic"))
        val desc = stripTags(data.optString("desc"))
        val pubDate = date(data.optLong("pubdate", 0L))

        val podcast = Podcast(
            id = "$SCHEME:$bvid",
            title = title,
            // 作者位写 UP 名,后面跟一个平台标记 —— 列表里同名频道很多,没有这一格
            // 用户分不清「这是播客」还是「这是一段视频」。应用内可以明写平台名。
            author = upName,
            artworkUrl = cover,
            feedUrl = videoUri(bvid),
            description = desc
        )

        val pages = data.optJSONArray("pages")
        val episodes = ArrayList<Episode>(pages?.length() ?: 1)
        if (pages == null || pages.length() == 0) {
            // 兜底:老接口理论上总给 pages,真没有就按单集处理(cid 取 data.cid)
            val cid = data.optLong("cid")
            if (cid > 0) {
                episodes.add(
                    Episode(
                        id = "$SCHEME:$bvid:$cid",
                        title = title,
                        description = desc,
                        audioUrl = audioUri(bvid, cid),
                        artworkUrl = cover,
                        podcastTitle = upName,
                        durationSec = data.optLong("duration"),
                        pubDate = pubDate,
                        feedUrl = videoUri(bvid)
                    )
                )
            }
        } else {
            for (i in 0 until pages.length()) {
                val p = pages.optJSONObject(i) ?: continue
                val cid = p.optLong("cid")
                if (cid <= 0) continue
                val part = p.optString("part").trim()
                val page = p.optInt("page", i + 1)
                episodes.add(
                    Episode(
                        id = "$SCHEME:$bvid:$cid",
                        // 单 P 视频不给自己加「P1」前缀:那会让播放页标题与用户在 B 站看到的不一样。
                        title = if (pages.length() == 1) title else part.ifBlank { "P$page" },
                        description = desc,
                        audioUrl = audioUri(bvid, cid),
                        artworkUrl = cover,
                        podcastTitle = upName,
                        durationSec = p.optLong("duration"),
                        pubDate = pubDate,
                        feedUrl = videoUri(bvid)
                    )
                )
            }
        }
        if (episodes.isEmpty()) {
            com.yuyin.reverb.util.Logger.w(TAG, "view no playable cid bvid=$bvid")
            return@withContext null
        }
        // mid 只用来打日志:订阅 UP 主那条路没做,留着它方便排查「同一个 UP 的另一条视频」
        com.yuyin.reverb.util.Logger.d(TAG, "view ok mid=$mid parts=${episodes.size}")
        FeedResult(podcast, episodes)
    }

    // ---------------------------------------------------------------- 关键词搜单集

    /**
     * 搜「单集」,不搜频道。
     *
     * 路径里带 `wbi` 但**实测免签**(见类注释第 1 条)—— 别看到路径名就去实现签名,
     * 那是原始调研里最贵的一块工作量,而且并不需要。
     *
     * 结果天然是视频粒度,正好对上「单集」这个语义;每个视频各自成一个
     * `bilibili://video/<bvid>` 频道,点进频道页会重新取一次元信息(见 [PodcastRepository.feed])。
     */
    suspend fun searchEpisodes(keyword: String, page: Int = 1): List<Episode> = withContext(Dispatchers.IO) {
        val kw = keyword.trim()
        if (kw.isEmpty()) return@withContext emptyList()
        val url = "$API/web-interface/wbi/search/type?search_type=video&keyword=${enc(kw)}&page=$page&page_size=20"
        val data = getJson(url)?.optJSONObject("data")
        val arr = data?.optJSONArray("result") ?: run {
            // 风控软拦的指纹是 `v_voucher`(code 仍是 0,没有 result)。单独报一句,
            // 否则日志里只剩 "search failed",下一个人会去怀疑关键词或网络。
            if (data?.has("v_voucher") == true) {
                com.yuyin.reverb.util.Logger.w(TAG, "search soft-blocked (v_voucher) — 检查 Referer")
            } else {
                com.yuyin.reverb.util.Logger.w(TAG, "search failed")
            }
            return@withContext emptyList()
        }
        val out = ArrayList<Episode>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val bvid = o.optString("bvid")
            if (bvid.isBlank()) continue
            val cover = https(o.optString("pic"))
            val author = stripTags(o.optString("author"))
            out.add(
                Episode(
                    // 搜索结果是「一个视频」,分 P 要等进频道页才知道 ⇒ id 先用 bvid 占位。
                    // 播放路径不靠 id 认视频(它解析 audioUrl),所以这个 id 只需要稳。
                    id = "$SCHEME:search:$bvid",
                    title = stripTags(o.optString("title")),
                    description = stripTags(o.optString("description")),
                    // 搜索结果里没有 cid,**这里刻意不给可播地址**:直接构造一个假 cid 会让
                    // 播放请求打到别人那一集。用户点进频道页拿到的才是真 cid。
                    audioUrl = videoUri(bvid),
                    artworkUrl = cover,
                    podcastTitle = author,
                    durationSec = HHMM_RE.find(o.optString("duration"))?.let { m ->
                        m.groupValues[1].toLong() * 60 + m.groupValues[2].toLong()
                    } ?: 0L,
                    pubDate = date(o.optLong("pubdate", 0L)),
                    feedUrl = videoUri(bvid)
                )
            )
        }
        com.yuyin.reverb.util.Logger.i(TAG, "search count=${out.size}")
        out
    }

    // ---------------------------------------------------------------- 播放前解析

    /**
     * `bilibili://audio/<bvid>/<cid>` → 一条**已经探通**的音频直链。
     *
     * 失败返回 null,由调用方走播放页那条错误状态行 —— 不要在这里重试:
     * 播放器的重投由 [com.yuyin.reverb.playback.PlayerController] 统一管,
     * 两处各自重试会变成「用户在等,两边都在等」。
     *
     * @return 可直接交给播放器的地址;解析不出来(下架、地区、风控)时为 null
     */
    suspend fun resolvePlayback(audioUrl: String): String? = withContext(Dispatchers.IO) {
        // 搜索结果的 audioUrl 是 `bilibili://video/<bvid>`(那时还拿不到 cid)。
        // 用户直接在搜索结果里点播放走的就是这个分支 —— 这里必须自己补一次 view,
        // 否则表现是「搜索结果点播放永远失败」,而列表看起来完全正常。
        val (bvid, cid) = parseAudioUri(audioUrl) ?: run {
            val id = videoIdOf(audioUrl) ?: return@withContext null
            val first = view(id)?.episodes?.firstOrNull() ?: return@withContext null
            parseAudioUri(first.audioUrl) ?: return@withContext null
        }
        val key = "$bvid:$cid"
        val now = System.currentTimeMillis()
        val cached = tracks[key]?.takeIf { it.expiresAt > now }
        val urls = cached?.urls ?: fetchCandidates(bvid, cid)?.also { found ->
            tracks[key] = Track(found.urls, found.expiresAt)
            // 缓存条数不设上限没有意义:用户在听的那几集才可能被重试,而条目本身很小。
            if (tracks.size > 64) tracks.clear()
            com.yuyin.reverb.util.Logger.i(TAG, "resolve candidates=${found.urls.size} ttlMin=${(found.expiresAt - now) / 60000}")
        }?.urls ?: run {
            com.yuyin.reverb.util.Logger.w(TAG, "resolve failed bvid=$bvid cid=$cid")
            return@withContext null
        }

        // 从游标处开始**逐个探通**:实测排第一的 PCDN 节点会回 503(见类注释第 3 条)。
        // 探测只用 1 字节的 Range,代价是一次 RTT;不探的代价是用户点开一集没反应。
        val start = (cursor[key] ?: 0) % urls.size
        cursor[key] = (start + 1) % urls.size
        for (i in urls.indices) {
            val candidate = urls[(start + i) % urls.size]
            if (probe(candidate)) {
                if (i > 0) com.yuyin.reverb.util.Logger.i(TAG, "probe fell back to #$i")
                return@withContext candidate
            }
        }
        // 全部探不通也让第一条去试:探测本身可能被网络抖动误伤,
        // 而播放器至少还会走一次自动重投(见 PlaybackController 的重试口径)。
        com.yuyin.reverb.util.Logger.w(TAG, "all candidates probe failed, using #0")
        urls.firstOrNull()
    }

    private class Candidates(val urls: List<String>, val expiresAt: Long)

    private fun fetchCandidates(bvid: String, cid: Long): Candidates? {
        val data = getJson("$API/player/playurl?bvid=$bvid&cid=$cid&fnval=16&fnver=0&fourk=0")
            ?.optJSONObject("data") ?: return null
        val audio = data.optJSONObject("dash")?.optJSONArray("audio")
            ?: return null
        if (audio.length() == 0) return null
        // 取码率最高的一条。匿名也能拿到全部三档(30216/30232/30280,实测),
        // 所以「匿名只有默认码率」那条调研结论在本端不成立。
        var best: JSONObject? = null
        for (i in 0 until audio.length()) {
            val o = audio.optJSONObject(i) ?: continue
            if (best == null || o.optLong("bandwidth") > best.optLong("bandwidth")) best = o
        }
        val track = best ?: return null
        val urls = ArrayList<String>(3)
        track.optString("baseUrl").takeIf { it.isNotBlank() }?.let(urls::add)
        track.optJSONArray("backupUrl")?.let { bu ->
            for (i in 0 until bu.length()) bu.optString(i).takeIf { it.isNotBlank() }?.let(urls::add)
        }
        if (urls.isEmpty()) return null
        return Candidates(urls, expiryOf(urls.first()))
    }

    /**
     * 直链里的 `deadline`(十进制 epoch 秒)就是失效时刻。解析不出来时按
     * 「2 小时后」保守估 —— 那个数是实测出来的:三次请求里 `deadline - now` 都是 7200 秒。
     */
    private fun expiryOf(url: String): Long {
        val deadline = url.substringAfter("deadline=", "").substringBefore('&').toLongOrNull()
        val now = System.currentTimeMillis()
        if (deadline == null) return now + 90L * 60 * 1000
        val at = deadline * 1000
        // 提前 5 分钟作废:拿着一条还剩 20 秒的链接去起播,等于必然失败一次。
        return if (at - now > 10 * 60 * 1000) at - 5 * 60 * 1000 else now + 60 * 1000
    }

    /** 1 字节 Range 探活。只认 200/206 —— 503/403 都说明这个节点这会儿不给流。 */
    private fun probe(url: String): Boolean = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", UA)
            .header("Referer", REFERER)
            .header("Range", "bytes=0-0")
            .build()
        client.newCall(req).execute().use { resp ->
            // 有些 CDN 对 HEAD/小 Range 回 200 + 整个 body,所以这里必须 close 而不是读完
            resp.code == 200 || resp.code == 206
        }
    } catch (e: Exception) {
        false
    }

    // ---------------------------------------------------------------- 底层

    private fun getJson(url: String): JSONObject? = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", UA)
            // Referer 对这个接口族**不是统一要求**,而是按端点分:
            //  - 搜索(type)**缺了就被风控软拦** —— 回 code=0 + `data:{"v_voucher":…}` + 零条,
            //    看起来"没搜到"(见类注释第 4 条);
            //  - view / playurl 带不带都通(实测两种都 200)。
            // 所以这里一律带上:省掉"哪个接口要哪个不要"的分叉,也少一条被当异常客户端的理由。
            .header("Referer", REFERER)
            .build()
        client.newCall(req).execute().use { resp ->
            val body = resp.body?.string()
            if (!resp.isSuccessful || body.isNullOrBlank()) {
                com.yuyin.reverb.util.Logger.w(
                    TAG,
                    "http ${resp.code} endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
                )
                null
            } else {
                val json = JSONObject(body)
                val code = json.optInt("code", 0)
                if (code != 0) {
                    com.yuyin.reverb.util.Logger.w(TAG, "api code=$code msg='${json.optString("message")}'")
                    null
                } else json
            }
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e(
            TAG,
            "http error endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}",
            e
        )
        null
    }

    /** 封面/头像是 `http://` 或协议相对的 `//host/…`,统一升 https:明文在两端都会被拦。 */
    private fun https(url: String): String = when {
        url.startsWith("//") -> "https:$url"
        url.startsWith("http://") -> "https://" + url.removePrefix("http://")
        else -> url
    }

    /** 搜索结果里的标题夹着 `<em class="keyword">`,展示前必须去掉。 */
    private fun stripTags(s: String): String =
        s.replace(Regex("<[^>]*>"), "")
            .replace("&nbsp;", " ").replace("&lt;", "<")
            .replace("&gt;", ">").replace("&quot;", "\"")
            .replace("&#39;", "'").replace("&amp;", "&")
            .trim()

    private fun date(epochSec: Long): String {
        if (epochSec <= 0) return ""
        return Instant.ofEpochSecond(epochSec).atZone(ZoneId.systemDefault()).toLocalDate().toString()
    }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
}
