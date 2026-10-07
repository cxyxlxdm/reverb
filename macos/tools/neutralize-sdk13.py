#!/usr/bin/env python3
"""
中性化 macOS 源码里「本机 SDK 13 无法解析」的 14+/26-only 依赖,
让 `swiftc -typecheck` 能走完整个模块 —— 这是本机能对 macOS 改动做的最强验收(见 AGENTS.md 的 macOS 一节 与 H128)。

用法:python3 tools/neutralize-sdk13.py <macos 目录>
只应作用于 scratch 树(基线树 + 改动树各一份),**不要在工作区上跑**。
两棵树必须跑同一份脚本,否则差分没有意义。

每一条改写都是「换掉一个本机不存在的符号」,不改控制流语义以外的任何东西;
清单与理由写在 typecheck-diff.sh 的注释里。
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
src = root / "Sources"
if not src.is_dir():
    sys.exit(f"找不到 {src}(应传 macos 目录,不是仓库根)")

changed = []


def sub(rel, old, new, label):
    """要求 old 至少命中一次;命中 0 次直接失败 —— 静默漏改会让「0 错误」变成假阳性。"""
    p = src / rel
    t = p.read_text(encoding="utf-8")
    n = t.count(old)
    if n == 0:
        sys.exit(f"NEUTRALIZE MISS [{label}] 在 {rel} 里找不到 {old[:70]!r}")
    p.write_text(t.replace(old, new), encoding="utf-8")
    changed.append(f"{label} ×{n} ({rel})")


# ① 双参数 onChange(macOS 14 起才有两参闭包)
n_onchange = 0
for f in src.rglob("*.swift"):
    t = f.read_text(encoding="utf-8")
    t2 = t.replace("{ _, new in", "{ new in").replace("{ _, _ in", "{ _ in")
    if t != t2:
        n_onchange += t.count("{ _, new in") + t.count("{ _, _ in")
        f.write_text(t2, encoding="utf-8")
if n_onchange == 0:
    sys.exit("NEUTRALIZE MISS [onChange 双参] 一处都没命中")
changed.append(f"① onChange 双参 -> 单参 ×{n_onchange}")

# ② 轮播那四个 modifier(macOS 14:containerRelativeFrame / scrollTargetLayout /
#    scrollTargetBehavior / scrollPosition)
sub("Reverb/UI/PlayerView.swift", ".containerRelativeFrame(.horizontal)", "", "② containerRelativeFrame")
sub("Reverb/UI/PlayerView.swift", "\n                .scrollTargetLayout()", "", "② scrollTargetLayout")
sub("Reverb/UI/PlayerView.swift", "\n            .scrollTargetBehavior(.paging)", "", "② scrollTargetBehavior")
sub("Reverb/UI/PlayerView.swift", "\n            .scrollPosition(id: $page)", "", "② scrollPosition")

# ③ focusEffectDisabled(macOS 14):整条 `if #available { … } else { self }` 退化成 self
sub("Reverb/UI/Theme.swift",
    "if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }",
    "self", "③ focusEffectDisabled")

# ④ themedSheet 读 @Published 字段:本机 Swift 5.7 的并发检查判它非隔离(编译期错误)
sub("Reverb/UI/Theme.swift",
    "\n    func themedSheet(_ settings: SettingsStore) -> some View {",
    "\n    @MainActor\n    func themedSheet(_ settings: SettingsStore) -> some View {",
    "④ themedSheet 加 @MainActor")

# ⑤ SettingsLink(macOS 14):保留 else 分支的 Button,把可用性判断换成恒真
sub("Reverb/RootView.swift",
    '            if #available(macOS 14.0, *) {\n'
    '                SettingsLink {\n'
    '                    Image(systemName: "gearshape")\n'
    '                }\n'
    '            } else {\n',
    "            if true {\n", "⑤ SettingsLink")

# ⑥ MainActor.assumeIsolated(macOS 14):换成 do 块,闭包体原样留下
sub("Reverb/Playback/PlayerController.swift", "MainActor.assumeIsolated {", "do {", "⑥ assumeIsolated")

# ⑦ nonisolated(unsafe) 是**语法级**依赖(Swift 5.9 语法,本机解析器连解析都过不了)
sub("Reverb/Data/Stores.swift", "nonisolated(unsafe) ", "", "⑦ nonisolated(unsafe)")

# ⑧ Transcriber:整个文件是 @available(macOS 26) 的 SpeechAnalyzer / SpeechTranscriber /
#    AssetInventory 封装。本机 SDK 13 连符号都没有,所以换成同签名的桩(类型定义照抄,
#    两个静态方法体换成最小实现);调用侧因此仍能过类型检查。
(src / "Reverb/Data/Transcriber.swift").write_text('''// 中性化桩(scratch 树专用,不是产品代码)。
// 原文件依赖 macOS 26 的 SpeechAnalyzer / SpeechTranscriber / AssetInventory,本机 SDK 13 无这些符号。
// 类型定义与两个静态方法的签名保持原样,方法体换成最小实现,好让调用侧照旧过类型检查。
import Foundation

struct TranscribedWord: Sendable, Codable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
}

struct TranscribedSegment: Sendable, Codable, Equatable {
    let text: String
    let startMs: Int
    let endMs: Int
    var words: [TranscribedWord]? = nil
}

enum Transcriber {
    enum Event: Sendable {
        case installingModel
        case volatile(String)
        case segment(TranscribedSegment)
    }

    static func resolveLocale(preferred: Locale) async -> Locale? { nil }

    static func events(fileURL: URL, locale: Locale) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
''', encoding="utf-8")
changed.append("⑧ Transcriber -> 同签名桩")

# ⑨ TranscriptStore.run():函数体只用 26-only 的 Transcriber 事件流,桩无法还原其行为,
#    所以整段换成一句赋值(两棵树同样处理 => 差分仍只反映本次改动)。
p = src / "Reverb/Data/TranscriptStore.swift"
t = p.read_text(encoding="utf-8")
marker = "    private func run(gen: Int, episodeId: String, audioURL: String, localURL: URL?, localeId: String) async {"
if marker not in t:
    sys.exit(f"NEUTRALIZE MISS [⑨ TranscriptStore.run] 找不到 {marker!r}")
i = t.index(marker)
j = t.index("{", i + len(marker) - 1)
depth, k = 0, j
while True:
    if t[k] == "{":
        depth += 1
    elif t[k] == "}":
        depth -= 1
        if depth == 0:
            break
    k += 1
body_lines = t[i:k + 1].count("\n")
p.write_text(t[:i] + marker + "\n        state = .needsMacOS26\n    }\n" + t[k + 1:], encoding="utf-8")
changed.append(f"⑨ TranscriptStore.run 函数体({body_lines} 行)-> 一句赋值")

n_class = len({c[0] for c in changed if c[0] in "①②③④⑤⑥⑦⑧⑨"})
print("\n".join("  " + c for c in changed))
print(f"NEUTRALIZED {root} 共 {n_class} 类")
