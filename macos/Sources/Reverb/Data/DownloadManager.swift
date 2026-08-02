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
              let url = URL(string: ep.audioUrl) else { return }
        active.insert(ep.id)
        progress[ep.id] = 0
        let task = session.downloadTask(with: url)
        episodesByTask[task.taskIdentifier] = ep
        task.resume()
    }

    /// 删除本地文件 + 清单条目。
    func delete(_ id: String) {
        if let url = store.localURL(id) { try? FileManager.default.removeItem(at: url) }
        store.remove(id)
        progress[id] = nil
        active.remove(id)
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
    }

    private func finalize(taskId: Int, staging: URL, ext: String, moved: Bool) {
        guard let ep = episodesByTask.removeValue(forKey: taskId) else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        active.remove(ep.id)
        progress[ep.id] = nil
        guard moved else { return }
        let dir = Self.downloadsDirectory()
        let final = dir.appendingPathComponent("\(Self.sanitize(ep.id)).\(ext)")
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: staging, to: final)
            store.add(ep, localPath: final.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
        }
    }

    private func fail(taskId: Int) {
        guard let ep = episodesByTask.removeValue(forKey: taskId) else { return }
        active.remove(ep.id)
        progress[ep.id] = nil
    }

    // MARK: - 非隔离工具(委托线程可用)

    nonisolated private static func downloadsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("Reverb/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
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
        guard error != nil else { return } // 成功由 didFinishDownloadingTo 处理
        let taskId = task.taskIdentifier
        Task { @MainActor in self.fail(taskId: taskId) }
    }
}
