import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Native scope selection and explicit execution for the saved domain workflows.
/// Opening this view performs no screen reads, model requests, or submissions.
struct WorkflowWorkspaceView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workflows: PhoneWorkflowWorkspace
    private enum Workspace: String, CaseIterable { case collection = "采集", chat = "聊天", files = "文件", diagnostics = "诊断" }
    private enum ChatRangeMode: String, CaseIterable { case currentPage = "当前可见页", time = "时间范围" }
    @State private var workspace: Workspace = .collection
    @State private var localError = ""
    @State private var transitionMessage = ""

    @State private var keyword = ""
    @State private var sampleSize = 20
    @State private var xhsMaxSeconds: Double = 120
    @State private var sort = "综合"
    @State private var filters = ""
    @State private var collectProfile = false
    @State private var profileID = ""
    @State private var xhsSaveAuthorized = false
    @State private var xhsRunAuthorized = false
    @State private var selectedXHS = ""

    @State private var chatTitle = "文件传输助手"
    @State private var chatStableID = PhonePageAdapters.canonicalConversation("文件传输助手") ?? ""
    @State private var chatRangeMode: ChatRangeMode = .currentPage
    @State private var chatCount = 100
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var maxPages = 20
    @State private var chatSaveAuthorized = false
    @State private var chatRunAuthorized = false
    @State private var selectedChat = ""

    @State private var importing = false
    @State private var fileQuery = ""
    @State private var selectedFiles: [UUID] = []
    @State private var recipientDescription = "文件传输助手"
    @State private var fileShareConfirmed = false
    @State private var automaticAccount = ""
    @State private var automaticConfirmed = false
    @State private var selectedAutomaticPlan = ""
    @State private var presentedShareID: UUID?
    @State private var shareHostID = UUID()
    @State private var reviewOperationID: String?

    private var busy: Bool {
        model.interactionBusy || model.queueRunning || model.calibrating || model.executor.calibrationInProgress || workflows.fileStore.hasActiveOperation
    }
    private var guiBlocked: Bool { busy || workflows.hasPendingReview }
    private var modelBlocked: Bool { guiBlocked || !model.modelReady || !model.consentReady }
    private var chosenXHS: XiaohongshuCollectionTask? { workflows.xhsTasks.first { $0.id == selectedXHS } }
    private var chosenChat: SavedChatWorkflow? { workflows.chatPlans.first { $0.id == selectedChat } }
    private var matchingArtifacts: [FileTransferArtifact] {
        let query = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let available=workflows.fileStore.artifacts.filter {!workflows.fileStore.isArchived(id:$0.id)}
        return query.isEmpty ? available : available.filter { $0.filename.localizedStandardContains(query) }
    }
    private var selectedArtifacts: [FileTransferArtifact] {
        selectedFiles.compactMap { id in workflows.fileStore.artifacts.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("长任务工作区").font(.title2.bold())
                    Spacer()
                    Button("关闭") { dismiss() }.frame(minHeight: 44).disabled(model.manualBusy)
                }
                Text("先保存读取范围；采集和聊天从当前目标页面开始，原始证据与进度保存在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("工作流", selection: $workspace) {
                    ForEach(Workspace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                switch workspace {
                case .collection: collectionPanel
                case .chat: chatPanel
                case .files: filesPanel
                case .diagnostics:
                    WorkflowDiagnosticsView(store:workflows.diagnostics,busy:busy)
                    Button("同步已核验回执的证据保留状态") {workflows.reconcileDiagnosticProtection()}.disabled(busy)
                }
                if model.manualBusy {
                    HStack {
                        ProgressView()
                        Text(transitionMessage.isEmpty ? "正在处理，进度会保存" : transitionMessage).font(.footnote)
                        Spacer()
                        Button("停止") { model.stop(); transitionMessage = "" }.frame(minHeight: 44)
                    }
                }
                if workflows.hasPendingReview {
                    AgentNotice(text: "有文件提交待核验，已暂停新的采集、聊天滚动和文件提交。请到文件页按实际结果核查；未知不能当未发送。")
                }
                Text(workflows.status).font(.footnote).textSelection(.enabled)
                if !workflows.diagnosticRecordingError.isEmpty {AgentNotice(text:workflows.diagnosticRecordingError,error:true)}
                if !localError.isEmpty { AgentNotice(text: localError, error: true) }
                if !model.notice.isEmpty { AgentNotice(text: model.notice, error: true) }
                resultsPanel
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {workflows.registerShareHost(shareHostID)}
        .onDisappear {workflows.unregisterShareHost(shareHostID)}
        .interactiveDismissDisabled(model.manualBusy)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: imported)
        .sheet(item: shareBinding, onDismiss: shareDismissed) { presentation in
            WorkflowNativeShareSheet(files: presentation.files, onPresented: { workflows.nativeSharePresented(id:presentation.id) }) { result in
                workflows.finishNativeShare(id: presentation.id, result: result)
            }
            .onAppear { presentedShareID = presentation.id }
        }
        .sheet(isPresented:reviewBinding) {
            if let id=reviewOperationID {FileTransferReviewView(workflows:workflows,operationID:id)}
        }
        .onChange(of: selectedXHS) { _, _ in xhsRunAuthorized = false }
        .onChange(of: selectedChat) { _, _ in chatRunAuthorized = false }
        .onChange(of: selectedFiles) { _, _ in fileShareConfirmed = false; automaticConfirmed = false }
        .onChange(of: recipientDescription) { _, _ in fileShareConfirmed = false; automaticConfirmed = false }
        .onChange(of: automaticAccount) { _, _ in automaticConfirmed = false }
        .onChange(of: collectProfile) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: profileID) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: keyword) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: sampleSize) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: xhsMaxSeconds) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: sort) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: filters) { _, _ in xhsSaveAuthorized = false }
        .onChange(of: chatTitle) { _, _ in chatSaveAuthorized = false }
        .onChange(of: chatStableID) { _, _ in chatSaveAuthorized = false }
        .onChange(of: chatRangeMode) { _, _ in chatSaveAuthorized = false }
        .onChange(of: chatCount) { _, _ in chatSaveAuthorized = false }
        .onChange(of: startDate) { _, _ in chatSaveAuthorized = false }
        .onChange(of: endDate) { _, _ in chatSaveAuthorized = false }
        .onChange(of: maxPages) { _, _ in chatSaveAuthorized = false }
        .onChange(of: model.manualBusy) { _, active in if !active { transitionMessage = "" } }
    }

    private var collectionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新建小红书采集范围").font(.headline)
                TextField("关键词", text: $keyword).agentField().accessibilityLabel("采集关键词")
                Toggle("采集当前作者主页笔记", isOn:$collectProfile)
                if collectProfile { TextField("资料页实际小红书号",text:$profileID).agentField() }
                Stepper("目标样本：\(sampleSize) 条", value: $sampleSize, in: 1...200)
                Picker("最多运行", selection: $xhsMaxSeconds) {
                    Text("2 分钟").tag(Double(120))
                    Text("10 分钟").tag(Double(600))
                    Text("30 分钟").tag(Double(1800))
                    Text("1 小时").tag(Double(3600))
                    Text("2 小时").tag(Double(7200))
                }
                Text("达到样本、运行时限或读取边界后结束；暂停后继续使用剩余预算。保持手机解锁、屏幕共享和配件连接。").font(.caption).foregroundStyle(.secondary)
                Picker("排序", selection: $sort) {
                    Text("综合").tag("综合")
                    Text("最新").tag("最新")
                    Text("最多点赞").tag("最多点赞")
                }.pickerStyle(.menu)
                TextField("筛选条件，每行一项；没有则留空", text: $filters, axis: .vertical).lineLimit(2...5).agentField()
                Text("从指定搜索结果或作者主页开始。排序/筛选核验实际选中态；缺来源时尝试受控复制链接，需返回本App读取时会保存并暂停。只统计实际样本，未读媒体不纳入结论。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("我明确授权保存并读取以上公开搜索范围", isOn: $xhsSaveAuthorized)
                Button("保存采集范围") { saveXHS() }
                    .buttonStyle(AgentButtonStyle(primary: false))
                    .disabled(busy || !xhsSaveAuthorized || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.agentPanel()
            if !workflows.xhsTasks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("已保存采集", selection: $selectedXHS) {
                        Text("选择任务").tag("")
                        ForEach(workflows.xhsTasks) { task in
                            Text("\(task.keyword) · \(task.sampleSize) 条 · \(task.sort)").tag(task.id)
                        }
                    }.pickerStyle(.menu)
                    if let task = chosenXHS {
                        Text("\(task.keyword) · \(task.profileID == nil ? "当前搜索结果" : "指定作者主页") · 最多 \(task.sampleSize) 条 · \(task.sort) · 运行时限 \(Int(task.stops.maxSeconds / 60)) 分钟").font(.subheadline)
                        if !task.filters.isEmpty { Text("筛选：" + task.filters.joined(separator: "、")).font(.caption) }
                        if let run = workflows.recentXHSRuns.first(where: { $0.id == task.id }) {
                            Text("已保存 \(run.notes.count) 条；待核验 \(run.pending.count) 条；\(run.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        if workflows.recentXHSRuns.first(where:{$0.id==task.id})?.pending.contains(where:{$0.sourceCapture != nil}) == true {
                            Button("核验已复制的笔记来源") { model.manualAction {try await workflows.completeXHSSource(id:task.id)} }
                                .disabled(guiBlocked)
                            Text("请在复制后尽快返回此页核验；中间另有复制或证据不符时不会绑定来源，也不会自动重按复制。").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("允许本次按此已保存范围采集或续作", isOn: $xhsRunAuthorized)
                        Text("点击后有 3 秒切换至对应搜索结果页；请先开启手机屏幕共享并完成控制准备。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("3 秒后开始 / 续作采集") { collect(task.id) }
                            .buttonStyle(AgentButtonStyle()).disabled(guiBlocked || !xhsRunAuthorized)
                        HStack {
                            Button("查看明细 / 导出") { perform { try workflows.showSavedXHS(task.id) } }
                                .disabled(busy || !workflows.recentXHSRuns.contains { $0.id == task.id })
                            Spacer()
                            Button("分析已有样本") { analyze(task.id) }
                                .disabled(modelBlocked || !workflows.recentXHSRuns.contains { $0.id == task.id })
                        }.frame(minHeight: 44)
                        Text("分析按钮会将已保存且允许分析的文字发送给当前已授权模型；采集与分析分别执行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.agentPanel()
            }
        }
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("新建聊天读取范围").font(.headline)
                TextField("准确会话标题", text: $chatTitle).agentField().accessibilityLabel("聊天会话标题")
                TextField("微信号或已保存的稳定会话 ID", text: $chatStableID).agentField().textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("普通联系人填写真实微信号，并先打开该人的个人资料页。流程核对微信号后点击当前‘发消息’进入会话；不会按昵称搜索或挑选同名联系人。文件传输助手已有历史时，请先打开助手个人资料页，核对 filehelper 账号与互传说明；首次使用也可从显示互传说明的聊天页开始。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("使用内置文件传输助手") {
                    chatTitle = "文件传输助手"
                    chatStableID = PhonePageAdapters.canonicalConversation(chatTitle) ?? ""
                }.frame(minHeight: 44)
                Picker("读取范围", selection: $chatRangeMode) {
                    ForEach(ChatRangeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if chatRangeMode == .currentPage {
                    Stepper("本页从底部向前最多 \(chatCount) 条", value: $chatCount, in: 1...200, step: 1)
                    Text("只取本次核号进入后首个可见聊天页的已识别消息，固定保存所选样本，不翻页或续读。当前无法证明会话最新端，因此不称为‘最近 N 条’；无文字气泡和媒介可能未被识别。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    DatePicker("开始时间", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("结束时间", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                }
                if chatRangeMode == .time { Stepper("单次最多 \(maxPages) 页", value: $maxPages, in: 1...300) }
                Toggle("我明确授权读取以上会话及消息范围", isOn: $chatSaveAuthorized)
                Button("保存聊天范围") { saveChat() }
                    .buttonStyle(AgentButtonStyle(primary: false))
                    .disabled(busy || !chatSaveAuthorized || chatTitle.isEmpty || chatStableID.isEmpty || (chatRangeMode == .time && startDate > endDate))
            }.agentPanel()
            if !workflows.chatPlans.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("已保存聊天范围", selection: $selectedChat) {
                        Text("选择范围").tag("")
                        ForEach(workflows.chatPlans) { plan in Text("\(plan.title) · \(rangeDescription(plan.range))").tag(plan.id) }
                    }.pickerStyle(.menu)
                    if let plan = chosenChat {
                        let savedSession = workflows.recentChatSessions.first(where: { $0.id == plan.id })
                        Text(plan.title + " · " + rangeDescription(plan.range)).font(.subheadline)
                        Text("稳定 ID：\(plan.stableID)").font(.caption).textSelection(.enabled)
                        if let session = savedSession {
                            Text("本地观察 \(session.messages.count) 条；本范围可总结 \(session.selectedMessages.count) 条；记录状态 \(session.state.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        if case .latest = plan.range {
                            Text("历史‘最近 N 条’范围的最新端未获证明，旧记录和报告仍可查看、导出，但不能重新读取或上传模型。请显式新建‘当前可见页’范围。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if case .currentPage = plan.range, savedSession?.pageSelection != nil {
                            Text("本页样本已固定。重新读取或换页需新建范围；现有样本可以查看、导出和总结。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle("允许本次按此已保存会话和范围读取", isOn: $chatRunAuthorized)
                            Text("普通联系人先打开个人资料页；内置助手已有历史时打开助手个人资料页。点击后有 3 秒切换。时间范围恢复仍需重新核号；语音、图片和附件未解析部分保留未读。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("3 秒后读取") { read(plan.id, direction: .older) }
                                if case .time = plan.range {
                                    Spacer()
                                    Button("3 秒后读取新增") { read(plan.id, direction: .newer) }
                                }
                            }.frame(minHeight: 44).disabled(guiBlocked || !chatRunAuthorized)
                        }
                        HStack {
                            Button("查看证据 / 导出") { perform { try workflows.showSavedChat(plan.id) } }
                                .disabled(busy || !workflows.recentChatSessions.contains { $0.id == plan.id })
                            Spacer()
                            Button("总结已有消息") { summarize(plan.id) }
                                .disabled(modelBlocked || savedSession?.selectedMessages.isEmpty != false)
                        }.frame(minHeight: 44)
                        Text("总结按钮会将已保存的此范围消息发送给当前已授权模型；未读内容不会补写为事实。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.agentPanel()
            }
        }
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("原件资料库").font(.headline)
                Text("导入后在本机保存原始字节、大小、来源和 SHA256；视频不会在这里重编码。点选顺序就是分享清单顺序。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("从文件 App 导入原件") { localError = ""; importing = true }
                    .buttonStyle(AgentButtonStyle(primary: false)).disabled(busy)
                TextField("按文件名查找原件", text: $fileQuery).agentField().accessibilityLabel("查找原件文件名")
                if workflows.fileStore.artifacts.isEmpty {
                    Text("尚未导入文件").font(.footnote).foregroundStyle(.secondary)
                } else if matchingArtifacts.isEmpty {
                    Text("没有匹配的文件；已选清单继续保留").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(matchingArtifacts) { artifact in
                    Button { toggleFile(artifact.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedFiles.contains(artifact.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.filename).font(.subheadline).foregroundStyle(.primary)
                                Text(fileDetail(artifact)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if let index = selectedFiles.firstIndex(of: artifact.id) { Text("\(index + 1)").font(.caption.monospacedDigit()) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }
            }.agentPanel()
            FileLibraryManagementView(workflows:workflows,selectedFiles:$selectedFiles,busy:busy).agentPanel()
            if !selectedArtifacts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("待分享原件 · \(selectedArtifacts.count) 项").font(.headline)
                        Spacer()
                        Button("清空") { selectedFiles = [] }.disabled(busy)
                    }
                    ForEach(Array(selectedArtifacts.enumerated()), id: \.element.id) { index, artifact in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(index + 1). \(artifact.filename)").font(.subheadline)
                                Text(fileDetail(artifact)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button { moveFile(index, by: -1) } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("上移 " + artifact.filename).disabled(busy || index == 0).frame(minWidth: 36, minHeight: 44)
                            Button { moveFile(index, by: 1) } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("下移 " + artifact.filename).disabled(busy || index + 1 == selectedArtifacts.count).frame(minWidth: 36, minHeight: 44)
                        }
                    }
                    TextField("你要求的收件对象说明", text: $recipientDescription).agentField()
                    Toggle("我已核对原件与顺序，将亲自选择并核对分享目标", isOn: $fileShareConfirmed)
                    Text("目标说明仅记录你的要求，分享扩展中的实际收件人尚未核验。扩展 completed 回调也会保留待核验，不能证明已发送、收到或已读。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("按准确对象自动发送").font(.subheadline.bold())
                    TextField("准确微信号；内置文件传输助手可留空",text:$automaticAccount).agentField().textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("我授权向以上准确对象自动发送这批原件及顺序",isOn:$automaticConfirmed)
                    Button("保存自动发送范围") {
                        perform {selectedAutomaticPlan=try workflows.createAutomaticFilePlan(title:recipientDescription,account:automaticAccount,artifactIDs:selectedFiles);automaticConfirmed=false}
                    }.disabled(guiBlocked || !automaticConfirmed)
                    Text("自动流程从本App前台启动真实分享。在实际扩展中必须核对准确账号、完整文件清单、字节数和原件状态，才点击一次发送；只显示昵称时会停下，结果未知不重发。").font(.caption).foregroundStyle(.secondary)
                    Button("打开系统分享面板") { shareSelected() }
                        .buttonStyle(AgentButtonStyle())
                        .disabled(guiBlocked || !fileShareConfirmed || recipientDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedArtifacts.count > 50)
                }.agentPanel()
            }
            if !workflows.filePlans.isEmpty {
                VStack(alignment:.leading,spacing:12) {
                    Picker("已保存的自动发送范围",selection:$selectedAutomaticPlan) {
                        Text("选择准确范围").tag("")
                        ForEach(workflows.filePlans) {plan in Text(plan.recipient.displayName+" · \(plan.artifactIDs.count) 项").tag(plan.id)}
                    }
                    if let plan=workflows.filePlans.first(where:{$0.id==selectedAutomaticPlan}) {
                        Text(plan.recipient.stableID).font(.caption).textSelection(.enabled)
                        ForEach(Array(plan.artifactIDs.enumerated()),id:\.element) {index,id in
                            Text("\(index+1). \(workflows.fileStore.artifacts.first(where:{$0.id==id})?.filename ?? "原件不可用")").font(.caption)
                        }
                        Button("启动这次自动发送") {
                            model.manualAction(allowsBackgroundScreen:true) {_ = try await workflows.automaticSend(id:plan.id,gui:workflows.driver())}
                        }.buttonStyle(AgentButtonStyle()).disabled(guiBlocked)
                    }
                }.agentPanel()
            }
            if !workflows.fileStore.operations.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("发送阶段与待核验记录").font(.headline)
                    ForEach(Array(workflows.fileStore.operations.reversed())) { operation in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(operation.recipient.displayName + " · " + operation.stage.rawValue).font(.subheadline.bold())
                            Text("要求目标，未必是扩展实际收件人").font(.caption).foregroundStyle(.secondary)
                            ForEach(operation.manifest) { item in
                                let state = operation.items.first { $0.artifactID == item.id }?.state.rawValue ?? "unknown"
                                Text("\(item.ordinal + 1). \(item.artifact.filename) · \(state)").font(.caption)
                            }
                            Text(operation.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(operation.operationID).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if operation.pending || operation.humanReviews?.isEmpty == false {
                                Button("逐文件核验 / 查看人工记录") { reviewOperationID = operation.operationID }
                                    .frame(minHeight: 44).disabled(busy)
                            }
                        }
                        Divider()
                    }
                }.agentPanel()
            }
        }
    }

    @ViewBuilder private var resultsPanel: some View {
        if !workflows.reportText.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("结果与证据").font(.headline)
                    Spacer()
                    if let url = workflows.exportURL { ShareLink(item: url) { Label("导出", systemImage: "square.and.arrow.up") } }
                }
                let previewEnd = workflows.reportText.index(workflows.reportText.startIndex, offsetBy: 18000,
                    limitedBy: workflows.reportText.endIndex) ?? workflows.reportText.endIndex
                if previewEnd != workflows.reportText.endIndex {
                    Text("下方预览前 18000 字；完整证据与结果请导出查看。").font(.caption).foregroundStyle(.secondary)
                }
                Text(String(workflows.reportText[..<previewEnd])).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.agentPanel()
        }
    }

    private func saveXHS() {
        perform {
            let items = filters.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            selectedXHS = try workflows.createXHS(keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines), sampleSize: sampleSize, sort: sort, filters: collectProfile ? [] : items, profileID: collectProfile ? profileID.trimmingCharacters(in:.whitespacesAndNewlines) : nil, maxSeconds:xhsMaxSeconds)
            xhsSaveAuthorized = false; xhsRunAuthorized = false
        }
    }
    private func saveChat() {
        perform {
            let range: ChatReadRange = chatRangeMode == .currentPage ? .currentPage(limit: chatCount) : .time(start: startDate, end: endDate)
            selectedChat = try workflows.createChat(title: chatTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                stableID: chatStableID.trimmingCharacters(in: .whitespacesAndNewlines), range: range, maxPages: chatRangeMode == .currentPage ? 1 : maxPages)
            chatSaveAuthorized = false; chatRunAuthorized = false
        }
    }
    private func collect(_ id: String) {
        guard !guiBlocked, xhsRunAuthorized else { return }
        xhsRunAuthorized = false; localError = ""; transitionMessage = "请在 3 秒内切换到指定小红书搜索结果页"
        model.manualAction(allowsBackgroundScreen: true) {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            try Task.checkCancellation()
            transitionMessage = "正在按已保存范围采集"
            _ = try await workflows.collectXHS(id: id, gui: workflows.driver())
        }
    }
    private func analyze(_ id: String) {
        guard !modelBlocked else { return }; localError = ""; transitionMessage = "正在分析已保存样本"
        model.manualAction { try await workflows.analyzeXHS(id: id) }
    }
    private func read(_ id: String, direction: ChatReadDirection) {
        guard !guiBlocked, chatRunAuthorized else { return }
        chatRunAuthorized = false; localError = ""; transitionMessage = "请在 3 秒内切换到指定微信会话"
        model.manualAction(allowsBackgroundScreen: true) {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            try Task.checkCancellation()
            transitionMessage = "正在读取指定会话的消息证据"
            _ = try await workflows.readChat(id: id, gui: workflows.driver(), direction: direction)
        }
    }
    private func summarize(_ id: String) {
        guard !modelBlocked else { return }; localError = ""; transitionMessage = "正在总结已保存的聊天证据"
        model.manualAction { _ = try await workflows.summarizeChat(id: id) }
    }
    private func imported(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let previous = Set(workflows.fileStore.artifacts.map(\.id))
            localError = ""; transitionMessage = "正在复制并校验原件"
            model.manualAction {
                try await workflows.importFiles(urls)
                let newIDs = workflows.fileStore.artifacts.filter { !previous.contains($0.id) }.map(\.id)
                selectedFiles.append(contentsOf: newIDs.filter { !selectedFiles.contains($0) })
                fileShareConfirmed = false
            }
        case .failure(let error): localError = error.localizedDescription
        }
    }
    private func shareSelected() {
        guard !guiBlocked, fileShareConfirmed, !selectedFiles.isEmpty else { return }
        let ids = selectedFiles, target = recipientDescription
        fileShareConfirmed = false; localError = ""; transitionMessage = "请在系统分享面板中独立核对目标和原件"
        model.manualAction { try await workflows.nativeSend(artifactIDs: ids, recipientDescription: target) }
    }
    private func toggleFile(_ id: UUID) {
        if let index = selectedFiles.firstIndex(of: id) { selectedFiles.remove(at: index) }
        else { selectedFiles.append(id) }
        fileShareConfirmed = false
    }
    private func moveFile(_ index: Int, by delta: Int) {
        let target = index + delta
        guard selectedFiles.indices.contains(index), selectedFiles.indices.contains(target) else { return }
        selectedFiles.swapAt(index, target); fileShareConfirmed = false
    }
    private func perform(_ body: () throws -> Void) {
        localError = ""
        do { try body() } catch { localError = error.localizedDescription }
    }
    private func fileDetail(_ file: FileTransferArtifact) -> String {
        ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file) + " · SHA256 …" + file.sha256.suffix(12)
    }
    private func rangeDescription(_ range: ChatReadRange) -> String {
        switch range {
        case .latest(let count): return "历史最近 \(count) 条（最新端未证）"
        case .currentPage(let limit): return "首次可见页最多 \(limit) 条"
        case .time(let start, let end): return start.formatted(date: .numeric, time: .shortened) + " 至 " + end.formatted(date: .numeric, time: .shortened)
        }
    }
    private var reviewBinding: Binding<Bool> {
        Binding(get: { reviewOperationID != nil }, set: { if !$0 { reviewOperationID = nil } })
    }
    private var shareBinding: Binding<NativeFileSharePresentation?> {
        Binding(get: { workflows.sharePresentation }, set: { value in
            guard value == nil, let id = presentedShareID ?? workflows.sharePresentation?.id else { return }
            workflows.finishNativeShare(id: id, result: .dismissedOrUnknown)
        })
    }
    private func shareDismissed() {
        guard let id = presentedShareID else { return }
        presentedShareID = nil
        workflows.finishNativeShare(id: id, result: .dismissedOrUnknown)
    }
}

/// Exact original URLs are passed to the actual system controller. This bridge
/// records only the extension callback and never infers recipient/delivery.
private struct WorkflowNativeShareSheet: UIViewControllerRepresentable {
    let files: [URL]
    let onPresented: () -> Void
    let finished: (FileTransferNativeShareResult) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = WorkflowActivityViewController(activityItems: files, applicationActivities: nil)
        controller.observedPresentation = onPresented
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            let result: FileTransferNativeShareResult = completed ? .extensionCompleted(activityType: activityType?.rawValue) : .dismissedOrUnknown
            Task { @MainActor in context.coordinator.finish(result) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        coordinator.finish(.dismissedOrUnknown)
    }
    @MainActor final class Coordinator {
        private var finishedOnce = false
        private let finished: (FileTransferNativeShareResult) -> Void
        init(finished: @escaping (FileTransferNativeShareResult) -> Void) { self.finished = finished }
        func finish(_ result: FileTransferNativeShareResult) {
            guard !finishedOnce else { return }; finishedOnce = true; finished(result)
        }
    }
}

/// Witnesses an actually visible UIKit controller, not a SwiftUI onAppear hint.
private final class WorkflowActivityViewController: UIActivityViewController {
    var observedPresentation: (() -> Void)?
    private var witnessed = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !witnessed, view.window != nil else {return}
        witnessed=true;observedPresentation?()
    }
}
