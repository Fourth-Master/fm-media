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
