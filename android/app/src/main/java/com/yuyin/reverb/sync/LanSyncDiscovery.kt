package com.yuyin.reverb.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import com.yuyin.reverb.util.Logger

/** 发现到的一台设备。`name` 优先取 TXT 里的设备名,拿不到才退回服务名。 */
data class LanSyncPeer(val name: String, val host: String, val port: Int) {
    val address: String get() = "$host:$port"
}

/**
 * mDNS/DNS-SD 发现(`_reverb._tcp`),走系统 NSD 服务,**不引三方库、不加组播锁**。
 *
 * 三条容易踩的坑:
 * 1. **解析必须串行**。同一时刻只允许一个 `resolveService`,并发会回调
 *    `FAILURE_ALREADY_ACTIVE`,而那看起来像"设备时有时无"。这里用一个待解析队列排队。
 * 2. **解析可能永远不回调**。`resolveService` 没有取消接口;服务在缓存里消失、或者应答丢包时,
 *    回调就是不来。2026-11-12 实测有一次 `resolve` 挂住 80 秒以上,之后**全队**每一项都立刻
 *    `FAILURE_ALREADY_ACTIVE` —— 面板从此再也发现不到任何设备,直到杀进程。所以每次解析都挂
 *    一个超时(见 [RESOLVE_TIMEOUT_MS]),超时就跳过这一项;槽位忙(ALREADY_ACTIVE)时退一步
 *    再继续,而不是原地重试。
 * 3. **发现只是"顺滑"这一半**。AP 隔离、访客网络、公司 Wi-Fi 经常让组播根本到不了对端 ——
 *    所以界面上永远同时给出「手动输入对方地址」,不把发现成功当成前置条件。组播只丢一个方向
 *    的网络(2026-11-12 的 H3C)由 [LanQuDiscovery] 那条单播应答的路兜住。
 *
 * 服务名里只有短 id(`Reverb-3f2a9c1b`),设备名放在 TXT(`nm`)里:服务名要参与主机名规则,
 * 中文/空格/长度都得转义,而 TXT 原样传 UTF-8 更省事;读不到 TXT 时退回服务名也不影响连接。
 */
