package com.yuyin.reverb.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.CastConnected
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yuyin.reverb.BuildConfig
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.cast.CastController
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.local.ChapterStore
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.asr.AsrFactory
import com.yuyin.reverb.ui.components.Artwork
import com.yuyin.reverb.ui.components.InkWave
import com.yuyin.reverb.ui.components.formatTime
import com.yuyin.reverb.ui.components.rememberSpectrumState
import com.yuyin.reverb.ui.share.ShareCards
import com.yuyin.reverb.ui.share.rememberImageSaver
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
fun PlayerScreen(onBack: () -> Unit, onOpenChannel: (String) -> Unit = {}, onOpenQueue: () -> Unit = {}) {
    val current by PlayerController.current.collectAsStateWithLifecycle()
    val isPlaying by PlayerController.isPlaying.collectAsStateWithLifecycle()
    val position by PlayerController.position.collectAsStateWithLifecycle()
    val duration by PlayerController.duration.collectAsStateWithLifecycle()
    val liveStream by PlayerController.liveStream.collectAsStateWithLifecycle()
    val speed by PlayerController.speed.collectAsStateWithLifecycle()
    val sleepRemaining by PlayerController.sleepRemainingMs.collectAsStateWithLifecycle()
    val sleepEnd by PlayerController.sleepEndOfEpisode.collectAsStateWithLifecycle()
    val playbackError by PlayerController.playbackError.collectAsStateWithLifecycle()

    val container = (LocalContext.current.applicationContext as ReverbApp).container
    val backSec by container.settingsStore.skipBackSec.collectAsStateWithLifecycle()
    val fwdSec by container.settingsStore.skipForwardSec.collectAsStateWithLifecycle()
    val favorites by container.favoriteStore.favorites.collectAsStateWithLifecycle()
    val hasNext by PlayerController.hasNext.collectAsStateWithLifecycle()
    val hasPrev by PlayerController.hasPrev.collectAsStateWithLifecycle()
    val spectrumEnabled by container.settingsStore.spectrumEnabled.collectAsStateWithLifecycle()
    val appContext = LocalContext.current.applicationContext
    val hasAudioPerm = remember {
        ContextCompat.checkSelfPermission(appContext, android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }
    // 仅在开启真频谱、已授权且正在播放时采集,其余走程序化墨纹。
    // BuildConfig.SPECTRUM 是合规降级的备用闸(原先是渠道门控:商店那份恒 false,
    // 因为那个市场把录音列为敏感权限;2026-10-18 两 flavor 合成一份包,见 H205)。
    val spectrum by rememberSpectrumState(
        active = BuildConfig.SPECTRUM && spectrumEnabled && hasAudioPerm && isPlaying
    )

    val episode = current
    if (episode == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.player_not_playing), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }

    val isFavorite = favorites.any { it.id == episode.id }

    val stamps by container.stampStore.stamps.collectAsStateWithLifecycle()
    val currentSeal = stamps.firstOrNull { it.episodeId == episode.id }?.seal
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    /**
     * 投播(DLNA)。状态在应用级 [CastController] 里:弹层关掉、播放页收起,
     * 电视那边仍在播,所以界面只消费状态、不持有会话。
     */
    val castState by container.cast.state.collectAsStateWithLifecycle()
    val isCasting = castState is CastController.State.Casting
    // 聚合开关里的「投放」。关掉时入口整颗不出现(不是灰掉),已打开的弹层也当场收起;
    // 已连上的会话由设置页那边断开,这里不用再停一次。
    val castEnabled by container.settingsStore.castEnabled.collectAsStateWithLifecycle()
    var castOpen by remember { mutableStateOf(false) }
    LaunchedEffect(castEnabled) { if (!castEnabled) castOpen = false }
    val castPermMessage = stringResource(R.string.cast_need_network)
    // Android 17 起「本地网络」是运行时权限(与局域网同步同一条):不申请不会崩,
    // 但组播会被丢、设备一个都发现不到 —— 比报错更难查(见 manifest 那段注释)。
    val castPermLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) castOpen = true
        else Toast.makeText(ctx, castPermMessage, Toast.LENGTH_LONG).show()
    }
    // 换集就收尾:投出去的那一路没有跟随换集的能力,继续留着会让「界面 A、电视 B」。
    LaunchedEffect(episode.id) { container.cast.onEpisodeChanged(episode.id) }
    val saveImage = rememberImageSaver { container.settingsStore.thirdPartyContentEnabled.value }
    var sealDialogOpen by remember { mutableStateOf(false) }
    /**
     * 批注弹层。**时间是按下那一刻的快照,不是跟随播放器的实时值**:
     * `position` 每 500ms 随 ticker 重算(PlayerController 的 ticker),而写一句话要十几秒 ——
     * 若弹层直接读 `position`,标题里的时间会在用户打字时一路往后走,
     * 保存下来的秒与看到的那一秒不是同一秒(功能名义上就是"记下这一秒",这正是它唯一的意义)。
     */
    var noteDialogOpen by remember { mutableStateOf(false) }
    var noteAtMs by remember { mutableStateOf(0L) }
    /**
     * 按下那一刻的**集**,和 `noteAtMs` 一起冻结。
     *
     * 只冻结时间不够:`episode` 来自 `PlayerController.current`,自动续播或手点下一集时它会变,
     * 而弹层还开着(写一句话要十几秒)。保存若读重组后的 `episode`,批注就挂到了**下一集**上,
     * 而标题里显示的还是上一集的那一秒 —— 时间对、集错,比两者都错更难被发现(见 A2-3#11)。
     */
    var noteEpisode by remember { mutableStateOf<Episode?>(null) }

    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableStateOf(0f) }
    /**
     * 章节(podcast:chapters)。只有发布方给了章表才出现入口 —— 这一集没有章节时
     * 不摆一个点进去空着的按钮(与逐字稿"没稿就不出第三页"同一条口径)。
     *
     * 弹层里的列表只在用户点开时才取(见 `ChapterStore.load`),所以这里挂一次
     * `prepare` 把上一集的章表清掉即可;否则自动续播到下一集时,弹层一开先闪上一集的章。
     */
    var chapterSheetOpen by remember { mutableStateOf(false) }
    val chapterState by container.chapterStore.state.collectAsStateWithLifecycle()
    LaunchedEffect(episode.id) { container.chapterStore.prepare(episode) }
    val chapters = (chapterState as? ChapterStore.State.Done)?.chapters.orEmpty()
    // 当前章:与逐字稿同一条「从后往前找第一个 startMs <= now」。章表已在解析侧保证单调
    val currentChapter = chapters.indexOfLast { it.startMs <= position }
    val sliderValue = if (dragging) dragValue else position.toFloat()
    val maxValue = if (duration > 0) duration.toFloat() else 1f
    /**
     * 直播流没有时间轴:进度条与两端时间换成一句 LIVE。
     *
     * 判据是 `isLive && duration <= 0` 而不是只看 isLive —— 用户粘进来的也可能是一个**有限**的
     * 音频文件,播放器一旦报出时长,进度条与快进快退就重新有意义,那时不该再装作是直播。
     *
     * **但「时长未知」在 HLS 直播上不成立**:Media3 会把播放列表窗口的长度当成时长报上来
     * (实测一路电台 `.m3u8` 报 `60000`),于是那一档退化成 `00:33 / 01:00`、永远走不完。
     * 所以再并上播放器自己的判词 [liveStream](`isCurrentMediaItemLive`)。见 H238。
     */
    val liveNoTimeline = episode.isLive && (duration <= 0 || liveStream)

    /**
     * 是否有第三页(逐字稿)。有引擎就跟设置开关走 ⇒ 任何一集都能转;
     * 没引擎(合并前商店那份,或以后把 `HAS_ENGINE` 降成 false)则**只有发布方给了逐字稿的那些集
     * 才出现第三页**(用户定的:没稿就别出空页)。
     */
    val transcriptEnabled by container.settingsStore.transcriptionEnabled.collectAsStateWithLifecycle()
    // 直播流不给第三页:逐字稿要么下载整段、要么转写整段,而直播没有"整段"这个边界 ——
    // 挂上去就是一个永远转不完、也永远不落盘的任务。
    val showTranscript = !liveNoTimeline &&
        ((AsrFactory.HAS_ENGINE && transcriptEnabled) || episode.transcriptUrl.isNotBlank())
    val pageCount = if (showTranscript) 3 else 2
    val uiLanguage by container.settingsStore.language.collectAsStateWithLifecycle()
    val pagerState = rememberPagerState(pageCount = { pageCount })

    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp)
    ) {
        // 顶部：收起 + 倍速
        Row(
            Modifier
                .fillMaxWidth()
                .padding(top = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Rounded.KeyboardArrowDown, contentDescription = stringResource(R.string.a11y_collapse_player))
            }
            Row(
                // 顶栏这一排的间距按**可见边缘**算,不按布局盒算。
                //
                // 原先写的是 spacedBy(2.dp):图标按钮是 48dp 盒、24dp 字形自带 12dp 内缩,
                // 而芯片与圆形收藏在布局上贴边 —— 结果可见间距变成 30 / 16 / 2 / 2dp 四种
                // (1080px 真机实测),芯片几乎粘在一起,读起来像排布坏了。
                // 现在:两颗图标按钮用 38dp 盒(见 `BarIconButton`,墨迹两侧合计约 7.4~9.6dp),
                // 芯片与收藏外面补 8dp 透明边,相邻可见间距落在 16~17.8dp 这一档(真机实测)。
                // 改数值时保持"墨迹/背景到布局边的空当之和相等"即可,
                // 单改某一对的间距会马上退回四种形状。
                horizontalArrangement = Arrangement.spacedBy(0.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (castEnabled) {
                    BarIconButton(
                        icon = if (isCasting) Icons.Rounded.CastConnected else Icons.Rounded.Cast,
                        description = stringResource(R.string.a11y_cast),
                        tint = if (isCasting) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        onClick = {
                            val needPerm = Build.VERSION.SDK_INT >= 37 &&
                                ContextCompat.checkSelfPermission(ctx.applicationContext, Manifest.permission.ACCESS_LOCAL_NETWORK) !=
                                PackageManager.PERMISSION_GRANTED
                            if (needPerm) castPermLauncher.launch(Manifest.permission.ACCESS_LOCAL_NETWORK)
                            else castOpen = true
                        }
                    )
                }
                BarIconButton(
                    icon = Icons.AutoMirrored.Rounded.QueueMusic,
                    description = stringResource(R.string.a11y_queue),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    onClick = onOpenQueue
                )
                // 直播不给倍速:它是线性源,倍速只会让声音脱离直播边缘;鸿蒙那边的
                // AVPlayer 更是直接拒绝(`Operate Not Permit: not support rate`,见 H239),
                // 三端一起藏掉,免得同一颗控件在一端能按、一端按了没反应。
                if (!liveNoTimeline) {
                    Box(Modifier.padding(horizontal = BarEdgeGap)) { SpeedChip(speed = speed) }
                }
                Box(Modifier.padding(horizontal = BarEdgeGap)) {
                    SleepChip(remainingMs = sleepRemaining, endOfEpisode = sleepEnd)
                }
                Box(Modifier.padding(horizontal = BarEdgeGap)) {
                    FavoriteButton(
                        favorited = isFavorite,
                        onToggle = { container.favoriteStore.toggle(episode) }
                    )
                }
            }
        }

        // 横滑：封面 ↔ 节目笔记
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
        ) { page ->
            when (page) {
                0 -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    InkWave(
                        playing = isPlaying,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.fillMaxSize(),
                        amplitudes = spectrum
                    )
                    Artwork(episode.artworkUrl, size = 260, corner = 24)
                }
                1 -> ShownotesPage(episode)
                else -> TranscriptPane(
                    episode = episode,
                    store = container.transcriptStore,
                    uiLanguage = uiLanguage,
                    /**
                     * 本地音频**两级**:下载件优先,其次"播过即缓存"那一份(见 REVIEW-2026-10-25 中-3 ②)。
                     *
                     * 原先只看 `downloadStore`,于是**明明已经整集在机器上**的一集(听着是从缓存起播的),
                     * 转逐字稿时却要走网络重下一遍 —— 而那条路还要被蜂窝闸门拦(REVIEW 中-3 ① 新接的那道),
                     * 用户看到的就是"这集我能听,却转不了"。两级顺序与起播选源那一路完全一致
                     * (下载 > 缓存,见 `PlayerController.playEpisode`),口径不能在这儿分叉。
                     *
                     * 两级都过 `AudioCacheManager.localPath` / 文件存在性判断:账本可能比文件新
                     * (系统清理、用户手动删过),把不存在的路径交给转写等于白跑一趟网络。
                     */
                    localPath = container.downloadStore.get(episode.id)?.localPath
                        ?.takeIf { java.io.File(it).exists() }
                        ?: com.yuyin.reverb.playback.AudioCacheManager.localPath(episode.id),
                    engine = container.asrEngine,
                    active = pagerState.currentPage == 2
                )
            }
        }

        // 页码指示点
        PagerDots(current = pagerState.currentPage, count = pageCount)

        Spacer(Modifier.height(12.dp))
        Text(
            episode.title,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(6.dp))
        // 频道名:有 feedUrl 时可点,跳转频道主页(随机电台尤其有用)
        val canOpenChannel = episode.feedUrl.isNotBlank()
        Text(
            episode.podcastTitle,
            style = MaterialTheme.typography.bodyMedium,
            color = if (canOpenChannel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    if (canOpenChannel)
                        Modifier.clickable { onOpenChannel(episode.feedUrl) }
                    else Modifier
                )
        )

        /**
         * 播放出错状态行(挂在频道名与进度条之间)。
         *
         * 为什么必须有这一行:流式播放断网后播放器进 `STATE_IDLE`,而界面**什么都没变** ——
         * 进度线冻住、按播放键像没反应,用户只能杀掉 App(见 REVIEW-2026-10-25 中-1)。
         * 数据层那份 [PlayerController.playbackError] 10-25 就接好了,当时故意没挂:
         * 五语字符串不能凭空塞没翻译的中文串。这一批补的就是文案。
         *
         * 判据是「**错的还是当前这一集**」:换集后上一集的失败要继续不显示 ——
         * 与自动重投那条同一个闸门(`errorRetryEpisodeId`),两处口径不能分叉。
         *
         * ⚠️ 用屏幕文字而不是 Toast:Toast 对 `uiautomator dump` 不可见,装机验收取不到证据
         * (本仓库的取证口径,见 docs/TROUBLESHOOTING.md 里 H133 那轮)。
         */
        val err = playbackError?.takeIf { it.episodeId == episode.id }
        if (err != null) {
            Spacer(Modifier.height(10.dp))
            Text(
                text = if (err.retrying) {
                    // retriesUsed 是"第几次重投正在进行",上限 MAX_ERROR_RETRIES 是私有的,不显示分母
                    stringResource(R.string.player_err_retrying, err.retriesUsed)
                } else {
                    stringResource(R.string.player_err_failed)
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
                // 两行:法语那句 61 字符要 ~1100 px,而这一列只有 948 px 可用
                // (10-26 真机量过 —— 同字号同列的「播放失败」那句 42 字符实测 760 px,
                //  即 ~18 px/字)。写成一行会被省略号截断,而截断掉的正好是"第几次"那个数。
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    // 自动重投进行中**不给点**:retryNow() 会清计数并重新走一遍选源,
                    // 和 handler 上已排的那次退避撞车;重投成功时 STATE_READY 自己会清掉这条。
                    .then(if (err.retrying) Modifier else Modifier.clickable { PlayerController.retryNow() })
            )
        }

        /**
         * 章节入口(只在发布方给了章表时出现;直播没有时间轴,自然也没有章节)。
         *
         * 显示**当前章标题**而不是"章节"两个字:它在播放时本身就是有用的信息,
         * 也让"点这里能跳章"这件事看得出来(主色可点样式)。
         */
        val showChapters = !liveNoTimeline && episode.chaptersUrl.isNotBlank()
        if (showChapters) {
            Spacer(Modifier.height(4.dp))
            TextButton(
                onClick = { chapterSheetOpen = true },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = chapters.getOrNull(currentChapter)?.title
                        ?: stringResource(R.string.player_chapters),
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        Spacer(Modifier.height(if (showChapters) 4.dp else 20.dp))
        if (liveNoTimeline) {
            // 直播没有「听到哪了」:一行 LIVE 替掉进度条与两端时间,高度与那两块相当,版面不跳
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.error)
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    stringResource(R.string.live_on_air),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.error
                )
            }
        } else {
            Slider(
                value = sliderValue.coerceIn(0f, maxValue),
                onValueChange = { dragging = true; dragValue = it },
                onValueChangeFinished = {
                    PlayerController.seekTo(dragValue.toLong())
                    dragging = false
                },
                valueRange = 0f..maxValue,
                colors = SliderDefaults.colors(
                    thumbColor = MaterialTheme.colorScheme.primary,
                    activeTrackColor = MaterialTheme.colorScheme.primary,
                    inactiveTrackColor = MaterialTheme.colorScheme.outline
                )
            )
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    formatTime(sliderValue.toLong()),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    formatTime(duration),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Spacer(Modifier.height(20.dp))
        // 主控制行:快退 · 上一集 · 播放 · 下一集 · 快进
        // 直播流只留中间那颗播放键:它没有可跳的时间轴,也没有"下一集"可去(播完不续播,
        // 见 PlayerController 的 STATE_ENDED 分支)。
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (!liveNoTimeline) SkipButton(seconds = backSec, forward = false) { PlayerController.skipBackward() }
            PrevNextButton(next = false, enabled = hasPrev && !liveNoTimeline) { PlayerController.previous() }
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .size(76.dp)
                    .clip(CircleShape)
            ) {
                IconButton(onClick = { PlayerController.togglePlayPause() }, modifier = Modifier.fillMaxSize()) {
                    Icon(
                        if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = stringResource(if (isPlaying) R.string.a11y_pause else R.string.a11y_play),
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(40.dp)
                    )
                }
            }
            PrevNextButton(next = true, enabled = hasNext && !liveNoTimeline) { PlayerController.next() }
            if (!liveNoTimeline) SkipButton(seconds = fwdSec, forward = true) { PlayerController.skipForward() }
        }

        // 剪藏 · 保存此刻 · 写批注 · 盖章。原先收在顶栏的 ⋮ 溢出菜单里,但顶栏在
        // 1080px(392.7dp)屏上已经装不下六颗控件(见顶栏注释),⋮ 会被挤到屏幕外 ——
        // 移到这排常驻,四颗都作用于当前这一集,顺序沿用原菜单:保存 / 剪藏 / 批注 / 盖章。
        // 必须带文字:第一版只画图标时,「保存此刻」用了下载箭头,与列表行里「下载本集」
        // 同形,会被读成下载音频。短标签是新增的 action_save / action_clip / action_note /
        // action_stamp(五语种),完整文案(clip_save 等)太长,四等分放不下。
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 12.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.Top
        ) {
            PlayerAction(
                icon = Icons.Rounded.Download,
                label = stringResource(R.string.action_save),
                a11yLabel = stringResource(R.string.clip_save),
                onClick = {
                    scope.launch {
                        val bmp = ShareCards.momentCard(ctx, episode, position)
                        saveImage(bmp, "reverb-moment-${kotlin.math.abs(episode.id.hashCode())}.png")
                    }
                }
            )
            PlayerAction(
                icon = Icons.Rounded.Share,
                label = stringResource(R.string.action_clip),
                a11yLabel = stringResource(R.string.clip_moment),
                onClick = {
                    scope.launch {
                        val bmp = ShareCards.momentCard(ctx, episode, position)
                        ShareCards.share(ctx, bmp, "reverb-moment-${kotlin.math.abs(episode.id.hashCode())}.png", ctx.getString(R.string.clip_share))
                    }
                }
            )
            PlayerAction(
                icon = Icons.Rounded.EditNote,
                label = stringResource(R.string.action_note),
                a11yLabel = stringResource(R.string.note_add),
                onClick = { noteAtMs = position; noteEpisode = episode; noteDialogOpen = true }
            )
            PlayerAction(
                icon = Icons.Rounded.Verified,
                label = stringResource(R.string.action_stamp),
                a11yLabel = stringResource(if (currentSeal != null) R.string.stamp_edit else R.string.stamp_add),
                tint = if (currentSeal != null) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
                onClick = { sealDialogOpen = true }
            )
        }
    }

    if (chapterSheetOpen) {
        ChapterSheet(
            episode = episode,
            store = container.chapterStore,
            positionMs = position,
            onSeek = { ms ->
                PlayerController.seekTo(ms.toLong())
                chapterSheetOpen = false
            },
            onDismiss = { chapterSheetOpen = false }
        )
    }

    if (sealDialogOpen) {
        SealDialog(
            current = currentSeal,
            onPick = { seal ->
                container.stampStore.set(episode.id, seal, episode.title, episode.podcastTitle, System.currentTimeMillis())
                sealDialogOpen = false
            },
            onRemove = { container.stampStore.remove(episode.id); sealDialogOpen = false },
            onDismiss = { sealDialogOpen = false }
        )
    }

    // 保存路径用的是 `noteTarget`(按下那一刻的集),不是 `episode`。
    // `!= null` 那个判断只是给智能转换用 —— 两个字段在同一句里一起写,弹层开着就一定有值。
    val noteTarget = noteEpisode
    if (noteDialogOpen && noteTarget != null) {
        NoteDialog(
            atMs = noteAtMs,
            onSave = { text ->
                container.noteStore.add(noteTarget, noteAtMs, text, System.currentTimeMillis())
                noteDialogOpen = false
            },
            onDismiss = { noteDialogOpen = false }
        )
    }

    if (castOpen && castEnabled) {
        CastDialog(cast = container.cast, episode = episode, onDismiss = { castOpen = false })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChapterSheet(
    episode: Episode,
    store: ChapterStore,
    positionMs: Long,
    onSeek: (Int) -> Unit,
    onDismiss: () -> Unit
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        val state by store.state.collectAsStateWithLifecycle()
        // 点开就取。缓存在 store 里,反复开合不会重复下载
        LaunchedEffect(episode.id) { store.load(episode) }

        Text(
            stringResource(R.string.player_chapters),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
        )
        when (val s = state) {
            ChapterStore.State.Idle, ChapterStore.State.Loading -> Box(
                Modifier
                    .fillMaxWidth()
                    .height(160.dp),
                contentAlignment = Alignment.Center
            ) { CircularProgressIndicator() }

            ChapterStore.State.Empty -> Text(
                stringResource(R.string.chapters_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 24.dp)
            )

            // 失败态给的是**再点一次**,不是一个空列表 —— 网络抖一下不该让这一集"没有章节"
            ChapterStore.State.Failed -> TextButton(
                onClick = { store.load(episode) },
                modifier = Modifier.padding(horizontal = 12.dp)
            ) { Text(stringResource(R.string.chapters_failed)) }

            is ChapterStore.State.Done -> {
                val chapters = s.chapters
                val current = chapters.indexOfLast { it.startMs <= positionMs }
                Column(
                    Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                ) {
                    chapters.forEachIndexed { index, c ->
                        val active = index == current
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clickable { onSeek(c.startMs) }
                                .padding(horizontal = 24.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.Top
                        ) {
                            Text(
                                formatTime(c.startMs.toLong()),
                                style = MaterialTheme.typography.labelMedium,
                                color = if (active) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.width(52.dp)
                            )
                            Text(
                                c.title,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = if (active) FontWeight.SemiBold else null,
                                color = if (active) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
    }
}

@Composable
private fun ShownotesPage(episode: Episode) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 8.dp)
    ) {
        Text(
            stringResource(R.string.shownotes),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground
        )
        Spacer(Modifier.height(10.dp))
        Text(
            episode.description.ifBlank { stringResource(R.string.shownotes_empty) },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun PagerDots(current: Int, count: Int) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        repeat(count) { i ->
            val active = i == current
            Box(
                Modifier
                    .padding(horizontal = 4.dp)
                    .size(if (active) 8.dp else 6.dp)
                    .clip(CircleShape)
                    .background(
                        if (active) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.outline
                    )
            )
        }
    }
}

/**
 * 顶栏里芯片与圆形收藏两侧的**透明边**,用来把「布局盒间距」换成「可见边缘间距」。
 *
 * 图标按钮是 38dp 盒 + 24dp 字形,字形两侧合计约 7.4~9.6dp(视图标墨迹宽窄);芯片与收藏的背景
 * 贴着自己的布局边,补上这 8dp 之后,相邻可见边缘的距离落在 16~17.8dp 这一档(真机实测)。
 * 调用处解释为什么不能用 `Arrangement.spacedBy` 来做这件事(会变成四种间距)。
 */
private val BarEdgeGap = 8.dp

/**
 * 顶栏图标键:38dp 命中盒 + 24dp 字形。
 *
 * 为什么是 38 而不是 48/40:芯片与收藏的背景贴着自己的布局边,图标字形的**墨迹**比 24dp 盒窄
 * (实测投播 22.2dp、队列 18.9dp),墨迹两侧的空当加起来约 7.9+9.6dp。盒子取 38dp 时,
 * 「投播→队列」的可见间距 ≈ 17.5dp,与「队列→芯片」的 17.6、「芯片→芯片」的 16.4 落在同一档;
 * 取 48/40 时这一对会宽出 3~4dp,又是肉眼能看出的不齐。
 *
 * 为什么不用 `IconButton`:Material3 的 IconButton 内部套了 `minimumInteractiveComponentSize()`,
 * 布局盒会被强制撑到 48dp,`Modifier.size(38.dp)` 压不下去 —— 间距会退回四种形状。
 */
@Composable
private fun BarIconButton(
    icon: ImageVector,
    description: String,
    tint: Color,
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .size(38.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = description, tint = tint, modifier = Modifier.size(24.dp))
    }
}

/** 倍速:点开下拉框选择,替代过去点一下换一档。 */
@Composable
private fun SpeedChip(speed: Float) {
    var open by remember { mutableStateOf(false) }
    Box {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .clickable { open = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 14.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)
            ) {
                Text(
                    "${formatSpeed(speed)}×",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary
                )
                Icon(
                    Icons.Rounded.ArrowDropDown,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            PlayerController.speedSteps.forEach { s ->
                DropdownMenuItem(
                    text = {
                        Text(
                            "${formatSpeed(s)}×",
                            color = if (kotlin.math.abs(s - speed) < 0.01f) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurface
                        )
                    },
                    onClick = { PlayerController.setSpeed(s); open = false }
                )
            }
        }
    }
}

/**
 * 写一条批注:标题带**按下的那一刻**的时间,正文一句话。
 *
 * 空文字**直接不放进去**(`NoteStore.add` 返回 null)而不是弹个"请输入内容"——
 * 用户点了保存又什么也没写,最自然的意图是"这条不要",关掉即可;
 * 而列表里出现一条空白批注,以后无从分辨它是不是误触(且它没有可删的正文,删除确认框会显示成空)。
 */
@Composable
private fun NoteDialog(atMs: Long, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.note_title)) },
        text = {
            Column {
                Text(
                    formatTime(atMs),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.note_hint)) },
                    minLines = 3,
                    maxLines = 6
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(text) }) { Text(stringResource(R.string.action_save)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        }
    )
}

