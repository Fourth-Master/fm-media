import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var transfers: TransferManager

    @State private var showAddSource = false
    @State private var editingSource: MediaSourceConfig?

    private static let downloadsSource = MediaSourceConfig(name: "本机下载",
                                                          kind: .local,
                                                          localPath: FileStore.downloads.path)

    private var localSources: [MediaSourceConfig] {
        database.sources.filter { $0.kind == .local }
    }

    private var serverSources: [MediaSourceConfig] {
        database.sources.filter { $0.kind.isMediaServer }
    }

    private var cloudSources: [MediaSourceConfig] {
        database.sources.filter { $0.kind.isCloud }
    }

    private var protocolSources: [MediaSourceConfig] {
        database.sources.filter { $0.kind == .webdav || $0.kind == .smb }
    }

    var body: some View {
        FMNavigationStack {
            List {
                Section {
                    sourceRow(FilesView.downloadsSource)
                } header: {
                    Text("本机")
                } footer: {
                    Text("下载的影片会保存在这里，可在系统「文件」App 中查看。")
                }

                if !localSources.isEmpty {
                    Section("导入的目录") {
                        ForEach(localSources) { source in
                            editableSourceRow(source)
                        }
                    }
                }

                if !serverSources.isEmpty {
                    Section("媒体服务器") {
                        ForEach(serverSources) { source in
                            editableSourceRow(source)
                        }
                    }
                }

                if !cloudSources.isEmpty {
                    Section("云盘") {
                        ForEach(cloudSources) { source in
                            editableSourceRow(source)
                        }
                    }
                }

                if !protocolSources.isEmpty {
                    Section("网络协议") {
                        ForEach(protocolSources) { source in
                            editableSourceRow(source)
                        }
                    }
                }

                Section {
                    Button {
                        showAddSource = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(FMTheme.accent)
                            Text("添加来源")
                                .foregroundStyle(FMTheme.accent)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                } footer: {
                    Text("支持 Emby、Jellyfin、飞牛影视、极空间影视、阿里云盘、百度网盘、115、天翼云盘、中国移动云盘、123 云盘、光鸭云盘、WebDAV 与 SMB。")
                }
            }
            .listStyle(.insetGrouped)
            .fmScrollContentBackgroundHidden()
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("文件")
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button {
                        showAddSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceView()
            }
            .sheet(item: $editingSource) { source in
                AddSourceView(editing: source)
            }
        }
    }

    private func editableSourceRow(_ source: MediaSourceConfig) -> some View {
        sourceRow(source)
            .swipeActions(edge: .trailing) {
                Button {
                    editingSource = source
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(FMTheme.accent)
            }
    }

    private func sourceRow(_ source: MediaSourceConfig) -> some View {
        NavigationLink {
            FileBrowserView(source: source)
        } label: {
            HStack(spacing: 12) {
                SourceIcon(kind: source.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(FMTheme.textPrimary)
                    Text(source.displayDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(FMTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }
}
