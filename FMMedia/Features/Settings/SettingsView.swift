import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transfers: TransferManager
    @EnvironmentObject private var subtitles: SubtitleLibrary

    @State private var showSubtitleStyle = false
    @State private var showAddSource = false
    @State private var imageCacheSize: Int64 = 0
    @State private var showClearLibrary = false
    @State private var removingSource: MediaSourceConfig?
    @State private var editingSource: MediaSourceConfig?
    @State private var statusMessage: String?

    var body: some View {
        FMNavigationStack {
            List {
                librarySection
                playbackSection
                subtitleSection
                transferSection
                storageSection
                sourcesSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .fmScrollContentBackgroundHidden()
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("设置")
            .sheet(isPresented: $showSubtitleStyle) {
                SubtitleSettingsSheet(delayMs: 0, onDelayChange: { _ in })
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceView(editing: editingSource)
            }
            .task {
                imageCacheSize = RemoteImageLoader.shared.diskCacheSize()
            }
            .confirmationDialog("清空媒体库？", isPresented: $showClearLibrary, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    library.clearLibrary()
                    settings.data.lastLibraryScan = nil
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除媒体库索引，不会删除任何视频文件。")
            }
            .confirmationDialog("移除来源「\(removingSource?.name ?? "")」？",
                                isPresented: Binding(get: { removingSource != nil },
                                                     set: { if !$0 { removingSource = nil } }),
                                titleVisibility: .visible) {
                Button("移除", role: .destructive) {
                    if let source = removingSource {
                        database.remove(source)
                        library.removeSourceItems(source.id)
                    }
                    removingSource = nil
                }
                Button("取消", role: .cancel) { removingSource = nil }
            } message: {
                Text("不会删除服务器或本机上的文件。")
            }
        }
    }

    // MARK: - 媒体库

    private var librarySection: some View {
        Section {
            Button {
                Task {
                    await library.scan(sources: database.sources, force: true)
                    settings.data.lastLibraryScan = library.lastScan
                    statusMessage = "扫描完成，共 \(library.items.count) 部"
                }
            } label: {
                HStack {
                    Label("扫描本机目录", systemImage: "arrow.clockwise")
                    Spacer()
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(library.items.count) 部")
                            .font(.system(size: 12))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                }
            }
            .disabled(library.isScanning)

            ForEach(database.mediaServers) { server in
                Button {
                    Task { await library.importFromServer(server) }
                } label: {
                    HStack {
                        Label("从 \(server.name) 导入媒体库", systemImage: "square.and.arrow.down.on.square")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                }
                .disabled(library.isScanning)
            }

            Toggle("显示未识别条目", isOn: $settings.data.showUnrecognizedItems)
            Toggle("封面显示「破解」标签", isOn: $settings.data.showCrackedBadge)
            Toggle("封面显示「字幕」标签", isOn: $settings.data.showSubtitleBadge)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("标题显示")
                    Text(settings.data.titleMode.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.textTertiary)
                }
                Spacer()
                Menu {
                    ForEach(TitleDisplayMode.allCases) { mode in
                        Button {
                            settings.data.titleMode = mode
                        } label: {
                            if settings.data.titleMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text(settings.data.titleMode.title)
                        .foregroundStyle(FMTheme.accent)
                }
            }

            Toggle("标题完整显示", isOn: $settings.data.showFullTitle)
            Toggle("版本升级后自动全量扫描", isOn: $settings.data.autoScanOnLaunch)
            Toggle("启用题材分类", isOn: $settings.data.enableGenreCategories)

            if settings.data.titleMode == .custom {
                HStack {
                    Text("大标题字段")
                    Spacer()
                    Menu {
                        ForEach(TitleField.allCases) { field in
                            Button {
                                settings.data.titleField = field
                            } label: {
                                if settings.data.titleField == field {
                                    Label(field.title, systemImage: "checkmark")
                                } else {
                                    Text(field.title)
                                }
                            }
                        }
                    } label: {
                        Text(titleFieldLabel(settings.data.titleField))
                            .foregroundStyle(FMTheme.accent)
                            .lineLimit(1)
                    }
                }

                HStack {
                    Text("小标题字段")
                    Spacer()
                    Menu {
                        ForEach(TitleField.allCases) { field in
                            Button {
                                toggleSubtitleField(field)
                            } label: {
                                if settings.data.subtitleFields.contains(field) {
                                    Label(field.title, systemImage: "checkmark")
                                } else {
                                    Text(field.title)
                                }
                            }
                        }
                    } label: {
                        Text(fieldsSummary(settings.data.subtitleFields))
                            .foregroundStyle(FMTheme.accent)
                            .lineLimit(1)
                    }
                }
            }

            Toggle("启动时自动扫描", isOn: $settings.data.autoScanOnLaunch)

            if let last = library.lastScan {
                HStack {
                    Text("上次扫描")
                    Spacer()
                    Text(last.shortText)
                        .foregroundStyle(FMTheme.textTertiary)
                }
                .font(.system(size: 13))
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(FMTheme.success)
            }

            NavigationLink {
                DuplicatesView()
            } label: {
                Label("重复番号检测", systemImage: "rectangle.stack.badge.minus")
            }
            NavigationLink {
                MPVLogViewer()
            } label: {
                Label("MPV 调试日志", systemImage: "doc.text.magnifyingglass")
            }

            Button(role: .destructive) {
                showClearLibrary = true
            } label: {
                Label("清空媒体库索引", systemImage: "trash")
            }
        } header: {
            Text("媒体库")
        } footer: {
            if let error = library.lastError {
                Text(error).foregroundStyle(FMTheme.danger)
            } else {
                Text("扫描会读取番号文件夹中的视频、字幕、封面、NFO 与 extrafanart 预览图。")
            }
        }
    }

    private func toggleSubtitleField(_ field: TitleField) {
        var fields = settings.data.subtitleFields
        if let index = fields.firstIndex(of: field) {
            fields.remove(at: index)
        } else {
            fields.append(field)
        }
        settings.data.subtitleFields = fields
    }

    private func titleFieldLabel(_ field: TitleField) -> String {
        field.title.components(separatedBy: "（").first ?? field.title
    }

    private func fieldsSummary(_ fields: [TitleField]) -> String {
        guard !fields.isEmpty else { return "未选择" }
        return fields.map { $0.title.components(separatedBy: "（").first ?? $0.title }.joined(separator: " + ")
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("解码方式")
                    Text(settings.data.decodePreference.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.textTertiary)
                }
                Spacer()
                Menu {
                    ForEach(PlaybackDecodeMode.allCases) { mode in
                        Button {
                            settings.data.decodePreference = mode
                        } label: {
                            if settings.data.decodePreference == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text(settings.data.decodePreference.title)
                        .foregroundStyle(FMTheme.accent)
                }
            }
            HStack {
                Text("默认倍速")
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate.formatted())×") {
                            settings.data.playbackRate = rate
                        }
                    }
                } label: {
                    Text("\(settings.data.playbackRate.formatted())×")
                        .foregroundStyle(FMTheme.accent)
                }
            }
            HStack {
                Text("长按倍速")
                Spacer()
                Menu {
                    ForEach([1.5, 2.0, 3.0, 4.0], id: \.self) { rate in
                        Button("\(rate.formatted())×") {
                            settings.data.longPressRate = rate
                        }
                    }
                } label: {
                    Text("\(settings.data.longPressRate.formatted())×")
                        .foregroundStyle(FMTheme.accent)
                }
            }
            Toggle("记住播放进度", isOn: $settings.data.resumePlayback)
            Button {
                showSubtitleStyle = true
            } label: {
                HStack {
                    Label("字幕外观与同步", systemImage: "textformat.size")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(FMTheme.textTertiary)
                }
            }
        } header: {
            Text("播放")
        } footer: {
            Text("MPV 内核由 FFmpeg 驱动，可播放 MKV、AVI、RMVB、WMV、FLV、TS、ISO 等全部常见格式；解码可选硬件/软件，硬解失败会自动回退软解；播放中也可在「更多」菜单临时切换。")
        }
    }

    // MARK: - 字幕

    private var subtitleSection: some View {
        Section {
            Toggle("启用在线字幕搜索", isOn: $settings.data.subtitleSearchEnabled)
            Toggle("迅雷字幕接口", isOn: $settings.data.xunleiSubtitleEnabled)
            Toggle("SubtitleCat", isOn: $settings.data.subtitlecatEnabled)
            HStack {
                Text("优先语言")
                Spacer()
                Menu {
                    ForEach(["zh", "en", "ja", "ko"], id: \.self) { code in
                        Button(languageTitle(code)) {
                            settings.data.preferredSubtitleLanguage = code
                        }
                    }
                } label: {
                    Text(languageTitle(settings.data.preferredSubtitleLanguage))
                        .foregroundStyle(FMTheme.accent)
                }
            }
            HStack {
                Text("已关联字幕")
                Spacer()
                Text("\(subtitles.totalCount) 个")
                    .foregroundStyle(FMTheme.textTertiary)
            }
        } header: {
            Text("字幕")
        } footer: {
            Text("搜索源：api-shoulei-ssl.xunlei.com 与 subtitlecat.com。下载的字幕会保存在本机并自动关联到影片。")
        }
    }

    private func languageTitle(_ code: String) -> String {
        switch code {
        case "zh": return "简体中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code
        }
    }

    // MARK: - 传输

    private var transferSection: some View {
        Section {
            Stepper(value: $settings.data.maxConcurrentTransfers, in: 1...4) {
                HStack {
                    Text("同时传输")
                    Spacer()
                    Text("\(settings.data.maxConcurrentTransfers) 个")
                        .foregroundStyle(FMTheme.textTertiary)
                }
            }
            HStack {
                Text("进行中")
                Spacer()
                Text("\(transfers.activeCount) 个任务")
                    .foregroundStyle(FMTheme.textTertiary)
            }
        } header: {
            Text("传输")
        } footer: {
            Text("传输速度取决于服务器带宽。暂停后继续会重新开始该任务。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            HStack {
                Text("封面缓存")
                Spacer()
                Text(imageCacheSize.fileSizeText)
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Button {
                RemoteImageLoader.shared.clearCaches()
                imageCacheSize = 0
            } label: {
                Label("清除图片缓存", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                subtitles.clearAll()
            } label: {
                Label("清除已下载字幕", systemImage: "captions.bubble")
            }
            HStack {
                Text("本机下载")
                Spacer()
                Text(FileStore.directorySize(of: FileStore.downloads).fileSizeText)
                    .foregroundStyle(FMTheme.textTertiary)
            }
        } header: {
            Text("存储")
        }
    }

    // MARK: - 来源

    private var sourcesSection: some View {
        Section {
            ForEach(database.sources) { source in
                HStack(spacing: 10) {
                    SourceIcon(kind: source.kind, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(source.displayDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(FMTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        editingSource = source
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(FMTheme.accent)
                    }
                    .buttonStyle(.plain)
                    Button {
                        removingSource = source
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                showAddSource = true
            } label: {
                Label("添加来源", systemImage: "plus.circle")
            }
        } header: {
            Text("来源")
        } footer: {
            Text("账号密码保存在系统钥匙串中，不会写入明文配置。")
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            NavigationLink {
                NamingRulesView()
            } label: {
                Label("番号命名规则", systemImage: "text.book.closed")
            }
            NavigationLink {
                ProtocolSupportView()
            } label: {
                Label("协议与接口支持", systemImage: "network")
            }
            HStack {
                Text("版本")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Toggle("调试日志", isOn: $settings.data.debugLogEnabled)
                .onChange(of: settings.data.debugLogEnabled) { AppDebugLog.setEnabled($0) }
            if settings.data.debugLogEnabled {
                NavigationLink {
                    DebugLogViewer()
                } label: {
                    Label("查看调试日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            Text("关于")
        } footer: {
            Text("FM影媒 · 本机与远程媒体聚合播放器。请确保对所使用的媒体内容拥有合法访问权限。")
        }
    }
}

// MARK: - 命名规则说明

struct NamingRulesView: View {
    private let rules: [(String, String)] = [
        ("ABC-123", "番号文件夹，正片与字幕文件同名为 ABC-123"),
        ("ABC-123-u", "标记为「破解」（u 不区分大小写）"),
        ("ABC-123-c", "标记为「字幕」（c 不区分大小写）"),
        ("ABC-123-uc", "同时标记「破解」与「字幕」，-cu 亦可"),
        ("ABC-123-poster.jpg", "小封面（竖版海报）"),
        ("ABC-123-fanart.jpg", "大封面（横版背景图）"),
        ("ABC-123.nfo", "影片信息，兼容 Kodi / Emby 格式"),
        ("extrafanart/0.jpg", "预览截图，从 0 开始按数字排序")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("目录结构示例")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FMTheme.textPrimary)

                Text("""
                ABC-123-uc/
                  ABC-123.mp4
                  ABC-123.srt
                  ABC-123-poster.jpg
                  ABC-123-fanart.jpg
                  ABC-123.nfo
                  extrafanart/
                    0.jpg
                    1.jpg
                """)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FMTheme.textSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("规则说明")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FMTheme.textPrimary)
                    .padding(.top, 4)

                ForEach(rules.indices, id: \.self) { index in
                    let rule = rules[index]
                    HStack(alignment: .top, spacing: 10) {
                        Text(rule.0)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(FMTheme.accent)
                            .frame(width: 150, alignment: .leading)
                        Text(rule.1)
                            .font(.system(size: 11))
                            .foregroundStyle(FMTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("提示：番号格式为 2–6 位字母 + 2–5 位数字（如 ABC-123、abcd-12345），分隔符支持 - _ . 与空格。扫描时以文件夹名为准，视频文件按同番号匹配。")
                    .font(.system(size: 11))
                    .foregroundStyle(FMTheme.textTertiary)
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("命名规则")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProtocolSupportView: View {
    private let items: [(SourceKind, String)] = [
        (.local, "系统文件夹书签授权，支持浏览、重命名、移动、复制、删除、上传。"),
        (.emby, "官方 API：登录、浏览媒体库、直接播放、海报与背景图。"),
        (.jellyfin, "兼容 Emby 认证与 Items 接口，支持浏览与播放。"),
        (.fnos, "飞牛影视：兼容模式接入，若接口不通请改用 WebDAV。"),
        (.zspace, "极空间影视：兼容模式接入，若接口不通请改用 WebDAV。"),
        (.aliyun, "阿里云盘开放接口：浏览、获取下载直链播放。"),
        (.baidu, "百度网盘开放接口：浏览、获取 dlink 播放与下载。"),
        (.pan115, "115 开放接口（实验性）：浏览、downurl 播放。"),
        (.pan123, "123 云盘开放接口：浏览、下载直链播放。"),
        (.tianyi, "天翼云盘需签名接口，建议通过 WebDAV 接入。"),
        (.cmcc, "中国移动云盘需签名接口，建议通过 WebDAV 接入。"),
        (.guangya, "光鸭云盘暂未公开标准接口，建议通过 WebDAV 接入。"),
        (.webdav, "完整 WebDAV：PROPFIND / GET / PUT / MKCOL / DELETE / MOVE / COPY。"),
        (.smb, "需添加 AMSMB2 依赖（见 README）。SMB 无法边下边播，播放前会缓存到本机。")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .top, spacing: 10) {
                        SourceIcon(kind: item.0, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.0.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FMTheme.textPrimary)
                                if item.0.isCloud {
                                    FMTag(text: item.0.cloudSupport.title,
                                          color: item.0.cloudSupport == .webdavOnly ? FMTheme.warning : FMTheme.accent)
                                }
                            }
                            Text(item.1)
                                .font(.system(size: 11))
                                .foregroundStyle(FMTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .fmCard(padding: 12)
                }
            }
            .padding(16)
        }
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("协议支持")
        .navigationBarTitleDisplayMode(.inline)
    }
}
