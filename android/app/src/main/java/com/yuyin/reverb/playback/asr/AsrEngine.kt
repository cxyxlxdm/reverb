package com.yuyin.reverb.playback.asr

import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment

/**
 * 本机离线语音识别。实现是 `SenseVoiceEngine`,工厂是 `AsrFactory`。
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
        Running,
        /**
         * 识别前那一步「把整集音频下到临时文件」被**蜂窝/计费网络闸门**拦下了(没下,也不会下)。
         *
         * 为什么要单独一个阶段而不是笼统的失败(REVIEW-2026-10-25 中-3):
         *  - 这一路的流量是**几十 MB**,和"下载/缓存"同一量级,却不接同一道闸门,
         *    用户关了「仅在 Wi-Fi 下载」后只有这里还在偷跑,这既是流量问题也是**说好的规则没守住**;
         *  - 报成"转写失败"的话,用户唯一能做的是再点一次重试 —— 而它还会被同样拦下,
         *    看起来就像这个功能坏了。
         * 引擎这里只报"因为网络被拦"这个事实,具体那句话怎么说归 UI(见 `TranscriptStore.State.NeedUnmetered`)。
         */
        NeedUnmetered
    }

    /**
     * 这个引擎能不能识别某种语言(按 `localeId` 判断,如 `zh-CN` / `fr-FR`)。
     *
     * 为什么要显式问一句,而不是"跑了失败再说":SenseVoice **只认 zh/en/ja/ko/yue**。
     * 法语、西语界面下如果照旧摆一个「生成逐字稿」按钮,点下去只会得到"转写失败";
     * 界面需要的是**在点之前**就说清"本机识别不支持这种语言,只能看发布方的官方稿"。
     */
    fun supports(localeId: String): Boolean

    /**
     * 转写一集。**挂起直到做完或被取消**;取消由协程取消传播,实现方要检查 `isActive`。
     *
     * @param localPath 已下载单集的本地路径;为空则实现方自己下载到临时文件
     * @param localeId  `zh-CN` / `en-US` …;空串表示让引擎自动判断语言
     * @param wordTimestamps 是否把**词级时间**存进结果(逐字高亮要用)。关掉只影响存不存,
     *   不影响切行 —— 引擎本来就能拿到 token 时刻
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
