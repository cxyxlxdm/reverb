import Foundation

/// 随包内置的精选清单(`Resources/seed_podcasts.json`,由 `shared/seed/gen-seed.py` 生成)。
///
/// 解决的问题:首次启动、清过缓存、或全程无网时,「发现」页各分类都是空白,只能干等。
/// 有了这份清单,磁盘缓存为空时先拿它顶上,首屏立刻有内容可看可点。
///
/// 它**只是兜底**:一旦 PopularCacheStore 有真实榜单就再也不用它,且**从不写入缓存**
/// —— 否则真假数据混在一起,之后无法区分"这是快照"还是"这是今天的榜"。
/// 首次访问时才解析一次;文件缺失/损坏一律退化为空(等同没有这个功能)。
final class SeedCatalog {
    private var lists: [String: [Podcast]]?
    private var generated = ""

    /// 该地区+分类的内置清单;没有则空。genreId 为 nil 表示综合推荐。
    func get(genreId: Int?, region: String) -> [Podcast] {
        load()["\(seedRegion(region)):\(genreId ?? 0)"] ?? []
    }

    /// 清单生成日期(yyyy-MM-dd)。
    func generatedAt() -> String {
        _ = load()
        return generated
    }

    // MARK: - 私有

    /// 种子只打包 cn / us 两份榜单(12 个地区全打进去没必要,它只是没网时的兜底)。
    /// 中文区落到 cn,其余一律落到 us。
    private func seedRegion(_ region: String) -> String {
        ["cn", "hk", "tw", "mo"].contains(region.lowercased()) ? "cn" : "us"
    }

    private func load() -> [String: [Podcast]] {
        if let lists { return lists }
        let parsed = parse()
        lists = parsed
        return parsed
    }

    private func parse() -> [String: [Podcast]] {
        guard let url = Self.resourceURL(),
              let data = try? Data(contentsOf: url) else {
            Log.w("Seed", "内置清单缺失,发现页退化为纯联网")
            return [:]
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["lists"] as? [String: [[String: Any]]] else {
            Log.w("Seed", "内置清单解析失败")
            return [:]
        }
        generated = (root["generatedAt"] as? String) ?? ""
        var out: [String: [Podcast]] = [:]
        for (key, entries) in raw {
            let items: [Podcast] = entries.compactMap { o in
                let feed = (o["feedUrl"] as? String) ?? ""
                guard !feed.isEmpty else { return nil }
                return Podcast(
                    id: (o["id"] as? String) ?? feed,
                    title: (o["title"] as? String) ?? "",
                    author: (o["author"] as? String) ?? "",
                    artworkUrl: (o["artworkUrl"] as? String) ?? "",
                    feedUrl: feed,
                    genre: (o["genre"] as? String) ?? ""
                    // 生成脚本已排除付费节目(点开播不了比空白更糟),故无需 isPaid
                )
            }
            if !items.isEmpty { out[key] = items }
        }
        Log.i("Seed", "内置清单就绪 \(out.count) 个榜单 生成于 \(generated)")
        return out
    }

    /// 资源查找。打包后在 `Reverb.app/Contents/Resources/`(见 package.sh);
    /// `swift run` 调试时 Bundle.main 是 .build 目录、里面没有资源,故再回落到源码树。
    private static func resourceURL() -> URL? {
        if let u = Bundle.main.url(forResource: "seed_podcasts", withExtension: "json") {
            return u
        }
        #if DEBUG
        // #filePath = <repo>/macos/Sources/Reverb/Data/SeedCatalog.swift → 上溯 4 层到 macos/
        let macosDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Data
            .deletingLastPathComponent()   // Reverb
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // macos
        let dev = macosDir.appendingPathComponent("Resources/seed_podcasts.json")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }
}
