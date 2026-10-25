import SwiftUI

/// 全屏播放页:水墨波纹背景 + 封面 + 进度 + 控制 + 倍速/收藏/睡眠/印记/批注。
struct PlayerView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    var onOpenChannel: (Podcast) -> Void = { _ in }

    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var showStamps = false
    @State private var showNote = false
    /// 按下「写批注」那一下冻结的时间。不能直接显示 `player.positionMs`:它每 0.5s 跟着播放器刷新,
    /// 弹窗挂着不动就会看到时间一路往上涨,而用户要的是"我按下的那一秒"。
    @State private var notePosMs = 0
    /// 按下那一下冻结的**那一集**。`actionRow(_ ep:)` 的参数在弹层开着时会跟着换集重新算进来
    /// (自动续播、手点下一集),保存若用它,批注就挂到了下一集上 —— 而弹层里显示的时间戳
    /// 还是上一集的,这种"时间对、集错"比两处都错更难被发现(见 A2-3#11)。
    @State private var noteEpisode: Episode?
    @State private var noteDraft = ""
    @State private var momentURL: URL?
    @State private var momentArtwork: NSImage?
    /// 「保存剪藏」失败提示。取消不算失败,所以这个状态只由 `.failed` 置起(见 `ShareCardOutcome`)。
    @State private var shareCardFailed = false
    @State private var page: Int? = 0   // 轮播当前页(macOS 14+)
    @State private var noteParagraphs: [String] = []   // 简介按段拆分(解析在渲染路径外,懒排版)
    @State private var noteForEpisode: String = ""      // 上述缓存对应的单集 id

    private let sleepMinutes = [15, 30, 45, 60]
    private let seals: [(seal: String, label: String)] = [
        ("喜", "开心"), ("暖", "治愈"), ("燃", "热血"),
        ("惊", "震撼"), ("思", "沉思"), ("悟", "领悟"),
        ("悲", "难过"), ("怒", "愤怒"), ("疲", "疲惫")
    ]

    private var accent: Color { Theme.accent(env.settings.accentIndex) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let ep = player.current {
                if #available(macOS 14, *) {
                    carousel(ep)
                } else {
                    playerPage(ep)   // 老系统:仅播放页,无轮播
                }
            } else {
                Spacer()
                Text("没有正在播放的内容").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .noFocusRing()
        // 只给标题、不给正文:与设置页那三条失败提示同形,文案对齐 Android / 鸿蒙的 `share_failed`。
        .alert("分享图片生成失败", isPresented: $shareCardFailed) {
            Button("好", role: .cancel) {}
        }
    }

    // MARK: - 轮播:播放 / 简介 / 转录

    /// 横滑分页(macOS 14+)。转录页在设置开启时出现;
    /// 但发布方给了逐字稿时即使本机识别关着也要露出 —— 那只是下载一个文件,
    /// 与「要不要在这台机器上跑几分钟的识别」是两件事(对齐 Android `(AsrEngine && enabled) || transcriptUrl`)
    @available(macOS 14, *)
    private func carousel(_ ep: Episode) -> some View {
        let showTranscript = env.settings.transcriptionEnabled || !ep.transcriptUrl.isEmpty
        let count = showTranscript ? 3 : 2
        return VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    playerPage(ep).containerRelativeFrame(.horizontal).id(0)
                    showNotePage(ep).containerRelativeFrame(.horizontal).id(1)
                    if showTranscript {
                        TranscriptPage(episode: ep, accent: accent, active: (page ?? 0) == 2)
                            .containerRelativeFrame(.horizontal).id(2)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            dots(count: count).padding(.bottom, 10)
        }
    }

    private func playerPage(_ ep: Episode) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                artwork(ep)
                titleBlock(ep)
                seekBar
                controls
                actionRow(ep)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
        }
    }

    private func showNotePage(_ ep: Episode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("简介").font(.headline)
                if noteForEpisode == ep.id {
                    if noteParagraphs.isEmpty {
                        Text("暂无简介").font(.callout).foregroundStyle(.secondary)
                    } else {
                        // 按段落进 LazyVStack:只对可见段落做文本布局,长简介也不再一次性排完
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(noteParagraphs.indices, id: \.self) { i in
                                Text(noteParagraphs[i])
                                    .font(.body).foregroundStyle(.secondary).lineSpacing(3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        // 解析(正则较重)放到渲染路径外,按集缓存,避免每次横滑重跑
        .task(id: ep.id) {
            noteParagraphs = Fmt.plainText(ep.description)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            noteForEpisode = ep.id
        }
    }

    private func dots(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == (page ?? 0) ? accent : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    // 圆点此前是纯装饰:7pt 且没有点击手势,触摸板能滑、鼠标没有任何
                    // 切换入口。包一层命中区并响应点击,点击即翻页(scrollPosition 驱动)。
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard (page ?? 0) != i else { return }
                        withAnimation { page = i }
                    }
            }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .noFocusRing()
            Spacer()
            Text("正在播放").font(.headline)
            Spacer()
            Image(systemName: "chevron.down").opacity(0) // 占位居中
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    // MARK: - 封面 + 水墨波纹

    private func artwork(_ ep: Episode) -> some View {
        ZStack {
            // 仅在播放页(第 0 页)可见且播放时才让波纹流动,避免后台/横滑时空跑
            InkWave(color: accent, animating: player.isPlaying && (page ?? 0) == 0)
                .frame(height: 300)
            Artwork(url: ep.artworkUrl, size: 240, corner: 18)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }

    private func titleBlock(_ ep: Episode) -> some View {
        VStack(spacing: 6) {
            Text(ep.title).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(3)
            // 频道名:有 feedUrl 时可点,跳转频道主页(随机电台尤其有用)
            if ep.feedUrl.isEmpty {
                Text(ep.podcastTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button {
                    onOpenChannel(Podcast(id: ep.feedUrl, title: ep.podcastTitle, author: "",
                                          artworkUrl: ep.artworkUrl, feedUrl: ep.feedUrl))
                } label: {
                    Text(ep.podcastTitle)
                        .font(.callout)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .help("查看频道")
            }
        }
    }

    // MARK: - 进度

    private var seekBar: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { dragging ? dragValue : Double(player.positionMs) },
                    set: { dragValue = $0 }
                ),
                in: 0...Double(max(1, player.durationMs)),
                onEditingChanged: { editing in
                    if editing { dragging = true }
                    else { player.seek(toMs: Int(dragValue)); dragging = false }
                }
            )
            .pointingHandCursor()
            HStack {
                Text(timeText(dragging ? Int(dragValue) : player.positionMs))
                Spacer()
                Text(timeText(player.durationMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 传输控制

    private var controls: some View {
        VStack(spacing: 14) {
            if let err = player.playbackError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).foregroundStyle(.secondary)
                    Button("重试") { player.retry() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            transportRow
        }
    }

    private var transportRow: some View {
        HStack(spacing: 26) {
            controlButton("gobackward.\(min(env.settings.skipBackSec, 30))", size: 22) { player.skipBackward() }
                .help("快退")
            controlButton("backward.fill", size: 20) { player.previous() }
                .disabled(!player.hasPrev)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            controlButton("forward.fill", size: 20) { player.next() }
                .disabled(!player.hasNext)
            controlButton("goforward.\(min(env.settings.skipForwardSec, 60))", size: 22) { player.skipForward() }
                .help("快进")
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作行

    private func actionRow(_ ep: Episode) -> some View {
        HStack(spacing: 22) {
            // 倍速
            Menu {
                ForEach(player.speedSteps, id: \.self) { s in
                    Button {
                        player.setSpeed(s)
                    } label: {
                        if abs(player.speed - s) < 0.001 { Label(speedText(s), systemImage: "checkmark") }
                        else { Text(speedText(s)) }
                    }
                }
            } label: {
                Text(speedText(player.speed)).font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // 收藏
            Button {
                env.favorites.toggle(ep)
            } label: {
                Image(systemName: env.favorites.isFavorite(ep.id) ? "heart.fill" : "heart")
                    .foregroundStyle(env.favorites.isFavorite(ep.id) ? accent : .primary)
            }
            .buttonStyle(.plain)
            .help("收藏")

            // 睡眠
            Menu {
                ForEach(sleepMinutes, id: \.self) { m in
                    Button("\(m) 分钟") { player.setSleepTimer(minutes: m) }
                }
                Button("本集结束") { player.setSleepEndOfEpisode() }
                Divider()
                Button("关闭") { player.cancelSleep() }
            } label: {
                Image(systemName: sleepActive ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(sleepActive ? accent : .primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("睡眠定时")

            // 印记
            Button {
                showStamps = true
            } label: {
                Image(systemName: "seal")
                    .foregroundStyle(currentSeal != nil ? accent : .primary)
                    .overlay {
                        if let s = currentSeal {
                            Text(s).font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("听觉印记")
            .popover(isPresented: $showStamps, arrowEdge: .bottom) { stampGrid(ep) }

            // 批注:写下这一秒(与剪藏并列的"记下来"动作,不是分享动作)
            Button {
                // 时间在这里取一次:positionMs 每 0.5s 跟着播放器刷,
                // 弹窗里显示的必须是"按下那一下"的那一秒,否则打字期间它会一路往上涨。
                notePosMs = player.positionMs
                noteEpisode = ep
                noteDraft = ""
                showNote = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("写批注")
            .popover(isPresented: $showNote, arrowEdge: .bottom) {
                // 见 `noteEpisode`:弹层只认按下那一刻的集
                if let frozen = noteEpisode {
                    noteComposer(frozen)
                }
            }

            // 剪藏分享
            if let momentURL {
                ShareLink(item: momentURL) { Image(systemName: "square.and.arrow.up") }
                    .help("分享剪藏")
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }

            // 保存剪藏
            Button { saveMoment(ep) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("保存剪藏")
        }
        .padding(.top, 4)
        .task(id: ep.id) { await prepareMoment(ep) }
    }

    private func card(_ ep: Episode) -> MomentCard {
        MomentCard(episode: ep, positionMs: player.positionMs, accent: accent, artwork: momentArtwork)
    }

    private func prepareMoment(_ ep: Episode) async {
        momentURL = nil
        momentArtwork = await loadNSImage(ep.artworkUrl)
        // 延后剪藏 PNG 渲染(ImageRenderer 在主线程同步执行),让开场/横滑动画先跑完再渲染
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        momentURL = renderPNG(card(ep))
    }

    private func saveMoment(_ ep: Episode) {
        // 「取消」不提示(H147 / #99 的口径:用户按取消不是错误);只有真失败才出声。
        if saveWithPanel(card(ep), defaultName: "reverb-moment.png") == .failed { shareCardFailed = true }
    }

    private var sleepActive: Bool { player.sleepRemainingMs > 0 || player.sleepEndOfEpisode }

    private var currentSeal: String? {
        guard let ep = player.current else { return nil }
        return env.stamps.sealFor(ep.id)
    }

    private func stampGrid(_ ep: Episode) -> some View {
        let columns = Array(repeating: GridItem(.fixed(64), spacing: 10), count: 3)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(seals, id: \.seal) { item in
                let active = currentSeal == item.seal
                Button {
                    if active {
                        env.stamps.remove(ep.id)
                    } else {
                        env.stamps.set(episodeId: ep.id, seal: item.seal, title: ep.title,
                                       podcastTitle: ep.podcastTitle, at: Date().timeIntervalSince1970)
                    }
                    showStamps = false
                } label: {
                    VStack(spacing: 4) {
                        Text(item.seal).font(.system(size: 22, weight: .bold))
                        Text(LocalizedStringKey(item.label)).font(.caption2)
                    }
                    .frame(width: 60, height: 60)
                    .background(active ? accent.opacity(0.2) : Color.gray.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(active ? accent : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    // MARK: - 工具

    /// 写批注的弹层:标题是**按下那一刻**冻结的时间,正文一句话。
    ///
    /// 空文字**静默丢弃**,不弹「请输入内容」—— 与 Android / 鸿蒙同一口径:
    /// 保存按钮点了没反应就是这个界面唯一的反馈,多弹一层反而是打断。
    private func noteComposer(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("记下这一秒").font(.headline)
            Text(Fmt.clock(notePosMs))
                .font(.title3.monospacedDigit())
                .foregroundStyle(accent)
            Text(ep.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // 占位文字自己叠:TextEditor 的 `prompt:` 参数是 macOS 14 才有的,
            // 而本包的 minos 是 13 —— 用了它就等于在 13 上要么编译失败要么运行时缺符号。
            // (本机 SDK 13.1 的 typecheck 直接把这条挡下来了:报 `extra argument 'prompt' in call`。)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteDraft)
                    .font(.body)
                    .frame(width: 300, height: 96)
                if noteDraft.isEmpty {
                    Text("此刻想到什么，写下来")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
            HStack {
                Spacer()
                Button("取消") { showNote = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveNote(ep) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func saveNote(_ ep: Episode) {
        env.notes.add(ep, positionMs: notePosMs,
                      text: noteDraft, at: Int(Date().timeIntervalSince1970 * 1000))
        showNote = false
    }

    private func timeText(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func speedText(_ s: Double) -> String {
        String(format: "%.2g×", s)
    }
}

/// 水墨波纹:多条正弦色带,仅在播放时流动。
private struct InkWave: View {
    let color: Color
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animating)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let ribbons = 3
                for r in 0..<ribbons {
                    var path = Path()
                    let amp = size.height * 0.06 * Double(r + 1)
                    let yBase = size.height * (0.4 + 0.12 * Double(r))
                    let phase = t * (0.6 + 0.25 * Double(r)) + Double(r)
                    let wavelength = size.width / (1.2 + 0.4 * Double(r))
                    path.move(to: CGPoint(x: 0, y: yBase))
                    var x: CGFloat = 0
                    while x <= size.width {
                        let y = yBase + amp * sin(Double(x) / wavelength * 2 * .pi + phase)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 6
                    }
                    ctx.stroke(path, with: .color(color.opacity(0.18 - 0.04 * Double(r))),
                               lineWidth: 2.0 + Double(r))
                }
            }
        }
        .allowsHitTesting(false)
        .blur(radius: 6)
    }
}
