import Foundation

/// 离线下载管理:URLSession 下载任务 + 进度上报,完成后写入 DownloadStore。
/// @MainActor 隔离,委托回调在后台线程触发后跳回主线程更新 @Published 状态。
@MainActor final class DownloadManager: NSObject, ObservableObject {
    /// episodeId -> 0…1 进度。
    @Published private(set) var progress: [String: Double] = [:]
    /// 正在下载的 episodeId 集合。
    @Published private(set) var active: Set<String> = []

    private let store: DownloadStore
    private var episodesByTask: [Int: Episode] = [:]
    /// episodeId -> 已记录的进度里程碑(25/50/75),避免重复打点。
    private var loggedMilestone: [String: Int] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init(store: DownloadStore) {
        self.store = store
        super.init()
    }

    func isDownloading(_ id: String) -> Bool { active.contains(id) }

    /// 开始下载。已下载或正在下载则忽略。
    func download(_ ep: Episode) {
        guard !store.contains(ep.id), !active.contains(ep.id),
              let url = URL(string: ep.audioUrl) else {
            Log.d("Download", "download 跳过 id=\(ep.id)(已下载/进行中/URL 无效)")
            return
        }
        Log.i("Download", "开始下载 id=\(ep.id) title=\"\(ep.title)\" url=\(ep.audioUrl)")
        active.insert(ep.id)
        progress[ep.id] = 0
        loggedMilestone[ep.id] = 0
        let task = session.downloadTask(with: url)
        episodesByTask[task.taskIdentifier] = ep
        task.resume()
    }

    /// 删除本地文件 + 清单条目。
    func delete(_ id: String) {
        Log.i("Download", "删除下载 id=\(id)")
        if let url = store.localURL(id) { try? FileManager.default.removeItem(at: url) }
        store.remove(id)
        progress[id] = nil
        active.remove(id)
        loggedMilestone[id] = nil
    }

    /// 已下载文件占用的总字节数。
    func usageBytes() -> Int {
        var total = 0
        for d in store.downloads {
            let url = URL(fileURLWithPath: d.localPath)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += size }
        }
        return total
    }

    // MARK: - 内部(主线程)

    private func updateProgress(taskId: Int, value: Double) {
        guard let ep = episodesByTask[taskId] else { return }
        progress[ep.id] = value
        // 在 25/50/75 里程碑各记录一次。
        let pct = Int(value * 100)
        let milestone = (pct / 25) * 25
        if milestone > 0, milestone < 100, (loggedMilestone[ep.id] ?? 0) < milestone {
            loggedMilestone[ep.id] = milestone
            Log.d("Download", "进度 \(milestone)% id=\(ep.id)")
        }
    }

    private func finalize(taskId: Int, staging: URL, ext: String, moved: Bool) {
        guard let ep = episodesByTask.removeValue(forKey: taskId) else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        active.remove(ep.id)
        progress[ep.id] = nil
        loggedMilestone[ep.id] = nil
        guard moved else {
            Log.e("Download", "完成但暂存文件缺失 id=\(ep.id)")
            return
        }
        let dir = Self.downloadsDirectory()
        let final = dir.appendingPathComponent("\(Self.sanitize(ep.id)).\(ext)")
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: staging, to: final)
            let bytes = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            store.add(ep, localPath: final.path)
            Log.i("Download", "完成 id=\(ep.id) bytes=\(bytes) path=\(final.path)")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            Log.e("Download", "归档失败 id=\(ep.id)", error: error)
        }
    }

    private func fail(taskId: Int, errorText: String) {
        guard let ep = episodesByTask.removeValue(forKey: taskId) else { return }
        active.remove(ep.id)
        progress[ep.id] = nil
        loggedMilestone[ep.id] = nil
        Log.e("Download", "下载失败 id=\(ep.id) error=\(errorText)")
    }

    // MARK: - 非隔离工具(委托线程可用)

    nonisolated private static func downloadsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Reverb/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        AppSupport.excludeFromBackup(d)
        return d
    }

    nonisolated private static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let s = String(mapped)
        return s.isEmpty ? UUID().uuidString : String(s.prefix(80))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 临时文件在回调返回后即被删除,必须同步搬到暂存文件,再回主线程归档。
        let taskId = downloadTask.taskIdentifier
        let raw = downloadTask.originalRequest?.url?.pathExtension ?? ""
        let ext = raw.isEmpty ? "m4a" : raw
        let dir = Self.downloadsDirectory()
        let staging = dir.appendingPathComponent("staging-\(taskId).\(ext)")
        try? FileManager.default.removeItem(at: staging)
        let moved = (try? FileManager.default.moveItem(at: location, to: staging)) != nil
        Task { @MainActor in self.finalize(taskId: taskId, staging: staging, ext: ext, moved: moved) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in self.updateProgress(taskId: taskId, value: p) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return } // 成功由 didFinishDownloadingTo 处理
        let taskId = task.taskIdentifier
        let errorText = String(describing: error)
        Task { @MainActor in self.fail(taskId: taskId, errorText: errorText) }
    }
}
