package com.yuyin.reverb.ui.share

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import androidx.core.content.FileProvider
import coil.imageLoader
import coil.request.ImageRequest
import com.yuyin.reverb.data.model.Episode
import com.yuyin.reverb.data.model.Podcast
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.sin

/**
 * 分享卡片:纯本地用 Android Canvas 绘制水墨风位图,经系统分享导出为图片。
 * 不接任何三方分享 SDK,只用系统 ACTION_SEND;图片落在 cacheDir/shares 经 FileProvider 授权。
 */
object ShareCards {

    // 水墨调色(与 App 深色主题一致)
    private const val INK = 0xFF0E1416.toInt()
    private const val INK2 = 0xFF161D20.toInt()
    private const val CELADON = 0xFF7FD1C0.toInt()
    private const val GOLD = 0xFFE9C879.toInt()
    private const val TEXT = 0xFFEAF0EF.toInt()
    private const val DIM = 0xFF95A3A0.toInt()

    private suspend fun loadArtwork(context: Context, url: String): Bitmap? {
        if (url.isBlank()) return null
        return try {
            val req = ImageRequest.Builder(context).data(url).allowHardware(false).build()
            val result = context.imageLoader.execute(req)
            (result.drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap
        } catch (e: Exception) {
            null
        }
    }

    /** 剪藏卡片:封面 + 标题 + 频道 + 时间点 + 水墨波纹,记录「此刻听到的这一段」。 */
    suspend fun momentCard(context: Context, episode: Episode, positionMs: Long): Bitmap =
        withContext(Dispatchers.IO) {
            val w = 1080
            val h = 1500
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            drawInkBackground(c, w, h)

            // 封面
            val art = loadArtwork(context, episode.artworkUrl)
            val artSize = 560
            val artLeft = (w - artSize) / 2f
            val artTop = 150f
            if (art != null) drawRoundedBitmap(c, art, RectF(artLeft, artTop, artLeft + artSize, artTop + artSize), 40f)
            else {
                val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = INK2 }
                c.drawRoundRect(RectF(artLeft, artTop, artLeft + artSize, artTop + artSize), 40f, 40f, p)
            }

            var y = artTop + artSize + 90f
            // 标题(最多两行,居中)
            y = drawWrappedCentered(c, episode.title, w, y, textSize = 56f, color = TEXT, bold = true, maxLines = 2, sidePad = 90)
            y += 18f
            // 频道
            if (episode.podcastTitle.isNotBlank())
                y = drawWrappedCentered(c, episode.podcastTitle, w, y, textSize = 38f, color = CELADON, bold = false, maxLines = 1, sidePad = 120)
            y += 40f
            // 时间点徽标
            val badge = "剪藏 · ${formatClock(positionMs)}"
            drawCenteredText(c, badge, w / 2f, y + 30f, 40f, GOLD, bold = false)

            // 底部落款
            drawCenteredText(c, "余音 · 每一段余音都值得留存", w / 2f, h - 70f, 34f, DIM, bold = false)
            bmp
        }

    /**
     * 朋友圈海报:频道 Logo + 频道名 + 简介(最多四行,超出省略)+ App 落款,
     * 不携带可能含私有凭据的 RSS 地址。
     *
     * 3:4(1080×1440)而不是原来的 1080×1500:微信朋友圈的单图预览按 3:4 收,
     * 原来的比例在信息流里会先被裁掉上下两头。改矮 60px 之后标题三行 + 简介四行
     * 的最坏情形仍离落款 50px 以上,不再需要原先为 1350 加的余量。
     */
    suspend fun channelCard(context: Context, podcast: Podcast): Bitmap =
        withContext(Dispatchers.IO) {
            val w = 1080
            val h = 1440
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            drawInkBackground(c, w, h)

            val art = loadArtwork(context, podcast.artworkUrl)
            val artSize = 620
            val artLeft = (w - artSize) / 2f
            val artTop = 170f
            val artRect = RectF(artLeft, artTop, artLeft + artSize, artTop + artSize)
            if (art != null) {
                drawRoundedBitmap(c, art, artRect, 48f)
            } else {
                val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = INK2 }
                c.drawRoundRect(artRect, 48f, 48f, p)
                drawCenteredText(c, "余", w / 2f, artTop + artSize / 2f + 55f, 150f, CELADON, bold = true)
            }

