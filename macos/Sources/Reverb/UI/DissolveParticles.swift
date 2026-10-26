import SwiftUI

// 播放条点 X 的**粒子消散**层 —— 三端同一套物理(解析式位移),完整的形态描述与参数
// 理由见 Android 侧 `DissolveParticles.kt` 头注;这里只写本端的实现差异:
// TimelineView(.animation) 逐帧给时间,Canvas 按 t 解析式画碎片,无逐帧积分、无状态同步。
// 碎片飞出条子矩形上方几百 pt 也不被裁 —— 本层在根视图 ZStack 里铺满全窗。

private struct Shard: Identifiable {
    let id: Int
    let x0: Double, y0: Double
    let vx: Double, vy: Double
    let size: Double
    let color: Color
    let lifeMs: Double
    let delayMs: Double
}

private let dampK = 2.4  // 2026-10-26 调慢一档(原 3.2),与两端同步
private let lifeMin = 600.0, lifeMax = 1000.0  // 2026-10-26 调慢,与两端同步
private let totalMs = lifeMax + 90

/// 速度阻尼解析式的位移:∫v0·e^(−kt) = v0·(1−e^(−kt))/k。
private func dampShift(_ v0: Double, _ tSec: Double) -> Double {
    v0 * (1 - exp(-dampK * tSec)) / dampK
}

struct DissolveParticles: View {
    /// tick 变化即按 rect 重开一轮消散(0 = 无)。
    let tick: Int
    /// 条子在**窗口坐标系**(.global)里的矩形,与 NowPlayingBar 上报的同一坐标系。
    let rect: CGRect
    let primary: Color

    @State private var shards: [Shard] = []
    @State private var startAt = Date.distantPast

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let t = timeline.date.timeIntervalSince(startAt) * 1000
                guard t >= 0, !shards.isEmpty else { return }
                for s in shards {
                    let lt = t - s.delayMs
                    guard lt >= 0, lt <= s.lifeMs else { continue }
                    let prog = lt / s.lifeMs
                    // (1−p)^2.5:前段稳、末段加速消失;尺寸随寿命缩到 65%
                    let a = pow(1 - prog, 2.5)
                    guard a > 0.02 else { continue }
                    let half = s.size * (1 - 0.35 * prog) / 2
                    let x = s.x0 + dampShift(s.vx, lt / 1000) - half
                    let y = s.y0 + dampShift(s.vy, lt / 1000) - half
                    ctx.opacity = a
                    ctx.fill(Path(CGRect(x: x, y: y, width: half * 2, height: half * 2)),
                             with: .color(s.color))
                }
            }
        }
        .onChange(of: tick) { _ in
            guard rect.width > 0, rect.height > 0 else { return }
            shards = Self.spawn(rect: rect, primary: primary)
            startAt = Date()
            // 散尽后清场(免得空转 TimelineView 的重画;TimelineView 本身留着,下轮直接可用)
            DispatchQueue.main.asyncAfter(deadline: .now() + totalMs / 1000 + 0.05) {
                if Date().timeIntervalSince(startAt) * 1000 >= totalMs { shards = [] }
            }
        }
        .allowsHitTesting(false)
    }

    /// 与 Android 同密度(条高 52 ⇒ 步长 6)同分布(70% 上抛 −120°~−60°,速度 240~720/120~420)。
    private static func spawn(rect: CGRect, primary: Color) -> [Shard] {
        let step = rect.height / 8.5
        let darks = [Color(red: 0.227, green: 0.247, blue: 0.290),
                     Color(red: 0.180, green: 0.200, blue: 0.239),
                     Color(red: 0.290, green: 0.306, blue: 0.341)]
        var out: [Shard] = []
        out.reserveCapacity(1200)
        var i = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let px = x + step * 0.5, py = y + step * 0.5
                let relX = (px - rect.minX) / rect.width
                let relY = (py - rect.minY) / rect.height
                let r = Double.random(in: 0...1)
                let color: Color
                if relY < 0.06 { color = primary }
                else if relX < 0.30 { color = darks[Int(r * 3) % 3] }
                else if relX > 0.76 && r < 0.3 { color = primary }
                else { color = Color(white: 0.55, opacity: 1) }
                let up = Double.random(in: 0...1) < 0.7
                let ang = (up ? -(120 - Double.random(in: 0...60)) : Double.random(in: 0...360)) * .pi / 180
                let speed = up ? Double.random(in: 200...560) : Double.random(in: 100...320)
                out.append(Shard(id: i, x0: px, y0: py,
                                  vx: speed * cos(ang), vy: speed * sin(ang),
                                  size: step * (relX < 0.30 ? Double.random(in: 0.55...1.0)
                                                            : Double.random(in: 0.35...0.70)),
                                  color: color,
                                  lifeMs: Double.random(in: lifeMin...lifeMax),
                                  delayMs: Double.random(in: 0...60)))
                i += 1
                x += step
            }
            y += step
        }
        return out
    }
}
