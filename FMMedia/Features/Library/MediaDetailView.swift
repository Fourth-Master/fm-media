import SwiftUI
import UniformTypeIdentifiers

struct MediaDetailView: View {
    let item: MediaItem

    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var subtitles: SubtitleLibrary
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var settings: AppSettings

    @State private var showSubtitleSearch = false
    @State private var showPreviewGallery = false
    @State private var showImportSubtitle = false

    private var current: MediaItem {
        library.item(id: item.id) ?? item
    }

    private var resumePosition: Double {
        settings.data.resumePlayback ? current.playProgress : 0
    }

    private var resolvedTitle: DisplayTitle {
        TitleResolver.resolve(item: current,
                              mode: settings.data.titleMode,
                              titleField: settings.data.titleField,
                              subtitleFields: settings.data.subtitleFields)
    }

    private var subtitleRecords: [SubtitleLibrary.Record] {
        subtitles.records(for: current.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                actionRow
                metaRow
                if !current.plot.isEmpty { plotSection }
                if !current.previews.isEmpty { previewSection }
                subtitleSection
                if !current.actors.isEmpty { actorsSection }
                infoSection
            }
            .padding(.bottom, 32)
        }
        .fmScrollIndicatorsHidden()
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(current.code)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .fmTrailing) {
                Button {
                    library.toggleFavorite(current)
                } label: {
                    Image(systemName: library.favorites.contains(current.id) ? "heart.fill" : "heart")
                        .foregroundStyle(library.favorites.contains(current.id) ? FMTheme.accent : FMTheme.textPrimary)
                }
            }
        }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchSheet(code: current.code,
                                itemID: current.id,
                                titleHint: current.displayTitle,
                                media: current)
        }
        .sheet(isPresented: $showPreviewGallery) {
            PreviewGallery(images: current.previews)
        }
        .fileImporter(isPresented: $showImportSubtitle,
                      allowedContentTypes: subtitleTypes,
                      allowsMultipleSelection: false) { result in
            handleSubtitleImport(result)
        }
    }

    private var subtitleTypes: [UTType] {
        let extensions = ["srt", "ass", "ssa", "vtt", "sub", "smi"]
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.plainText] : types
    }

    // MARK: - 头部

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            FMImageView(ref: current.bestArtwork, cornerRadius: 0)
                .frame(height: 250)
                .clipped()
            LinearGradient(colors: [.clear, FMTheme.background.opacity(0.65), FMTheme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 250)

            HStack(alignment: .bottom, spacing: 14) {
                FMImageView(ref: current.poster, cornerRadius: 10)
                    .frame(width: 96, height: 136)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text(resolvedTitle.title)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(settings.data.showFullTitle ? nil : 2)
                        .fixedSize(horizontal: false, vertical: settings.data.showFullTitle)
                    HStack(spacing: 6) {
                        Text(current.code)
                        if !resolvedTitle.subtitle.isEmpty {
                            Text("·")
                            Text(resolvedTitle.subtitle)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(FMTheme.textSecondary)
                    HStack(spacing: 5) {
                        ForEach(current.displayBadges(showCracked: settings.data.showCrackedBadge, showSubtitle: settings.data.showSubtitleBadge), id: \.self) { badge in
                            FMTag(text: badge,
                                  color: badge == "破解" ? FMTheme.accent : FMTheme.success)
                        }
                    }
                    HStack(spacing: 10) {
                        if let year = current.year {
                            Text("\(year)")
                        }
                        if let rating = current.rating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(FMTheme.warning)
                        }
                        if let runtime = current.runtimeMinutes, runtime > 0 {
                            Text("\(runtime) 分钟")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(FMTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .frame(height: 250)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            Button {
                presenter.play(media: current, startAt: resumePosition)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(resumePosition > 5 ? "继续播放 \(Double(resumePosition).timecode)" : "立即播放")
                }
                .fmPrimaryButton()
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                smallAction(icon: "captions.bubble", title: "搜索字幕") {
                    showSubtitleSearch = true
                }
                smallAction(icon: "square.and.arrow.down", title: "导入字幕") {
                    showImportSubtitle = true
                }
                smallAction(icon: library.favorites.contains(current.id) ? "heart.fill" : "heart",
                            title: "收藏") {
                    library.toggleFavorite(current)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func smallAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(FMTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if !current.studio.isEmpty {
                infoChip(current.studio)
            }
            ForEach(current.genres.prefix(3), id: \.self) { genre in
                infoChip(genre)
            }
            if let size = current.video?.size, size > 0 {
                infoChip(size.fileSizeText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func infoChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(FMTheme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(FMTheme.surface, in: Capsule())
    }

    private var plotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "简介")
            Text(current.plot)
                .font(.system(size: 13))
                .foregroundStyle(FMTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "预览截图", subtitle: "\(current.previews.count) 张")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(current.previews.prefix(12).indices), id: \.self) { index in
                        Button {
                            showPreviewGallery = true
                        } label: {
                            FMImageView(ref: current.previews[index], cornerRadius: 8)
                                .frame(width: 140, height: 84)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "字幕",
                          subtitle: "\(current.subtitles.count + subtitleRecords.count) 个可用",
                          actionTitle: "在线搜索",
                          action: { showSubtitleSearch = true })

            if current.subtitles.isEmpty && subtitleRecords.isEmpty {
                Text("暂无字幕。可使用迅雷字幕 / SubtitleCat 在线搜索，或导入本地字幕文件。")
                    .font(.system(size: 12))
                    .foregroundStyle(FMTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(current.subtitles) { file in
                        subtitleRow(name: file.name, detail: file.size.fileSizeText, source: "同目录")
                    }
                    ForEach(subtitleRecords) { record in
                        subtitleRow(name: record.name,
                                    detail: record.addedAt.dayText,
                                    source: record.source)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func subtitleRow(name: String, detail: String, source: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .foregroundStyle(FMTheme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FMTheme.textPrimary)
                    .lineLimit(1)
                Text("\(source) · \(detail)")
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var actorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "演员")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(current.actors.prefix(20)) { actor in
                        VStack(spacing: 5) {
                            FMImageView(ref: actor.thumb, cornerRadius: 26)
                                .frame(width: 52, height: 52)
                            Text(actor.name)
                                .font(.system(size: 10))
                                .foregroundStyle(FMTheme.textSecondary)
                                .lineLimit(1)
                                .frame(width: 62)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "文件信息")
            VStack(spacing: 0) {
                if let video = current.video {
                    detailRow("视频文件", video.name)
                    detailRow("文件大小", video.size > 0 ? video.size.fileSizeText : "—")
                }
                if !current.releaseDate.isEmpty {
                    detailRow("发行日期", current.releaseDate)
                }
                if let nfo = current.nfoPath {
                    detailRow("NFO", (nfo as NSString).lastPathComponent)
                }
                detailRow("所在目录", current.folderPath)
                if let source = database.source(id: current.sourceID) {
                    detailRow("来源", source.name)
                }
            }
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(FMTheme.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(FMTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func handleSubtitleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let destination = FileStore.uniqueDestination(for: url.lastPathComponent, in: FileStore.subtitles)
            try? data.write(to: destination, options: .atomic)
            subtitles.add(itemID: current.id, fileURL: destination, name: destination.lastPathComponent, source: "手动导入")
        case .failure:
            break
        }
    }
}

// MARK: - 预览图浏览

struct PreviewGallery: View {
    let images: [ImageRef]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        FMNavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TabView(selection: $index) {
                    ForEach(Array(images.indices), id: \.self) { offset in
                        FMImageView(ref: images[offset], contentMode: .fit, cornerRadius: 0)
                            .tag(offset)
                            .padding(.vertical, 20)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
            .navigationTitle("\(index + 1) / \(images.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