            var y = drawWrappedCentered(
                c, podcast.title, w, artTop + artSize + 90f,
                textSize = 62f, color = TEXT, bold = true, maxLines = 3, sidePad = 90
            )
            if (podcast.description.isNotBlank()) {
                y += 34f
                y = drawWrappedCentered(
                    c, podcast.description, w, y,
                    textSize = 36f, color = DIM, bold = false, maxLines = 4, sidePad = 110
                )
            }
            drawCenteredText(c, "余音 · Reverb", w / 2f, h - 78f, 38f, DIM, bold = false)
            bmp
        }

    /** 听觉足迹海报:把已盖的印章排成网格,标题化为一张可分享的年度足迹图。 */
    fun footprintPoster(seals: List<Triple<String, String, String>>): Bitmap {
        // 每项:Triple(印章字, 单集标题, 频道)
        val w = 1080
        val cols = 3
        val cell = 300
        val gridTop = 240
        val rows = (seals.size + cols - 1) / cols
        val h = (gridTop + rows.coerceAtLeast(1) * cell + 160).coerceAtLeast(900)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        drawInkBackground(c, w, h)

        drawCenteredText(c, "听觉足迹", w / 2f, 130f, 64f, TEXT, bold = true)
        drawCenteredText(c, "共 ${seals.size} 枚印记", w / 2f, 185f, 36f, GOLD, bold = false)

        val gridLeft = (w - cols * cell) / 2f
        seals.forEachIndexed { i, (seal, _, _) ->
            val cx = gridLeft + (i % cols) * cell + cell / 2f
            val cy = gridTop + (i / cols) * cell + cell / 2f - 20f
            // 印章:圆角方框 + 中心印字
            val box = 150f
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE; strokeWidth = 5f; color = CELADON
            }
            c.drawRoundRect(RectF(cx - box / 2, cy - box / 2, cx + box / 2, cy + box / 2), 24f, 24f, stroke)
            drawCenteredText(c, seal, cx, cy + 30f, 84f, GOLD, bold = true)
        }
        drawCenteredText(c, "余音 · Reverb", w / 2f, h - 60f, 34f, DIM, bold = false)
        return bmp
    }

    /** 保存位图到系统相册(Pictures/余音)。Android 10+ 免权限;9 及以下需调用方先取得写外存权限。返回是否成功。 */
    fun saveToGallery(context: Context, bitmap: Bitmap, displayName: String): Boolean {
        return try {
            val resolver = context.contentResolver
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, android.os.Environment.DIRECTORY_PICTURES + "/余音")
                    put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
                }
            }
            val collection = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q)
                android.provider.MediaStore.Images.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            val uri = resolver.insert(collection, values) ?: return false
            resolver.openOutputStream(uri)?.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } ?: return false
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                values.clear()
                values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 保存位图到 cacheDir/shares 并弹出系统分享。 */
    fun share(context: Context, bitmap: Bitmap, fileName: String, chooserTitle: String) {
        val dir = File(context.cacheDir, "shares").apply { mkdirs() }
        val f = File(dir, fileName)
        f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val uri = FileProvider.getUriForFile(context, context.packageName + ".fileprovider", f)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            // 把 uri 放进 ClipData,分享面板预览缩略图才能拿到读权限正常显示(否则只见系统占位图)
            clipData = android.content.ClipData.newUri(context.contentResolver, "Reverb", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(
            Intent.createChooser(send, chooserTitle).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    // ---- 绘制辅助 ----

    private fun drawInkBackground(c: Canvas, w: Int, h: Int) {
        c.drawColor(INK)
        // 顶部与底部各一层水墨波纹
        val wave = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE; strokeWidth = 3f; color = (CELADON and 0x00FFFFFF) or 0x33000000
        }
        for (layer in 0 until 2) {
            val baseY = if (layer == 0) h * 0.14f else h * 0.9f
            val amp = if (layer == 0) 26f else 20f
            val path = Path()
            val steps = 60
            for (i in 0..steps) {
                val x = w * i / steps.toFloat()
                val yy = baseY + amp * sin(i / steps.toFloat() * 2.4f * Math.PI.toFloat() + layer)
                if (i == 0) path.moveTo(x, yy) else path.lineTo(x, yy)
            }
            c.drawPath(path, wave)
        }
    }

    private fun drawRoundedBitmap(c: Canvas, src: Bitmap, dst: RectF, radius: Float) {
        val shader = android.graphics.BitmapShader(src, android.graphics.Shader.TileMode.CLAMP, android.graphics.Shader.TileMode.CLAMP)
        // 缩放贴合目标框
        val m = android.graphics.Matrix()
        val scale = maxOf(dst.width() / src.width, dst.height() / src.height)
        m.setScale(scale, scale)
        m.postTranslate(dst.left - (src.width * scale - dst.width()) / 2f, dst.top - (src.height * scale - dst.height()) / 2f)
        shader.setLocalMatrix(m)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
        c.drawRoundRect(dst, radius, radius, p)
    }

    private fun paint(textSize: Float, color: Int, bold: Boolean) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        this.textSize = textSize
        typeface = if (bold) Typeface.create(Typeface.DEFAULT, Typeface.BOLD) else Typeface.DEFAULT
    }

    private fun drawCenteredText(c: Canvas, text: String, cx: Float, baseY: Float, size: Float, color: Int, bold: Boolean) {
        val p = paint(size, color, bold).apply { textAlign = Paint.Align.CENTER }
        c.drawText(text, cx, baseY, p)
    }

    /** 居中绘制可换行文本,返回绘制后底部 y。 */
    private fun drawWrappedCentered(
        c: Canvas, text: String, w: Int, top: Float, textSize: Float, color: Int, bold: Boolean, maxLines: Int, sidePad: Int
    ): Float {
        val tp = paint(textSize, color, bold)
        val width = w - sidePad * 2
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, tp, width)
            .setAlignment(Layout.Alignment.ALIGN_CENTER)
            .setMaxLines(maxLines)
            .setEllipsize(TextUtils.TruncateAt.END)
            .build()
        c.save()
        c.translate(sidePad.toFloat(), top)
        layout.draw(c)
        c.restore()
        return top + layout.height
    }

    private fun formatClock(ms: Long): String {
        val total = (ms / 1000).coerceAtLeast(0)
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }
}
