import SwiftUI
import UniformTypeIdentifiers

struct AddSourceView: View {
    @EnvironmentObject private var database: AppDatabase
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// 传入即为编辑模式
    var editing: MediaSourceConfig? = nil

    @State private var kind: SourceKind = .local
    @State private var name = ""
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var share = ""
    @State private var remotePath = ""
    @State private var domain = ""
    @State private var token = ""
    @State private var driveId = ""
    @State private var apiBase = ""

    @State private var isBusy = false
    @State private var didLoadEditing = false
    @State private var revealPassword = false
    @State private var revealToken = false
    @State private var errorMessage: String?
    @State private var showFolderPicker = false
    @State private var pickedURL: URL?
    @State private var pickedBookmark: Data?

    private let kinds = SourceKind.allCases

    var body: some View {
        FMNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    kindGrid
                    nameField
                    kindFields

                    if kind.isCloud {
                        cloudHint
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(FMTheme.warning)
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(FMTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(FMTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Text(isBusy ? "正在连接…" : (editing == nil ? "保存并连接" : "保存修改"))
                        }
                        .fmPrimaryButton()
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
                .padding(16)
            }
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(editing == nil ? "添加来源" : "编辑来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { loadEditingIfNeeded() }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                handleFolderPick(result)
            }
        }
    }

    // MARK: - 类型

    private var kindGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("来源类型")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FMTheme.textTertiary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(kinds) { option in
                    Button {
                        select(option)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: option.symbol)
                                .font(.system(size: 16, weight: .semibold))
                            Text(option.title)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(kind == option ? .white : FMTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(kind == option ? FMTheme.accent : FMTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(editing != nil)
                }
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("名称")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FMTheme.textTertiary)
            TextField(defaultNamePlaceholder, text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(11)
                .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var defaultNamePlaceholder: String {
        if kind == .local, let pickedURL { return pickedURL.lastPathComponent }
        return kind.title
    }

    @ViewBuilder
    private var kindFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .local:
                Button {
                    showFolderPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(FMTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pickedURL == nil ? "选择本机文件夹" : "已选择")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FMTheme.textPrimary)
                            Text(pickedURL?.path ?? "支持 iCloud Drive、共享文件夹与 App 内目录")
                                .font(.system(size: 10))
                                .foregroundStyle(FMTheme.textTertiary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .fmCard(padding: 12)
                }
                .buttonStyle(.plain)
                Text("目录内的文件夹需按番号命名，才会被智能媒体库识别。")
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)

            case .emby, .jellyfin, .fnos, .zspace:
                field("服务器地址", text: $serverAddress, placeholder: "http://192.168.1.10:8096")
                field("用户名", text: $username)
                secretField("密码", text: $password, placeholder: editing == nil ? "请输入密码" : "留空保持现有登录", isRevealed: $revealPassword)
                if editing != nil {
                    Text("已登录的服务器可留空，保持现有登录状态。").font(.system(size: 10)).foregroundStyle(FMTheme.textTertiary)
                }
                if kind == .fnos || kind == .zspace {
                    Text("该平台可能未提供 Emby 兼容接口，可优先尝试 WebDAV 方式连接同一设备。")
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.textTertiary)
                }

