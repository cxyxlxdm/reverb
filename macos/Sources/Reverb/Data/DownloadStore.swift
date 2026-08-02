import Foundation

/// 一集离线下载:原始单集元信息 + 本地文件绝对路径。
struct DownloadedEpisode: Codable, Identifiable, Hashable {
    var episode: Episode
    var localPath: String
    var id: String { episode.id }
}

/// 本地下载清单:最近置顶,持久化到 downloads.json。
@MainActor final class DownloadStore: ObservableObject {
    @Published private(set) var downloads: [DownloadedEpisode]
    init() { downloads = AppSupport.load("downloads.json", as: [DownloadedEpisode].self) ?? [] }

    func contains(_ id: String) -> Bool { downloads.contains { $0.episode.id == id } }

    /// 已下载且文件仍存在时返回本地 URL,供播放器优先本地播放。
    func localURL(_ id: String) -> URL? {
        guard let d = downloads.first(where: { $0.episode.id == id }) else { return nil }
        let url = URL(fileURLWithPath: d.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func add(_ episode: Episode, localPath: String) {
        downloads.removeAll { $0.episode.id == episode.id }
        downloads.insert(DownloadedEpisode(episode: episode, localPath: localPath), at: 0)
        persist()
    }

    func remove(_ id: String) {
        downloads.removeAll { $0.episode.id == id }
        persist()
    }

    private func persist() { AppSupport.save("downloads.json", downloads) }
}
