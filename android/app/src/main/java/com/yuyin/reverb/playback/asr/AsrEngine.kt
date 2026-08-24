package com.yuyin.reverb.playback.asr

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment

/**
 * 本机离线语音识别。**只有默认渠道有实现**(见各 flavor 各自一份的 `AsrFactory`)。
 *
 * 为什么把接口放 `main`、实现放 flavor:R8 能折叠常量删掉 Kotlin 代码,但
 * **删不掉 `.so` 与 assets** —— native 库和模型是构建系统按 source set 打进包的。
 * 所以大陆商店渠道必须靠「那份工厂返回 null + 那个 source set 里没有实现类、没有 jniLibs、
 * 没有模型」来保证**包里真的没有**,而不是靠运行时开关。
 * 验收方式是解包 grep,不是点界面(这条教训见 TROUBLESHOOTING H46 / H54)。
 */
interface AsrEngine {

    /// 识别过程的阶段。界面文案由 `TranscriptStore` 映射,引擎不关心 UI。
    enum class Stage {
        /** 流式单集:识别前要先把音频下载到临时文件 */
        DownloadingAudio,
        /** 首次:把模型读进内存 */
        LoadingModel,
        Running
    }

    /**
     * 转写一集。**挂起直到做完或被取消**;取消由协程取消传播,实现方要检查 `isActive`。
     *
     * @param localPath 已下载单集的本地路径;为空则实现方自己下载到临时文件
     * @param localeId  `zh-CN` / `en-US` …;空串表示让引擎自动判断语言
     * @param wordTimestamps 是否额外算**词级时间**(逐字高亮要用)。在 whisper 上几乎不要钱
     *   (只是多跑一遍时间戳启发式),仍留作参数是因为用户可以在设置里关掉这个效果
     * @param onSegment 逐句吐出,**按时间顺序**
     * @return true = 正常做完
     */
    suspend fun transcribe(
        episode: Episode,
        localPath: String?,
        localeId: String,
        wordTimestamps: Boolean,
        onStage: (Stage) -> Unit,
        onVolatile: (String) -> Unit,
        onSegment: (TranscribedSegment) -> Unit
    ): Boolean

    fun close()
}
