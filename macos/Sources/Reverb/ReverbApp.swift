import SwiftUI

@main
struct ReverbApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
    }
}
