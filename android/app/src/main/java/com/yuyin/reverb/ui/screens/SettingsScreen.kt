package com.yuyin.reverb.ui.screens

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.Manifest
import android.os.Build
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.core.content.ContextCompat
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.imageLoader
import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.BuildConfig
import com.yuyin.reverb.R
import com.yuyin.reverb.ReverbApp
import com.yuyin.reverb.data.local.BackupManager
import com.yuyin.reverb.data.local.SettingsStore
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.OpmlSupport
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.playback.asr.AsrFactory
import com.yuyin.reverb.ui.REGION_OPTIONS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private enum class Dlg { NONE, REGION, THEME, FONT, ACCENT, SPEED, SKIP_BACK, SKIP_FWD, LANGUAGE, RADIO }

// 字号的四档**倍率**不在这里了:它下移到了 `SettingsStore.FONT_SCALES`,因为备份读写
// 也要在同一份表上做「倍率 ↔ 下标」换算(那是数据口径,不该依赖本文件)。下面这张标签表
// 与那张倍率表**按下标对齐**,任一端加一档必须两边同改,并且鸿蒙那份也要跟上。
private val FONT_LABEL_RES = listOf(R.string.font_small, R.string.font_normal, R.string.font_large, R.string.font_xlarge)
private val THEME_LABEL_RES = listOf(R.string.theme_system, R.string.theme_light, R.string.theme_dark, R.string.theme_white)
private val ACCENT_LABEL_RES = listOf(R.string.accent_celadon, R.string.accent_blue, R.string.accent_red, R.string.accent_green)
private val SPEED_VALUES = listOf(0.8f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f)
private val SKIP_BACK_OPTIONS = listOf(5, 10, 15, 30)
private val SKIP_FWD_OPTIONS = listOf(15, 30, 45, 60)
private val LANG_TAGS = listOf("", "zh-CN", "zh-TW", "en", "fr", "es")