// 以 Ekman 基本情绪为骨架、替换掉听播客用不上的「惧/厌」,凑成 3×3 情绪方阵;每枚附小字注明。
private val SEALS = listOf(
    "喜" to "开心", "暖" to "治愈", "燃" to "热血",
    "惊" to "震撼", "思" to "沉思", "悟" to "领悟",
    "悲" to "难过", "怒" to "愤怒", "疲" to "疲惫"
)

/** 盖章选择:3×3 水墨情绪印章(附小字)。点选即盖,再点同一枚即取消;点外部关闭。 */
@Composable
private fun SealDialog(current: String?, onPick: (String) -> Unit, onRemove: () -> Unit, onDismiss: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                stringResource(R.string.stamp_title),
                modifier = Modifier.fillMaxWidth(),
                textAlign = TextAlign.Center
            )
        },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    stringResource(R.string.stamp_hint),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center
                )
                Spacer(Modifier.height(14.dp))
                SEALS.chunked(3).forEach { row ->
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        row.forEach { (s, label) ->
                            val sel = s == current
                            Column(
                                Modifier.weight(1f),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Surface(
                                    shape = RoundedCornerShape(12.dp),
                                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(56.dp)
                                        .clip(RoundedCornerShape(12.dp))
                                        .clickable { if (sel) onRemove() else onPick(s) } // 再点同一枚即取消
                                ) {
                                    Box(contentAlignment = Alignment.Center) {
                                        Text(
                                            s,
                                            style = MaterialTheme.typography.headlineSmall,
                                            color = if (sel) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
                                        )
                                    }
                                }
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    label,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (sel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                }
            }
        },
        confirmButton = {} // 无需按钮:点选即生效,点外部关闭
    )
}

