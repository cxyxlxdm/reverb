package com.yuyin.reverb.data.model

import android.util.Base64
import java.net.URI

/**
 * 私有订阅源的 HTTP Basic 凭据。
 *
 * **为什么有这个东西**:一部分 RSS 源(自建 / WordPress 会员站 / 有声书服务器)在
 * feed 与音频上都要求用户名密码,不带就一律 401。这类源与"URL 里带 token"的私密源
 * (Patreon 那一类)不是一回事 —— 后者不需要认证逻辑,我们的粘贴订阅本来就能用。
 *
 * 凭据只用于**用户点名的那一个源**:feed 请求、以及同一主机(或互为子域)上的音频 /
 * 逐字稿请求。刻意不做"任何地址都带上" —— 音频经常放在第三方 CDN 上,那样等于
 * 把用户口令交给一个与他无关的主机(见 `FeedAuthStore.headerForUrl`)。
 */
data class FeedCredential(val username: String, val password: String) {

    /**
     * `Authorization` 头。
     *
     * @param utf8 true = 按 UTF-8 编;false = 按 RFC 7617 的默认字节语义(ISO-8859-1)。
     *
     * 不传参数时按内容自动选:含非 Latin-1 字符(中文口令)用 UTF-8,否则 ISO。
     * 这条规则只适用于**不能重试**的调用点(音频 / 逐字稿)。feed 请求走的是
     * `RssParser` 那套「先 ISO、401 再 UTF-8」,与 AntennaPod 同一条兜底 —— 因为
     * RFC 7617 没有规定字符集,两种服务器都真实存在。
     */
    fun header(utf8: Boolean = needsUtf8): String {
        val raw = "$username:$password"
        val bytes = if (utf8) raw.toByteArray(Charsets.UTF_8) else raw.toByteArray(Charsets.ISO_8859_1)
        return "Basic " + Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    /**
     * 默认按 UTF-8 编:含 ISO-8859-1 表示不了的字符(中文口令)。
     *
     * ⚠️ 它**不是**「两种编码是否不同」。`é` 这类 Latin-1 表示得了的字符,ISO 与 UTF-8
     * 编出来的字节并不一样(0xE9 vs 0xC3 0xA9),可这里仍是 false —— 拿它当重试门槛,
     * 服务器按 UTF-8 解口令时就永远试不到第二发。重试的门槛是 [encodingDiffers]。
     */
    val needsUtf8: Boolean
        get() = username.any { it.code > 255 } || password.any { it.code > 255 }

    /**
     * 两种编码出来的头是否**真的不同** —— 只有不同才值得在 401 之后重试一次。
     *
     * 纯 ASCII 两串完全一样,重试等于重发同一个头;`é` / `ß` 这类字符两串不同 ——
     * 服务器按 UTF-8 解时,第一发必然失败,这一发才是救回来的那发(见 H253)。
     * 中文口令的 ISO 编码在 Kotlin 里落成一串 `?`,与 UTF-8 也不同,照旧会重试一次。
     */
    val encodingDiffers: Boolean
        get() = header(utf8 = false) != header(utf8 = true)

    companion object {
        /**
         * 把 `https://user:pass@host/feed.xml` 拆成(去掉 userinfo 的 URL, 凭据)。
         *
         * **必须把 userinfo 从 URL 里拿掉**,它有三个不该去的地方:
         *  - 订阅列表与导出备份(口令会跟着 JSON 走);
         *  - 运行日志(`url=…` 是全仓库通用的日志写法);
         *  - 频道/单集的持久字段(分享卡片、widget 快照都可能再读一次)。
         * 没有 userinfo 时原样返回(trim 之后),凭据为 null。
         */
        fun splitUrl(raw: String): Pair<String, FeedCredential?> {
            val trimmed = raw.trim()
            val uri = runCatching { URI(trimmed) }.getOrNull() ?: return trimmed to null
            val userInfo = uri.userInfo ?: return trimmed to null
            val scheme = uri.scheme ?: return trimmed to null
            val host = uri.host ?: return trimmed to null
            val sep = userInfo.indexOf(':')
            val user = if (sep >= 0) userInfo.substring(0, sep) else userInfo
            val pass = if (sep >= 0) userInfo.substring(sep + 1) else ""
            if (user.isEmpty()) return trimmed to null
            // 用解码后的各段重建:URI 的 7 参构造会自己按需百分号编码,
            // 传 rawPath/rawQuery 会变成二次编码(%25)。
            val clean = URI(scheme, null, host, uri.port, uri.path, uri.query, uri.fragment).toString()
            return clean to FeedCredential(user, pass)
        }
    }
}
