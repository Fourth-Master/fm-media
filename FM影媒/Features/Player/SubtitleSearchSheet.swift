import SwiftUI

struct SubtitleSearchSheet: View {
    let code: String
    let itemID: String
    let titleHint: String
    var media: MediaItem? = nil
    var onApply: ((URL) -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var subtitles: SubtitleLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var results: [SubtitleSearchResult] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var downloadingID: String?
    @State private var appliedName: String?

    init(code: String,
         itemID: String,
         titleHint: String,
         media: MediaItem? = nil,
         onApply: ((URL) -> Void)? = nil) {
        self.code = code
        self.itemID = itemID
        self.titleHint = titleHint
        self.media = media
        self.onApply = onApply
        _query = State(initialValue: code)
    }

    var body: some View {
        FMNavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    FMSearchField(text: $query, placeholder: "输入番号搜索字幕")
                    Button {
                        Task { await search() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(FMTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isSearching)
                }
                .padding(.horizontal, 16)

                if isSearching {
                    LoadingBanner(text: "正在搜索迅雷字幕与 SubtitleCat…")
                        .padding(.horizontal, 16)
                }

                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(appliedName == nil ? FMTheme.textTertiary : FMTheme.success)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }

                List {
                    if results.isEmpty && !isSearching {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("没有找到字幕")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FMTheme.textSecondary)
                                Text("可能原因：番号不准确、字幕站暂时不可用，或该字幕为压缩包格式。也可以先下载字幕文件后用「导入字幕」加载。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(FMTheme.textTertiary)
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    ForEach(results) { result in
                        Button {
                            Task { await apply(result) }
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                        .disabled(downloadingID != nil)
                    }
                }
                .listStyle(.plain)
                .fmScrollContentBackgroundHidden()
            }
            .padding(.top, 8)
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("搜索字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if results.isEmpty { await search() }
            }
        }
    }

    private func resultRow(_ result: SubtitleSearchResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble.fill")
                .foregroundStyle(FMTheme.success)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FMTheme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(result.provider)
                        .foregroundStyle(FMTheme.accent)
                    Text(result.language)
                    Text(result.format)
                    if !result.note.isEmpty {
                        Text(result.note)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(FMTheme.textTertiary)
            }
            Spacer()
            if downloadingID == result.id {
                ProgressView().controlSize(.small).tint(FMTheme.textSecondary)
            } else if appliedName != nil && result.title.contains(appliedName?.deletingPathExtension ?? "") {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FMTheme.success)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(FMTheme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func search() async {
        let keyword = query.trimmed
        guard !keyword.isEmpty else { return }
        isSearching = true
        message = nil
        appliedName = nil
        let options = SubtitleSearchService.SearchOptions(
            xunleiEnabled: settings.data.xunleiSubtitleEnabled,
            subtitlecatEnabled: settings.data.subtitlecatEnabled,
            language: settings.data.preferredSubtitleLanguage
        )
        let found = await SubtitleSearchService.shared.search(code: keyword, options: options)
        results = found
        isSearching = false
        if found.isEmpty {
            message = "未找到字幕，可尝试更换番号或稍后重试"
        }
    }

    private func apply(_ result: SubtitleSearchResult) async {
        downloadingID = result.id
        message = "正在下载：\(result.title)"
        do {
            let downloaded = try await SubtitleSearchService.shared.download(result)
            let record = subtitles.saveText(itemID: itemID,
                                            name: downloaded.fileName,
                                            text: downloaded.text,
                                            source: result.provider)
            if let record {
                let url = URL(fileURLWithPath: record.path)
                onApply?(url)
                appliedName = record.name
                message = "已应用字幕：\(record.name)"
            } else if let localURL = downloaded.localURL {
                onApply?(localURL)
                appliedName = downloaded.fileName
                message = "已下载字幕：\(downloaded.fileName)"
            } else {
                message = "字幕下载成功，但写入本地失败"
            }
        } catch {
            message = describeError(error)
        }
        downloadingID = nil
    }
}
