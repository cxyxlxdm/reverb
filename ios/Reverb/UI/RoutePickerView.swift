import SwiftUI
import AVKit

/// 手机端的 AirPlay 选路按钮。系统控件自己枚举可投放设备并维护选中态;
/// 路由对象是系统音频栈,`AVPlayer` 在出声就够,iOS 这份不需要显式绑定 player。
struct AirPlayRouteButton: UIViewRepresentable {
    var tint: UIColor = .secondaryLabel

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = tint
        v.activeTintColor = tint
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {
        v.tintColor = tint
        v.activeTintColor = tint
    }
}