@Composable
fun SettingsScreen(onBack: () -> Unit, onOpenAbout: () -> Unit, onOpenLicenses: () -> Unit, onOpenFootprint: () -> Unit = {}) {
    val context = LocalContext.current
    val container = (context.applicationContext as ReverbApp).container
    val settings = container.settingsStore
    val regionStore = container.regionStore
    val scope = rememberCoroutineScope()

    val themeMode by settings.themeMode.collectAsStateWithLifecycle()
    val fontScale by settings.fontScale.collectAsStateWithLifecycle()
    val accentIndex by settings.accentIndex.collectAsStateWithLifecycle()
    val allowCellular by settings.allowCellularDownload.collectAsStateWithLifecycle()
    val updatesEnabled by settings.updatesEnabled.collectAsStateWithLifecycle()
    val defaultSpeed by settings.defaultSpeed.collectAsStateWithLifecycle()
    val skipBack by settings.skipBackSec.collectAsStateWithLifecycle()
    val skipFwd by settings.skipForwardSec.collectAsStateWithLifecycle()
    val language by settings.language.collectAsStateWithLifecycle()
    val spectrumEnabled by settings.spectrumEnabled.collectAsStateWithLifecycle()
    val transcriptionEnabled by settings.transcriptionEnabled.collectAsStateWithLifecycle()
    val wordHighlight by settings.wordHighlight.collectAsStateWithLifecycle()
    val contextualRadio by settings.contextualRadio.collectAsStateWithLifecycle()
    val regionOverride by regionStore.override.collectAsStateWithLifecycle()

    // 录音权限申请:仅在用户主动开启「真实频谱」时触发;授权成功才落地开关
    val recordAudioLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        settings.setSpectrumEnabled(granted)
    }

    // 通知权限同理:**只在用户主动开启「订阅更新提醒」时**申请,授权成功才落地开关并排任务。
    // 原先是在 ReverbRoot 里启动即无条件弹,既与隐私政策的表述不符,也属于
    // "启动即申请非必要权限"。拒绝授权则开关保持关闭 —— 拿不到通知权限,这个功能没有意义。
    val notifyLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        settings.setUpdatesEnabled(granted)
        if (granted) ReverbApp.scheduleFeedUpdates(context) else ReverbApp.cancelFeedUpdates(context)
    }

    // 语言显示名：跟随系统本地化，其余为各自母语写法
    val langLabels = listOf(
        stringResource(R.string.lang_system), "简体中文", "繁體中文", "English", "Français", "Español"
    )

    var dlg by remember { mutableStateOf(Dlg.NONE) }
    var confirmCache by remember { mutableStateOf(false) }
    var confirmDownloads by remember { mutableStateOf(false) }
    var confirmHistory by remember { mutableStateOf(false) }
    var confirmClearLog by remember { mutableStateOf(false) }

    var cacheBytes by remember { mutableStateOf(-1L) }
    var dlBytes by remember { mutableStateOf(-1L) }
    var logBytes by remember { mutableStateOf(-1L) }
    var refreshTick by remember { mutableStateOf(0) }
    LaunchedEffect(refreshTick) {
        cacheBytes = withContext(Dispatchers.IO) {
            container.popularCache.sizeBytes() +
                container.feedCache.sizeBytes() +
                container.transcriptStore.usageBytes() +
                runCatching { context.imageLoader.diskCache?.size ?: 0L }.getOrDefault(0L)
        }
        dlBytes = withContext(Dispatchers.IO) { DownloadManager.usageBytes() }
        logBytes = withContext(Dispatchers.IO) { com.yuyin.reverb.util.Logger.sizeBytes() }
    }

    var importing by remember { mutableStateOf(false) }
    var importResult by remember { mutableStateOf<Int?>(null) }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            importing = true
            scope.launch {
                val n = importOpml(context, container, uri)
                importing = false
                importResult = n
            }
        }
    }
    // 提示条:备份 / OPML / 日志三条导出与恢复共用同一个 AlertDialog(见下面 backupMsg?.let)。
    // 这一行必须排在 exportLauncher **之前** —— Kotlin 的 lambda 只能捕获已声明的局部变量,
    // 原先它声明在下面,是因为那时只有备份那两条回调引用它。
    var backupMsg by remember { mutableStateOf<String?>(null) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/xml")
    ) { uri ->
        if (uri != null) scope.launch {
            val ok = exportOpml(context, container, uri)
            // 这一格原先成功失败都不出声 —— H142 判据④(失败必须出声)那轮只补了 share/mail 两条,
            // OPML 导出漏了;鸿蒙 SettingsPage.exportOpml 一直是两条提示都有,所以补的是 Android 这一侧,
            // 不是把鸿蒙改成静默。文案取 backup_done / backup_failed:这一行就在 sec_backup 段里,
            // 与「完整备份」用同一个键(那一行也在 sec_backup 段里),不像 log_export 那样换成 saved_fail。
            backupMsg = context.getString(if (ok) R.string.backup_done else R.string.backup_failed)
        }
    }

    var backupExportOpen by remember { mutableStateOf(false) }
    var backupExportSel by remember { mutableStateOf(BackupManager.Section.entries.toSet()) }
    var backupImportJson by remember { mutableStateOf<String?>(null) }
    var backupImportAvail by remember { mutableStateOf(emptySet<BackupManager.Section>()) }
    var backupImportSel by remember { mutableStateOf(emptySet<BackupManager.Section>()) }
    val backupExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        if (uri != null) scope.launch {
            val ok = writeTextViaSaf(context, uri) { BackupManager.build(container, backupExportSel) }
            backupMsg = context.getString(if (ok) R.string.backup_done else R.string.backup_failed)
        }
    }
    val backupImportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            val text = withContext(Dispatchers.IO) {
                runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } }.getOrNull()
            }
            val avail = if (text != null) BackupManager.sectionsIn(text) else emptySet()
            if (text != null && avail.isNotEmpty()) {
                backupImportJson = text; backupImportAvail = avail; backupImportSel = avail
            } else backupMsg = context.getString(R.string.backup_invalid)
        }
    }

    val logExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain")
    ) { uri ->
        // 与鸿蒙的 `log_export` 同一格:把日志落到用户选的位置。
        // 这条行此前只有鸿蒙有 —— 补齐方向是给 Android 加,**不是**把鸿蒙那条删掉。
        // 走 SAF 而不是复用 `shareLog` 的 cacheDir:后者只给了分享目标,用户手上没有文件。
        if (uri != null) scope.launch {
            val ok = writeTextViaSaf(context, uri) {
                com.yuyin.reverb.util.Logger.allText().ifBlank { "(暂无日志)" }
            }
            // 失败用 `saved_fail`(「保存失败」)而不是复用 `backup_failed`:这一行不在备份段里,
            // 弹一句「备份失败」会让人以为刚导出的备份坏了。
            backupMsg = context.getString(if (ok) R.string.log_done else R.string.saved_fail)
        }
    }

    val cacheStr = if (cacheBytes < 0) stringResource(R.string.size_calculating) else human(cacheBytes)
    val dlStr = if (dlBytes < 0) stringResource(R.string.size_calculating) else human(dlBytes)

    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.settings), onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
        ) {
            SectionLabel(stringResource(R.string.sec_content))
            // 「地区」只作用于分类榜单、关键词检索与电台的取材范围 —— 这三者在无内容目录的
            // 渠道里都不存在,留着就是个改了也没反应的死设置。
            if (BuildConfig.CATALOG) {
                SettingRow(
                    stringResource(R.string.set_region),
                    value = stringResource(REGION_OPTIONS.firstOrNull { it.code == regionOverride }?.labelRes ?: R.string.region_auto)
                ) { dlg = Dlg.REGION }
            }
            SettingRow(stringResource(R.string.set_footprint), stringResource(R.string.set_footprint_sub)) { onOpenFootprint() }
            // 电台本身就是「内容推荐」,无内容目录的渠道已整体去掉,设置项自然也不该留
            if (BuildConfig.CATALOG) {
                SettingRow(
                    stringResource(R.string.set_radio_mode),
                    value = stringResource(if (contextualRadio) R.string.radio_contextual else R.string.radio_start)
                ) { dlg = Dlg.RADIO }
            }

            SectionLabel(stringResource(R.string.sec_appearance))
            SettingRow(stringResource(R.string.set_theme), value = stringResource(THEME_LABEL_RES.getOrElse(themeMode) { THEME_LABEL_RES[0] })) { dlg = Dlg.THEME }
            SettingRow(stringResource(R.string.set_font), value = stringResource(FONT_LABEL_RES[SettingsStore.fontIndexFor(fontScale)])) { dlg = Dlg.FONT }
            SettingRow(
                stringResource(R.string.set_accent),
                value = stringResource(ACCENT_LABEL_RES.getOrElse(accentIndex) { ACCENT_LABEL_RES[0] }),
                trailing = { ColorSwatch(accentColor(accentIndex)) }
            ) { dlg = Dlg.ACCENT }
            SettingRow(stringResource(R.string.set_language), value = langLabels[LANG_TAGS.indexOf(language).coerceAtLeast(0)]) { dlg = Dlg.LANGUAGE }
            // 真实频谱仅默认渠道提供。商店渠道 BuildConfig.SPECTRUM=false:
            // 该市场把录音列为敏感隐私权限、需逐次举证,而这只是一个视觉效果,
            // 故那个渠道既不声明权限也不显示本开关(见 app/build.gradle 的 flavor 注释)。
            if (BuildConfig.SPECTRUM) {
                SettingSwitch(stringResource(R.string.set_spectrum), stringResource(R.string.set_spectrum_sub), checked = spectrumEnabled) { on ->
                    if (on) {
                        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED
                        ) settings.setSpectrumEnabled(true)
                        else recordAudioLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
                    } else settings.setSpectrumEnabled(false)
                }
            }

            SectionLabel(stringResource(R.string.sec_playback))
            /**
             * 段内顺序:**先播放本身的几项,逐字稿相关放最后**,与鸿蒙端一致。
             *
             * 原先把逐字高亮放在段首 —— 一进「播放与下载」先看到一个两三行副标题的
             * 附属开关,倍速/快退这些核心项被挤到下面,而且两端顺序还不一样。
             */
            SettingRow(stringResource(R.string.set_default_speed), value = speedLabel(defaultSpeed)) { dlg = Dlg.SPEED }
            SettingRow(stringResource(R.string.set_skip_back), value = stringResource(R.string.unit_seconds, skipBack)) { dlg = Dlg.SKIP_BACK }
            SettingRow(stringResource(R.string.set_skip_fwd), value = stringResource(R.string.unit_seconds, skipFwd)) { dlg = Dlg.SKIP_FWD }
            SettingSwitch(stringResource(R.string.set_wifi_only), stringResource(R.string.set_wifi_only_sub), checked = !allowCellular) {
                settings.setAllowCellularDownload(!it)
            }
            // 逐字稿开关只在**有离线识别引擎的渠道**显示。大陆商店渠道没有引擎
            // (`AsrFactory.HAS_ENGINE=false`,包里连模型都没有),那边这个开关无意义 ——
            // 而"发布方给了稿的集照样出第三页"不受它管,所以不显示也不会少功能。
            if (AsrFactory.HAS_ENGINE) {
                SettingSwitch(
                    stringResource(R.string.set_transcription),
                    stringResource(R.string.set_transcription_sub),
                    checked = transcriptionEnabled
                ) { on -> settings.setTranscriptionEnabled(on) }
            }
            // 逐字高亮**两个渠道都给**,但副标题按渠道分别写:
            // 完整版说明"不额外增加转写耗时",国内版说明"依赖发布方的逐字稿且要带逐字时间"
            // (见 src/default|store/res/values-* 下的 set_word_highlight_sub)。
            SettingSwitch(
                stringResource(R.string.set_word_highlight),
                stringResource(R.string.set_word_highlight_sub),
                checked = wordHighlight
            ) { on -> settings.setWordHighlight(on) }

            SectionLabel(stringResource(R.string.sec_reminder))
            SettingSwitch(stringResource(R.string.set_updates), stringResource(R.string.set_updates_sub), checked = updatesEnabled) { on ->
                if (on && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    // 尚未授权:先征求通知权限,结果回调里再落地开关
                    notifyLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    settings.setUpdatesEnabled(on)
                    if (on) ReverbApp.scheduleFeedUpdates(context) else ReverbApp.cancelFeedUpdates(context)
                }
            }

            SectionLabel(stringResource(R.string.sec_storage))
            SettingRow(stringResource(R.string.set_clear_cache), stringResource(R.string.set_clear_cache_sub, cacheStr)) { confirmCache = true }
            SettingRow(stringResource(R.string.set_clear_downloads), stringResource(R.string.set_clear_downloads_sub, dlStr)) { confirmDownloads = true }
            SettingRow(stringResource(R.string.set_clear_history)) { confirmHistory = true }

            SectionLabel(stringResource(R.string.sec_backup))
            SettingRow(stringResource(R.string.set_export_opml), stringResource(R.string.set_export_opml_sub)) {
                exportLauncher.launch("reverb-subscriptions.opml")
            }
            SettingRow(stringResource(R.string.set_import_opml), stringResource(R.string.set_import_opml_sub)) {
                importLauncher.launch(arrayOf("*/*"))
            }
            SettingRow(stringResource(R.string.set_full_backup), stringResource(R.string.set_full_backup_sub)) { backupExportOpen = true }
            SettingRow(stringResource(R.string.set_restore), stringResource(R.string.set_restore_sub)) { backupImportLauncher.launch(arrayOf("*/*")) }

            SectionLabel(stringResource(R.string.set_logs))
            SettingRow(stringResource(R.string.set_share_log), stringResource(R.string.set_share_log_sub)) {
                scope.launch { shareLog(context) { msg -> backupMsg = msg } }
            }
            SettingRow(stringResource(R.string.set_mail_log), stringResource(R.string.set_mail_log_sub)) {
                scope.launch { mailLog(context) { msg -> backupMsg = msg } }
            }
            SettingRow(stringResource(R.string.log_export), onClick = { logExportLauncher.launch("reverb-log.txt") })
            SettingRow(
                stringResource(R.string.set_clear_log),
                stringResource(R.string.log_size, if (logBytes < 0) stringResource(R.string.size_calculating) else human(logBytes))
            ) { confirmClearLog = true }

            SectionLabel(stringResource(R.string.sec_about))
            SettingRow(stringResource(R.string.set_about), onClick = onOpenAbout)
            // 隐私政策必须**在应用内随时可查**,不能只在首启弹一次(平台合规指引)
            SettingRow(
                stringResource(R.string.set_privacy),
                stringResource(R.string.set_privacy_sub)
            ) {
                runCatching {
                    context.startActivity(
                        android.content.Intent(
                            android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse(context.getString(R.string.privacy_url))
                        )
                    )
                }
            }
            SettingRow(stringResource(R.string.set_licenses), onClick = onOpenLicenses)
            SettingRow(stringResource(R.string.set_version), value = BuildConfig.VERSION_NAME)
            Spacer(Modifier.height(24.dp))
        }
    }

    val dismiss = { dlg = Dlg.NONE }
    when (dlg) {
        Dlg.REGION -> ChoiceDialog(
            stringResource(R.string.dlg_region_title),
            REGION_OPTIONS.map { stringResource(it.labelRes) },
            REGION_OPTIONS.indexOfFirst { it.code == regionOverride }.coerceAtLeast(0),
            onPick = { i -> regionStore.setOverride(REGION_OPTIONS[i].code); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.THEME -> ChoiceDialog(
            stringResource(R.string.dlg_theme_title), THEME_LABEL_RES.map { stringResource(it) }, themeMode,
            onPick = { i -> settings.setThemeMode(i); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.FONT -> ChoiceDialog(
            stringResource(R.string.dlg_font_title), FONT_LABEL_RES.map { stringResource(it) }, SettingsStore.fontIndexFor(fontScale),
            onPick = { i -> settings.setFontScale(SettingsStore.FONT_SCALES[i]); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.RADIO -> ChoiceDialog(
            stringResource(R.string.set_radio_mode),
            listOf(stringResource(R.string.radio_start), stringResource(R.string.radio_contextual)),
            if (contextualRadio) 1 else 0,
            onPick = { i -> settings.setContextualRadio(i == 1); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.ACCENT -> AccentDialog(accentIndex,
            onPick = { i -> settings.setAccentIndex(i); dlg = Dlg.NONE }, onDismiss = dismiss)
        Dlg.SPEED -> ChoiceDialog(
            stringResource(R.string.dlg_speed_title), SPEED_VALUES.map { speedLabel(it) },
            SPEED_VALUES.indexOfFirst { kotlin.math.abs(it - defaultSpeed) < 0.01f }.coerceAtLeast(0),
            onPick = { i -> settings.setDefaultSpeed(SPEED_VALUES[i]); PlayerController.setSpeed(SPEED_VALUES[i]); dlg = Dlg.NONE },
            onDismiss = dismiss
        )
        Dlg.SKIP_BACK -> ChoiceDialog(
            stringResource(R.string.dlg_skip_back_title), SKIP_BACK_OPTIONS.map { stringResource(R.string.unit_seconds, it) },
            SKIP_BACK_OPTIONS.indexOf(skipBack).coerceAtLeast(0),
            onPick = { i -> settings.setSkipBackSec(SKIP_BACK_OPTIONS[i]); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.SKIP_FWD -> ChoiceDialog(
            stringResource(R.string.dlg_skip_fwd_title), SKIP_FWD_OPTIONS.map { stringResource(R.string.unit_seconds, it) },
            SKIP_FWD_OPTIONS.indexOf(skipFwd).coerceAtLeast(0),
            onPick = { i -> settings.setSkipForwardSec(SKIP_FWD_OPTIONS[i]); dlg = Dlg.NONE }, onDismiss = dismiss
        )
        Dlg.LANGUAGE -> ChoiceDialog(
            stringResource(R.string.dlg_language_title), langLabels,
            LANG_TAGS.indexOf(language).coerceAtLeast(0),
            onPick = { i ->
                settings.setLanguage(LANG_TAGS[i]); dlg = Dlg.NONE
                (context as? Activity)?.recreate()
            }, onDismiss = dismiss
        )
        Dlg.NONE -> Unit
    }

    if (confirmCache) ConfirmDialog(
        stringResource(R.string.set_clear_cache), stringResource(R.string.confirm_clear_cache), stringResource(R.string.action_clear),
        onConfirm = {
            container.popularCache.clear()
            container.feedCache.clear()
            // 逐字稿也算缓存:都能重新取回来,不该占着地方
            container.transcriptStore.clearAll()
            runCatching {
                val loader = context.imageLoader
                loader.memoryCache?.clear(); loader.diskCache?.clear()
            }
            confirmCache = false; refreshTick++
        },
        onDismiss = { confirmCache = false }
    )
    if (confirmDownloads) ConfirmDialog(
        stringResource(R.string.set_clear_downloads), stringResource(R.string.confirm_clear_downloads), stringResource(R.string.action_delete),
        onConfirm = { DownloadManager.deleteAll(); confirmDownloads = false; refreshTick++ },
        onDismiss = { confirmDownloads = false }
    )
    if (confirmHistory) ConfirmDialog(
        stringResource(R.string.set_clear_history), stringResource(R.string.confirm_clear_history), stringResource(R.string.action_clear_confirm),
        onConfirm = { container.historyStore.clear(); confirmHistory = false },
        onDismiss = { confirmHistory = false }
    )
    if (confirmClearLog) ConfirmDialog(
        stringResource(R.string.set_clear_log), stringResource(R.string.log_clear_confirm), stringResource(R.string.action_clear_confirm),
        onConfirm = { com.yuyin.reverb.util.Logger.clear(); confirmClearLog = false; refreshTick++ },
        onDismiss = { confirmClearLog = false }
    )

    if (importing) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text(stringResource(R.string.opml_importing_title)) },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(12.dp))
                    Text(stringResource(R.string.opml_importing_msg))
                }
            },
            confirmButton = { }
        )
    }
    importResult?.let { n ->
        AlertDialog(
            onDismissRequest = { importResult = null },
            title = { Text(stringResource(R.string.opml_done_title)) },
            text = { Text(if (n > 0) stringResource(R.string.opml_done_n, n) else stringResource(R.string.opml_done_none)) },
            confirmButton = { TextButton(onClick = { importResult = null }) { Text(stringResource(R.string.action_know)) } }
        )
    }

    if (backupExportOpen) BackupSectionDialog(
        title = stringResource(R.string.backup_export_title), confirmLabel = stringResource(R.string.backup_confirm),
        available = null, selected = backupExportSel,
        onToggle = { s, on -> backupExportSel = if (on) backupExportSel + s else backupExportSel - s },
        onConfirm = { backupExportOpen = false; backupExportLauncher.launch("reverb-backup.json") },
        onDismiss = { backupExportOpen = false }
    )
    backupImportJson?.let { json ->
        BackupSectionDialog(
            title = stringResource(R.string.backup_restore_title), confirmLabel = stringResource(R.string.restore_confirm),
            available = backupImportAvail, selected = backupImportSel,
            onToggle = { s, on -> backupImportSel = if (on) backupImportSel + s else backupImportSel - s },
            onConfirm = {
                val sel = backupImportSel
                backupImportJson = null
                scope.launch {
                    val importedSettings = withContext(Dispatchers.IO) { BackupManager.apply(container, json, sel) }
                    if (importedSettings) {
                        if (container.settingsStore.updatesEnabled.value) ReverbApp.scheduleFeedUpdates(context)
                        else ReverbApp.cancelFeedUpdates(context)
                    }
                    refreshTick++
                    backupMsg = context.getString(R.string.restore_done)
                }
            },
            onDismiss = { backupImportJson = null }
        )
    }
    backupMsg?.let { msg ->
        AlertDialog(
            onDismissRequest = { backupMsg = null },
            title = { Text(msg) },
            confirmButton = { TextButton(onClick = { backupMsg = null }) { Text(stringResource(R.string.action_know)) } }
        )
    }
}

private suspend fun importOpml(context: Context, container: AppContainer, uri: Uri): Int {
    val text = withContext(Dispatchers.IO) {
        runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } }.getOrNull()
    } ?: return 0
    val urls = OpmlSupport.extractFeedUrls(text)
    val podcasts = ArrayList<Podcast>()
    for (u in urls) {
        val fr = runCatching { container.repository.feed(u) }.getOrNull()
        if (fr != null) podcasts.add(fr.podcast)
    }
    if (podcasts.isNotEmpty()) container.subscriptionStore.addAll(podcasts)
    return podcasts.size
}

private suspend fun exportOpml(context: Context, container: AppContainer, uri: Uri): Boolean =
    writeTextViaSaf(context, uri) {
        OpmlSupport.buildOpml(container.subscriptionStore.subscriptions.value)
    }

/**
 * 经 SAF 把一段文本写到用户选的位置,返回**真实**成败。三条导出(备份 / OPML / 日志)共用。
 *
 * 两个坑都在「假成功」这一侧:
 * ① `openOutputStream(uri)?.use { … }` 整个包在 `runCatching` 里,而 ContentResolver 的契约是
 *    **打不开就返回 null、不抛异常** —— 于是 null 分支让 `isSuccess` 照样为 true,
 *    用户看到「备份完成」而文件里什么都没有。这里把 null 变成 error,让它真的算失败。
 * ② 生成文本(备份 JSON / OPML / 整份日志)也放在 `withContext(Dispatchers.IO)` 里面,
 *    调用方只拿一个 Bool —— 大 JSON 序列化不能落到 UI 线程(硬规矩 8 的同一口径)。
 */
private suspend fun writeTextViaSaf(context: Context, uri: Uri, build: () -> String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            val text = build()
            context.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                ?: error("openOutputStream 返回 null(目标不可写):$uri")
        }.onFailure { com.yuyin.reverb.util.Logger.e("Settings", "SAF 写入失败", it) }.isSuccess
    }

