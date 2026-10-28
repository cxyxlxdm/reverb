package com.yuyin.reverb.playback

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.yuyin.reverb.MainActivity
import com.yuyin.reverb.data.remote.BilibiliSource

/**
 * 后台播放服务：基于 Media3 MediaSessionService，
 * 提供系统媒体通知、锁屏控制、音频焦点管理。音频由 ExoPlayer 直接流式拉取 enclosure 直链。
 */
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        com.yuyin.reverb.util.Logger.i("Service", "PlaybackService onCreate")
        // 视频 CDN 的直链要 `UA + Referer`,而 ExoPlayer 这一侧默认两样都没有 —— media3 1.3.1 的
        // DefaultHttpDataSource 默认 `userAgent = null`(不再像 ExoPlayer 2 那样自动填 UA),
        // 于是 B 站那条地址会 403,且**探活是通的**(探活走 BilibiliSource 自己的 OkHttp,头是齐的),
        // 现象是「解析直链成功、然后播放器报错」。
        //
        // 为什么不用 `setDefaultRequestProperties`:那是整条管道的默认头,会把 Referer 一并发给
        // 所有播客主机;而这里只需要给它自己那一族地址。ResolvingDataSource 恰好是"按这一次的
        // 地址改 DataSpec"的位置 —— 补的是 `httpRequestHeaders`,`DefaultHttpDataSource` 会照单设上
        // (它自己的 userAgent 为 null,不会再把 User-Agent 覆盖回去)。
        val dataSourceFactory = ResolvingDataSource.Factory(DefaultDataSource.Factory(this)) { spec ->
            if (BilibiliSource.needsStreamHeaders(spec.uri.toString())) {
                spec.buildUpon()
                    .setHttpRequestHeaders(BilibiliSource.streamHeaders())
                    .build()
            } else {
                spec
            }
        }
        val exo = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this).setDataSourceFactory(dataSourceFactory))
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK) // 锁屏/后台流式播放不因深睡中断
            .build()
        // 包一层,把系统通知/锁屏的「上一首/下一首」命令转发到队列导航(与 App 内按钮同一套逻辑)
        val player = NavForwardingPlayer(
            exo,
            onNext = { mainHandler.post { PlayerController.next() } },
            onPrev = { mainHandler.post { PlayerController.previous() } }
        )
        // 点击系统通知（非控制按钮区）时回到余音并打开播放页，而不是跳到别的 App
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_OPEN_PLAYER, true)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        mediaSession = MediaSession.Builder(this, player)
            .setSessionActivity(pendingIntent)
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onDestroy() {
        com.yuyin.reverb.util.Logger.i("Service", "PlaybackService onDestroy")
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        super.onDestroy()
    }
}

/**
 * 让播放器始终声明支持「上一首/下一首」命令,并把这些命令转发到队列导航,
 * 从而系统通知栏与锁屏会显示上/下一首按钮,点击走与 App 内相同的队列逻辑。
 */
private class NavForwardingPlayer(
    player: Player,
    private val onNext: () -> Unit,
    private val onPrev: () -> Unit
) : ForwardingPlayer(player) {

    override fun getAvailableCommands(): Player.Commands =
        super.getAvailableCommands().buildUpon()
            .add(Player.COMMAND_SEEK_TO_NEXT)
            .add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            .add(Player.COMMAND_SEEK_TO_PREVIOUS)
            .add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            .build()

    override fun isCommandAvailable(command: Int): Boolean = when (command) {
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> true
        else -> super.isCommandAvailable(command)
    }

    override fun hasNextMediaItem(): Boolean = true
    override fun hasPreviousMediaItem(): Boolean = true

    override fun seekToNext() = onNext()
    override fun seekToNextMediaItem() = onNext()
    override fun seekToPrevious() = onPrev()
    override fun seekToPreviousMediaItem() = onPrev()
}
