import SwiftUI
import UIKit

struct WorkflowDiagnosticsView: View {
    @ObservedObject var store:WorkflowDiagnosticsStore
    let busy:Bool
    @State private var exported:URL?
    @State private var preview:Data?
    @State private var localError=""
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("关键画面与诊断").font(.headline)
            Text("在本机保留有限数量的关键画面、识别文字、动作和停因。待核验发送的证据受到保护；空间不足时会明确显示原图未保存。").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("生成诊断文件") {perform {exported=try store.export().url}}.disabled(busy || store.records.isEmpty)
                if let exported {ShareLink(item:exported) {Label("分享",systemImage:"square.and.arrow.up")}.disabled(busy)}
                Spacer()
                Button("清理未保护记录",role:.destructive) {perform {_ = try store.clearResolved();exported=nil}}.disabled(busy)
            }
            Text("导出文件包含截图和识别文字，请检查后再选择分享目标。没有自动上传。").font(.caption).foregroundStyle(.secondary)
            if !localError.isEmpty {Text(localError).font(.footnote).foregroundStyle(.red)}
            if let error=store.error {Text(error).font(.footnote).foregroundStyle(.red)}
            ForEach(store.records.reversed()) {record in
                VStack(alignment:.leading,spacing:6) {
                    Text(boundary(record.context.boundary)).font(.subheadline.bold())
                    Text(record.context.confirmedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    if let action=record.context.action {Text(action).font(.footnote)}
                    if let reason=record.context.reason {Text(reason).font(.footnote)}
                    if let result=record.context.result {Text(result).font(.footnote)}
                    if record.isProtectedPendingSubmission {Text("发送仍待核验，证据已保护").font(.caption).foregroundStyle(.orange)}
                    Text(record.imageStored ? "原图已保存" : "原图未保存；仅保留本条诊断文字").font(.caption).foregroundStyle(.secondary)
                    if record.imageStored {Button("查看关键画面") {perform {preview=try store.preview(id:record.id)}}}
                }.frame(maxWidth:.infinity,alignment:.leading)
                Divider()
            }
            if store.records.isEmpty {Text("尚无诊断记录").foregroundStyle(.secondary)}
        }.agentPanel()
        .sheet(isPresented:Binding(get:{preview != nil},set:{if !$0 {preview=nil}})) {
            NavigationStack {
                ScrollView {
                    if let preview,let image=UIImage(data:preview) {Image(uiImage:image).resizable().scaledToFit()}
                    else {Text("原图不可读取，未显示替代画面")}
                }
                .navigationTitle("原始关键画面")
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button("关闭") {preview=nil}}}
            }
        }
    }
    private func perform(_ action:() throws->Void) {do {try action();localError=""} catch {localError=error.localizedDescription}}
    private func boundary(_ value:WorkflowDiagnosticBoundary)->String {
        switch value {
        case .observed:return "已识别当前页面"
        case .beforeInput:return "动作前"
        case .afterInput:return "动作已返回"
        case .paused:return "已暂停"
        case .failed:return "流程停止或出错"
        case .completed:return "本次流程已结束"
        case .pendingSubmission:return "发送结果待核验"
        }
    }
}
