import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var presenter: PlayerPresenter

    @State private var showAddSource = false
    @State private var selectedDetail: MediaItem?

    private var continueItems: [MediaItem] {
        library.items
            .filter { $0.playProgress > 5 }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    private var recentItems: [MediaItem] {
        Array(library.items.sorted { $0.addedAt > $1.addedAt }.prefix(12))
    }

    var body: some View {
        FMNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statRow
                    if library.isScanning {
                        LoadingBanner(text: library.scanStatus.isEmpty ? "正在扫描媒体库…" : library.scanStatus)
                    }
                    if !continueItems.isEmpty { continueSection }
                    if !recentItems.isEmpty { recentSection }
                    sourcesSection
                    if library.items.isEmpty && !library.isScanning { onboarding }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .fmScrollIndicatorsHidden()
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .fmHideNavigationBar()
            .background(
                Group {
                    if let detail = selectedDetail {
                        NavigationLink(
                            destination: MediaDetailView(item: detail),
                            isActive: Binding(
                                get: { selectedDetail != nil },
                                set: { if !$0 { selectedDetail = nil } }
                            )
                        ) { EmptyView() }
                        .hidden()
                    }
                }
            )
            .sheet(isPresented: $showAddSource) {
                AddSourceView()
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(FMTheme.accent)
                    Text("FM影媒")
                        .font(.system(size: 25, weight: .heavy))
                        .foregroundStyle(FMTheme.textPrimary)
                }
                Text("本机 · 媒体服务器 · 云盘 · WebDAV · SMB")
                    .font(.system(size: 11))
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Spacer()
            Button {
                Task { await library.scan(sources: database.sources) }
            } label: {
                Image(systemName: library.isScanning ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FMTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(FMTheme.surface, in: Circle())
            }
            .disabled(library.isScanning)
        }
    }

    private var statRow: some View {
        let stats = library.stats
        return HStack(spacing: 8) {
            StatTile(value: "\(stats.total)", label: "影片")
            StatTile(value: "\(stats.cracked)", label: "破解", tint: FMTheme.accent)
            StatTile(value: "\(stats.subtitled)", label: "字幕", tint: FMTheme.success)
            StatTile(value: stats.size.fileSizeText, label: "占用")
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "继续观看", subtitle: "从上次位置继续")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(continueItems) { item in
                        Button {
                            presenter.play(media: item, startAt: item.playProgress)
                        } label: {
                            WideCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                presenter.play(media: item, startAt: item.playProgress)
                            } label: {
                                Label("播放", systemImage: "play.fill")
                            }
                            Button {
                                selectedDetail = item
                            } label: {
                                Label("查看详情", systemImage: "info.circle")
                            }
                            Button(role: .destructive) {
                                library.clearProgress(itemID: item.id)
                            } label: {
                                Label("移出播放记录", systemImage: "clock.badge.xmark")
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近添加",
                          subtitle: "共 \(library.items.count) 部")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recentItems) { item in
                        NavigationLink {
                            MediaDetailView(item: item)
                        } label: {
                            PosterCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "我的来源",
                          subtitle: "\(database.sources.count) 个来源",
                          actionTitle: "添加",
                          action: { showAddSource = true })

            if database.sources.isEmpty {
                Button {
                    showAddSource = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(FMTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加第一个来源")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FMTheme.textPrimary)
                            Text("本机目录、Emby、云盘、WebDAV、SMB")
                                .font(.system(size: 11))
                                .foregroundStyle(FMTheme.textTertiary)
                        }
                        Spacer()
                    }
                    .fmCard(padding: 14)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(database.sources) { source in
                        NavigationLink {
                            FileBrowserView(source: source)
                        } label: {
                            HStack(spacing: 12) {
                                SourceIcon(kind: source.kind)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(FMTheme.textPrimary)
                                    Text(source.displayDetail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(FMTheme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(FMTheme.textTertiary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        if source.id != database.sources.last?.id {
                            Divider().background(FMTheme.separator).padding(.leading, 60)
                        }
                    }
                }
                .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开始使用 FM影媒")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FMTheme.textPrimary)
            Text("按「番号」命名整理好的文件夹导入后，会自动识别封面、大图、NFO 与预览截图，并生成智能媒体库。")
                .font(.system(size: 12))
                .foregroundStyle(FMTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showAddSource = true
            } label: {
                Text("导入本机目录 / 添加服务器").fmPrimaryButton()
            }
            .buttonStyle(.plain)
            Text("命名示例：ABC-123 / ABC-123-u（破解）/ ABC-123-c（字幕）/ ABC-123-uc")
                .font(.system(size: 11))
                .foregroundStyle(FMTheme.textTertiary)
        }
        .fmCard(padding: 16)
    }
}