/**
 * 播放页底部的一颗动作:图标 + 短标签。四颗等分排开(SpaceEvenly),都作用于当前这一集。
 *
 * 标签是**可见文字**,不能只靠 contentDescription:这排的第一版只有图标,
 * 「保存此刻」的下载箭头与列表行的「下载本集」同形,肉眼分辨不出来(见调用处注释)。
 * 命中区由 padding 撑到 ~56dp 高,不小于 Material 的 48dp 下限。
 */
@Composable
private fun PlayerAction(
    icon: ImageVector,
    label: String,
    a11yLabel: String,
    onClick: () -> Unit,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant
) {
    Column(
        Modifier
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(icon, contentDescription = a11yLabel, tint = tint, modifier = Modifier.size(24.dp))
        Spacer(Modifier.height(2.dp))
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = tint,
            maxLines = 1
        )
    }
}

/** 收藏当前单集:填充心表示已收藏,描边心表示未收藏。 */
@Composable
private fun FavoriteButton(favorited: Boolean, onToggle: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onToggle)
    ) {
        Icon(
            if (favorited) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            contentDescription = stringResource(if (favorited) R.string.a11y_unfavorite else R.string.a11y_favorite),
            tint = if (favorited) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .padding(8.dp)
                .size(20.dp)
        )
    }
}

