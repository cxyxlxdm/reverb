package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Notes
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.R
import com.yuyin.reverb.data.local.TranscriptStore
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.TranscribedSegment
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.asr.AsrFactory
import com.yuyin.reverb.util.TranscriptLines

/**
 * 播放页第三页:逐字稿。对应 macOS `UI/TranscriptPage.swift`。
 *
 * 两种来源在界面上**不作区分** —— 用户要的是"这一集的文字",不关心是发布方给的还是本机转的。
 * 差别只体现在等待时长上(官方稿一两秒,本机识别几分钟)。
 *
 * @param active 这一页是否真的滑到眼前。自动滚动与逐帧外推都只在可见时跑 ——
 *   在看不见的页上逐帧计算纯属白烧电。
 */
@Composable
fun TranscriptPane(
    episode: Episode,
    store: TranscriptStore,
    uiLanguage: String,
    localPath: String?,
    engine: com.yuyin.reverb.playback.asr.AsrEngine?,
    active: Boolean
) {
    val state by store.state.collectAsStateWithLifecycle()
    val segments by store.segments.collectAsStateWithLifecycle()
    val tail by store.volatileTail.collectAsStateWithLifecycle()
    val position by PlayerController.position.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    // 切集/切语言:交给 store 决定是命中缓存秒显,还是等用户点「生成」
    LaunchedEffect(episode.id, uiLanguage) {
        store.prepare(episode, uiLanguage, AsrFactory.HAS_ENGINE)
    }

    val nowMs = rememberExtrapolatedPosition(position, isPlaying, active)
    val currentIndex = remember(segments, nowMs) {
        segments.indexOfLast { it.startMs <= nowMs }
    }

    val start: () -> Unit = { store.start(episode, uiLanguage, localPath, engine) }

    Column(Modifier.fillMaxSize()) {
        when (val s = state) {
            is TranscriptStore.State.Done, is TranscriptStore.State.Running ->
                TranscriptList(segments, tail, currentIndex, nowMs, active)

            // 有官方稿与没有官方稿,**要说不同的话**:前者只是下载一个文件(一两秒),
            // 后者是本机满载算几分钟。都写成「离线转成文字」是不诚实的。
            is TranscriptStore.State.Idle -> {
                val official = episode.transcriptUrl.isNotBlank()
                Hint(
                    icon = Icons.Rounded.Notes,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    text = stringResource(
                        if (official) R.string.transcript_prompt_official else R.string.transcript_prompt
                    ),
                    actionLabel = stringResource(
                        if (official) R.string.transcript_show else R.string.transcript_start
                    ),
                    onAction = start
                )
            }

            is TranscriptStore.State.FetchingOfficial -> Progress(stringResource(R.string.transcript_fetching))
            is TranscriptStore.State.DownloadingAudio -> Progress(stringResource(R.string.transcript_preparing_audio))
            is TranscriptStore.State.LoadingModel -> Progress(stringResource(R.string.transcript_loading_model))

            is TranscriptStore.State.Failed -> Hint(
                icon = Icons.Rounded.WarningAmber,
                tint = MaterialTheme.colorScheme.error,
                text = s.message.ifBlank { stringResource(R.string.transcript_failed) },
                actionLabel = stringResource(R.string.action_retry),
                onAction = start
            )

            // 本渠道没有识别引擎,且这一集发布方也没给稿 —— 如实说,不给一个点了没用的按钮
            is TranscriptStore.State.NoEngine -> Hint(
                icon = Icons.Rounded.Notes,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                text = stringResource(R.string.transcript_none),
                actionLabel = null,
                onAction = {}
            )
        }
    }
}

/**
 * 播放位置的**逐帧外推**。
 *
 * `PlayerController.position` 每约 0.5 秒才更新一次,直接拿它找当前句会让高亮一跳一跳
 * (短句尤其明显 —— 一句只有一两秒,采样误差就占了一半)。这里记住"上一次采样值 +
 * 采样时的帧时刻",两次采样之间按真实流逝时间往前推,与 macOS `TranscriptPage.swift`
 * 的 anchorMs / anchorAt 同一手法。
 *
 * 暂停时不再逐帧唤醒(位置不会变),页面不可见时也不跑。
 */
@Composable
private fun rememberExtrapolatedPosition(position: Long, isPlaying: Boolean, active: Boolean): Long {
    var anchorMs by remember { mutableStateOf(position) }
    var anchorFrame by remember { mutableStateOf(0L) }
    var now by remember { mutableStateOf(position) }

    LaunchedEffect(position) {
        anchorMs = position
        anchorFrame = withFrameMillis { it }
        now = position
    }
    LaunchedEffect(active, isPlaying, anchorMs) {
        if (!active || !isPlaying) {
            now = anchorMs
            return@LaunchedEffect
        }
        while (true) {
            withFrameMillis { frame ->
                if (anchorFrame > 0) now = anchorMs + (frame - anchorFrame)
            }
        }
    }
    return now
}

