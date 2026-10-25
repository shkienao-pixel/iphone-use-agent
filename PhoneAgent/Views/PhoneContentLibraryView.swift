import SwiftUI

/// Local viewing only. The immutable saved body is rendered verbatim without
/// Markdown, scripts, network requests, clipboard preparation or write tools.
struct PhoneContentLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PhoneContentStore.shared
    @State private var search = ""
    @State private var path: [UUID] = []

    private var visibleArtifacts: [PhoneContentArtifact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.artifacts.reversed().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionPage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.error.isEmpty ? "已保存 \(store.artifacts.count) / \(PhoneContentStore.maximumArtifacts) 份" : "保存数量暂不可用")
                        .font(.headline).accessibilityIdentifier("phoneContent.count")
                    Text("查看 Agent 保存在这部 iPhone 的 Sela 中的原文与目录。")
                        .font(.subheadline).foregroundStyle(SelaHomePalette.secondary)
                }
                TextField("搜索标题", text: $search).agentField()
                    .accessibilityIdentifier("phoneContent.search")
                if !store.error.isEmpty {
                    AgentNotice(text: store.error, error: true)
                } else if visibleArtifacts.isEmpty {
                    Text(search.isEmpty ? "暂无保存内容" : "没有匹配的标题")
                        .foregroundStyle(SelaHomePalette.secondary)
                        .accessibilityIdentifier("phoneContent.empty")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleArtifacts.enumerated()), id: \.element.id) { index, artifact in
                            if index > 0 {
                                Rectangle().fill(SelaHomePalette.line).frame(height: 0.5)
                                    .padding(.leading, 64).accessibilityHidden(true)
                            }
                            ConnectionRow(artifact.title,
                                detail: artifact.createdAt.formatted(date: .abbreviated, time: .shortened),
                                icon: "doc.text", status: "\(artifact.characterCount) 字",
                                identifier: "phoneContent.item:" + artifact.id.uuidString) {
                                path.append(artifact.id)
                            }
                        }
                    }.background(SelaHomePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .navigationTitle("本机内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("phoneContent.done")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let artifact = store.artifacts.first(where: { $0.id == id }) {
                    PhoneContentDetailView(artifact: artifact)
                } else {
                    ConnectionPage { Text("内容暂不可用") }
                }
            }
        }
        .accessibilityIdentifier("phoneContent.library")
    }
}

private struct PhoneContentDetailView: View {
    let artifact: PhoneContentArtifact
    var body: some View {
        ConnectionPage {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: artifact.title).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("phoneContent.title")
                Text(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(SelaHomePalette.secondary)
            }
            AgentCard {
                Text(verbatim: artifact.body).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("phoneContent.body")
            }
            DisclosureGroup("保存信息") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(artifact.characterCount) 字 · \(artifact.utf8Count) UTF-8 字节")
                    Text(verbatim: artifact.sha256).font(.caption2).textSelection(.enabled)
                }.font(.caption).foregroundStyle(SelaHomePalette.secondary).padding(.top, 8)
            }
        }
        .navigationTitle("内容")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("phoneContent.detail")
    }
}
