package com.yuyin.reverb.playback.asr

import android.content.Context

/**
 * 默认渠道(自分发):**带离线识别引擎**。
 *
 * 与 `src/store/` 下那份同名文件成对 —— 见那份的注释说明为什么必须用 source set 隔离,
 * 而不是运行时开关。
 *
 * TODO(asr-engine): 引擎本体(whisper.cpp 的 JNI 封装 + 内置模型)还没落地,
 * 所以现在也返回 null。落地时改动只有三处:`HAS_ENGINE = true`、
 * `create()` 返回 `WhisperEngine(context)`、以及把 `.so` 与模型放进这个 source set。
 * **在那之前 HAS_ENGINE 必须是 false** —— 否则界面会给出一个点了就失败的入口。
 */
object AsrFactory {
    /// 本渠道是否有引擎。界面据此决定要不要显示「生成转写」入口与设置开关。
    const val HAS_ENGINE = false

    fun create(context: Context): AsrEngine? = null
}