/**
 * 导出全部日志到 cacheDir/shares/ 并经系统分享面板发出(text/plain)。
 *
 * **失败必须出声**(H142 判据 ④,2026-10-07 真机造出来过一次):「分享日志」「发送日志」这两个入口原先是
 * `catch { Logger.e(...) }` 就结束了 —— 面板不弹、界面不给任何反馈,用户看到的就是"点了没反应"(与 H141 那条"点了不动"同族)。
 * 鸿蒙同两条一直在失败时写 `this.hint`,所以这里补的是**缺的那一侧**,不是把另一侧删掉。
 * 文案用 `log_send_failed`(「日志发送失败」):不能复用 `share_failed`(它的值是「分享图片生成失败」,
 * 讲的是剪藏海报),也不能复用 `backup_failed`(本端值是「备份失败」,而这一行不在备份段里 ——
 * 同一个坑在 `log_export` 上已经踩过一次,见该行的注释)。
 */
private suspend fun shareLog(context: Context, onFailed: (String) -> Unit) {
    try {
        val text = com.yuyin.reverb.util.Logger.allText().ifBlank { "(暂无日志)" }
        val uri = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "shares").apply { mkdirs() }
            val file = File(dir, "reverb-log.txt")
            file.writeText(text)
            androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "Reverb log")
            clipData = ClipData.newRawUri("reverb-log", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, context.getString(R.string.set_share_log))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e("Settings", "share log failed", e)
        onFailed(context.getString(R.string.log_send_failed))
    }
}