            case .webdav:
                field("服务器地址", text: $serverAddress, placeholder: "https://dav.example.com/dav")
                field("用户名", text: $username)
                secretField("密码", text: $password, placeholder: "请输入密码（无密码可留空）", isRevealed: $revealPassword)
                field("起始目录（可选）", text: $remotePath, placeholder: "留空为根目录，例如 /media")
                if editing != nil {
                    Text("密码留空则保持现有密码；改地址或账号时请重新输入。")
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.textTertiary)
                }

            case .smb:
                field("服务器地址", text: $serverAddress, placeholder: "192.168.1.10")
                field("共享名称", text: $share, placeholder: "Media")
                field("子路径", text: $remotePath, placeholder: "可选，例如 Movies")
                field("用户名", text: $username)
                secretField("密码", text: $password, placeholder: "请输入密码", isRevealed: $revealPassword)
                field("域", text: $domain, placeholder: "可选，例如 WORKGROUP")

            default:
                secretField("Access Token / Cookie", text: $token, placeholder: editing == nil ? "请粘贴 Token / Cookie" : "留空保持现有 Token", isRevealed: $revealToken)
                field("Drive ID（可选）", text: $driveId)
                field("API 地址（可选）", text: $apiBase, placeholder: "使用官方默认接口")
                Text("云盘接口需要账号授权。可粘贴网页端获取的 access_token；如提示未授权，请改用 WebDAV 方式。")
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
            }
        }
    }

    private var cloudHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(FMTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind.title) · \(kind.cloudSupport.title)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FMTheme.textSecondary)
                Text(cloudHintText)
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .background(FMTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var cloudHintText: String {
        switch kind.cloudSupport {
        case .openAPI:
            return "已接入开放接口，支持浏览、播放与下载。上传需服务端支持。"
        case .experimental:
            return "接口依赖账号权限，可能随时调整；如不稳定请改用 WebDAV。"
        case .webdavOnly:
            return "官方未开放标准接口，建议在「WebDAV」中填写该网盘提供的 WebDAV 地址。"
        }
    }

    /// 密码 / Token 输入框：可切换明文，编辑时带回填
    private func secretField(_ title: String,
                             text: Binding<String>,
                             placeholder: String,
                             isRevealed: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FMTheme.textTertiary)
            HStack(spacing: 8) {
                Group {
                    if isRevealed.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14))

                Button {
                    isRevealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(FMTheme.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "", secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FMTheme.textTertiary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(11)
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 行为

    private func select(_ option: SourceKind) {
        guard editing == nil, kind != option else { return }
        kind = option
        errorMessage = nil
        serverAddress = ""
        username = ""
        password = ""
        token = ""
        share = ""
        remotePath = ""
        domain = ""
        driveId = ""
        apiBase = ""
        pickedURL = nil
        pickedBookmark = nil
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        pickedBookmark = BookmarkStore.makeBookmark(for: url)
        pickedURL = url
        if name.isEmpty { name = url.lastPathComponent }
    }

    @MainActor
    private func save() async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let isEditing = editing != nil
        let finalName = name.trimmed.isEmpty ? defaultNamePlaceholder : name.trimmed

        // 编辑时基于原配置修改：保留 id、钥匙串密钥、已授权目录等
        var config = editing ?? MediaSourceConfig(name: finalName, kind: kind)
        config.name = finalName
        if !isEditing { config.kind = kind }

        // 编辑模式下密码 / Token 留空 = 保持原值
        let typedPassword = password.trimmed
        let typedToken = token.trimmed

        do {
            switch kind {
            case .local:
                if let pickedURL, let pickedBookmark {
                    config.localPath = pickedURL.path
                    config.localBookmark = pickedBookmark
                }
                guard let path = config.localPath, !path.isEmpty else {
                    throw AppError.notConfigured("请先选择一个文件夹")
                }
                _ = path
                LocalAccessManager.shared.activate(config)

            case .emby, .jellyfin, .fnos, .zspace:
                guard !serverAddress.trimmed.isEmpty else {
                    throw AppError.notConfigured("请填写服务器地址")
                }
                let normalized = HTTPClient.normalizeServerAddress(serverAddress)
                let addressChanged = isEditing
                    && normalized != HTTPClient.normalizeServerAddress(config.baseURL)
                let needsLogin = !isEditing || !typedPassword.isEmpty || addressChanged
                if needsLogin {
                    let pw = typedPassword.isEmpty ? config.secret : typedPassword
                    guard !pw.isEmpty else {
                        throw AppError.notConfigured(isEditing ? "修改服务器地址后需要重新输入密码" : "请填写密码")
                    }
                    let result = try await EmbyProvider.authenticate(baseURL: normalized,
                                                                     username: username,
                                                                     password: pw)
                    config.extra["userId"] = result.userId
                    config.extra["deviceId"] = result.deviceId
                    config.secret = result.accessToken
                    if name.trimmed.isEmpty, !result.serverName.isEmpty {
                        config.name = result.serverName
                    }
                }
                config.baseURL = normalized
                config.username = username

            case .webdav:
                guard !serverAddress.trimmed.isEmpty else {
                    throw AppError.notConfigured("请填写服务器地址")
                }
                config.baseURL = HTTPClient.normalizeServerAddress(serverAddress)
                config.username = username
                if !typedPassword.isEmpty { config.secret = typedPassword }
                let startPath = HTTPClient.normalizeDirPath(remotePath)
                if startPath.isEmpty {
                    config.extra.removeValue(forKey: "path")
                } else {
                    config.extra["path"] = startPath
                }
                let provider = WebDAVProvider(config: config)
                _ = try await provider.list(path: provider.rootPath)

            case .smb:
                guard !serverAddress.trimmed.isEmpty else {
                    throw AppError.notConfigured("请填写服务器地址")
                }
                guard !share.trimmed.isEmpty else {
                    throw AppError.notConfigured("请填写共享名称")
                }
                config.baseURL = serverAddress.trimmed
                config.username = username
                if !typedPassword.isEmpty { config.secret = typedPassword }
                config.extra["share"] = share.trimmed
                if remotePath.trimmed.isEmpty {
                    config.extra.removeValue(forKey: "path")
                } else {
                    config.extra["path"] = remotePath.trimmed
                }
                if domain.trimmed.isEmpty {
                    config.extra.removeValue(forKey: "domain")
                } else {
                    config.extra["domain"] = domain.trimmed
                }
                let provider = try SMBProvider.make(config: config)
                _ = try await provider.list(path: provider.rootPath)

            default:
                if !driveId.trimmed.isEmpty {
                    config.extra["driveId"] = driveId.trimmed
                } else {
                    config.extra.removeValue(forKey: "driveId")
                }
                if !apiBase.trimmed.isEmpty {
                    config.extra["apiBase"] = HTTPClient.normalizeServerAddress(apiBase)
                } else {
                    config.extra.removeValue(forKey: "apiBase")
                }
                if !typedToken.isEmpty { config.secret = typedToken }

                if kind.cloudSupport == .webdavOnly {
                    // 未开放标准接口，仅登记来源，实际浏览请通过 WebDAV
                } else {
                    guard !config.secret.isEmpty else {
                        throw AppError.notConfigured(isEditing ? "Token 为空，请重新填写" : "请填写 Access Token")
                    }
                    let provider = CloudDriveProvider(config: config)
                    _ = try await provider.list(path: provider.rootPath)
                }
            }

            if isEditing {
                database.update(config)
            } else {
                database.add(config)
            }
            dismiss()

            if kind == .local || kind == .webdav || kind == .smb {
                library.markSourceForRescan(config.id)
                let sources = database.sources
                Task {
                    await library.scan(sources: sources)
                }
            }
        } catch {
            errorMessage = describeError(error)
        }
    }
}

extension AddSourceView {
    @MainActor
    private func loadEditingIfNeeded() {
        guard !didLoadEditing, let source = editing else { return }
        didLoadEditing = true
        kind = source.kind
        name = source.name
        serverAddress = source.baseURL
        username = source.username
        remotePath = source.extra["path"] ?? ""
        share = source.extra["share"] ?? ""
        domain = source.extra["domain"] ?? ""
        driveId = source.extra["driveId"] ?? ""
        apiBase = source.extra["apiBase"] ?? ""
        if source.kind == .local {
            pickedURL = source.localPath.map { URL(fileURLWithPath: $0) }
            pickedBookmark = source.localBookmark
        }
        switch source.kind {
        case .webdav, .smb:
            password = source.secret
            token = ""
        case .emby, .jellyfin, .fnos, .zspace:
            // 密码是登录凭据而非 Token，留空表示保持现有登录
            password = ""
            token = ""
        default:
            password = ""
            token = source.secret
        }
    }
}
