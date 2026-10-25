import Foundation
import CoreGraphics
import ImageIO

// 宿主端断言探针:直接编译**产品源码**(不是副本),对 M8/M9 的缓存做可复现判据。
// 每条「0 / 不算 / 拒绝」都配一个必须非 0 的阳性对照 —— 否则那个 0 可能只是探针没跑。
//
// 跑法见同目录 run.sh。它会把产品源码 + 本文件编成一个临时可执行文件,再起一个本地
// HTTP 服务器当音源/图源(所以不需要联网,也不会去碰真实的播客网站)。
//
// ⚠️ 判据落在**真实的** `~/Library/Application Support/Reverb/` 上(`AppSupport.dir` 不认
// `HOME` 重定向,实测)。所以:① 开头记录原有条目,收尾只删本探针新建的;
// ② 跑之前那份目录里除了 `Logs` 不该有别的东西 —— 有的话请先备份再跑。

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("PASS  \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
    else { fail += 1; print("FAIL  \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
}

let base = AppSupport.dir
let fm = FileManager.default
let before = Set((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
print("处理量: AppSupport=\(base.path) 原有条目=\(before.sorted())")

// ── 夹具 ────────────────────────────────────────────────────────────────
let env = ProcessInfo.processInfo.environment
let serverDir = URL(fileURLWithPath: env["PROBE_SRV"] ?? "/tmp/reverb-cache-probe-srv", isDirectory: true)
try? fm.createDirectory(at: serverDir, withIntermediateDirectories: true)

func pngBytes(_ w: Int, _ h: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let goodPNG = pngBytes(8, 8)
let audioBytes = Data(repeating: 0x41, count: 2000)
try? goodPNG.write(to: serverDir.appendingPathComponent("art.png"))
try? Data("not an image at all".utf8).write(to: serverDir.appendingPathComponent("bad.png"))
try? audioBytes.write(to: serverDir.appendingPathComponent("e.mp3"))
print("夹具: png=\(goodPNG.count)B audio=\(audioBytes.count)B")

// ── 1. 文件名哈希:跨进程稳定 / 不泄漏 URL ─────────────────────────────────
check("PNG 头能被 decodable 接受(阳性对照)", ArtworkCache.decodable(goodPNG), "\(goodPNG.count)B 真 PNG")
check("垃圾字节被拒", !ArtworkCache.decodable(Data("not an image at all".utf8)))
check("截断的 PNG 被拒", !ArtworkCache.decodable(goodPNG.prefix(goodPNG.count / 3)))
check("空数据被拒", !ArtworkCache.decodable(Data()))

let u1 = "https://example.com/a/cover.png"
let u2 = "https://example.com/b/cover.png"
let n1 = ArtworkCache.fileName(u1)
check("同一 URL 两次算出同一文件名", n1 == ArtworkCache.fileName(u1), n1)
check("不同 URL 算出不同文件名", n1 != ArtworkCache.fileName(u2))
check("文件名格式 art_<hex><ext>", n1.range(of: #"^art_[0-9a-f]{1,16}\.(png|webp|gif|avif|jpg)$"#, options: .regularExpression) != nil, n1)
check("文件名不含 URL 原文", !n1.contains("example") && !n1.contains("http"))
check("扩展名按内容选", ArtworkCache.fileName("https://x/y.webp?z=1").hasSuffix(".webp")
      && ArtworkCache.fileName("https://x/y").hasSuffix(".jpg"))

var names = Set<String>()
for i in 0..<1000 { names.insert(ArtworkCache.fileName("https://example.com/\(i).jpg")) }
check("1000 个不同 URL 无碰撞", names.count == 1000, "去重后 \(names.count) 个")

// ── 2. ArtworkCache 端到端(本地 HTTP 服务器) ────────────────────────────
let port = env["PROBE_PORT"] ?? "18099"
let artURL = "http://127.0.0.1:\(port)/art.png"
let badURL = "http://127.0.0.1:\(port)/bad.png"

// 扫描是 detached 起跑的;先等它把空目录扫完,否则下面 count() 的基线不准
try? await Task.sleep(nanoseconds: 300_000_000)
let artDir = base.appendingPathComponent("artwork_cache", isDirectory: true)

let got = await ArtworkCache.shared.data(for: artURL)
check("封面下载落盘", got == goodPNG, "拿回 \(got?.count ?? -1)B")
check("count()==1", await ArtworkCache.shared.count() == 1)
let artUsage = await ArtworkCache.shared.usageBytes()
check("usageBytes 计入这张图", artUsage == Int64(goodPNG.count), "\(artUsage)B")
check("目录里确实有 1 个文件", ((try? fm.contentsOfDirectory(atPath: artDir.path)) ?? []).count == 1)

// 断源之后还拿得到 → 证明走的是磁盘,不是网络
try? fm.removeItem(at: serverDir.appendingPathComponent("art.png"))
let again = await ArtworkCache.shared.data(for: artURL)
check("源文件删掉后仍命中磁盘", again == goodPNG)
check("命中不重复计数", await ArtworkCache.shared.count() == 1)

let garbage = await ArtworkCache.shared.data(for: badURL)
check("坏图片被拒(返回 nil)", garbage == nil)
check("坏图片不落盘", await ArtworkCache.shared.count() == 1,
      "目录 \(((try? fm.contentsOfDirectory(atPath: artDir.path)) ?? []).count) 个文件")

// `.part` 不计:先证明扫描看得见文件(阳性对照),再证明 .part 被排除
let partURL = artDir.appendingPathComponent("art_feedface.jpg.part")
let realURL = artDir.appendingPathComponent("art_beefcafe.jpg")
try? Data(repeating: 0x42, count: 4096).write(to: partURL)
let withPart = await ArtworkCache.shared.usageBytes()
check("阳性对照:目录里新增真实文件会被计入", withPart >= artUsage, "\(withPart)B")
check(".part 不计入", withPart == artUsage, "写 4096B 的 .part 后仍是 \(withPart)B")
try? Data(repeating: 0x43, count: 1024).write(to: realURL)
let withReal = await ArtworkCache.shared.usageBytes()
check("普通孤儿文件会计入(证明扫描不是恒 0)", withReal == withPart + 1024, "\(withReal)B")
try? fm.removeItem(at: realURL)

await ArtworkCache.shared.clear()
let afterClear = await ArtworkCache.shared.usageBytes()
let leftFiles = (try? fm.contentsOfDirectory(atPath: artDir.path)) ?? []
check("clear() 后 usageBytes==0", afterClear == 0, "\(afterClear)B")
check("clear() 后目录为空(含 .part)", leftFiles.isEmpty, "剩 \(leftFiles)")

// ── 3. AudioCacheManager 端到端 ─────────────────────────────────────────
let audio = AudioCacheManager()
try? await Task.sleep(nanoseconds: 300_000_000)
let audioDir = base.appendingPathComponent(AudioCacheStore.dirName, isDirectory: true)

let ep = Episode(
    id: "harness-ep-1",
    title: "夹具",
    description: "",
    audioUrl: "http://127.0.0.1:\(port)/e.mp3",
    artworkUrl: "",
    podcastTitle: "夹具频道"
)
audio.cache(ep)
var local: URL? = nil
for _ in 0..<200 {
    local = audio.localURL(ep.id)
    if local != nil { break }
    try? await Task.sleep(nanoseconds: 50_000_000)
}
check("首播之后整集落到本机", local != nil, local?.lastPathComponent ?? "nil")
check("落盘字节与源一致", (local.flatMap { try? Data(contentsOf: $0) })?.count == audioBytes.count,
      "\((local.flatMap { try? Data(contentsOf: $0) })?.count ?? -1)B")
check("count()==1", audio.count() == 1)
check("没有残留 .part", !((try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? []).contains { $0.hasSuffix(".part") },
      "目录 \(((try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? []))")
let audioUsage = audio.usageBytes()
check("usageBytes 计入这一集", audioUsage >= Int64(audioBytes.count), "\(audioUsage)B")

let audioPart = audioDir.appendingPathComponent("ca_feedface.mp3.part")
try? Data(repeating: 0x44, count: 8192).write(to: audioPart)
check("音频 .part 不计入", audio.usageBytes() == audioUsage, "写 8192B .part 后 \(audio.usageBytes())B")
try? fm.removeItem(at: audioPart)

// 账上有、文件没了 → 必须返回 nil(交给播放器一个不存在的路径 = 点了没反应)
try? fm.removeItem(at: local!)
check("文件被外部删掉后 localURL 返回 nil", audio.localURL(ep.id) == nil)

audio.clearAll()
let audioLeft = (try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? []
check("clearAll() 后目录为空", audioLeft.isEmpty, "剩 \(audioLeft)")
check("clearAll() 后 count==0", audio.count() == 0)

// ── 4. 清缓存的范围:只删自己那一类 ───────────────────────────────────────
let pop = PopularCacheStore()
let decoy = base.appendingPathComponent("harness_decoy.json")
try? Data("decoy".utf8).write(to: decoy)
pop.put("harnesskey", [])
let popBefore = pop.sizeBytes()
check("榜单缓存写入可见(阳性对照)", popBefore > 0, "\(popBefore)B")
let removed = pop.clear()
check("clear() 删掉 1 份榜单缓存", removed == 1, "removed=\(removed)")
check("clear() 后榜单占用归 0", pop.sizeBytes() == 0)
check("clear() 不碰无关文件", fm.fileExists(atPath: decoy.path))
try? fm.removeItem(at: decoy)

// ── 收尾:只删本探针新建的顶层条目 ──────────────────────────────────────
//
// 顺序是硬的:`AppSupport.save` 是 0.4 秒去抖的,`clearAll` 与 `put` 都还挂着待写任务。
// 先删后 flush 的话,那次写盘会把 `audio_cache.json` 之类**重新造出来** —— 第一版就踩到了,
// 目录里留下一个 2 字节的空账本。所以:flush → 等去抖窗口 → 删 → 再 flush 一遍确认没有复活。
func cleanupNew() {
    for n in Set((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).subtracting(before) {
        try? fm.removeItem(at: base.appendingPathComponent(n))
    }
}
for _ in 0..<3 {
    AppSupport.flushPending()
    try? await Task.sleep(nanoseconds: 500_000_000)
    cleanupNew()
}
let residue = Set((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).subtracting(before)
try? fm.removeItem(at: serverDir)

print("结果: pass=\(pass) fail=\(fail)  收尾后残留=\(residue.sorted())")
exit(fail == 0 && residue.isEmpty ? 0 : 1)
