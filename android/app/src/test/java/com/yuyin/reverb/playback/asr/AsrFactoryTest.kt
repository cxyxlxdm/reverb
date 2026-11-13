package com.yuyin.reverb.playback.asr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 界面语言 → 引擎语言的那张表。
 *
 * 它有两个下游,错一个方向都很难在界面上看出来:
 * - `supports()` 决定播放页第三页是"可以生成"还是"先说清不支持"(法/西界面);
 * - `engineLanguage()` 直接把字符串交给 sherpa-onnx,给错了它不会报错,只会吐别的语种的乱码。
 *
 * ⚠️ 这里**故意**断言 `zh-TW → zh`:模型只出简体,而界面不能因此退化成"不支持"。
 * 那条限制写在 docs/TRANSCRIPT.md,不是这里漏了一个分支。
 */
class AsrFactoryTest {

    @Test
    fun `五种支持的语言都归一到模型认的短码`() {
        assertEquals("zh", AsrFactory.engineLanguage("zh-CN"))
        assertEquals("zh", AsrFactory.engineLanguage("zh-TW"))
        assertEquals("en", AsrFactory.engineLanguage("en-US"))
        assertEquals("ja", AsrFactory.engineLanguage("ja-JP"))
        assertEquals("ko", AsrFactory.engineLanguage("ko-KR"))
        assertEquals("yue", AsrFactory.engineLanguage("yue-HK"))
    }

    @Test
    fun `没有地区的短码照样认`() {
        assertEquals("zh", AsrFactory.engineLanguage("zh"))
        assertEquals("en", AsrFactory.engineLanguage("en"))
        assertEquals("yue", AsrFactory.engineLanguage("yue"))
    }

    @Test
    fun `大小写不敏感`() {
        // 本仓库的语言 id 一律用 `-` 分隔(`TranscriptStore.localeFor` 就产出 zh-CN / en-US)。
        // 注意 `Locale.toString()` 那种 `en_US` 写法不在这张表的输入面上 —— 真要接它,
        // 得先在这里显式归一,别指望 lowercase() 顺手兜住。
        assertEquals("zh", AsrFactory.engineLanguage("ZH-CN"))
        assertEquals("en", AsrFactory.engineLanguage("EN-US"))
    }

    @Test
    fun `法语西语与空串都给 null`() {
        assertNull(AsrFactory.engineLanguage("fr"))
        assertNull(AsrFactory.engineLanguage("fr-FR"))
        assertNull(AsrFactory.engineLanguage("es-ES"))
        assertNull(AsrFactory.engineLanguage("de-DE"))
        assertNull(AsrFactory.engineLanguage(""))
    }

    @Test
    fun `supports 与引擎语言表一致`() {
        // 中文、英文、日文、韩文、粤语 → 界面应当给出「生成」
        listOf("zh-CN", "zh-TW", "en-US", "ja-JP", "ko-KR", "yue-HK").forEach {
            assertTrue("$it 应当支持", AsrFactory.supports(it))
        }
        // 法、西 → 界面应当直接说不支持,而不是摆了按钮再失败
        listOf("fr-FR", "es-ES", "").forEach {
            assertFalse("$it 不应当支持", AsrFactory.supports(it))
        }
    }

    @Test
    fun `这一份包带引擎`() {
        // 合并 flavor 后只有一份包;若哪天出降级档,这条会先红,提醒同步界面与文档
        assertTrue(AsrFactory.HAS_ENGINE)
    }
}
