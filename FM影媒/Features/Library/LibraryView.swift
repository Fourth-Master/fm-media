import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var subtitles: SubtitleLibrary

    @State private var showSubtitleSheet = false
    @State private var subtitleTarget: MediaItem?

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

    private var columns: [GridItem] {
        let count = max(2, min(6, settings.data.gridColumns))
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        FMNavigationStack {
            VStack(spacing: 10) {
                FMSearchField(text: $library.query)
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
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(items) { item in
                                NavigationLink {
                                    MediaDetailView(item: item)
                                } label: {
                                    PosterGridCard(item: item)
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
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 30)
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
        }
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

                Button {
                    settings.data.gridColumns = settings.data.gridColumns >= 5 ? 2 : settings.data.gridColumns + 1
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FMTheme.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(FMTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
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

// MARK: - 网格卡片

struct PosterGridCard: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(0.7, contentMode: .fit)
                .overlay {
                    FMImageView(ref: item.poster, cornerRadius: 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                    .font(.system(size: 8, weight: .bold))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FMTheme.textPrimary)
                .lineLimit(settings.data.showFullTitle ? nil : 1)
                .fixedSize(horizontal: false, vertical: settings.data.showFullTitle)
                .multilineTextAlignment(.leading)
            if !resolved.subtitle.isEmpty {
                Text(resolved.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
                    .lineLimit(settings.data.showFullTitle ? nil : 1)
                    .fixedSize(horizontal: false, vertical: settings.data.showFullTitle)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