/**
 * `"%.2f".format(...)` 用的是**设备默认 locale**,法/西环境里小数点会渲染成逗号
 * (`1.0` → `"1,00"`),所以去尾零之后还要把**逗号**也去掉 —— 原先只去 `.` 和 `0`,
 * 于是整数倍速在 fr/es 界面上念成 `1,×`(真机通读实测,见 H160)。
 * 保留 locale 的小数分隔符而不是强改成 `.`:非整数倍速(1,25)在法/西里本来就该带逗号。
 */
private fun formatSpeed(speed: Float): String =
    "%.2f".format(speed).trimEnd('0').trimEnd('.', ',')

/** 上一集 / 下一集按钮:不可用时置灰。 */
@Composable
private fun PrevNextButton(next: Boolean, enabled: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(52.dp)) {
        Icon(
            if (next) Icons.Rounded.SkipNext else Icons.Rounded.SkipPrevious,
            contentDescription = stringResource(if (next) R.string.a11y_next else R.string.a11y_prev),
            tint = if (enabled) MaterialTheme.colorScheme.onBackground else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f),
            modifier = Modifier.size(34.dp)
        )
    }
}

@Composable
private fun SkipButton(seconds: Int, forward: Boolean, onClick: () -> Unit) {
    // 图标居中(与播放/上一集/下一集图标对齐),秒数悬在图标下一行、不顶高图标
    Box(contentAlignment = Alignment.Center, modifier = Modifier.height(76.dp)) {
        IconButton(onClick = onClick, modifier = Modifier.size(52.dp)) {
            Icon(
                Icons.Rounded.Replay,
                contentDescription = stringResource(if (forward) R.string.a11y_skip_fwd else R.string.a11y_skip_back, seconds),
                tint = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .size(32.dp)
                    .then(if (forward) Modifier.graphicsLayer(scaleX = -1f) else Modifier)
            )
        }
        Text(
            "$seconds",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .align(Alignment.Center)
                .offset(y = 22.dp)
        )
    }
}

@Composable
private fun SleepChip(remainingMs: Long, endOfEpisode: Boolean) {
    var open by remember { mutableStateOf(false) }
    val active = remainingMs > 0 || endOfEpisode
    val label = when {
        remainingMs > 0 -> formatTime(remainingMs)
        endOfEpisode -> stringResource(R.string.sleep_current)
        else -> stringResource(R.string.sleep)
    }
    val tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Box {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(20.dp))
                .clickable { open = true }
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                Icon(Icons.Rounded.Bedtime, contentDescription = stringResource(R.string.sleep), tint = tint, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(label, style = MaterialTheme.typography.labelLarge, color = tint)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf(15, 30, 45, 60).forEach { m ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sleep_minutes, m)) },
                    onClick = { PlayerController.setSleepTimer(m); open = false }
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.sleep_end_of_episode)) },
                onClick = { PlayerController.setSleepEndOfEpisode(); open = false }
            )
            if (active) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.sleep_off)) },
                    onClick = { PlayerController.cancelSleep(); open = false }
                )
            }
        }
    }
}
