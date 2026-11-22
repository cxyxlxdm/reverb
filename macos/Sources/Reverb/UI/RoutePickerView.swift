import SwiftUI
import AVKit

/// 桌面端的 AirPlay 选路按钮。
///
/// 不用自绘:系统这个控件自己负责枚举可投放的扬声器 / Apple TV,并维护选中状态。
/// 桌面这份与 iOS 那份是同一个 `AVRoutePickerView`,差别只在 API(macOS 走
/// `setRoutePickerButtonColor:forState:`,且必须把 `player` 交给它才知道给谁换路由)。
struct AirPlayRouteButton: NSViewRepresentable {
    var player: AVPlayer?
    var tint: NSColor = .secondaryLabelColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        apply(v)
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        v.player = player
        apply(v)
    }

    private func apply(_ v: AVRoutePickerView) {
        v.setRoutePickerButtonColor(tint, for: .normal)
        v.setRoutePickerButtonColor(tint, for: .normalHighlighted)
        v.setRoutePickerButtonColor(tint, for: .active)
        v.setRoutePickerButtonColor(tint, for: .activeHighlighted)
    }
}
