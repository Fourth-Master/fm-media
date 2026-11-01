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
        // 底部标签栏不透明背景（iOS 15.4 上全屏播放器关闭后 tab bar 偶发变全透明），颜色随深浅模式
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x15181E) : UIColor(hex: 0xFFFFFF)
        }
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
                .preferredColorScheme(colorScheme(from: settings.data.appearance))
                .tint(FMTheme.accent)
        }
    }

    private func colorScheme(from appearance: AppearancePreference) -> ColorScheme? {
        switch appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
