import UIKit

/// 运行时横竖屏切换（iOS 15 用 UIDevice，16+ 用几何更新）
enum OrientationManager {
    static func toggle() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let landscape = scene.interfaceOrientation.isLandscape
        set(landscape ? .portrait : .landscapeRight)
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
        case .landscape, .landscapeRight, .allButUpsideDown:
            value = UIInterfaceOrientation.landscapeRight.rawValue
        default:
            value = UIInterfaceOrientation.portrait.rawValue
        }
        UIDevice.current.setValue(value, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
