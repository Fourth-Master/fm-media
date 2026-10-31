import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transfers: TransferManager
    @EnvironmentObject private var presenter: PlayerPresenter

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }

            LibraryView()
                .tabItem { Label("媒体库", systemImage: "square.grid.2x2.fill") }

            FilesView()
                .tabItem { Label("文件", systemImage: "folder.fill") }

            TransfersView()
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down.circle.fill") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(FMTheme.accent)
        .fullScreenCover(item: $presenter.request) { request in
            PlayerScreen(request: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fmPlayerProgress)) { notification in
            guard let itemID = notification.userInfo?["itemID"] as? String,
                  let seconds = notification.userInfo?["seconds"] as? Double else { return }
            library.updateProgress(itemID: itemID, seconds: seconds)
        }
        .onAppear {
            transfers.maxConcurrent = settings.data.maxConcurrentTransfers
            presenter.database = database
            autoScanIfNeeded()
        }
        .onChange(of: settings.data.maxConcurrentTransfers) { newValue in
            transfers.maxConcurrent = newValue
        }
    }

    private func autoScanIfNeeded() {
        guard settings.data.autoScanOnLaunch else { return }
        guard !database.sources.isEmpty else { return }
        // 版本升级后强制重扫，保证标题/原名等新字段生效
        let versionChanged = library.lastScanAppVersion != LibraryStore.currentAppVersion
        if !versionChanged, let last = library.lastScan, Date().timeIntervalSince(last) < 300 { return }
        Task {
            await library.scan(sources: database.sources, force: versionChanged)
            settings.data.lastLibraryScan = Date()
        }
    }
}
