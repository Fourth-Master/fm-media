import UIKit

/// 运行时横竖屏切换（iOS 15 用 UIDevice，16+ 用几何更新）
enum OrientationManager {
    static func toggle() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        // 横屏状态下左右翻转（上下横屏切换），竖屏进入右横屏
        switch scene.interfaceOrientation {
        case .landscapeLeft:
            set(.landscapeRight)
        case .landscapeRight:
            set(.landscapeLeft)
        default:
            set(.landscapeRight)
        }
    }

    static func set(_ mask: UIInterfaceOrientationMask) {
        if #available(iOS 16.0, *) {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
                UIViewController.attemptRotationToDeviceOrientation()
                return
            }
        }
        let value: Int
        switch mask {
        case .landscapeLeft:
            value = UIInterfaceOrientation.landscapeLeft.rawValue
        case .landscapeRight:
            value = UIInterfaceOrientation.landscapeRight.rawValue
        default:
            value = UIInterfaceOrientation.portrait.rawValue
        }
        UIDevice.current.setValue(value, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
