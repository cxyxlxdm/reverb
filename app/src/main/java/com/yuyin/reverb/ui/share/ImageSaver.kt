package com.yuyin.reverb.ui.share

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.yuyin.reverb.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 返回一个「保存图片到相册」的动作:Android 10+ 直接经 MediaStore 保存(免权限);
 * 9 及以下先申请写外存权限。保存在后台线程完成,结果以 Toast 反馈。
 */
@Composable
fun rememberImageSaver(): (Bitmap, String) -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<Pair<Bitmap, String>?>(null) }

    fun persist(bmp: Bitmap, name: String) {
        scope.launch {
            val ok = withContext(Dispatchers.IO) { ShareCards.saveToGallery(context, bmp, name) }
            Toast.makeText(context, context.getString(if (ok) R.string.saved_ok else R.string.saved_fail), Toast.LENGTH_SHORT).show()
        }
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val p = pending
        pending = null
        if (granted && p != null) persist(p.first, p.second)
        else Toast.makeText(context, context.getString(R.string.saved_fail), Toast.LENGTH_SHORT).show()
    }

    return remember {
        { bmp: Bitmap, name: String ->
            val ok29 = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
            if (ok29 || granted) persist(bmp, name)
            else {
                pending = bmp to name
                launcher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
    }
}
