package com.yuyin.reverb.playback.asr

import android.content.Context

/**
 * 默认渠道(自分发):**带离线识别引擎**。
 *
 * 与 `src/store/` 下那份同名文件成对 —— 见那份的注释说明为什么必须用 source set 隔离,
 * 而不是运行时开关。
 *
 * 引擎本体是 `WhisperEngine`(whisper.cpp + 随包内置的 base-q5_1 模型)。
 * `.so` 与模型都**不入版本管理**,由 `tools/build-asr.sh` 备到这个 source set 里;
 * 打包前 `build-release.sh` 会检查它们在不在。
 */
object AsrFactory {
    /**
     * 本渠道是否有引擎。界面据此决定要不要显示「生成逐字稿」入口与设置开关。
     *
     * **暂时置 false:引擎的 JNI 路径还没在真机上跑通。**
     * 症状:模型能加载、`.so` 能加载(nativeloader 确认 ok)、解码器起来了,但
     * `whisper_full` 之后一句都没有,而且**没有任何错误日志**(既不是 -1 返回,
     * 也没有 native abort / OOM / UnsatisfiedLinkError)。已在 `WhisperEngine` 里
     * 埋了三处日志(进出 transcribe、每块的样本数与偏移、whisper 返回值),
     * 下次接上真机跑一遍就能定位。
     *
     * 在跑通之前必须是 false —— 否则默认渠道会显示一个点了就「转写失败」的按钮。
     * 官方逐字稿那条路不受影响(它不经过引擎),两个渠道都照常可用。
     */
    const val HAS_ENGINE = false

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