/**
 * 把日志作为附件、经系统邮件发送到开发者邮箱(收件人/主题预填)。
 * 失败出声的口径与 `shareLog` 完全一致(见那里的注释),文案同样用 `log_send_failed`。
 */
private suspend fun mailLog(context: Context, onFailed: (String) -> Unit) {
    try {
        val text = com.yuyin.reverb.util.Logger.allText().ifBlank { "(暂无日志)" }
        val uri = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "shares").apply { mkdirs() }
            val file = File(dir, "reverb-log.txt")
            file.writeText(text)
            androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }
        val ver = try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        } catch (e: Exception) { "?" }
        val body = "请描述你遇到的问题:\n\n\n——\n余音 Android v$ver · Android ${android.os.Build.VERSION.RELEASE}"
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "message/rfc822"
            putExtra(Intent.EXTRA_EMAIL, arrayOf("woooxooom@gmail.com"))
            putExtra(Intent.EXTRA_SUBJECT, "余音 Android 日志反馈")
            putExtra(Intent.EXTRA_TEXT, body)
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("reverb-log", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, context.getString(R.string.set_mail_log))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
    } catch (e: Exception) {
        com.yuyin.reverb.util.Logger.e("Settings", "mail log failed", e)
        onFailed(context.getString(R.string.log_send_failed))
    }
}

