import Foundation

/// 搜索历史:发现页搜索框的本地小账本(`Application Support/Reverb/search_history.json`)。
///
/// 它服务的是**输入体验**,不是用户资产 —— 所以**不进备份、不走局域网同步**:
/// 换机 / 重装后为空是可以接受的,而给一份历史记录开同步协议(还要管删除传播的墓碑)
/// 与它带来的价值不成比例。口径写在 `docs/FEATURES.md` 搜索一节。
///
/// 只在用户**真正发起搜索**时写入一次(键盘搜索键 / 点历史条目 / 语音识别完成),
/// 每条都先 trim,重复的提到最前,最多留 [limit] 条。
@MainActor final class SearchHistoryStore: ObservableObject {
    static let limit = 20
    /// 单条最长长度:语音识别偶尔会吐一长串,存下来只会把列表撑爆;截断比拒绝友好。
    private static let maxLength = 100

    @Published private(set) var items: [String]

    init() {
        items = AppSupport.load("search_history.json", as: [String].self) ?? []
        // 手工改坏文件时也别让界面带着超限/空白条目启动,读进来就按写入规则归一化一次。
        items = Self.normalized(items)
    }

    /// 记一次搜索。空串与只有空白的直接忽略(与 `runSearch` 的 guard 同一条口径)。
    func record(_ raw: String) {
        let q = Self.clean(raw)
        guard !q.isEmpty else { return }
        items.removeAll { $0 == q }
        items.insert(q, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    func remove(_ query: String) {
        let before = items.count
        items.removeAll { $0 == query }
        guard items.count != before else { return }
        persist()
    }

    /// 批量删除 = 清空全部。界面会给一次二次确认。
    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
    }

    private func persist() { AppSupport.save("search_history.json", items) }

    private static func clean(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(maxLength))
    }

    private static func normalized(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let q = clean(raw)
            guard !q.isEmpty, !seen.contains(q) else { continue }
            seen.insert(q)
            out.append(q)
            if out.count == limit { break }
        }
        return out
    }
}
