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

private data class Lib(val name: String, val license: String)

private val LIBS = listOf(
    Lib("Jetpack Compose / AndroidX", "Apache License 2.0"),
    Lib("AndroidX Media3 (ExoPlayer)", "Apache License 2.0"),
    Lib("OkHttp", "Apache License 2.0"),
    Lib("Coil", "Apache License 2.0"),
    Lib("Kotlin Coroutines", "Apache License 2.0"),
    Lib("AndroidX WorkManager", "Apache License 2.0")
)

private val SOURCES = listOf(
    "Apple iTunes Search / Marketing RSS",
    "fyyd.de",
    "gpodder.net"
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
            LIBS.forEach { LibRow(it.name, it.license) }
            Header(stringResource(R.string.licenses_h_sources))
            Text(
                stringResource(R.string.licenses_sources_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(8.dp))
            SOURCES.forEach { LibRow(it, "") }
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