private fun speedLabel(v: Float): String = "%.2f".format(v).trimEnd('0').trimEnd('.') + "×"

private fun human(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.0f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    return "%.2f GB".format(mb / 1024.0)
}

@Composable
private fun accentColor(index: Int): Color {
    val a = com.yuyin.reverb.ui.theme.ACCENTS.getOrElse(index) { com.yuyin.reverb.ui.theme.ACCENTS[0] }
    return if (androidx.compose.foundation.isSystemInDarkTheme()) a.primaryDark else a.primaryLight
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 2.dp)
    )
}

/**
 * 设置项的一行。
 *
 * **`value` 与 `subtitle` 是两回事,别混用**:
 *  - `value` = 这一项**当前的取值**(深色 · 水墨 / 标准 / 1× / 10 秒…),**靠右对齐**,
 *    与标题同一行 —— 一列取值右缘对齐,扫一眼就能看完当前配置;
 *  - `subtitle` = 对这一项的**说明**(「关闭后蜂窝网络也允许下载」「当前日志 8 KB」),
 *    留在标题下方换行。
 *
 * 原先取值也是当 `subtitle` 传的,于是每一行都占两行高、取值散在左侧参差不齐。
 * 鸿蒙侧一直是右对齐(见 SettingsPage.choiceRow),这次两端统一到右对齐。
 */
