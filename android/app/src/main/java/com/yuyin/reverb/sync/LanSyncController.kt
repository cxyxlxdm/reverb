package com.yuyin.reverb.sync

import android.content.Context
import com.yuyin.reverb.AppContainer
import com.yuyin.reverb.util.Logger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/** 同步界面的状态机。UI 只读它,不碰协议。 */
sealed class LanSyncState {
    data object Idle : LanSyncState()

    data class Listening(
        val deviceName: String,
        val addresses: List<String>,
        val peers: List<LanSyncPeer>
    ) : LanSyncState()

    data class Connecting(val target: String) : LanSyncState()

    data class Confirm(val peerName: String, val code: String) : LanSyncState()

    data class Syncing(val peerName: String, val stage: LanSyncStage, val percent: Int) : LanSyncState()

    data class Done(val result: LanSyncResult) : LanSyncState()

    data class Failed(val peerName: String?, val fail: LanSyncFail, val detail: String) : LanSyncState()
}

/**
 * 局域网同步的总控:一台设备上**同时**做服务端和客户端。
 *
 * 这不是"文件互传",是**双向合并**:任何一端发起,双方最终都拿到并集。所以界面上只需要
 * "在任意一台设备上点对方" —— 被点的那台会自动进入配对码确认,不用再点一次。
 *
 * 生命周期跟对话框绑定:`start()` 打开,关掉对话框 `stop()` —— 不在后台常驻监听。
 * (用户明确说过 P0 不做锁屏/后台自动接力;这也顺带避开手机厂商对后台网络的限制。)
 *
 * 并发只有一条:**同一时刻只跑一个会话**。两端同时点对方时会各失败一次(对端的监听正在忙),
 * 界面上提示"只在一台设备上点连接",重试即可 —— 比让两端各跑两个会话、弹两次配对码清楚。
 */
