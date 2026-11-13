package com.yuyin.reverb.util

import java.security.MessageDigest

/**
 * 把任意字符串压成**能当文件名用的短摘要**:SHA-256 的前 8 字节(16 个十六进制字符)。
 *
 * 为什么不是 `String.hashCode()`(见 REVIEW-2026-10-25 低·族 A):
 *  - `hashCode` 是 32 位、多项式 31 的**弱散列**,几十万个输入里撞到同一个值是完全现实的量级
 *    (生日攻击下约 65536 个就有五成概率撞一次)。这几处把它当**文件名唯一键**用,
 *    撞上了就是"A 集的下载件被 B 集认领"—— 表现为播某集会跳出另一集的声音,
 *    而账本、目录、日志全都自洽,查不到根因;
 *  - `kotlin.math.abs(hashCode)` 还多一个洞:`Int.MIN_VALUE` 的绝对值仍是它自己(负数),
 *    于是文件名里会带一个 `-`(见 `SenseVoiceEngine` 那一处);
 *  - 摘要长度取 16 个 hex = 64 位:碰撞概率在本 App 的量级(单集 id 数量 ≤ 1e5)下小到可以当作 0,
 *    而整段 64 个 hex 会让目录列表和备份里的路径长一倍,没有收益。
 *
 * 只给**本机文件名/内部键**用,不是安全语义(要防伪该用整段摘要)。
 * ⚠️ 也别把它当成"三端一致的键":这些名字不进任何跨端 JSON,各端算各端的。
 *
 * `SHA-256` 是 Java 平台规范里必供的算法(Android 每个 API 级别都有),所以这里不写降级分支 ——
 * 真要抛异常,那台机器连 TLS 都跑不起来。
 */
object ShortHash {

    private val HEX = "0123456789abcdef".toCharArray()

    /** [s] 的 SHA-256 前 16 个十六进制字符(小写)。 */
    fun hex16(s: String): String {
        val d = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(16)
        for (i in 0 until 8) {
            val b = d[i].toInt()
            sb.append(HEX[(b shr 4) and 0x0F]).append(HEX[b and 0x0F])
        }
        return sb.toString()
    }
}
