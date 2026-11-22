package com.yuyin.reverb.update

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationManagerCompat
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * 安装包的后台下载。
 *
 * **为什么是前台服务**:包体已经 200 MB 级,而在手机上"下载"天然要跑几分钟到几十分钟 ——
 * 用户这期间会看别的、锁屏、去听播客。普通协程跟着进程走,进程一被回收下载就断,
 * 而这条链路又没有断点续传(每次都是整包重来)。前台服务把进程钉住,进度挂通知栏,
 * 弹窗可以随时收起(见 [SelfUpdate.dialogShown])。
 *
 * 下载逻辑整段仍在 [SelfUpdate] 里:这个服务只负责三件事 —— 起进程驻留、把进度刷进通知栏、
 * 收尾时发结果通知并退出。这样 `SelfUpdate` 的校验(字节数 / sha256)与状态机不需要第二份。
 *
 * `START_NOT_STICKY`:被系统杀掉后不重启。重来一次必须重新走「检测 → 问蜂窝 → 下载」,
 * 而那条路径的入口在界面上;盲目重启一个没有待装版本的下载比不重启更糟。
 */
class UpdateDownloadService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var current: SelfUpdate.Release? = null
    private var progressJob: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            val rel = current
            if (rel != null) SelfUpdate.dismiss(rel) else stopSelf()
            return START_NOT_STICKY
        }
        // 交接只在本进程内存里:拿不到就说明这次启动不是我们发起的(或进程被重建过),
        // 直接退出 —— 从磁盘上"猜"一份待装版本是没有依据的。
        val rel = current ?: SelfUpdate.pendingRelease
        if (rel == null) {
            Logger.w(TAG, "update service started without pending release")
            stopSelf()
            return START_NOT_STICKY
        }
        if (current != null) return START_NOT_STICKY   // 重复启动:同一份正在下

        current = rel
        // 必须先把 startForeground 挂上(Android 对 startForegroundService 有 5 秒时限);
        // 第一帧用不确定进度,读到第一个整百分比后由下面的收集器换成真实进度。
        startForeground(UpdateNotifications.ID, UpdateNotifications.progress(this, 0))
        acquireWakeLock()

        progressJob = scope.launch {
            SelfUpdate.state.collect { s ->
                if (s is SelfUpdate.UpdateState.Downloading) {
                    val notif = UpdateNotifications.progress(this@UpdateDownloadService, s.percent)
                    runCatching {
                        NotificationManagerCompat.from(this@UpdateDownloadService)
                            .notify(UpdateNotifications.ID, notif)
                    }
                }
            }
        }

        scope.launch {
            SelfUpdate.runServiceDownload(rel, this).join()
            finish(rel)
        }
        return START_NOT_STICKY
    }

    /**
     * 收尾:撤掉常驻进度条,按状态机最后落在哪一格决定发不发结果通知。
     * `Idle` = 用户取消了,什么都不发。
     */
    private fun finish(rel: SelfUpdate.Release) {
        progressJob?.cancel()
        progressJob = null
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        when (SelfUpdate.state.value) {
            is SelfUpdate.UpdateState.Ready -> UpdateNotifications.done(this)
            is SelfUpdate.UpdateState.Failed -> {
                Logger.w(TAG, "update download ended failed tag=${rel.tag}")
                UpdateNotifications.failed(this)
            }
            else -> Unit
        }
        current = null
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        releaseWakeLock()
        // 服务被系统收回而下载没跑完:给状态机一个可重试的落点,别把界面钉在"正在下载"。
        // 正常收尾时 finish 已把 current 清空,这里是空转。
        current?.let { SelfUpdate.markInterrupted(it) }
        super.onDestroy()
    }

    /**
     * 大文件下载期间屏幕熄灭,CPU 可能先睡过去而把网络收尾拖住;前台服务本身不保证 CPU 醒着。
     * 拿一把部分唤醒锁,收尾 / 销毁时释放(进程被杀时系统会连带释放,不会漏)。
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        runCatching {
            val pm = getSystemService(PowerManager::class.java) ?: return
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "reverb:update-download")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }.onFailure { Logger.w(TAG, "update wake lock failed: ${it.javaClass.simpleName}") }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    companion object {
        private const val TAG = "Update"

        /// 通知上「取消下载」那条动作的 action。
        const val ACTION_CANCEL = "com.yuyin.reverb.update.CANCEL_DOWNLOAD"
    }
}
