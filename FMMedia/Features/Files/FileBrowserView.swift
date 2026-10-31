import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let source: MediaSourceConfig

    @StateObject private var vm: FileBrowserViewModel
    @EnvironmentObject private var transfers: TransferManager
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var database: AppDatabase

    @State private var showUpload = false
    @State private var showDeleteConfirm = false
    @State private var deleteTargets: [FileEntry] = []
    @State private var inputRequest: InputSheetRequest?
    @State private var inputText = ""
    @State private var previewImage: ImageRef?
    @State private var banner: String?
    @State private var isPreparingPlayback = false

    init(source: MediaSourceConfig) {
        self.source = source
        _vm = StateObject(wrappedValue: FileBrowserViewModel(source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            header

            if let message = vm.errorMessage {
                errorBanner(message)
            }

            if vm.isLoading && vm.entries.isEmpty {
                Spacer()
                ProgressView().tint(FMTheme.textSecondary)
                Spacer()
            } else if vm.filteredEntries.isEmpty {
                Spacer()
                EmptyStateView(icon: "folder",
                               title: "这个目录是空的",
                               message: vm.capabilities.upload ? "可以从「…」菜单上传文件或新建文件夹。" : "该来源暂时没有可显示的内容。")
                Spacer()
            } else {
                list
            }

            if vm.selectMode {
                selectionBar
            }
        }
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle(vm.currentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .fmTrailing) {
                trailingMenu
            }
        }
        .task {
            await vm.loadInitial()
        }
        .refreshable {
            await vm.refresh()
        }
        .sheet(item: $inputRequest) { request in
            TextInputSheet(title: request.title,
                           placeholder: request.placeholder,
                           text: $inputText,
                           confirmTitle: request.kind == .newFolder ? "创建" : "确定") { value in
                switch request.kind {
                case .newFolder:
                    Task { await vm.makeFolder(name: value) }
                case .rename(let entry):
                    Task { await vm.rename(entry, to: value) }
                }
            }
        }
        .confirmationDialog("确认删除 \(deleteTargets.count) 项？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let targets = deleteTargets
                deleteTargets = []
                Task { await vm.delete(targets) }
            }
            Button("取消", role: .cancel) { deleteTargets = [] }
        } message: {
            Text("删除后无法恢复。")
        }
        .fileImporter(isPresented: $showUpload,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            handleUpload(result)
        }
        .sheet(item: $previewImage) { ref in
            ImagePreviewSheet(ref: ref)
        }
        .overlay(alignment: .bottom) {
            if let banner {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .overlay {
            if isPreparingPlayback {
                ProgressView("正在准备播放…")
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - 面包屑

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(vm.crumbs) { crumb in
                    Button {
                        Task { await vm.jump(to: crumb) }
                    } label: {
                        Text(crumb.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(crumb.id == vm.crumbs.last?.id ? FMTheme.accent : FMTheme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(FMTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if crumb.id != vm.crumbs.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            FMSearchField(text: $vm.query, placeholder: "在当前目录搜索")
            Menu {
                Button {
                    vm.ascending.toggle()
                } label: {
                    Label(vm.ascending ? "升序排列" : "降序排列", systemImage: "arrow.up.arrow.down")
                }
                if vm.canGoUp {
                    Button {
                        Task { await vm.goUp() }
                    } label: {
                        Label("返回上级", systemImage: "arrow.up.left")
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(FMTheme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List {
            ForEach(vm.filteredEntries) { entry in
                row(entry)
                    .listRowBackground(FMTheme.surface)
                    .listRowSeparatorTint(FMTheme.separator)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if vm.selectMode {
                            if let index = vm.selection.firstIndex(of: entry.id) {
                                vm.selection.remove(at: index)
                            } else {
                                vm.selection.insert(entry.id)
                            }
                        } else {
                            handleTap(entry)
                        }
                    }
                    .contextMenu {
                        contextMenu(for: entry)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if vm.capabilities.delete {
                            Button(role: .destructive) {
                                deleteTargets = [entry]
                                showDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        Button {
                            download(entry)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                        }
                        .tint(FMTheme.accent)
                        if vm.capabilities.rename {
                            Button {
                                presentRename(entry)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.gray)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .fmScrollContentBackgroundHidden()
    }

    private func row(_ entry: FileEntry) -> some View {
        HStack(spacing: 11) {
            if vm.selectMode {
                Image(systemName: vm.selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(vm.selection.contains(entry.id) ? FMTheme.accent : FMTheme.textTertiary)
            }

            Image(systemName: entry.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(entry.isDirectory ? FMTheme.accent : FMTheme.textSecondary)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FMTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if entry.isDirectory {
                        Text("文件夹")
                    } else {
                        Text(entry.size.fileSizeText)
                    }
                    if let modified = entry.modified {
                        Text(modified.dayText)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(FMTheme.textTertiary)
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FMTheme.textTertiary)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button {
                Task { await vm.open(entry) }
            } label: {
                Label("打开", systemImage: "folder")
            }
        } else if entry.kind.isPlayable {
            Button {
                play(entry)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
        } else if entry.kind == .image && source.kind == .local {
            Button {
                previewImage = ImageRef(url: URL(fileURLWithPath: entry.path))
            } label: {
                Label("查看图片", systemImage: "photo")
            }
        }

        if !entry.isDirectory {
            Button {
                download(entry)
            } label: {
                Label("下载到本机", systemImage: "arrow.down.circle")
            }
        }

        if vm.capabilities.rename {
            Button {
                presentRename(entry)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
        }

        if vm.capabilities.delete {
            Button(role: .destructive) {
                deleteTargets = [entry]
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                if vm.selection.count == vm.filteredEntries.count {
                    vm.selection.removeAll()
                } else {
                    vm.selection = Set(vm.filteredEntries.map { $0.id })
                }
            } label: {
                Text(vm.selection.count == vm.filteredEntries.count ? "取消全选" : "全选")
            }
            Spacer()
            Text("已选 \(vm.selection.count)")
                .font(.system(size: 12))
                .foregroundStyle(FMTheme.textSecondary)
            Spacer()
            Button {
                let targets = vm.filteredEntries.filter { vm.selection.contains($0.id) && !$0.isDirectory }
                targets.forEach { download($0) }
                vm.selection.removeAll()
                vm.selectMode = false
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            if vm.capabilities.delete {
                Button(role: .destructive) {
                    deleteTargets = vm.filteredEntries.filter { vm.selection.contains($0.id) }
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(FMTheme.danger)
                }
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(FMTheme.accent)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func presentNewFolder() {
        inputText = ""
        inputRequest = InputSheetRequest(kind: .newFolder, title: "新建文件夹", placeholder: "文件夹名称")
    }

    private func presentRename(_ entry: FileEntry) {
        inputText = entry.displayName
        inputRequest = InputSheetRequest(kind: .rename(entry), title: "重命名", placeholder: "新名称")
    }

    private var trailingMenu: some View {
        Menu {
            if vm.capabilities.createFolder {
                Button {
                    presentNewFolder()
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
            }
            if vm.capabilities.upload {
                Button {
                    showUpload = true
                } label: {
                    Label("上传文件", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                Task { await vm.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Divider()
            Button {
                vm.selectMode.toggle()
                vm.selection.removeAll()
            } label: {
                Label(vm.selectMode ? "退出多选" : "多选", systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FMTheme.warning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(FMTheme.textSecondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(10)
        .background(FMTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - 操作

    private func handleTap(_ entry: FileEntry) {
        if entry.isDirectory {
            Task { await vm.open(entry) }
        } else if entry.kind.isPlayable {
            play(entry)
        } else if entry.kind == .image && source.kind == .local {
            previewImage = ImageRef(url: URL(fileURLWithPath: entry.path))
        } else {
            banner = entry.displayName
            dismissBanner()
        }
    }

    private func play(_ entry: FileEntry) {
        guard !isPreparingPlayback else { return }
        isPreparingPlayback = true
        Task {
            defer { isPreparingPlayback = false }
            do {
                let request = try await vm.playbackRequest(for: entry)
                presenter.play(request)
            } catch {
                vm.errorMessage = describeError(error)
            }
        }
    }

    private func download(_ entry: FileEntry) {
        transfers.enqueueDownload(source: source,
                                  remotePath: entry.path,
                                  fileName: entry.displayName,
                                  destinationDirectory: FileStore.downloads)
        banner = "已加入下载队列：\(entry.displayName)"
        dismissBanner()
    }

    private func dismissBanner() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { banner = nil }
        }
    }

    private func localURL(for entry: FileEntry) -> URL {
        URL(fileURLWithPath: entry.path)
    }

    private func handleUpload(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: temp)
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                vm.errorMessage = "读取待上传文件失败：\(describeError(error))"
                continue
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
            transfers.enqueueUpload(source: source, localURL: temp, remoteDirectory: vm.currentPath)
        }
        banner = "已加入上传队列"
        dismissBanner()
    }
}

// MARK: - 图片预览

struct ImagePreviewSheet: View {
    let ref: ImageRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FMNavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                FMImageView(ref: ref, contentMode: .fit, cornerRadius: 0)
                    .padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private extension FileBrowserViewModel {
    var canGoUp: Bool { crumbs.count > 1 }
}
