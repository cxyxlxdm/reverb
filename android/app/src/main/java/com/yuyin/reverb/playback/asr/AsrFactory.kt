package com.yuyin.reverb.playback.asr

import android.content.Context

/**
 * 离线识别引擎的工厂。**Android 只有一份包,它带引擎**(2026-10-18 两 flavor 合并,见 H205)。
 *
 * 原先这里有两份同名文件:`src/default` 那份返回 `WhisperEngine`、`src/store` 那份恒返回 null,
 * 因为要做到「商店包里连 `.so` 与模型都不存在」—— 那只能靠 source set 隔离,
 * `BuildConfig` 常量删得掉代码、删不掉资源(硬规矩 3 / H70)。合并成一份包之后这层隔离没有对象了,
 * 只留这一份真实现。
 *
 * 引擎本体是 `WhisperEngine`(whisper.cpp + 随包内置的 base-q5_1 模型)。
 * `.so` 与模型都**不入版本管理**,由 `tools/build-asr.sh` 备到 `src/main/` 里;
 * 打包前 `build-release.sh` 会检查它们在不在。
 */
object AsrFactory {
    /**
     * 包里有没有引擎。界面据此决定要不要显示「生成逐字稿」入口与设置开关。
     *
     * 合并后它恒为 true,留着是**降级用的备用闸**:若哪天要出一个不含本机识别的包
     * (例如市场把几十 MB 模型判为风险面),把这一行改成 false 并把 `.so`/模型移出编译树,
     * 界面那几处门控会自动收掉 —— 与 `BuildConfig.CATALOG` 同一待遇。
     *
     * 官方逐字稿那条路不经过引擎,不论这一行是什么都照常可用。
     */
    const val HAS_ENGINE = true

    fun create(context: Context): AsrEngine? = try {
        WhisperEngine(context)
    } catch (e: Throwable) {
        // 唯一的失败路径是 System.loadLibrary 抛 UnsatisfiedLinkError ——
        // 也就是打包时漏跑了 tools/build-asr.sh。返回 null 让界面退回"没有引擎",
        // 而不是让整个播放页崩掉。
        com.yuyin.reverb.util.Logger.e("Asr", "引擎不可用(是否漏跑 tools/build-asr.sh?)", Exception(e))
        null
    }
}
