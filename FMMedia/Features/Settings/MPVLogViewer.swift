import SwiftUI

/// MPV 调试日志查看器
struct MPVLogViewer: View {
    @State private var logContent = ""
    @State private var logFiles: [URL] = []
    @State private var selectedFile: URL?
    @State private var copied = false

    var body: some View {
        List {
            if !logContent.isEmpty {
                Section {
                    Button {
                        UIPasteboard.general.string = logContent
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        HStack {
                            Label("复制全部", systemImage: "doc.on.doc")
                            Spacer()
                            if copied {
                                Text("已复制").foregroundStyle(FMTheme.success)
                            }
                        }
                    }
                }
                Section("日志内容") {
                    Text(logContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FMTheme.textSecondary)
                        .textSelection(.enabled)
                }
            } else {
                EmptyStateView(icon: "doc.text.magnifyingglass",
                               title: "暂无日志",
                               message: "播放一次视频后会生成调试日志。")
            }

            if !logFiles.isEmpty {
                Section("历史日志") {
                    ForEach(logFiles, id: \.absoluteString) { file in
                        Button {
                            if let content = try? String(contentsOf: file, encoding: .utf8) {
                                logContent = content
                            }
                        } label: {
                            Text(file.lastPathComponent)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(FMTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .fmScrollContentBackgroundHidden()
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("MPV 调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadLogs() }
    }

    private func loadLogs() {
        let dir = FileStore.caches.appendingPathComponent("MPVLogs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        logFiles = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let latest = logFiles.first,
           let content = try? String(contentsOf: latest, encoding: .utf8) {
            logContent = content
        }
    }
}
