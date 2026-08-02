import SwiftUI

/// 设置:外观 / 内容 / 播放。
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        SettingsForm(settings: env.settings, player: env.player)
    }
}

private struct SettingsForm: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: PlayerController

    private let themeNames = ["跟随系统", "浅色", "深色", "纯白"]
    private let regions: [(code: String, name: String)] = [
        ("", "自动"), ("cn", "中国大陆"), ("hk", "中国香港"), ("tw", "中国台湾"),
        ("us", "美国"), ("jp", "日本"), ("kr", "韩国"), ("gb", "英国")
    ]
    private let skipBackOptions = [5, 10, 15, 30]
    private let skipForwardOptions = [15, 30, 45, 60]

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.themeMode) {
                    ForEach(0..<themeNames.count, id: \.self) { Text(themeNames[$0]).tag($0) }
                }
                Picker("配色", selection: $settings.accentIndex) {
                    ForEach(0..<Theme.accents.count, id: \.self) { i in
                        Text(Theme.accents[i].name).tag(i)
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.fontScale * 100))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.fontScale, in: 0.85...1.3, step: 0.05)
                }
            }

            Section("内容") {
                Picker("地区", selection: $settings.regionOverride) {
                    ForEach(regions, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("电台模式", selection: $settings.contextualRadio) {
                    Text("随机").tag(false)
                    Text("情境").tag(true)
                }
            }

            Section("播放") {
                Picker("默认倍速", selection: Binding(
                    get: { settings.defaultSpeed },
                    set: { settings.defaultSpeed = $0; player.setSpeed($0) }
                )) {
                    ForEach(player.speedSteps, id: \.self) { s in
                        Text(String(format: "%g×", s)).tag(s)
                    }
                }
                Picker("快退", selection: $settings.skipBackSec) {
                    ForEach(skipBackOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Picker("快进", selection: $settings.skipForwardSec) {
                    ForEach(skipForwardOptions, id: \.self) { Text("\($0) 秒").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }
}
