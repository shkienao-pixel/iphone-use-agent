import SwiftUI

struct FileLibraryManagementView: View {
    @ObservedObject var workflows: PhoneWorkflowWorkspace
    @Binding var selectedFiles:[UUID]
    let busy:Bool
    @State private var expanded=false
    @State private var calculating=false
    @State private var statistics:FileTransferStorageStatistics?
    @State private var localError=""
    @State private var deleteID:UUID?
    private var items:[FileTransferLibraryItem] {workflows.fileStore.managementItems(referencedBySavedPlans:workflows.referencedFileIDs)}
    var body:some View {
        DisclosureGroup("管理原件与空间",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {
                Text("归档后不再出现在新分享的选择列表。被发送回执或已保存计划引用的原件会保留，供后续核验。").font(.footnote).foregroundStyle(.secondary)
                Button(calculating ? "正在核算…" : "核算空间") {calculate()}.disabled(busy || calculating)
                if let statistics {
                    Text("核算时清单：\(statistics.artifactCount) 项 · \(statistics.verifiedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    Text("原件清单："+bytes(statistics.manifestBytes)).font(.caption)
                    if let unique=statistics.uniqueStoredFileBytes {Text("实际独立内容："+bytes(unique)).font(.caption)}
                    else {Text("有原件缺失或内容无法核实，独立占用暂不可确定。").font(.caption).foregroundStyle(.orange)}
                    if !statistics.complete {Text("缺失原件：\(statistics.unavailableArtifactIDs.count)；内容异常：\(statistics.corruptArtifactIDs.count)").font(.caption).foregroundStyle(.orange)}
                    if let saved=statistics.hardLinkSavingsBytes {Text("已复用节省："+bytes(saved)).font(.caption)}
                }
                ForEach(items) {item in
                    VStack(alignment:.leading,spacing:5) {
                        Text(item.artifact.filename).font(.subheadline)
                        Text(item.artifact.importedAt.formatted()+" · "+bytes(item.artifact.byteCount)).font(.caption).foregroundStyle(.secondary)
                        if item.sameContentSourceCount>1 {Text("导入时内容相同的记录：\(item.sameContentSourceCount) 条；各自文件名和来源保留。").font(.caption)}
                        HStack {
                            if item.archivedAt != nil {
                                Button("恢复到原件列表") {perform {try workflows.restoreArtifact(item.artifact.id)}}
                            } else {
                                Button("归档") {perform {try workflows.archiveArtifact(item.artifact.id);selectedFiles.removeAll {$0==item.artifact.id}}}
                            }
                            Spacer()
                            Button("删除本机原件",role:.destructive) {deleteID=item.artifact.id}.disabled(!item.canDelete)
                        }.disabled(busy || calculating)
                        if let reason=item.deletionBlockReason {Text(reason).font(.caption).foregroundStyle(.secondary)}
                    }
                    Divider()
                }
                if !localError.isEmpty {Text(localError).font(.footnote).foregroundStyle(.red)}
                if !workflows.fileStore.error.isEmpty {Text(workflows.fileStore.error).font(.footnote).foregroundStyle(.red)}
            }.padding(.top,10)
        }
        .alert("删除未被引用的本机原件？",isPresented:Binding(get:{deleteID != nil},set:{if !$0 {deleteID=nil}}),presenting:deleteID) { id in
            Button("取消",role:.cancel) {deleteID=nil}
            Button("删除",role:.destructive) {
                deleteID=nil
                perform {try workflows.deleteArtifact(id);selectedFiles.removeAll {$0==id};statistics=nil}
            }
        } message: { _ in Text("只删除此 App 保存的副本和导入记录，不删除文件 App 中的来源文件。已有发送回执、计划或执行中的文件不会删除。")}
    }
    private func bytes(_ value:Int64)->String {ByteCountFormatter.string(fromByteCount:value,countStyle:.file)}
    private func perform(_ action:() throws->Void) {do {try action();localError="";statistics=nil} catch {localError=error.localizedDescription}}
    private func calculate() {
        calculating=true;localError=""
        Task { @MainActor in
            defer {calculating=false}
            do {statistics=try await workflows.fileStore.storageStatisticsAsync()} catch {localError=error.localizedDescription}
        }
    }
}
