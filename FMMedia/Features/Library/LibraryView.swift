import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var subtitles: SubtitleLibrary

    @State private var showSubtitleSheet = false
    @State private var subtitleTarget: MediaItem?
    /// 搜索草稿：输入时不搜索，回车（输入法「搜索」键）或点关闭才提交
    @State private var searchDraft = ""

    private var viewMode: LibraryViewMode { settings.data.libraryViewMode }

    private var items: [MediaItem] {
        var result = library.filteredItems(filter: library.filter,
                                           sort: settings.data.librarySort,
                                           showUnrecognized: settings.data.showUnrecognizedItems)
        if settings.data.enableGenreCategories,
           let genre = library.selectedGenre,
           !genre.isEmpty {
            result = result.filter { $0.genres.contains(genre) }
        }
        return result
    }

    private var genreOptions: [String] {
        guard settings.data.enableGenreCategories else { return [] }
        var counts: [String: Int] = [:]
        for item in library.items {
            for genre in item.genres where !genre.trimmed.isEmpty {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { $0.key }.prefix(12).map { $0 }
    }

    /// 大图每行 2 个、小图每行 4 个；顶部对齐（标题完整显示时行内不参差）
    private var columns: [GridItem] {
        let count = viewMode == .small ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: count)
    }

    var body: some View {
        FMNavigationStack {
            VStack(spacing: 10) {
                FMSearchField(text: $searchDraft, onSubmit: commitSearch)
                    .padding(.horizontal, 16)
                    .onChange(of: searchDraft) { newValue in
                        // 清空关键词立即恢复全部结果；输入过程不触发搜索
                        if newValue.trimmed.isEmpty, !library.query.trimmed.isEmpty {
                            library.query = ""
                        }
                    }

                viewModePicker
                    .padding(.horizontal, 16)

                filterRow

                if !genreOptions.isEmpty {
                    genreRow
                }

                if library.isScanning {
                    LoadingBanner(text: library.scanStatus.isEmpty ? "正在扫描…" : library.scanStatus)
                        .padding(.horizontal, 16)
                }

                if items.isEmpty {
                    ScrollView {
                        EmptyStateView(icon: "film.stack",
                                       title: library.items.isEmpty ? "媒体库为空" : "没有匹配的影片",
                                       message: library.items.isEmpty
                                        ? "到「文件 → 添加来源」导入按番号命名的本机目录，或添加媒体服务器后导入媒体库。"
                                        : "试试切换筛选条件或清空搜索关键词。")
                            .padding(.top, 40)
                    }
                } else {
                    ScrollView {
                        if viewMode == .content {
                            LazyVStack(spacing: 8) {
                                ForEach(items) { item in
                                    itemCell(item) { ContentRowCard(item: item) }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 30)
                        } else {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(items) { item in
                                    itemCell(item) { PosterGridCard(item: item, compact: viewMode == .small) }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 30)
                        }
                    }
                }
            }
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("媒体库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    sortMenu
                }
                ToolbarItem(placement: .fmTrailing) {
                    Button {
                        Task { await library.scan(sources: database.sources) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(library.isScanning)
                }
            }
            .sheet(isPresented: $showSubtitleSheet) {
                if let target = subtitleTarget {
                    SubtitleSearchSheet(code: target.code,
                                        itemID: target.id,
                                        titleHint: target.displayTitle,
                                        media: target)
                }
            }
            .onAppear { searchDraft = library.query }
        }
    }

    // MARK: - 条目（含长按菜单）

    private func itemCell<Content: View>(_ item: MediaItem, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink {
            MediaDetailView(item: item)
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                presenter.play(media: item, startAt: item.playProgress)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                subtitleTarget = item
                showSubtitleSheet = true
            } label: {
                Label("搜索字幕", systemImage: "captions.bubble")
            }
            Button {
                library.toggleFavorite(item)
            } label: {
                Label(library.favorites.contains(item.id) ? "取消收藏" : "收藏",
                      systemImage: library.favorites.contains(item.id) ? "heart.slash" : "heart")
            }
        }
    }

    // MARK: - 搜索提交

    private func commitSearch() {
        library.query = searchDraft.trimmed
    }

    // MARK: - 视图模式

    private var viewModePicker: some View {
        Picker("视图", selection: Binding(
            get: { viewMode },
            set: { settings.data.libraryViewMode = $0 }
        )) {
            ForEach(LibraryViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .font(.system(size: 12))
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { filter in
                    Button {
                        library.filter = filter
                    } label: {
                        let active = library.filter == filter
                        Text(filter.title)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : FMTheme.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(active ? FMTheme.accent : FMTheme.surface,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var genreRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                genreChip(title: "全部题材", value: nil)
                ForEach(genreOptions, id: \.self) { genre in
                    genreChip(title: genre, value: genre)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func genreChip(title: String, value: String?) -> some View {
        let active = library.selectedGenre == value
        return Button {
            library.selectedGenre = value
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : FMTheme.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(active ? FMTheme.accent.opacity(0.85) : FMTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button {
                    settings.data.librarySort = sort
                } label: {
                    if settings.data.librarySort == sort {
                        Label(sort.title, systemImage: "checkmark")
                    } else {
                        Text(sort.title)
                    }
                }
            }
            Divider()
            Toggle("显示未识别条目", isOn: $settings.data.showUnrecognizedItems)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

// MARK: - 网格卡片（大图 / 小图）

struct PosterGridCard: View {
    let item: MediaItem
    /// 小图模式：字号更小，标题始终单行截断
    var compact: Bool = false
    @EnvironmentObject private var settings: AppSettings

    private var resolved: DisplayTitle {
        TitleResolver.resolve(item: item,
                              mode: settings.data.titleMode,
                              titleField: settings.data.titleField,
                              subtitleFields: settings.data.subtitleFields)
    }

    private var badges: [String] {
        item.displayBadges(showCracked: settings.data.showCrackedBadge,
                           showSubtitle: settings.data.showSubtitleBadge)
    }

    /// 小图模式默认关闭「标题完整显示」：始终单行
    private var fullTitle: Bool { !compact && settings.data.showFullTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(0.7, contentMode: .fit)
                .overlay {
                    FMImageView(ref: item.poster, cornerRadius: compact ? 7 : 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    if item.playProgress > 5 {
                        ProgressBarView(progress: item.playProgress / max(item.durationSeconds ?? 0, 1))
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !badges.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(badges.prefix(2), id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: compact ? 7 : 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(FMTheme.accent.opacity(0.92), in: Capsule())
                            }
                        }
                        .padding(5)
                    }
                }

            Text(resolved.title)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(FMTheme.textPrimary)
                .lineLimit(fullTitle ? nil : 1)
                .fixedSize(horizontal: false, vertical: fullTitle)
                .multilineTextAlignment(.leading)
            if !resolved.subtitle.isEmpty {
                Text(resolved.subtitle)
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(FMTheme.textTertiary)
                    .lineLimit(fullTitle ? nil : 1)
                    .fixedSize(horizontal: false, vertical: fullTitle)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - 内容行卡片（每行一个，完整数据源信息，高度不超过小图）

struct ContentRowCard: View {
    let item: MediaItem
    @EnvironmentObject private var settings: AppSettings

    private var resolved: DisplayTitle {
        TitleResolver.resolve(item: item,
                              mode: settings.data.titleMode,
                              titleField: settings.data.titleField,
                              subtitleFields: settings.data.subtitleFields)
    }

    private var badges: [String] {
        item.displayBadges(showCracked: settings.data.showCrackedBadge,
                           showSubtitle: settings.data.showSubtitleBadge)
    }

    /// 行高上限与小图卡片封面高度一致
    private let rowHeight: CGFloat = 108

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear
                .aspectRatio(0.7, contentMode: .fit)
                .frame(height: rowHeight)
                .overlay {
                    FMImageView(ref: item.poster, cornerRadius: 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottom) {
                    if item.playProgress > 5 {
                        ProgressBarView(progress: item.playProgress / max(item.durationSeconds ?? 0, 1))
                            .padding(.horizontal, 5)
                            .padding(.bottom, 4)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(resolved.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FMTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !resolved.subtitle.isEmpty {
                    Text(resolved.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(FMTheme.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(badges.prefix(2), id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(FMTheme.accent.opacity(0.92), in: Capsule())
                    }
                    Text(item.code)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(FMTheme.textTertiary)
                    if settings.data.enableGenreCategories, !item.genres.isEmpty {
                        Text(item.genres.prefix(2).joined(separator: " / "))
                            .font(.system(size: 9))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                    if let size = item.video?.size, size > 0 {
                        Text(size.fileSizeText)
                            .font(.system(size: 9))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: rowHeight)
    }
}
