package com.yuyin.reverb.playback.asr

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment

/**
 * 本机离线语音识别。实现是 `WhisperEngine`,工厂是 `AsrFactory`。
 *
 * 这两样原先分开放(接口在 `main`、实现按 flavor 各一份),理由是要保证商店那个渠道的包里
 * **连实现类、`.so` 与模型都不存在** —— R8 能折叠常量删掉 Kotlin 代码,但删不掉 `.so` 与 assets,
 * native 库和模型是构建系统按 source set 打进包的,所以「包里真的没有」只能靠 source set 隔离,
 * 而不是运行时开关(那条教训见 H46 / H54,验收方式一直是解包 grep)。
 * 2026-10-18 两个 flavor 合并成一份包之后这层隔离没有了,接口与实现在同一棵编译树里;
 * 「降级时包里真的没有」的手段退回 `BuildConfig` 常量 + 把产物移出 `src/main`(见 H205)。
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
