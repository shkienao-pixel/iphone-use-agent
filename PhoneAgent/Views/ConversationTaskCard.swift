import SwiftUI

struct ConversationTaskCard: View {
    let taskID: UUID
    var savedResult: NativeTaskSnapshot? = nil
    @EnvironmentObject private var model: PhoneAgentViewModel
    private var record: PhoneTaskRecord? {
        if model.engine.currentRecord?.id == taskID { return model.engine.currentRecord }
        if let background = model.backgroundTasks.record(taskID) { return background }
        return model.history.records.first { $0.id == taskID } ?? model.taskQueue.items.first { $0.id == taskID }?.record
    }
    var body: some View {
        if let record {
            let handoffConversationID = model.conversation.currentConversationID
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: record.outcome == .completed ? "checkmark.circle.fill" : "gearshape.2")
                        .foregroundStyle(record.outcome == .completed ? .green : AgentPalette.secondaryText)
                    Text(record.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(record.outcome.label).font(.caption).foregroundStyle(.secondary)
                }
                let offers = record.logs.filter { $0.title == "工具回执" && $0.detail.hasPrefix("来源：携程") }
                    .flatMap { CtripFlightParser.offers($0.detail, query: record.goal, at: record.updatedAt) }
                if !offers.isEmpty {
                    CtripFlightCards(offers: offers, onBook: { offer in
                        model.bookFlight(offer, taskID: record.id, conversationID: handoffConversationID,
                            isVisible: { model.conversation.messages.contains { $0.taskID == record.id } })
                    })
                }
                let nativeResults = record.nativeResults ?? []
                if !nativeResults.isEmpty { NativeTaskResultCards(results: nativeResults) }
                let summary = offers.isEmpty ? record.summary : CtripFlightParser.narrative(record.summary, representedBy: offers)
                if !summary.isEmpty {
                    if !nativeResults.isEmpty, record.outcome == .completed {
                        DisclosureGroup("查看任务报告") { SelaMarkdownText(text: summary) }
                            .accessibilityIdentifier("task.report." + taskID.uuidString)
                    } else { SelaMarkdownText(text: summary) }
                }
                if let approval = model.tools.pending, approval.taskID == taskID {
                    NavigationLink { ToolApprovalView(approval: approval) } label: {
                        Label("核对待确认的工具操作", systemImage: "checkmark.shield")
                    }.buttonStyle(.borderedProminent)
                }
                if (model.engine.currentRecord?.id == taskID && model.engine.hasCurrentTask && model.engine.running) || model.backgroundTasks.running(taskID) {
                    HStack {
                        Button("暂停") { model.pauseTask(taskID) }
                        Spacer()
                        Button("停止", role: .destructive) { model.stopTask(taskID) }
                    }.buttonStyle(.bordered)
                }
                if model.recoverableTask(taskID) != nil {
                    HStack(spacing: 12) {
                        Button("重试") { _ = model.retryTask(taskID) }.accessibilityIdentifier("task.retry")
                        Button("继续任务") { _ = model.continueTask(taskID) }.accessibilityIdentifier("task.continue")
                        if (model.engine.currentRecord?.id == taskID && model.engine.hasCurrentTask) || model.backgroundTasks.token(taskID) != nil {
                            Button("停止", role: .destructive) { model.stopTask(taskID) }
                        }
                    }.buttonStyle(.bordered).disabled(model.taskRecoveryBusy(taskID))
                }
            }.padding(16).background(AgentPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain).accessibilityIdentifier("task.card." + taskID.uuidString)
        } else if let savedResult, savedResult.taskID == taskID, savedResult.valid {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(savedResult.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(savedResult.state.label).font(.caption).foregroundStyle(.secondary)
                }
                Text("历史结果 · " + savedResult.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                NativeTaskResultCards(results: savedResult.results)
                if !savedResult.summary.isEmpty {
                    DisclosureGroup("查看任务报告") { SelaMarkdownText(text: savedResult.summary) }
                        .accessibilityIdentifier("task.report." + taskID.uuidString)
                }
            }.padding(16).background(AgentPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain).accessibilityIdentifier("task.snapshot." + taskID.uuidString)
        } else {
            Label("任务记录暂不可用", systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