@Composable
private fun TranscriptList(
    segments: List<TranscribedSegment>,
    tail: String,
    currentIndex: Int,
    nowMs: Long,
    autoScroll: Boolean
) {
    val listState = rememberLazyListState()

    /**
     * 当前句滚进视线。**只在用户没有手动滚动时**才自动跟随 ——
     * 否则往上翻看前文会被一次次拽回来。手指一碰就停,4 秒后恢复跟随。
     */
    var userScrolledAt by remember { mutableStateOf(0L) }
    LaunchedEffect(listState.isScrollInProgress) {
        if (listState.isScrollInProgress) userScrolledAt = System.currentTimeMillis()
    }
    LaunchedEffect(currentIndex, autoScroll) {
        if (!autoScroll || currentIndex < 0) return@LaunchedEffect
        if (System.currentTimeMillis() - userScrolledAt < 4000) return@LaunchedEffect
        // 往上留两行:当前句落在偏上的位置,下面还没读到的文字能多看见几行
        runCatching { listState.animateScrollToItem((currentIndex - 2).coerceAtLeast(0)) }
    }

    LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
        itemsIndexed(segments) { i, seg ->
            val isCurrent = i == currentIndex
            // 点一句跳到那儿 —— 逐字稿最实用的一点。不要涟漪:密排文字上那一片水波很吵
            val interaction = remember { MutableInteractionSource() }
            val accent = MaterialTheme.colorScheme.primary
            val dim = MaterialTheme.colorScheme.onSurfaceVariant
            /**
             * 当前句**逐词高亮**,其余句整句一个颜色。
             *
             * 词级时间只有一种来源:发布方的 Podcast Index JSON 稿(那种稿本来就是一词一条,
             * 合并成行时把原始条目留在了 `words` 里,见 `TranscriptFetcher`)。
             * 本机识别与 SRT/VTT 稿都没有词级时间 ⇒ `words` 为 null ⇒ 自动退化成整句高亮,
             * 调用方不用分辨(macOS 侧同样的回退设计)。
             */
            val rendered = remember(seg, isCurrent, if (isCurrent) nowMs / 80 else 0L) {
                karaokeLine(seg, isCurrent, nowMs, accent, dim)
            }
            Text(
                rendered,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(interactionSource = interaction, indication = null) {
                        PlayerController.seekTo(seg.startMs.toLong())
                    }
                    .padding(vertical = 6.dp)
            )
        }
        // 识别中尚未定稿的尾巴:浅一档,表示"还会变"
        if (tail.isNotBlank()) {
            item {
                Text(
                    tail,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 6.dp)
                )
            }
        }
    }
}

/**
 * 把一句渲染成带样式的文本。
 *
 * - 不是当前句:整句暗色常规体;
 * - 是当前句但没有词级时间:整句强调色 + 半粗(与之前的行为一致);
 * - 是当前句且有词级时间:**已读到的那个词**用强调色 + 半粗,同句其余部分用强调色的 55% ——
 *   这样"这一句在读"和"读到这儿了"两层信息同时看得见,而不是只有其中一层。
 *
 * 文本**由 words 重新拼**而不是拿 seg.text 去找子串:拼接规则(西文词前补空格、中文不补)
 * 与 `TranscriptFetcher` 合并成行时用的是同一条,所以拼出来与 seg.text 一致,
 * 而按子串定位会在重复词上错位。
 */
private fun karaokeLine(
    seg: TranscribedSegment,
    isCurrent: Boolean,
    nowMs: Long,
    accent: androidx.compose.ui.graphics.Color,
    dim: androidx.compose.ui.graphics.Color
): AnnotatedString {
    val words = seg.words
    if (!isCurrent || words.isNullOrEmpty()) {
        return AnnotatedString(
            seg.text,
            SpanStyle(
                color = if (isCurrent) accent else dim,
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal
            )
        )
    }
    val spoken = words.indexOfLast { it.startMs <= nowMs }
    val read = SpanStyle(color = accent.copy(alpha = 0.55f))
    val at = SpanStyle(color = accent, fontWeight = FontWeight.SemiBold)
    return buildAnnotatedString {
        for ((idx, w) in words.withIndex()) {
            if (length > 0 && TranscriptLines.isAsciiHead(w.text)) append(' ')
            withStyle(if (idx == spoken) at else read) { append(w.text) }
        }
    }
}

@Composable
private fun Progress(text: String) {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 12.dp)
        )
    }
}

@Composable
private fun Hint(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: androidx.compose.ui.graphics.Color,
    text: String,
    actionLabel: String?,
    onAction: () -> Unit
) {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(icon, contentDescription = null, Modifier.size(38.dp), tint = tint)
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 12.dp, start = 24.dp, end = 24.dp)
        )
        if (actionLabel != null) {
            Button(onClick = onAction, modifier = Modifier.padding(top = 14.dp)) { Text(actionLabel) }
        }
    }
}
