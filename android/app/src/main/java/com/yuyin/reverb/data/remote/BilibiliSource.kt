package com.yuyin.reverb.data.remote

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.FeedResult
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
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
 *     ⚠️ 探活与播放**都要 UA + Referer**,而且 UA 不能含 `Android`(全 403)——
 *     原先这里写的是「四种组合实测都是同样的码」,2026-10-28 复测推翻了它,详见 [UA]。
 *     ⚠️ 但那是 **`upos-*` 镜像节点**的口径:`*.mcdn.bilivideo.cn` 那类 PCDN 节点**什么都不查**
 *     (空 UA、无 Referer 也一样 206)。所以「不带头也偶尔能播」是真的 —— 取决于这一集的
 *     候选 #0 落在哪一侧;按最严的那侧对待(一律带头),见 [streamHeaders]。
 *  4. ⚠️ **搜索要 `Referer: https://www.bilibili.com/`**,缺了会被风控软拦:
 *     回 **`code=0` + `data:{"v_voucher": …}` + 零条结果** —— 看起来完全像「没搜到」,
 *     而不是报错。这一条踩过:本地用 curl 连试三次全 0 条,差点把「搜索做不了」写进结论;
 *     同一台机器只补一个 Referer 就出 20 条(2026-10-28,逐组对照记在
 *     `docs/TROUBLESHOOTING.md`)。所以下面 [getJson] 对所有请求都带 Referer。
 *  5. 音频流是 `.m4s` 分片 MP4(`ftyp`/`moov`/`sidx`/`moof`/`mdat`,实测头部),
 *     `Range` 请求回 206 ⇒ 播放器按普通渐进流处理、拖动进度条可用。
 *  6. ⚠️ **充电专属视频没有 `dash.audio`**:playurl 对它们只回旧的 `durl`(一个混流的
 *     `video/mp4`),`fetchCandidates` 拿到空数组 ⇒ 解析必然失败。而**搜索接口不带任何
 *     标记**(实测两条确认的充电视频:`is_charge_video=0`、`badgepay` / `corner` 全空),
 *     唯一判据是 `view` 的 `data.is_upower_exclusive` ⇒ 只能在搜到之后补一次 view 再筛,
 *     见 [isCharging] 与 H231。
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
    private class Track(val urls: List<String>, val expiresAt: Long, val durationSec: Long)

    private val tracks = ConcurrentHashMap<String, Track>()
    /** 每集下次从第几个候选开始试。重试(换一个 503 的 PCDN 节点)靠它生效。 */
    private val cursor = ConcurrentHashMap<String, Int>()
    /**
     * bvid → 是不是「充电专属」。只缓存**判定了的**结论(取不到就放行、不落缓存),
     * 只在内存里、有上限 —— 它是搜索结果过滤的中间结果,不是持久数据。见 H231。
     */
    private val charging = ConcurrentHashMap<String, Boolean>()

    /**
     * 一次解析的结果:探通的直链 + **这一 P 的真实时长(秒)**。
     *
     * 为什么要把时长一起带出来:搜索接口给的 `duration` 对**多 P 视频是整条视频的总和**
     * (实测 `BV1MN4dewEQZ`:26 个 P,搜索回 `457:6` = 27 426 秒),而播放这一路只解析
     * **P1**(1 127 秒)—— 元数据里那个数于是比真正在放的东西大 24 倍。它不止是列表上
     * 一个数字:macOS 拿它当「显式跳转的上限」、三端的批注拿它当位置上限、历史行拿它当
     * 「这一集的长度」。`playurl` 的 `data.dash.duration`(秒)与 `data.timelength`(毫秒)
     * 给的正是**这个 cid** 的长度 ⇒ 解析处是唯一能同时知道「播哪一段」与「它多长」的地方。
     * 见 H226。
     */
    data class ResolvedStream(val url: String, val durationSec: Long)

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
        /**
         * ⚠️ **这一串是两个相反约束的交点,不是随便挑的**(2026-10-28 同一台机器逐组实测)。
         *
         *  - **取流(CDN)** 不要 `Android`:UA 含 `Android` ⇒ 同一集三条候选**全 403**;
         *    iOS / 桌面串 ⇒ 全 206。缺 `Referer` 同样 403(与 UA 无关)。
         *    ⚠️ 这条只管 **`upos-*` 镜像节点**;`*.mcdn.bilivideo.cn` 那类 PCDN 节点不查这两样
         *    (空 UA、无 Referer 也 206),所以"不带头偶尔也能播"取决于候选 #0 落在哪一侧。
         *  - **搜索接口**反过来不要桌面串:桌面 Chrome ⇒ `code=0` + `v_voucher` + **零条**
         *    (软拦,看起来像"没搜到",两轮复测稳定);iOS / `Android` 串 ⇒ 20 条。
         *
         * ⇒ **只有 iOS 串两头都过**。本端原先用带 `Android` 的那串:搜索正常,
         * 但 [probe] 恒 403 ⇒ 日志里永远是 `all candidates probe failed, using #0`,
         * 也就是 PCDN 轮换那层保护**从没生效过** —— 播放能出声只是碰巧 #0 可用。
         */
        private const val UA =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " +
                "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        private val BV_RE = Regex("BV[0-9A-Za-z]{10}")
        private val HHMM_RE = Regex("^(\\d+):(\\d+)$")
        /** 见 [getJson]:只有**快于这个数**的失败才补一次。慢失败(真超时)重试等于把等待翻倍。 */
        private const val RETRY_FAST_MS = 3000L
        private const val RETRY_DELAY_MS = 400L

        /** 这一集是不是需要播放前解析。三端同口径(鸿蒙/ macOS 用同一个前缀判断)。 */
        fun isPseudo(url: String): Boolean = url.startsWith("$SCHEME://")

        /**
         * **取流**(不是探活、不是接口)要带的两个头。
         *
         * `upos-*` 镜像节点缺任何一个都 403 —— 实测:空 UA / curl / ExoPlayer 串全 403,
         * iPhone 串 + Referer 才 206(见 [UA]);mcdn 节点不查,但按严的那侧对待。
         * 播放器与整集缓存都从这条直链取,所以两处都要给。
         */
        fun streamHeaders(): Map<String, String> = mapOf("User-Agent" to UA, "Referer" to REFERER)

        /**
         * 这条地址要不要补 [streamHeaders]。
         *
         * 判据是 playurl 直链的参数指纹,**不是域名白名单**:同一集的三条备用落在
         * `upos-*.bilivideo.com` / `*.mcdn.bilivideo.cn:8082`,再往外还有第三方 CDN 域名,
         * 按域名列迟早漏一个,而漏掉的那一路就是 403。
         * 普通 RSS enclosure 不会同时带 `upsig` 与 `deadline` 这两个参数。
         */
        fun needsStreamHeaders(url: String): Boolean {
            val u = url.lowercase()
            if (!u.startsWith("http")) return false
            return u.contains("bilivideo.") || (u.contains("upsig=") && u.contains("deadline="))
        }

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
        // 充电专属视频没有可播的音频流:playurl 对它们只回旧的 `durl`(混流 video/mp4),
        // `dash.audio` 是空的 ⇒ 播放必然失败。放它进来只会变成「播放条切走了、报错、
        // 重试也不会好」。频道页、粘贴链接、以及搜索结果点播放的兜底(见 [resolvePlayback])
        // 都从这里过 ⇒ 这是唯一需要设闸的地方。见 H231。
        if (data.optBoolean("is_upower_exclusive", false)) {
            charging[bvid] = true
            com.yuyin.reverb.util.Logger.w(TAG, "view skip charging bvid=$bvid")
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
        val bvids = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val bvid = o.optString("bvid")
            if (bvid.isBlank()) continue
            val cover = https(o.optString("pic"))
            val author = stripTags(o.optString("author"))
            bvids.add(bvid)
            out.add(
                Episode(
                    // 搜索结果是「一个视频」,分 P 要等进频道页才知道 ⇒ id 先用 bvid 占位。
                    // 播放路径不靠 id 认视频(它解析 audioUrl),所以稳定性够用;但它与频道页的
                    // `$SCHEME:$bvid:$cid` **不是同一个 id** —— 同一视频两个入口各播一次会留两条
                    // 历史、两份缓存(见 H226 教训④与 ROADMAP 技术债)。
                    id = "$SCHEME:search:$bvid",
                    title = stripTags(o.optString("title")),
                    description = stripTags(o.optString("description")),
                    // 搜索结果里没有 cid,**这里刻意不给可播地址**:直接构造一个假 cid 会让
                    // 播放请求打到别人那一集。用户点进频道页拿到的才是真 cid。
                    audioUrl = videoUri(bvid),
                    artworkUrl = cover,
                    podcastTitle = author,
                    // ⚠️ 多 P 视频这个数是**整条视频的总和**(实测 `BV1MN4dewEQZ`:26 个 P,
                    // 这里回 `457:6` = 27 426 秒),而点开播放只给 P1(1 127 秒)。
                    // 搜索接口没有任何字段能分辨多 P(`episode_count_text` 对它们也是空),
                    // 所以列表这一行只能照它显示;真值的纠正发生在解析处 ——
                    // `resolvePlayback` 会把那个 cid 的时长带回来覆盖掉它(见 [ResolvedStream])。
                    durationSec = HHMM_RE.find(o.optString("duration"))?.let { m ->
                        m.groupValues[1].toLong() * 60 + m.groupValues[2].toLong()
                    } ?: 0L,
                    pubDate = date(o.optLong("pubdate", 0L)),
                    feedUrl = videoUri(bvid)
                )
            )
        }
        // 充电专属视频要在这里就剔掉(见类注释第 6 条):用户点它只会看到播放条切走、
        // 然后「播放失败,点按重试」,而那个重试永远不会成功 —— 看起来完全是播放器的 bug。
        // 搜索接口不带判据,只能逐条补一次 view(`isCharging` 有内存缓存,同一视频不重复问)。
        // 并发发、顺序收:20 条实测约 0.5 s,且没有触发风控;一条失败就放行,不误删正常视频。
        val flags = coroutineScope {
            bvids.map { bv -> async { isCharging(bv) } }.awaitAll()
        }
        val kept = ArrayList<Episode>(out.size)
        for (i in out.indices) if (!flags[i]) kept.add(out[i])
        val dropped = out.size - kept.size
        com.yuyin.reverb.util.Logger.i(
            TAG, "search count=${kept.size}" + if (dropped > 0) " dropped_charge=$dropped" else ""
        )
        kept
    }

    /**
     * 这条视频是不是「充电专属」(UP 主设了付费门槛)。见类注释第 6 条与 H231。
     *
     * 只认 `view` 的 `data.is_upower_exclusive`:搜索接口对这类视频**不带任何标记**
     * (实测 `is_charge_video` 恒 0,`badgepay` / `corner` 全空)。
     *
     * 取不到一律返回 false(**放行**):一次超时或风控不该把一条正常视频从结果里抹掉;
     * 漏过滤的代价只是回到修之前那个「切条 + 报错」,可看见、可重试。只缓存判定出来的结论。
     */
    private suspend fun isCharging(bvid: String): Boolean {
        charging[bvid]?.let { return it }
        val data = getJson("$API/web-interface/view?bvid=$bvid")?.optJSONObject("data") ?: return false
        val exclusive = data.optBoolean("is_upower_exclusive", false)
        // 条目本身很小(bvid + 一个布尔),但搜索是长期入口:不设上限迟早堆起来。
        if (charging.size > 512) charging.clear()
        charging[bvid] = exclusive
        return exclusive
    }

    // ---------------------------------------------------------------- 播放前解析

    /**
     * `bilibili://audio/<bvid>/<cid>` → 一条**已经探通**的音频直链 + 这一 P 的真实时长。
     *
     * 失败返回 null,由调用方走播放页那条错误状态行 —— 不要在这里重试:
     * 播放器的重投由 [com.yuyin.reverb.playback.PlayerController] 统一管,
     * 两处各自重试会变成「用户在等,两边都在等」。
     *
     * @return 可直接交给播放器的地址与这一段的长秒数;解析不出来(下架、地区、风控)时为 null
     */
    suspend fun resolvePlayback(audioUrl: String): ResolvedStream? = withContext(Dispatchers.IO) {
        // 搜索结果的 audioUrl 是 `bilibili://video/<bvid>`(那时还拿不到 cid)。
        // 用户直接在搜索结果里点播放走的就是这个分支 —— 这里必须自己补一次 view,
        // 否则表现是「搜索结果点播放永远失败」,而列表看起来完全正常。
        //
        // 顺带接住 view 里那条**准确的**分 P 时长:搜索接口给多 P 视频的是整条总和,
        // 而这里只播 P1(见 [ResolvedStream] 的注释)。
        var hint = 0L
        val (bvid, cid) = parseAudioUri(audioUrl) ?: run {
            val id = videoIdOf(audioUrl) ?: return@withContext null
            val first = view(id)?.episodes?.firstOrNull() ?: return@withContext null
            hint = first.durationSec
            parseAudioUri(first.audioUrl) ?: return@withContext null
        }
        val key = "$bvid:$cid"
        val now = System.currentTimeMillis()
        val cached = tracks[key]?.takeIf { it.expiresAt > now }
        val fetched = if (cached == null) fetchCandidates(bvid, cid)?.also {
            tracks[key] = Track(it.urls, it.expiresAt, it.durationSec)
            // 缓存条数不设上限没有意义:用户在听的那几集才可能被重试,而条目本身很小。
            if (tracks.size > 64) tracks.clear()
            com.yuyin.reverb.util.Logger.i(TAG, "resolve candidates=${it.urls.size} ttlMin=${(it.expiresAt - now) / 60000}")
        } else null
        val urls = cached?.urls ?: fetched?.urls
        if (urls == null) {
            com.yuyin.reverb.util.Logger.w(TAG, "resolve failed bvid=$bvid cid=$cid")
            return@withContext null
        }
        // 直链接口没给时长时退到 view 那条(它同样是「这一 P」的口径);都没有就留 0,
        // 由调用方保留原元数据 —— 不猜。
        val durationSec = (cached?.durationSec ?: fetched?.durationSec ?: 0L).takeIf { it > 0 } ?: hint

        // 从游标处开始**逐个探通**:实测排第一的 PCDN 节点会回 503(见类注释第 3 条)。
        // 探测只用 1 字节的 Range,代价是一次 RTT;不探的代价是用户点开一集没反应。
        //
        // 每个候选的码都打出来(三端同口径,见 H225):只记「全失败」时,探针本身坏掉
        // 与节点真的不给流在日志里长得一样。
        val start = (cursor[key] ?: 0) % urls.size
        cursor[key] = (start + 1) % urls.size
        val codes = ArrayList<Int>(urls.size)
        for (i in urls.indices) {
            val candidate = urls[(start + i) % urls.size]
            val code = probe(candidate)
            codes.add(code)
            if (code == 200 || code == 206) {
                com.yuyin.reverb.util.Logger.i(TAG, "probe ok #$i code=$code" + if (i > 0) " fell back" else "")
                return@withContext ResolvedStream(candidate, durationSec)
            }
            com.yuyin.reverb.util.Logger.w(TAG, "probe #$i code=$code")
        }
        // 全部探不通也让第一条去试:探测本身可能被网络抖动误伤,
        // 而播放器至少还会走一次自动重投(见 PlaybackController 的重试口径)。
        com.yuyin.reverb.util.Logger.w(TAG, "all candidates probe failed, using #0 codes=$codes")
        urls.firstOrNull()?.let { ResolvedStream(it, durationSec) }
    }

    private class Candidates(val urls: List<String>, val expiresAt: Long, val durationSec: Long)

    private suspend fun fetchCandidates(bvid: String, cid: Long): Candidates? {
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
        // 这一段(这个 cid)的真实时长:`dash.duration` 是秒,`timelength` 是毫秒;
        // 实测两者一致(`BV1MN4dewEQZ` P1:1127 / 1126143)。优先取秒,免得四舍五入。
        val durationSec = data.optJSONObject("dash")?.optLong("duration", 0L)?.takeIf { it > 0 }
            ?: (data.optLong("timelength", 0L) / 1000L)
        return Candidates(urls, expiryOf(urls.first()), durationSec)
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

    /**
     * 1 字节 Range 探活,**返回状态码**;拿不到(超时 / 连接失败)回 0,由调用方按 200/206 判通
     * —— 503/403 都说明这个节点这会儿不给流。
     *
     * 回码不回 Bool 是为了日志能读出「节点给了什么」(见 H225)。本端这条路本身没中那个坑
     * —— OkHttp 的 `execute()` 自己就带码,macOS 用的是 `URLSession` 的 async 便利方法。
     */
    private fun probe(url: String): Int = try {
        val req = Request.Builder()
            .url(url)
            .header("User-Agent", UA)
            .header("Referer", REFERER)
            .header("Range", "bytes=0-0")
            .build()
        client.newCall(req).execute().use { resp ->
            // 有些 CDN 对 HEAD/小 Range 回 200 + 整个 body,所以这里必须 close 而不是读完
            resp.code
        }
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.w(TAG, "probe exception ${e.javaClass.simpleName}: ${e.message}")
        0
    }

    // ---------------------------------------------------------------- 底层

    /**
     * 接口族的统一 GET。**网络层快速失败补一次**(见 H233)。
     *
     * 一次瞬时的拒连不该被判成「这一集播不了」:2026-10-31 的同形现场在鸿蒙那台
     * (`view` 在 14 / 17ms 里被网络栈拒掉),而 H232 已经把「解析失败」改成不提交、
     * 只提示一句 ⇒ 用户点几次几次播不了,看起来像功能坏了。
     *
     * 三个边界:
     *  - **只在快失败时补**:超过 [RETRY_FAST_MS] 的失败通常是真的超时,再等一轮只会让
     *    「播放页转圈」翻倍;
     *  - **`code≠0` 不补**:那是接口在说话(下架 / 风控),再来一次不会变;
     *  - 重试的这一次也受 [API_TIMEOUT_MS] 约束,失败后照样回 null,由播放层提示。
     */
    private suspend fun getJson(url: String): JSONObject? {
        for (attempt in 0 until 2) {
            val startedAt = System.currentTimeMillis()
            val json = getJsonOnce(url)
            if (json != null) {
                val code = json.optInt("code", 0)
                if (code != 0) {
                    com.yuyin.reverb.util.Logger.w(TAG, "api code=$code msg='${json.optString("message")}'")
                    return null
                }
                return json
            }
            val elapsed = System.currentTimeMillis() - startedAt
            if (attempt == 1 || elapsed >= RETRY_FAST_MS) return null
            com.yuyin.reverb.util.Logger.w(
                TAG,
                "retry after fast failure elapsed=${elapsed}ms endpoint=${com.yuyin.reverb.util.Logger.endpoint(url)}"
            )
            delay(RETRY_DELAY_MS)
        }
        return null
    }

    /** 单次请求:非 200 / 空体 / 传输异常都回 null,是否补一次由 [getJson] 决定。 */
    private fun getJsonOnce(url: String): JSONObject? = try {
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
                JSONObject(body)
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
