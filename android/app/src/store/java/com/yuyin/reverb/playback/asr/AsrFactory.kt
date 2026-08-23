package com.yuyin.reverb.playback.asr

import android.content.Context

/**
 * 大陆商店渠道:**不含离线识别引擎**,恒返回 null。
 *
 * 合规口径下,内置一个几十 MB 的语音识别模型是无谓的风险面;而这个渠道本来就有
 * 「发布方自己的逐字稿」那条路(`podcast:transcript`),那条不需要任何模型。
 *
 * **这份文件是空实现,不是"以后再补"** —— 默认渠道那份在
 * `src/default/java/.../AsrFactory.kt`。同名文件各 flavor 一份是 Android 的标准做法:
 * 同一模块内 Kotlin 没有 expect/actual 可用,而只有 source set 级的隔离才能保证
 * 这个渠道的包里连 `.so` 和模型都不存在(BuildConfig 常量只能删代码,删不掉资源)。
 *
 * 因此**不要**把这里改成"运行时判断一下再决定用不用引擎":那等于把引擎打进包里。
 */
object AsrFactory {
    /// 本渠道是否有引擎。界面据此决定要不要显示「生成转写」入口与设置开关。
    const val HAS_ENGINE = false

    fun create(context: Context): AsrEngine? = null
}
