import SwiftUI

struct TransfersView: View {
    @EnvironmentObject private var transfers: TransferManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        FMNavigationStack {
            Group {
                if transfers.tasks.isEmpty {
                    ScrollView {
                        EmptyStateView(icon: "arrow.up.arrow.down",
                                       title: "暂无传输任务",
                                       message: "在「文件」中长按或左滑文件，即可下载到本机；也可以把本机文件上传到远程目录。")
                            .padding(.top, 60)
                        downloadsSection
                            .padding(.horizontal, 16)
                    }
                } else {
                    List {
                        ForEach(transfers.tasks) { task in
                            TransferRow(task: task)
                                .listRowBackground(FMTheme.surface)
                                .listRowSeparatorTint(FMTheme.separator)
                        }
                    }
                    .listStyle(.plain)
                    .fmScrollContentBackgroundHidden()
                }
            }
            .background(FMTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("传输")
            .toolbar {
                ToolbarItem(placement: .fmLeading) {
                    if !transfers.tasks.isEmpty {
                        Text("\(transfers.activeCount) 个进行中")
                            .font(.system(size: 12))
                            .foregroundStyle(FMTheme.textTertiary)
                    }
                }
                ToolbarItem(placement: .fmTrailing) {
                    Menu {
                        Button {
                            transfers.maxConcurrent = min(4, transfers.maxConcurrent + 1)
                            settings.data.maxConcurrentTransfers = transfers.maxConcurrent
                        } label: {
                            Label("并发数 \(transfers.maxConcurrent)", systemImage: "speedometer")
                        }
                        Button {
                            transfers.removeFinished()
                        } label: {
                            Label("清除已结束", systemImage: "trash")
                        }
                        Button(role: .destructive) {
                            transfers.clearAll()
                        } label: {
                            Label("取消全部", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var downloadsSection: some View {
        NavigationLink {
            FileBrowserView(source: VirtualSources.downloads)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(FMTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(FMTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("本机下载目录")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FMTheme.textPrimary)
                    Text("\(FileStore.directorySize(of: FileStore.downloads).fileSizeText) · 可在系统文件中查看")
                        .font(.system(size: 11))
                        .foregroundStyle(FMTheme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FMTheme.textTertiary)
            }
            .padding(12)
            .background(FMTheme.surface, in: RoundedRectangle(cornerRadius: FMTheme.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 20)
    }
}

struct TransferRow: View {
    let task: TransferTask
    @EnvironmentObject private var transfers: TransferManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FMTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(task.status.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }

            ProgressBarView(progress: task.progress,
                            height: 4,
                            tint: task.status == .failed ? FMTheme.danger : tint)

            HStack(spacing: 8) {
                Text("\(Int(task.progress * 100))%")
                if !task.sizeText.isEmpty {
                    Text(task.sizeText)
                }
                if !task.speedText.isEmpty && task.status == .running {
                    Text(task.speedText)
                }
                Text("\(task.sourceName) → \(task.targetName)")
                    .lineLimit(1)
                Spacer()
                actions
            }
            .font(.system(size: 10))
            .foregroundStyle(FMTheme.textTertiary)

            if let error = task.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch task.direction {
        case .download: return "arrow.down.circle.fill"
        case .upload: return "arrow.up.circle.fill"
        case .copy: return "doc.on.doc.fill"
        }
    }

    private var tint: Color {
        switch task.status {
        case .completed: return FMTheme.success
        case .failed: return FMTheme.danger
        case .paused: return FMTheme.warning
        case .cancelled: return FMTheme.textTertiary
        default: return FMTheme.accent
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch task.status {
        case .running, .queued:
            Button {
                transfers.pause(task.id)
            } label: {
                Image(systemName: "pause.circle")
            }
        case .paused:
            Button {
                transfers.resume(task.id)
            } label: {
                Image(systemName: "play.circle")
            }
        case .failed, .cancelled:
            Button {
                transfers.retry(task.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FMTheme.success)
        }
        if task.status.isActive || task.status == .failed {
            Button {
                transfers.cancel(task.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(FMTheme.textTertiary)
            }
        }
    }
}
