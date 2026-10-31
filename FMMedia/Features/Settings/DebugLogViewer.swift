import SwiftUI

struct DebugLogViewer: View {
    @State private var logContent = ""
    @State private var copied = false

    var body: some View {
        Group {
            if logContent.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(FMTheme.textTertiary)
                    Text("暂无调试日志")
                        .font(.system(size: 14))
                        .foregroundStyle(FMTheme.textSecondary)
                    Text("打开调试日志开关后播放一次视频即可生成")
                        .font(.system(size: 11))
                        .foregroundStyle(FMTheme.textTertiary)
                }
            } else {
                ScrollView {
                    Text(logContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FMTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .background(FMTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .fmTrailing) {
                Button {
                    UIPasteboard.general.string = logContent
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
        }
        .onAppear { logContent = AppDebugLog.read() }
    }
}
