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
import com.yuyin.reverb.data.model.Podcast
import com.yuyin.reverb.data.remote.OpmlSupport
import com.yuyin.reverb.playback.DownloadManager
import com.yuyin.reverb.playback.PlayerController
import com.yuyin.reverb.ui.REGION_OPTIONS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private enum class Dlg { NONE, REGION, THEME, FONT, ACCENT, SPEED, SKIP_BACK, SKIP_FWD, LANGUAGE, RADIO }

private val FONT_SCALES = listOf(0.85f, 1.0f, 1.15f, 1.3f)
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
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/xml")
    ) { uri -> if (uri != null) scope.launch { exportOpml(context, container, uri) } }

    var backupExportOpen by remember { mutableStateOf(false) }
    var backupExportSel by remember { mutableStateOf(BackupManager.Section.entries.toSet()) }
    var backupImportJson by remember { mutableStateOf<String?>(null) }
    var backupImportAvail by remember { mutableStateOf(emptySet<BackupManager.Section>()) }
    var backupImportSel by remember { mutableStateOf(emptySet<BackupManager.Section>()) }
    var backupMsg by remember { mutableStateOf<String?>(null) }
    val backupExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        if (uri != null) scope.launch {
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val json = BackupManager.build(container, backupExportSel)
                    context.contentResolver.openOutputStream(uri)?.use { it.write(json.toByteArray(Charsets.UTF_8)) }
                }.isSuccess
            }
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
            SettingRow(stringResource(R.string.set_font), value = stringResource(FONT_LABEL_RES[fontIndex(fontScale)])) { dlg = Dlg.FONT }
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
            SettingRow(stringResource(R.string.set_default_speed), value = speedLabel(defaultSpeed)) { dlg = Dlg.SPEED }
            SettingRow(stringResource(R.string.set_skip_back), value = stringResource(R.string.unit_seconds, skipBack)) { dlg = Dlg.SKIP_BACK }
            SettingRow(stringResource(R.string.set_skip_fwd), value = stringResource(R.string.unit_seconds, skipFwd)) { dlg = Dlg.SKIP_FWD }
            SettingSwitch(stringResource(R.string.set_wifi_only), stringResource(R.string.set_wifi_only_sub), checked = !allowCellular) {
                settings.setAllowCellularDownload(!it)
            }

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
                scope.launch { shareLog(context) }
            }
            SettingRow(stringResource(R.string.set_mail_log), stringResource(R.string.set_mail_log_sub)) {
                scope.launch { mailLog(context) }
            }
            SettingRow(
                stringResource(R.string.set_clear_log),
                stringResource(R.string.log_size, if (logBytes < 0) stringResource(R.string.size_calculating) else human(logBytes))
            ) { confirmClearLog = true }

            SectionLabel(stringResource(R.string.sec_about))
            SettingRow(stringResource(R.string.set_about), onClick = onOpenAbout)
            // 隐私政策必须**在应用内随时可查**,不能只在首启弹一次(平台合规指引 7.5)
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
            SettingRow(stringResource(R.string.set_version), value = stringResource(R.string.version_name))
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
            stringResource(R.string.dlg_font_title), FONT_LABEL_RES.map { stringResource(it) }, fontIndex(fontScale),
            onPick = { i -> settings.setFontScale(FONT_SCALES[i]); dlg = Dlg.NONE }, onDismiss = dismiss
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

private suspend fun exportOpml(context: Context, container: AppContainer, uri: Uri) {
    withContext(Dispatchers.IO) {
        runCatching {
            val opml = OpmlSupport.buildOpml(container.subscriptionStore.subscriptions.value)
            context.contentResolver.openOutputStream(uri)?.use { it.write(opml.toByteArray(Charsets.UTF_8)) }
        }
    }
}

/** 导出全部日志到 cacheDir/shares/ 并经系统分享面板发出(text/plain)。 */
private suspend fun shareLog(context: Context) {
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
    }
}

/** 把日志作为附件、经系统邮件发送到开发者邮箱(收件人/主题预填)。 */
private suspend fun mailLog(context: Context) {
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

private fun fontIndex(scale: Float): Int {
    var best = 1
    var diff = Float.MAX_VALUE
    FONT_SCALES.forEachIndexed { i, s -> val d = kotlin.math.abs(s - scale); if (d < diff) { diff = d; best = i } }
    return best
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
        Column(Modifier.weight(1f)) {
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
                modifier = Modifier.padding(start = 12.dp)
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
        Column(Modifier.weight(1f)) {
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
