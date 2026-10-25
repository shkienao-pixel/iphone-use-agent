import SwiftUI

/// Only explicit native controls create a human finding; closing this page has
/// no effect. A finding records what the user saw, never an automatic receipt.
struct FileTransferReviewView: View {
    @ObservedObject var workflows: PhoneWorkflowWorkspace
    let operationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var resolution: FileTransferHumanResolution = .stillUnknown
    @State private var detail = ""
    @State private var localError = ""
    private var operation: FileTransferOperation? {workflows.fileStore.operations.first {$0.operationID==operationID}}
    var body: some View {
        NavigationStack {
            Form {
                if let operation {
                    Section("选择已独立检查的原件") {
                        Text(operation.recipient.displayName).font(.headline)
                        Text("只记录你在目标应用逐项检查的结果；不会触发发送，也不证明送达或已读。").font(.footnote).foregroundStyle(.secondary)
                        ForEach(operation.manifest) {item in
                            if let progress=operation.items.first(where:{$0.artifactID==item.id}) {
                                if progress.pending {
                                    Toggle(isOn:Binding(get:{selected.contains(item.id)},set:{if $0 {selected.insert(item.id)} else {selected.remove(item.id)}})) {
                                        VStack(alignment:.leading) {
                                            Text("\(item.ordinal+1). \(item.artifact.filename)")
                                            Text(state(progress.state)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    LabeledContent("\(item.ordinal+1). \(item.artifact.filename)",value:state(progress.state))
                                }
                            }
                        }
                    }
                    Section("这些原件的核验结果") {
                        Picker("结果",selection:$resolution) {
                            Text("仍无法确定").tag(FileTransferHumanResolution.stillUnknown)
                            Text("我已确认提交").tag(FileTransferHumanResolution.userReportsSubmitted)
                            Text("我已确认未提交").tag(FileTransferHumanResolution.userConfirmsNotSubmitted)
                        }
                        TextField("在哪里检查、看到了什么",text:$detail,axis:.vertical).lineLimit(3...8)
                        Text("每次只勾选结果相同的文件；其余文件保持原状态，未知项仍阻止重发。").font(.footnote).foregroundStyle(.secondary)
                        Button("保存 \(selected.count) 项核验结果") {save(operation)}
                            .disabled(selected.isEmpty || detail.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || workflows.fileStore.hasActiveOperation)
                    }
                    if !localError.isEmpty {Text(localError).foregroundStyle(.red)}
                    if let reviews=operation.humanReviews,!reviews.isEmpty {
                        Section("已保存的人工记录") {
                            ForEach(reviews.reversed()) {review in
                                VStack(alignment:.leading,spacing:5) {
                                    Text("\(review.artifactIDs.count) 项 · \(label(review.resolution))")
                                    Text(review.detail).font(.footnote)
                                    Text(review.reviewedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {Text("该回执不可读取，未修改任何结果。")}
            }
            .navigationTitle("逐文件核验")
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("完成") {dismiss()}}}
        }
    }
    private func state(_ value:FileTransferItemProgress.State)->String {
        switch value {
        case .notSubmitted:return "尚未提交"
        case .submissionPending:return "提交待核验"
        case .uploading:return "上传中"
        case .observedSent:return "界面已观察到提交"
        case .userReportedSubmitted:return "用户确认已提交"
        case .confirmedFailed:return "确认未提交"
        case .unknown:return "结果未知"
        }
    }
    private func label(_ value:FileTransferHumanResolution) -> String {
        switch value {case .stillUnknown:return "仍未知";case .userReportsSubmitted:return "用户确认已提交";case .userConfirmsNotSubmitted:return "用户确认未提交"}
    }
    private func save(_ operation:FileTransferOperation) {
        do {
            let request=FileTransferReviewRequest(operationID:operationID,artifactIDs:operation.manifest.map(\.id).filter {selected.contains($0)},resolution:resolution,detail:detail.trimmingCharacters(in:.whitespacesAndNewlines))
            try request.validate(operation:operation)
            try workflows.reviewFile(request)
            selected=[];detail="";localError=""
        } catch {localError=error.localizedDescription}
    }
}