class LanSyncController(
    context: Context,
    private val container: AppContainer
) {
    private val appContext = context.applicationContext
    private val identity = LanSyncIdentity(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()

    private val _state = MutableStateFlow<LanSyncState>(LanSyncState.Idle)
    val state: StateFlow<LanSyncState> = _state.asStateFlow()

    @Volatile private var running = false
    @Volatile private var stopping = false
    /** 每次 start/stop 自增。异步铺开的中途发现代号变了,就把自己刚拿到的东西收掉。 */
    private val runToken = AtomicInteger()
    private var server: ServerSocket? = null
    private var discovery: LanSyncDiscovery? = null
    private var quDiscovery: LanQuDiscovery? = null
    private var serverJob: Job? = null
    private var sessionJob: Job? = null
    private var session: LanSyncSession? = null
    private var confirmWaiter: CompletableDeferred<Boolean>? = null
    private var material: LanSyncIdentity.Material? = null
    private var nsdPeers: List<LanSyncPeer> = emptyList()
    private var quPeers: List<LanSyncPeer> = emptyList()
    private var peers: List<LanSyncPeer> = emptyList()
    @Volatile private var currentPeer: String? = null

    /** 打开面板:绑端口 + 广播 + 开始发现。可重复调用。 */
    fun start() {
        if (running) return
        running = true
        stopping = false
        val token = runToken.incrementAndGet()
        scope.launch {
            val m = try {
                identity.material
            } catch (e: Exception) {
                fail(null, LanSyncFail.IO, "本机身份初始化失败:${e.message}")
                return@launch
            }
            material = m
            // `start()` 是异步铺开的,对话框可能在它铺完之前就被关掉(stop() 只关它当时看得见的
            // 那几个字段)。每过一个 await 点确认一次:号变了就把刚拿到的东西自己收掉,
            // 否则会留下一个没人认领的 ServerSocket / 广播 —— 下一次打开时端口就被自己占着。
            if (runToken.get() != token) return@launch
            val socket = bindServer()
            if (socket == null) {
                fail(null, LanSyncFail.IO, "端口被占用,且系统没有给出可用端口")
                return@launch
            }
            if (runToken.get() != token) {
                runCatching { socket.close() }
                return@launch
            }
            server = socket
            val ownService = "Reverb-${m.deviceId.take(8)}"
            val d = LanSyncDiscovery(appContext, ::onNsdPeers, ::onDiscoveryError)
            discovery = d
            if (runToken.get() != token) {
                d.stop()
                runCatching { socket.close() }
                return@launch
            }
            d.advertise(ownService, m.name, socket.localPort)
            d.startDiscovery()
            // 组播只丢一个方向的 AP 上系统 NSD 会一直为空;QU 查询的应答是单播,兜住那种网络。
            val q = LanQuDiscovery(ownService, ::onQuPeers)
            quDiscovery = q
            if (runToken.get() != token) {
                d.stop()
                q.stop()
                runCatching { socket.close() }
                return@launch
            }
            q.start()
            nsdPeers = emptyList()
            quPeers = emptyList()
            peers = emptyList()
            publishListening()
            serverJob = scope.launch { acceptLoop(socket) }
            Logger.i(TAG, "开始监听 port=${socket.localPort} name=${m.name} id=${m.deviceId}")
        }
    }

    /** 关闭面板:停服务、停发现、断开当前会话。 */
    fun stop() {
        stopping = true
        running = false
        runToken.incrementAndGet()
        discovery?.stop()
        discovery = null
        quDiscovery?.stop()
        quDiscovery = null
        runCatching { server?.close() }
        server = null
        session?.let { runCatching { it.close() } }
        session = null
        serverJob?.cancel()
        serverJob = null
        sessionJob?.cancel()
        sessionJob = null
        synchronized(lock) {
            confirmWaiter?.cancel()
            confirmWaiter = null
        }
        peers = emptyList()
        nsdPeers = emptyList()
        quPeers = emptyList()
        currentPeer = null
        _state.value = LanSyncState.Idle
        Logger.i(TAG, "已停止监听")
    }

    /** 人眼比对之后的唯一出口。拒绝时两端都会看到"已取消"。 */
    fun confirm(accept: Boolean) {
        val waiter = synchronized(lock) { confirmWaiter }
        if (waiter != null && !waiter.isCompleted) waiter.complete(accept)
    }

    /**
     * 手动连接。接受 `192.168.1.5:47820` / `192.168.1.5`(默认端口)两种写法。
     * 和自动发现挤在同一个面板里,用户直接照抄对方屏幕上那行地址即可。
     */
    fun connectTo(raw: String) {
        val target = parseTarget(raw)
        if (target == null) {
            _state.value = LanSyncState.Failed(null, LanSyncFail.CONNECT, "地址格式不对:$raw")
            return
        }
        val (host, port) = target
        val busy = synchronized(lock) { sessionJob?.isActive == true }
        if (busy) {
            _state.value = LanSyncState.Failed(null, LanSyncFail.CONNECT, "已有一次同步在跑")
            return
        }
        _state.value = LanSyncState.Connecting("$host:$port")
        sessionJob = scope.launch {
            var socket: Socket? = null
            try {
                socket = Socket()
                socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                val s = socket
                socket = null // runSession 负责关闭
                runSession(s, initiator = true)
            } catch (e: LanSyncException) {
                if (!stopping) _state.value = LanSyncState.Failed(null, e.fail, e.message ?: "")
            } catch (e: Exception) {
                if (!stopping) {
                    Logger.w(TAG, "连接 $host:$port 失败:${e.message}")
                    _state.value = LanSyncState.Failed(null, LanSyncFail.CONNECT, e.message ?: "")
                }
            } finally {
                socket?.let { runCatching { it.close() } }
            }
        }
    }

    // ---- 内部 ----

    private fun bindServer(): ServerSocket? {
        for (port in intArrayOf(DEFAULT_PORT, 0)) {
            try {
                val s = ServerSocket()
                s.reuseAddress = true
                s.bind(InetSocketAddress(port))
                return s
            } catch (e: Exception) {
                Logger.w(TAG, "绑定端口 $port 失败:${e.message}")
            }
        }
        return null
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running) {
            val socket = try {
                server.accept()
            } catch (e: Exception) {
                if (running) Logger.w(TAG, "accept 中断:${e.message}")
                break
            }
            val busy = synchronized(lock) { sessionJob?.isActive == true }
            if (busy) {
                Logger.w(TAG, "已有会话,拒绝新连接")
                runCatching { socket.close() }
                continue
            }
            sessionJob = scope.launch { runSession(socket, initiator = false) }
        }
    }

    private suspend fun runSession(socket: Socket, initiator: Boolean) {
        var s: LanSyncSession? = null
        try {
            val m = material ?: identity.material.also { material = it }
            s = LanSyncSession(
                identity = m,
                socket = socket,
                initiator = initiator,
                ui = bridge,
                buildSnapshot = { LanSyncMerge.build(container) },
                applySnapshot = { json -> LanSyncMerge.apply(container, json) }
            )
            session = s
            val result = s.run()
            _state.value = LanSyncState.Done(result)
        } catch (e: LanSyncException) {
            Logger.w(TAG, "会话结束 ${e.fail}:${e.message}")
            if (!stopping) _state.value = LanSyncState.Failed(currentPeer, e.fail, e.message ?: "")
        } catch (e: Exception) {
            Logger.e(TAG, "会话异常", e)
            if (!stopping) _state.value = LanSyncState.Failed(currentPeer, LanSyncFail.IO, e.message ?: "网络中断")
        } finally {
            s?.close()
            session = null
            synchronized(lock) {
                confirmWaiter?.cancel()
                confirmWaiter = null
            }
        }
    }

    private val bridge = object : LanSyncUiBridge {
        override suspend fun confirm(peerName: String, code: String): Boolean {
            currentPeer = peerName
            val waiter = CompletableDeferred<Boolean>()
            synchronized(lock) { confirmWaiter = waiter }
            _state.value = LanSyncState.Confirm(peerName, code)
            return try {
                waiter.await()
            } finally {
                synchronized(lock) { if (confirmWaiter === waiter) confirmWaiter = null }
            }
        }

        override fun stage(peerName: String, stage: LanSyncStage, percent: Int) {
            currentPeer = peerName
            _state.value = LanSyncState.Syncing(peerName, stage, percent.coerceIn(0, 100))
        }
    }

    private fun onNsdPeers(list: List<LanSyncPeer>) {
        nsdPeers = list
        mergePeers()
    }

    private fun onQuPeers(list: List<LanSyncPeer>) {
        quPeers = list
        mergePeers()
    }

    /**
     * 两条发现路径各报各的,这里取并集。
     *
     * 不互相清空:NSD 的 `SERVICE_LOST` 与 QU 的"这一轮没收到应答"含义并不相同 ——
     * 前者是系统缓存里那条记录过期,后者只是这一轮没回包(设备可能正在忙)。
     * 谁报来的就只覆盖谁那一半,另一半点过的设备不会因为对面沉默两秒就消失。
     * 真正的存活判断交给用户:点一下就试,连不上会有 CONNECT 失败提示。
     */
    private fun mergePeers() {
        peers = (nsdPeers + quPeers).distinctBy { it.name to it.address }
        if (_state.value is LanSyncState.Listening) publishListening()
    }

    private fun onDiscoveryError(detail: String) {
        // 发现失败**不**把面板变成错误:手动地址仍然能用。只记日志(界面一直写着手动入口)。
        Logger.w(TAG, "发现不可用:$detail")
    }

    private fun publishListening() {
        val m = material ?: return
        _state.value = LanSyncState.Listening(m.name, localAddresses(), peers)
    }

    private fun fail(peer: String?, fail: LanSyncFail, detail: String) {
        Logger.w(TAG, "失败 $fail:$detail")
        _state.value = LanSyncState.Failed(peer, fail, detail)
    }

    /** 本机 Wi-Fi 上的 IPv4 地址(不含回环 / 链路本地)。没有地址时返回空表,界面提示检查 Wi-Fi。 */
    private fun localAddresses(): List<String> {
        val port = server?.localPort ?: return emptyList()
        return try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && it.isSiteLocalAddress }
                .mapNotNull { it.hostAddress }
                .distinct()
                .map { "$it:$port" }
        } catch (e: Exception) {
            Logger.w(TAG, "读取本机地址失败:${e.message}")
            emptyList()
        }
    }

    private fun parseTarget(raw: String): Pair<String, Int>? {
        val text = raw.trim()
            .removePrefix("http://")
            .removePrefix("https://")
            .removeSuffix("/")
        if (text.isEmpty()) return null
        val colon = text.lastIndexOf(':')
        return if (colon > 0 && text.count { it == ':' } == 1) {
            val host = text.substring(0, colon).trim()
            val port = text.substring(colon + 1).trim().toIntOrNull() ?: return null
            if (host.isEmpty() || port !in 1..65535) null else host to port
        } else {
            text to DEFAULT_PORT
        }
    }

    private companion object {
        const val TAG = "LanSync"
        const val DEFAULT_PORT = 47820
        const val CONNECT_TIMEOUT_MS = 6_000
    }
}
