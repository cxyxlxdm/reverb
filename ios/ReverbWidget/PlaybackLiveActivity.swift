import SwiftUI
import WidgetKit
import ActivityKit

/// 播放中的 **Live Activity**:锁屏卡片 + 灵动岛三档(紧凑 / 最小 / 展开)。
///
/// 与主屏「继续收听」卡片的分工:
///  - 主屏卡片回答"上次听到哪、可以接着放"(常驻,暂停时也在);
///  - Live Activity 只在**真的在放**时出现,回答"现在在放什么、放到哪"(锁屏与灵动岛)。
///    暂停后保留一段(可以就地续播),App 里结束播放时由 `PlaybackLiveActivityBridge` 撤下。
///
/// 进度条在播放态走 `ProgressView(timerInterval:)`:系统按绝对时间推进,App 被挂起也不停;
/// 暂停态改成静态百分比 —— 否则暂停期间进度条会自己往前跑。
struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Palette.of(dark: context.state.dark).bg)
                .activitySystemActionForegroundColor(Palette.of(dark: context.state.dark).text)
                .widgetURL(WidgetShared.playerURL(id: context.attributes.episodeId))
        } dynamicIsland: { context in
            let p = Palette.of(dark: context.state.dark)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    artTile(context.state, palette: p)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: ReverbLiveActivityControlIntent(.toggle)) {
                        Image(systemName: context.state.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(p.onAccent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(p.accent))
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Text(context.state.podcast)
                            .font(.system(size: 11))
                            .foregroundStyle(p.sub)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.live {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text(NSLocalizedString("直播", comment: "直播流没有时间轴"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(p.accent)
                    } else if context.state.durationMs > 0 {
                        ProgressRow(state: context.state, palette: p, compact: true)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.live ? "dot.radiowaves.left.and.right" : "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.accent)
                    .padding(.leading, 2)
            } compactTrailing: {
                if context.state.playing && !context.state.live && context.state.durationMs > 0 {
                    ProgressView(timerInterval: interval(context.state), countsDown: true)
                        .progressViewStyle(.circular)
                        .tint(p.accent)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: context.state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(p.accent)
                }
            } minimal: {
                Image(systemName: context.state.playing ? "waveform" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.accent)
            }
            .widgetURL(WidgetShared.playerURL(id: context.attributes.episodeId))
            .keylineTint(p.accent)
        }
    }

    /// 播放态用"整集的时间区间"喂系统计时器:区间起点 = 锚点减去已播时长,
    /// 终点 = 起点 + 总时长。它不随每次 update 重算,进度条因此是连续推进的。
    private func interval(_ s: PlaybackActivityAttributes.ContentState) -> ClosedRange<Date> {
        let rate = max(s.rate, 0.5)
        let elapsed = Double(s.positionMs) / 1000 / rate
        let start = s.anchor.addingTimeInterval(-elapsed)
        let end = start.addingTimeInterval(Double(s.durationMs) / 1000 / rate)
        return start...max(start.addingTimeInterval(1), end)
    }
}

// MARK: - 锁屏卡片

private struct LockScreenView: View {
    let state: PlaybackActivityAttributes.ContentState

    private var p: Palette { Palette.of(dark: state.dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artTile(state, palette: p)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Text(state.podcast)
                        .font(.system(size: 11))
                        .foregroundStyle(p.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                control(.previous, size: 15, palette: p)
                Button(intent: ReverbLiveActivityControlIntent(.toggle)) {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(p.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(p.accent))
                }
                .buttonStyle(.plain)
                control(.next, size: 15, palette: p)
            }
            if state.live {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(NSLocalizedString("直播", comment: "直播流没有时间轴"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(p.accent)
            } else if state.durationMs > 0 {
                ProgressRow(state: state, palette: p, compact: false)
            }
        }
        .padding(14)
    }

    private func control(_ command: WidgetCommand, size: CGFloat, palette: Palette) -> some View {
        Button(intent: ReverbLiveActivityControlIntent(command)) {
            Image(systemName: command == .previous ? "backward.fill" : "forward.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 进度行

private struct ProgressRow: View {
    let state: PlaybackActivityAttributes.ContentState
    let palette: Palette
    let compact: Bool

    private var end: Date {
        let rate = max(state.rate, 0.5)
        let elapsed = Double(state.positionMs) / 1000 / rate
        let start = state.anchor.addingTimeInterval(-elapsed)
        return start.addingTimeInterval(Double(state.durationMs) / 1000 / rate)
    }

    private var fraction: Double {
        guard state.durationMs > 0 else { return 0 }
        return min(max(Double(state.positionMs) / Double(state.durationMs), 0), 1)
    }

    var body: some View {
        VStack(spacing: 3) {
            if state.playing {
                ProgressView(timerInterval: state.anchor.addingTimeInterval(-Double(state.positionMs) / 1000 / max(state.rate, 0.5))...max(end, state.anchor.addingTimeInterval(1)), countsDown: false)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
            }
            HStack {
                Text(Fmt.clock(state.positionMs))
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(palette.sub)
                Spacer()
                if state.playing {
                    Text(timerInterval: Date()...max(end, Date().addingTimeInterval(1)), countsDown: true)
                        .font(.system(size: compact ? 10 : 11).monospacedDigit())
                        .foregroundStyle(palette.sub)
                } else {
                    Text("-\(Fmt.clock(max(state.durationMs - state.positionMs, 0)))")
                        .font(.system(size: compact ? 10 : 11).monospacedDigit())
                        .foregroundStyle(palette.sub)
                }
            }
        }
    }
}

// MARK: - 颜色与封面

private struct Palette {
    let bg: Color
    let text: Color
    let sub: Color
    let accent: Color
    let onAccent: Color

    static func of(dark: Bool) -> Palette {
        // 与主屏卡片、另三端同一组十六进制值(见 ReverbWidget.swift)
        dark
            ? Palette(bg: Color(hex: 0x161D20), text: Color(hex: 0xF2F2ED),
                      sub: Color(hex: 0x9AA8A6), accent: Color(hex: 0x7FD1C0),
                      onAccent: Color(hex: 0x10181A))
            : Palette(bg: Color(hex: 0xFCFAF4), text: Color(hex: 0x1B2426),
                      sub: Color(hex: 0x66716F), accent: Color(hex: 0x3F8A7C),
                      onAccent: Color(hex: 0xFFFFFF))
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// 锁屏与展开态左侧的封面。Live Activity **不读 App Group 里的封面文件**:
/// 扩展在锁屏/后台被拉起时组容器不一定已挂载,读图失败会变成一块空白;
/// 这里用同一套强调色的波形瓦片,视觉上与主屏卡片的占位一致。
private func artTile(_ state: PlaybackActivityAttributes.ContentState, palette: Palette) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.accent.opacity(state.dark ? 0.22 : 0.16))
        Image(systemName: state.live ? "dot.radiowaves.left.and.right" : "waveform")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.accent)
    }
    .frame(width: 44, height: 44)
}

/// `12:34`。扩展里拿不到 App 的 `Fmt`(它是 App 侧工具),这里只保留这一种格式。
private enum Fmt {
    static func clock(_ ms: Int) -> String {
        let total = max(ms, 0) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
