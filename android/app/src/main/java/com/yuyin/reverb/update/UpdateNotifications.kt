package com.yuyin.reverb.update

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.yuyin.reverb.MainActivity
import com.yuyin.reverb.R

/**
 * 更新下载的两条通知(进行中 / 结果)。
 *
 * 与订阅更新的 [Notifications] 分开:**渠道不同**。那一条是"有新一期"的默认重要度通知,
 * 这一条是前台服务的常驻进度 —— 用默认重要度会一开下就响一声,而进度本身每秒都在变,
 * 只能用 LOW + `setOnlyAlertOnce`。合成一个渠道等于两者取其一,都会有一头不对。
 *
 * 进行中那条由 [UpdateDownloadService] 用 `startForeground` 挂出去,百分号变化时只更新不重响;
 * 结果那条在服务退出前发,点开就是主界面 —— 主界面的 [SelfUpdate] 状态机看到 `Ready` 会弹安装确认。
 */
internal object UpdateNotifications {
    private const val CHANNEL_ID = "update_download"

    /// 与 [Notifications.NOTIF_ID] 错开:两条通知可能同时在场。
    const val ID = 1002

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = context.getSystemService(NotificationManager::class.java) ?: return
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.update_notif_channel_name),
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = context.getString(R.string.update_notif_channel_desc) }
                mgr.createNotificationChannel(ch)
            }
        }
    }

    fun progress(context: Context, percent: Int): Notification {
        ensureChannel(context)
        val pct = percent.coerceIn(0, 100)
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_reverb)
            .setContentTitle(context.getString(R.string.update_notif_downloading_title))
            .setContentText(context.getString(R.string.update_downloading, pct))
            // percent <= 0 时用不确定进度条:还没读到第一个整百分比的阶段不能被画成 0%
            .setProgress(100, pct, pct <= 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openApp(context))
            .addAction(0, context.getString(R.string.update_action_cancel), cancelDownload(context))
            .build()
    }

    /** 下载完成:留着等用户来点(点开主界面,由弹窗把文件交给系统安装器)。 */
    fun done(context: Context) {
        ensureChannel(context)
        val notif = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_reverb)
            .setContentTitle(context.getString(R.string.update_notif_done_title))
            .setContentText(context.getString(R.string.update_notif_done_text))
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(ID, notif) }
    }

    fun failed(context: Context) {
        ensureChannel(context)
        val notif = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_reverb)
            .setContentTitle(context.getString(R.string.update_failed_title))
            .setContentText(context.getString(R.string.update_notif_failed_text))
            .setContentIntent(openApp(context))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(ID, notif) }
    }

    fun cancel(context: Context) {
        runCatching { NotificationManagerCompat.from(context).cancel(ID) }
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getActivity(context, 2, intent, flags)
    }

    /// 通知上的「取消下载」:走服务而不是直接改状态 —— 服务的停止(以及前台通知的撤下)
    /// 仍由它自己的收尾路径完成,用户在别处取消时两条路径合并成同一条。
    private fun cancelDownload(context: Context): PendingIntent {
        val intent = Intent(context, UpdateDownloadService::class.java)
            .setAction(UpdateDownloadService.ACTION_CANCEL)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getService(context, 3, intent, flags)
    }
}