@Composable
private fun SettingRow(
    title: String,
    subtitle: String? = null,
    value: String? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null
) {
    val base = Modifier.fillMaxWidth()
    Row(
        modifier = (if (onClick != null) base.clickable(onClick = onClick) else base)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 同 SettingSwitch:右侧有取值或 trailing 时,文字栏要留出间距,
        // 否则长副标题折行后会贴住右边的取值/控件
        Column(
            Modifier
                .weight(1f)
                .padding(end = if (!value.isNullOrBlank() || trailing != null) 12.dp else 0.dp)
        ) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onBackground)
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (!value.isNullOrBlank()) {
            Text(
                value,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                // 右侧还有 trailing(目前只有配色那颗色点)时补一段间距,否则字会贴着它
                modifier = Modifier.padding(start = 12.dp, end = if (trailing != null) 10.dp else 0.dp)
            )
        }
        if (trailing != null) trailing()
    }
}

@Composable
private fun SettingSwitch(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // **end 内边距不能省**:文字栏是 weight(1f),会一路吃到开关的左边缘,
        // 长副标题折行后第二行正好顶在开关上。给 16dp 让它们之间有口气。
        Column(
            Modifier
                .weight(1f)
                .padding(end = 16.dp)
        ) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onBackground)
            if (!subtitle.isNullOrBlank()) {
                Text(subtitle, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun ColorSwatch(color: Color) {
    Box(
        Modifier
            .size(20.dp)
            .clip(CircleShape)
            .background(color)
    )
}

@Composable
private fun ChoiceDialog(
    title: String,
    options: List<String>,
    selectedIndex: Int,
    onPick: (Int) -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEachIndexed { i, o ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onPick(i) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(selected = i == selectedIndex, onClick = { onPick(i) })
                        Spacer(Modifier.width(8.dp))
                        Text(o, style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } }
    )
}

@Composable
private fun AccentDialog(selectedIndex: Int, onPick: (Int) -> Unit, onDismiss: () -> Unit) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val accents = com.yuyin.reverb.ui.theme.ACCENTS
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.dlg_accent_title)) },
        text = {
            Column {
                accents.forEachIndexed { i, a ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onPick(i) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        RadioButton(selected = i == selectedIndex, onClick = { onPick(i) })
                        Spacer(Modifier.width(8.dp))
                        ColorSwatch(if (dark) a.primaryDark else a.primaryLight)
                        Spacer(Modifier.width(12.dp))
                        Text(stringResource(ACCENT_LABEL_RES.getOrElse(i) { ACCENT_LABEL_RES[0] }), style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } }
    )
}

