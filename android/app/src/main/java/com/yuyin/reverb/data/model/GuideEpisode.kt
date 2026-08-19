package com.yuyin.reverb.data.model

import android.content.Context
import com.yuyin.reverb.R

/**
 * 随包内置的「新手引导」音频。
 *
 * 为什么要有它：全新安装、又恰好没网时，播放链路一个字节都放不出来 —— 播放条、进度、倍速、
 * 后台继续放、锁屏控制，全都无从体验，也无从判断"是 App 坏了还是网络不通"。
 * 这段 30 秒的音频打在包里，任何时候点开都能走通完整播放流程。
 *
 * 音频资源：`assets/guide_intro.m4a`（由 `shared/guide/make-guide.sh` 生成，可替换成真人录音）。
 * ExoPlayer 的 DefaultDataSource 原生支持 `asset://`，所以不必先拷到 filesDir。
 *
 * **它不是一集真正的播客**，因此刻意不进任何统计：
 * 见 [PlayerController.playEpisode] 里对 [ID] 的判断 —— 不记历史、不计收听时长。
 * 否则"收听时长"第一条就是引导音频，听觉印记也能盖在它身上，都很荒唐。
 */
object GuideEpisode {

    /** 稳定标识。用 reverb:// 前缀，确保不会与任何真实 RSS 的 guid 相同。 */
    const val ID = "reverb://guide-intro"

    /** 与 assets 里的实际音频时长一致（见 make-guide.sh 输出），用于进度条刻度。 */
    private const val DURATION_SEC = 32L

    fun get(context: Context): Episode = Episode(
        id = ID,
        title = context.getString(R.string.guide_title),
        description = context.getString(R.string.guide_desc),
        audioUrl = "asset:///guide_intro.m4a",
        artworkUrl = "",                                  // 无封面，UI 回落到水墨波形占位
        podcastTitle = context.getString(R.string.app_name),
        durationSec = DURATION_SEC
    )

    /** 是否为引导音频。播放层与统计层据此跳过记账。 */
    fun isGuide(episodeId: String?): Boolean = episodeId == ID
}
