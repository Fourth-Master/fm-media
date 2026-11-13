import SwiftUI

/// 演员影片列表：点击详情页演员照片进入。
/// 多姓名匹配（参考 gfriends 的同名多姓名思路）：同一头像（thumb 相同）在不同
/// 条目的 NFO 里可能对应不同姓名（别名/译名），同脸姓名互相视为别名，
/// 别名下的影片全部纳入；同名条目（无头像或头像不同）也一并命中。
struct ActorSheet: View {
    let name: String
    let thumb: ImageRef?
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 同脸别名姓名（保留原始写法用于展示）
    private var aliasDisplayNames: [String] {
        guard let thumb else { return [] }
        var names: Set<String> = []
        for item in library.items {
            for actor in item.actors where actor.thumb == thumb {
                names.insert(actor.name)
            }
        }
        return names.sorted()
    }

    /// 命中影片：姓名属于别名集合，或头像与点击的头像相同
    private var matchedItems: [MediaItem] {
        var aliases: Set<String> = [normalized(name)]
        if let thumb {
            for item in library.items {
                for actor in item.actors where actor.thumb == thumb {
                    aliases.insert(normalized(actor.name))
                }
            }
        }
        return library.items.filter { item in
            item.actors.contains { actor in
                aliases.contains(normalized(actor.name)) || (thumb != nil && actor.thumb == thumb)
            }
        }
    }

    var body: some View {
        FMNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 14) {
                        ForEach(matchedItems) { item in
                            NavigationLink {
                                MediaDetailView(item: item)
                            } label: {
                                PosterGridCard(item: item, compact: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .fmTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FMImageView(ref: thumb, cornerRadius: 32)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                let aliases = aliasDisplayNames.filter { normalized($0) != normalized(name) }
                if !aliases.isEmpty {
                    Text("别名：" + aliases.joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(FMTheme.textTertiary)
                        .lineLimit(2)
                }
                Text("共 \(matchedItems.count) 部影片")
                    .font(.caption)
                    .foregroundStyle(FMTheme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}
