import SwiftUI
import UIKit

@main
struct FMApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var database = AppDatabase()
    @StateObject private var library = LibraryStore()
    @StateObject private var transfers = TransferManager()
    @StateObject private var presenter = PlayerPresenter()
    @StateObject private var subtitles = SubtitleLibrary.shared

    init() {
        // iOS 15 的 List 默认有系统底色，这里统一改为透明
        UITableView.appearance().backgroundColor = .clear
        // 底部标签栏固定不透明背景：iOS 15.4 上全屏播放器关闭后 tab bar 偶发变全透明
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(red: 0x15 / 255.0, green: 0x18 / 255.0, blue: 0x1E / 255.0, alpha: 1)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(database)
                .environmentObject(library)
                .environmentObject(transfers)
                .environmentObject(presenter)
                .environmentObject(subtitles)
                .preferredColorScheme(.dark)
                .tint(FMTheme.accent)
        }
    }
}
