import Foundation
import Network

/// 发现到的一台设备。`name` 优先取 TXT 里的设备名,拿不到才退回服务名。
struct LanSyncPeer: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// mDNS/DNS-SD 发现(`_reverb._tcp`)。用 Network.framework 的 NWBrowser,**不引三方库**。
///
/// 广播端在 `LanSyncController`(NWListener.Service);这里只负责"看见别人"。
/// 两条容易踩的坑与 Android 那边同源:
/// 1. **发现只是"顺滑"这一半**。AP 隔离、访客网络、公司 Wi-Fi 经常让组播根本到不了对端 ——
///    所以界面上永远同时给出「手动输入对方地址」,不把发现成功当成前置条件。
/// 2. 解析主机名/端口交给连接本身(`NWConnection(to: endpoint)`),这里不猜 IP:
///    先解析再连接会多一次超时窗口,而连接失败本来就要给用户一句能看懂的话。
final class LanSyncDiscovery {
    private let queue = DispatchQueue(label: "cn.cxyxl.reverb.lansync.browser")
    private var browser: NWBrowser?
    private var peers: [String: LanSyncPeer] = [:]
    private let onPeers: @MainActor ([LanSyncPeer]) -> Void
    private let onError: @MainActor (String) -> Void

    init(onPeers: @escaping @MainActor ([LanSyncPeer]) -> Void,
         onError: @escaping @MainActor (String) -> Void) {
        self.onPeers = onPeers
        self.onError = onError
    }

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_reverb._tcp", domain: nil), using: params)
        browser = b
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                Log.w("LanSync.Discovery", "发现不可用:\(error.localizedDescription)(手动输入地址仍可用)")
                Task { @MainActor in self.onError(error.localizedDescription) }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var map: [String: LanSyncPeer] = [:]
            for r in results {
                guard case let .service(serviceName, _, _, _) = r.endpoint else { continue }
                // 自己的广播也会被自己发现(名字冲突时系统还会改名,所以不能只比服务名):
                // 交给握手层按设备 id 再挡一次,这里不猜。
                var display = serviceName
                if case let .bonjour(txt) = r.metadata, let nm = txt["nm"]?.trimmingCharacters(in: .whitespacesAndNewlines), !nm.isEmpty {
                    display = nm
                }
                map[serviceName] = LanSyncPeer(id: serviceName, name: display, endpoint: r.endpoint)
            }
            self.peers = map
            let list = map.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self.onPeers(list) }
        }
        b.start(queue: queue)
        Log.i("LanSync.Discovery", "开始发现 _reverb._tcp")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        peers.removeAll()
        let empty: [LanSyncPeer] = []
        Task { @MainActor [onPeers] in onPeers(empty) }
    }
}
