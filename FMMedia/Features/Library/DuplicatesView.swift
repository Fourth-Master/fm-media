import SwiftUI

/// 重复番号检测与清理
struct DuplicatesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var database: AppDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var report: DuplicateFinder.Report?
    @State private var selected: Set<String> = []
    /// 手动指定的保留条目（组码 → 条目 id）；未指定时用分析建议（LTX 优先）
    @State private var keepChoices: [String: String] = [:]
    @State private var isPurging = false
    @State private var resultText: String?
    @State private var deleteRemoteFiles = false
    @State private var showConfirm = false

    var body: some View {
        Group {
            if let report {
                if report.groups.isEmpty {
                    ScrollView {
                        EmptyStateView(icon: "checkmark.seal",
                                       title: "没有重复番号",
                                       message: "当前媒体库中每个番号只有一个条目。")
                            .padding(.top, 80)
                    }
                } else {
                    List {
                        Section {
                            HStack {
                                Text("共 \(report.groups.count) 组重复，可清理 \(report.totalDuplicates) 部")
                                    .font(.system(size: 12))
                                    .foregroundStyle(FMTheme.textTertiary)
                                Spacer()
                                Button(selected.count == report.totalDuplicates ? "取消全选" : "全选建议清理") {
                                    if selected.count == report.totalDuplicates {
                                        selected.removeAll()
                                    } else {
                                        selected = Set(report.groups.flatMap { group in
                                            candidates(of: group)
                                                .filter { $0.id != effectiveKeepID(group) }
                                                .map { $0.id }
                                        })
                                    }
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(FMTheme.accent)
                            }

                            Toggle("同时删除远程服务器文件", isOn: $deleteRemoteFiles)
                                .font(.system(size: 13))

                            if let resultText {
                                Text(resultText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(FMTheme.success)
                            }
                        } footer: {
                            Text(deleteRemoteFiles
                                 ? "Emby/Jellyfin 通过接口删除条目（需账号有删除权限）；WebDAV/SMB 直接删除文件与同目录封面/NFO。删除失败时会保留条目。"
                                 : "绿色「保留」为建议（优先 LTX 版本），默认未勾选任何待清理条目。点条目勾选删除；点「保留」按钮可自行更换要保留的版本。勾选上方开关可同时删除服务器上的影片与封面/NFO，本机影片始终连文件一起删除。")
                        }.fmGlassListRow()

                        ForEach(report.groups) { group in
                            Section {
                                ForEach(candidates(of: group)) { candidate in
                                    if candidate.id == effectiveKeepID(group) {
                                        keepRow(group, candidate)
                                    } else {
                                        duplicateRow(group, candidate)
                                    }
                                }
                            } header: {
                                Text(group.code)
                            }.fmGlassListRow()
                        }
                    }
                    .listStyle(.insetGrouped)
                    .fmScrollContentBackgroundHidden()
                }
            } else {
                ProgressView("正在分析媒体库…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fmPageBackground()
        .navigationTitle("重复番号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .fmTrailing) {
                if selected.count > 0 {
                    Button("清理 \(selected.count)") { showConfirm = true }
                        .foregroundStyle(FMTheme.danger)
                        .disabled(isPurging)
                }
            }
        }
        .confirmationDialog("清理 \(selected.count) 部重复影片？",
                            isPresented: $showConfirm,
                            titleVisibility: .visible) {
            Button("清理（同时删除封面/NFO/字幕）", role: .destructive) {
                Task { await purge() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteRemoteFiles
                 ? "本机与远程影片都会连同封面、大图、NFO、字幕一起删除；本机目录清空后也会被删除。服务器端删除不可恢复。"
                 : "本机影片会连同封面、大图、NFO、字幕与 extrafanart 一起删除；清空后目录也会被删除。远程条目仅从媒体库移除。此操作不可恢复。")
        }
        .task {
            if report == nil {
                report = DuplicateFinder.analyze(items: library.items)
            }
        }
    }

    // MARK: - 保留项选择

    /// 组内全部条目（建议保留项排第一）
    private func candidates(of group: DuplicateFinder.Group) -> [DuplicateFinder.Candidate] {
        [group.keep] + group.duplicates
    }

    /// 生效的保留条目：手动指定优先，未指定或已失效时用分析建议（LTX 优先）
    private func effectiveKeepID(_ group: DuplicateFinder.Group) -> String {
        if let override = keepChoices[group.code],
           candidates(of: group).contains(where: { $0.id == override }) {
            return override
        }
        return group.keep.id
    }

    private func setKeep(_ group: DuplicateFinder.Group, _ id: String) {
        keepChoices[group.code] = id
        selected.remove(id)   // 保留项不能同时是待清理项
    }

    // MARK: - 行

    private func keepRow(_ group: DuplicateFinder.Group, _ candidate: DuplicateFinder.Candidate) -> some View {
        let isSuggestion = candidate.id == group.keep.id
        return HStack(spacing: 10) {
            FMImageView(ref: candidate.item.poster, cornerRadius: 6)
                .frame(width: 34, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(isSuggestion ? "建议保留：" + candidate.item.rawName
                                  : "保留（已手动选择）：" + candidate.item.rawName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FMTheme.success)
                Text(reasonText(candidate))
                    .font(.system(size: 10))
                    .foregroundStyle(FMTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(FMTheme.success)
        }
        .padding(.vertical, 2)
    }

    private func duplicateRow(_ group: DuplicateFinder.Group, _ candidate: DuplicateFinder.Candidate) -> some View {
        Button {
            selected.toggleMembership(candidate.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(candidate.id) ? FMTheme.danger : FMTheme.textTertiary)

                FMImageView(ref: candidate.item.poster, cornerRadius: 6)
                    .frame(width: 34, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.item.rawName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FMTheme.textPrimary)
                        .lineLimit(1)
                    Text(reasonText(candidate))
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.warning)
                        .lineLimit(2)
                }
                Spacer()
                if let size = candidate.item.video?.size, size > 0 {
                    Text(size.fileSizeText)
                        .font(.system(size: 10))
                        .foregroundStyle(FMTheme.textTertiary)
                }

                // 自行更换保留条目
                Button {
                    setKeep(group, candidate.id)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 15))
                        Text("保留")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(FMTheme.accent)
                    .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isPurging)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(isPurging)
    }

    private func reasonText(_ candidate: DuplicateFinder.Candidate) -> String {
        let base = candidate.item.displayBadges(showCracked: true, showSubtitle: true).joined(separator: " / ")
        let reasons = candidate.reasons.joined(separator: "、")
        if base.isEmpty { return reasons.isEmpty ? "—" : reasons }
        return base + (reasons.isEmpty ? "" : " · " + reasons)
    }

    // MARK: - 清理

    private func purge() async {
        isPurging = true
        defer { isPurging = false }
        let targets = library.items.filter { selected.contains($0.id) }
        let (removed, errors) = await DuplicateFinder.purge(items: targets,
                                                            deleteRemoteFiles: deleteRemoteFiles,
                                                            library: library,
                                                            database: database)
        resultText = errors.isEmpty
            ? "已清理 \(removed) 部"
            : "已清理 \(removed) 部，\(errors.count) 项失败：\(errors.prefix(2).joined(separator: "；"))"
        selected.removeAll()
        report = DuplicateFinder.analyze(items: library.items)
    }
}
