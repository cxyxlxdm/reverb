// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reverb",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Reverb", targets: ["Reverb"]),
        // 「继续收听」卡片扩展。它不是独立 App:bin 产物由 package.sh 装进
        // Reverb.app/Contents/PlugIns/ReverbWidget.appex(见那里的注释)。
        .executable(name: "ReverbWidget", targets: ["ReverbWidget"])
    ],
    targets: [
        // App 与扩展**共用的数据契约**。两边各是一个进程、各编各的,契约必须只有一份,
        // 否则字段一改就静默错位(与 Android / 鸿蒙的「App 写、卡片读」同一条边界)。
        .target(
            name: "WidgetContract",
            path: "Sources/WidgetContract"
        ),
        .executableTarget(
            name: "Reverb",
            dependencies: ["WidgetContract"],
            path: "Sources/Reverb"
        ),
        .executableTarget(
            name: "ReverbWidget",
            dependencies: ["WidgetContract"],
            path: "Sources/ReverbWidget"
        )
    ]
)
