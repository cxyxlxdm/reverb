package com.yuyin.reverb.playback.asr

import android.content.Context

/**
 * 离线识别引擎的工厂。**Android 只有一份包,它带引擎**(2026-10-18 两 flavor 合并,见 H205)。
 *
 * 引擎本体是 `SenseVoiceEngine`(sherpa-onnx + 随包内置的 SenseVoiceSmall int8 模型)。
 * 1.0.8 之前的 whisper.cpp 版已整体替换,理由与实测数据见
 * `docs/research/2026-11-11-offline-asr-engine.md`。
 * jar / `.so` / 模型都**不入版本管理**,由 `tools/build-asr.sh` 备到 `src/main/` 里;
 * 打包前 `build-release.sh` 会检查它们在不在。
 */
object AsrFactory {
    /**
     * 包里有没有引擎。界面据此决定要不要显示「生成逐字稿」入口与设置开关。
     *
     * 合并后它恒为 true,留着是**降级用的备用闸**:若哪天要出一个不含本机识别的包
     * (例如市场把两百多 MB 模型判为风险面),把这一行改成 false 并把 jar / `.so` / 模型
     * 移出编译树,界面那几处门控会自动收掉 —— 与 `BuildConfig.CATALOG` 同一待遇。
     *
     * 官方逐字稿那条路不经过引擎,不论这一行是什么都照常可用。
     */
    const val HAS_ENGINE = true

    fun create(context: Context): AsrEngine? = try {
        SenseVoiceEngine(context)
    } catch (e: Throwable) {
        // 唯一的失败路径是 sherpa-onnx 的类或 .so 缺失(UnsatisfiedLinkError /
        // NoClassDefFoundError)—— 也就是打包时漏跑了 tools/build-asr.sh。
        // 返回 null 让界面退回"没有引擎",而不是让整个播放页崩掉。
        com.yuyin.reverb.util.Logger.e("Asr", "引擎不可用(是否漏跑 tools/build-asr.sh?)", Exception(e))
        null
    }

    /**
     * UI 语言 → SenseVoice 的 `language` 取值。`null` = 这个语言不在模型支持范围内。
     *
     * 支持范围是模型能力,不是可以随便扩的列表:zh / en / ja / ko / yue。
     * 法语、西语界面没有本机识别 —— 界面据此在点之前就说清原因,而不是让用户点了才失败。
     *
     * ⚠️ **zh-TW(繁体界面)也走 `zh`**,而 SenseVoice 输出的是**简体**(它没有"输出繁体"
     * 这个开关,也不能像 whisper 那样靠提示词带过去)。这是已知限制:繁体界面下本机转写
     * 出来的是简体字,官方稿不受影响。记录在 docs/TRANSCRIPT.md,不要当成 bug 重新查。
     */
    fun engineLanguage(localeId: String): String? =
        when (localeId.substringBefore('-').lowercase()) {
            "zh" -> "zh"
            "en" -> "en"
            "ja" -> "ja"
            "ko" -> "ko"
            "yue" -> "yue"
            else -> null
        }

    /// 本机识别能不能处理这个语言。界面在"生成"按钮出现之前就要用它。
    fun supports(localeId: String): Boolean = HAS_ENGINE && engineLanguage(localeId) != null
}
