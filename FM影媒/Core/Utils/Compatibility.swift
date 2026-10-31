import SwiftUI
import UIKit

// MARK: - iOS 15.4 兼容层

/// iOS 16 的 NavigationStack 在 15.x 上退回 NavigationView
struct FMNavigationStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

extension ToolbarItemPlacement {
    /// iOS 15 使用 navigationBarTrailing（在 17 上被弃用），16+ 使用 topBarTrailing
    static var fmTrailing: ToolbarItemPlacement {
        if #available(iOS 16.0, *) {
            return .topBarTrailing
        } else {
            return .navigationBarTrailing
        }
    }

    static var fmLeading: ToolbarItemPlacement {
        if #available(iOS 16.0, *) {
            return .topBarLeading
        } else {
            return .navigationBarLeading
        }
    }
}

extension View {
    @ViewBuilder
    func fmScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func fmScrollIndicatorsHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func fmHideNavigationBar() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(.hidden, for: .navigationBar)
        } else {
            self.navigationBarHidden(true)
        }
    }

    /// 播放页全屏：隐藏状态栏与系统浮层
    @ViewBuilder
    func fmPlayerChrome() -> some View {
        if #available(iOS 16.0, *) {
            self.statusBarHidden().persistentSystemOverlays(.hidden)
        } else {
            self.statusBar(hidden: true)
        }
    }
}

// MARK: - 文本输入弹窗（iOS 15 的 alert 不支持输入框）

/// 通用输入弹窗请求
struct InputSheetRequest: Identifiable {
    enum Kind: Equatable {
        case newFolder
        case rename(FileEntry)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let placeholder: String
}

struct TextInputSheet: View {
    let title: String
    var placeholder: String = ""
    @Binding var text: String
    var confirmTitle: String = "确定"
    var onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FMNavigationStack {
            VStack(spacing: 14) {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(FMTheme.separator, lineWidth: 1)
                    )

                Button {
                    let value = text.trimmed
                    guard !value.isEmpty else { return }
                    onConfirm(value)
                    dismiss()
                } label: {
                    Text(confirmTitle).fmPrimaryButton()
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(16)
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