class LanSyncDiscovery(
    context: Context,
    private val onPeers: (List<LanSyncPeer>) -> Unit,
    private val onError: (String) -> Unit
) {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val peers = LinkedHashMap<String, LanSyncPeer>()
    private val pending = ArrayDeque<NsdServiceInfo>()
    /** 已入过队/已解析出的服务名。缓存会反复通知同一个服务,不挡一下会一直空转。 */
    private val queued = HashSet<String>()
    private var resolving = false
    private var attempt = 0
    private var timeoutTask: Runnable? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var ownServiceName = ""

    fun advertise(serviceName: String, deviceName: String, port: Int) {
        ownServiceName = serviceName
        stopAdvertising()
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = SERVICE_TYPE
            this.port = port
            // API 21 起公开的只有 `setAttribute(String, String)`(UTF-8 编码进 TXT);
            // 按字节截断交给系统,这里只限制字符数,避免一条超长 TXT 让整条广播失败。
            runCatching { setAttribute("nm", deviceName.take(32)) }
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Logger.i(TAG, "已广播 ${info.serviceName} 端口=$port")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Logger.w(TAG, "广播失败 code=$errorCode(手动输入地址仍可用)")
                onError("advertise:$errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        registration = listener
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                Logger.w(TAG, "registerService 抛错:${it.message}")
                onError("advertise:${it.javaClass.simpleName}")
            }
    }

    fun startDiscovery() {
        if (discovery != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Logger.w(TAG, "发现启动失败 code=$errorCode")
                onError("discover:$errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Logger.w(TAG, "发现停止失败 code=$errorCode")
            }

            override fun onDiscoveryStarted(serviceType: String) {
                Logger.i(TAG, "开始发现 $serviceType")
            }

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onServiceFound(info: NsdServiceInfo) {
                // 自己的广播也会被自己发现(名字冲突时系统还会改名,所以不能只比服务名):
                // 交给握手层按设备 id 再挡一次,这里先不猜。
                if (info.serviceName == ownServiceName) return
                enqueue(info)
            }

            override fun onServiceLost(info: NsdServiceInfo) {
                synchronized(lock) {
                    peers.remove(info.serviceName)
                    // 允许它下次再被发现时重新解析(地址可能变了)。
                    queued.remove(info.serviceName)
                }
                publish()
            }
        }
        discovery = listener
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure {
                discovery = null
                Logger.w(TAG, "discoverServices 抛错:${it.message}")
                onError("discover:${it.javaClass.simpleName}")
            }
    }

    fun stop() {
        stopAdvertising()
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        invalidate()
        synchronized(lock) {
            peers.clear()
            pending.clear()
            queued.clear()
            resolving = false
        }
    }

    private fun stopAdvertising() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
    }

    private fun enqueue(info: NsdServiceInfo) {
        val name = info.serviceName ?: return
        val start = synchronized(lock) {
            if (!queued.add(name)) return
            pending.addLast(info)
            if (resolving) false else {
                resolving = true
                true
            }
        }
        if (start) schedule(0)
    }

    /** 作废当前这一次尝试:迟到的回调会看到 token 不匹配而直接丢掉。 */
    private fun invalidate() {
        cancelTimeout()
        synchronized(lock) { attempt++ }
    }

    private fun schedule(delayMs: Long) {
        val token = synchronized(lock) { ++attempt }
        main.postDelayed({
            if (!valid(token)) return@postDelayed
            val next = synchronized(lock) {
                val n = pending.removeFirstOrNull()
                if (n == null) resolving = false
                n
            } ?: return@postDelayed
            resolve(token, next)
        }, delayMs)
    }

    private fun valid(token: Int): Boolean = synchronized(lock) { token == attempt }

    private fun resolve(token: Int, info: NsdServiceInfo) {
        val name = info.serviceName ?: ""
        timeoutTask = Runnable {
            if (!valid(token)) return@Runnable
            Logger.w(TAG, "解析 $name 超时(系统没回调),跳过")
            synchronized(lock) { queued.remove(name) }
            finish(token, RESOLVE_GAP_MS)
        }.also { main.postDelayed(it, RESOLVE_TIMEOUT_MS) }

        @Suppress("DEPRECATION")
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                if (!valid(token)) return
                cancelTimeout()
                Logger.w(TAG, "解析 ${info.serviceName} 失败 code=$errorCode")
                if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE) {
                    // 系统里还压着上一次没回来的 resolve(见类注释第 2 条)。多退一步再继续,
                    // 否则这一队每一项都会秒失败、面板永远是空的。
                    Logger.w(TAG, "解析槽位忙,暂停 ${ALREADY_ACTIVE_BACKOFF_MS}ms 继续")
                    finish(token, ALREADY_ACTIVE_BACKOFF_MS)
                } else {
                    finish(token, RESOLVE_GAP_MS)
                }
            }

            @Suppress("DEPRECATION")
            override fun onServiceResolved(info: NsdServiceInfo) {
                if (!valid(token)) return
                cancelTimeout()
                val host = info.host?.hostAddress
                if (host.isNullOrBlank()) {
                    Logger.w(TAG, "解析 ${info.serviceName} 没有地址")
                } else {
                    val txt = info.attributes?.get("nm")?.let { runCatching { String(it, Charsets.UTF_8) }.getOrNull() }
                    val name = txt?.trim()?.takeIf { it.isNotEmpty() } ?: info.serviceName
                    synchronized(lock) {
                        peers[info.serviceName] = LanSyncPeer(name, host, info.port)
                    }
                    Logger.i(TAG, "发现 $name $host:${info.port}")
                    publish()
                }
                finish(token, RESOLVE_GAP_MS)
            }
        }
        runCatching { nsd.resolveService(info, listener) }.onFailure {
            Logger.w(TAG, "resolveService 抛错:${it.message}")
            finish(token, RESOLVE_GAP_MS)
        }
    }

    /** 结束这一次尝试并安排下一项。先作废旧 token,避免刚结束就收到迟到的回调。 */
    private fun finish(token: Int, nextDelayMs: Long) {
        if (!valid(token)) return
        invalidate()
        schedule(nextDelayMs)
    }

    private fun cancelTimeout() {
        timeoutTask?.let { main.removeCallbacks(it) }
        timeoutTask = null
    }

    private fun publish() {
        val snapshot = synchronized(lock) { peers.values.toList() }
        onPeers(snapshot)
    }

    private companion object {
        const val TAG = "LanSync.Discovery"
        const val SERVICE_TYPE = "_reverb._tcp."

        /** 一个健康 LAN 上 resolve 通常 <300ms;2.5s 还没回调的,基本是死条目。 */
        const val RESOLVE_TIMEOUT_MS = 2_500L

        /** 两次解析之间让出一点时间,系统侧清理上一个 listener 是异步的。 */
        const val RESOLVE_GAP_MS = 150L

        /** 槽位被上一次卡死的解析占着时,再退一步 —— 既不原地空转,也不放弃整队。 */
        const val ALREADY_ACTIVE_BACKOFF_MS = 1_000L
    }
}
