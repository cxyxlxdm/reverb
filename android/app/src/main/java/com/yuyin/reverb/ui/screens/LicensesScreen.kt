package com.yuyin.reverb.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.yuyin.reverb.R
import com.yuyin.reverb.playback.asr.AsrFactory

private data class Lib(val name: String, val license: String)

/**
 * 清单在 composable 里构造(原来是顶层 val),因为**带中文说明的那几条必须走资源** ——
 * 顶层 val 拿不到 `stringResource`。
 *
 * **哪些留字面量、哪些进资源**,判据是「换语种要不要变」:
 * `Jetpack Compose` / `OkHttp` / `Coil` 这类是**专有名词**,五套界面同形,搬进资源只是让
 * 五个文件各抄一遍;而 `whisper.cpp(离线语音识别)` 的括号里是一句**说明**,
 * 法/西/英用户看到的就该是当地语言(2026-10-08 真机 fr/es 通读实测:这两行在法西界面上仍是中文)。
 *
 * 那两条的资源键在 `src/main/res/` 里定义、`src/store/res/` 里覆盖成**空串**:
 * 商店渠道不展示它们(下面 `HAS_ENGINE` 那支已被 R8 删掉),但**资源不跟着删**,
 * 于是包里会留一句「whisper.cpp」的文案 —— 这一版按硬规矩 1 的口径,
 * 「包里没有」也要能解包 grep 证明,所以覆盖成空而不是靠代码分支。
 */
@Composable
private fun libs(): List<Lib> = listOfNotNull(
    Lib("Jetpack Compose / AndroidX", "Apache License 2.0"),
    Lib("AndroidX Media3 (ExoPlayer)", "Apache License 2.0"),
    Lib("OkHttp", "Apache License 2.0"),
    Lib("Coil", "Apache License 2.0"),
    Lib("Kotlin Coroutines", "Apache License 2.0"),
    Lib("AndroidX WorkManager", "Apache License 2.0"),
    // 离线语音识别**只随默认渠道分发**,所以只在那个渠道登记。
    // 大陆商店渠道的包里连 .so 和模型都没有(见 playback/asr/AsrEngine),
    // 列上去就是不实陈述。`HAS_ENGINE` 是编译期常量,R8 会把另一支的**代码**删掉,
    // 资源那半靠 store source set 覆盖空串(见上面 libs 的注释)—— 与鸿蒙相反,那边没有 DCE(H54)。
    if (AsrFactory.HAS_ENGINE) Lib(stringResource(R.string.lic_whisper), "MIT License") else null,
    if (AsrFactory.HAS_ENGINE) Lib(stringResource(R.string.lic_whisper_model), "MIT License") else null
)

/**
 * 数据来源按渠道列**实际用到的那些**。无内容目录的渠道压根不连目录接口
 * (R8 已把 iTunes/fyyd/gpodder 三个源整体剔除),照抄一份就是不实陈述。
 * 目录那三条是接口名/域名,同形不动;另外两条是句子,走资源(理由见 [libs])。
 */
@Composable
private fun sources(): List<String> = if (com.yuyin.reverb.BuildConfig.CATALOG) listOf(
    "Apple iTunes Search / Marketing RSS",
    "fyyd.de",
    "gpodder.net"
) else listOf(
    stringResource(R.string.src_publisher_rss),
    stringResource(R.string.src_site_opml)
)

@Composable
fun LicensesScreen(onBack: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.licenses_title), onBack)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp)
        ) {
            Text(
                stringResource(R.string.licenses_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Header(stringResource(R.string.licenses_h_libs))
            libs().forEach { LibRow(it.name, it.license) }
            Header(stringResource(R.string.licenses_h_sources))
            Text(
                // 这段引言也要按渠道分支 —— 商店渠道里写「以下为公开的播客目录/检索接口」
                // 就是文不对题:下面列的是 RSS 地址与官网 OPML,压根没有目录接口。
                // 发布截图里这一页会被逐字核对。鸿蒙侧同一处同一改法。
                stringResource(
                    if (com.yuyin.reverb.BuildConfig.CATALOG) R.string.licenses_sources_note_catalog
                    else R.string.licenses_sources_note
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(8.dp))
            sources().forEach { LibRow(it, "") }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Header(text: String) {
    Spacer(Modifier.height(20.dp))
    Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun LibRow(name: String, license: String) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
    ) {
        Text(name, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onBackground)
        if (license.isNotBlank()) {
            Text(license, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