@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(confirmLabel, color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } }
    )
}

private val SECTION_ROWS = listOf(
    BackupManager.Section.SUBSCRIPTIONS to R.string.backup_row_subscriptions,
    BackupManager.Section.FAVORITES to R.string.backup_row_favorites,
    BackupManager.Section.STAMPS to R.string.backup_row_stamps,
    // 批注紧跟印记:两者都是「用户自己写出来的字」,在勾选列表里也该挨在一起
    BackupManager.Section.NOTES to R.string.backup_row_notes,
    BackupManager.Section.DOWNLOADS to R.string.backup_row_downloads,
    BackupManager.Section.HISTORY to R.string.backup_row_history,
    BackupManager.Section.LISTEN_STATS to R.string.backup_row_listen_stats,
    BackupManager.Section.SETTINGS to R.string.backup_row_settings
)

@Composable
private fun BackupSectionDialog(
    title: String,
    confirmLabel: String,
    available: Set<BackupManager.Section>?,
    selected: Set<BackupManager.Section>,
    onToggle: (BackupManager.Section, Boolean) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    val rows = SECTION_ROWS.filter { available == null || it.first in available }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column {
                rows.forEach { (sec, labelRes) ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { onToggle(sec, sec !in selected) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Checkbox(checked = sec in selected, onCheckedChange = { onToggle(sec, it) })
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(labelRes), style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onConfirm, enabled = selected.isNotEmpty()) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } }
    )
}
