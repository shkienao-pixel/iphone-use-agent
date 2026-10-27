import SwiftUI

/// Connection and local recovery management. Business selections and order
/// confirmations live in the Sela conversation, never in an order form here.
struct MeituanPaotuiView: View {
    var onChat: () -> Void = {}
    var canRestoreConversation: (UUID) -> Bool = { _ in false }
    var onRestoreConversation: (UUID) -> Bool = { _ in false }
    @ObservedObject private var store = MeituanPaotuiStore.shared
    @State private var disconnecting = false
    @State private var reviewingOrders = false
    @State private var recoveringPreparation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("美团跑腿", systemImage: "bicycle").font(.headline)
                Spacer()
                Text(store.statusLabel).font(.caption).foregroundStyle(store.ready ? .green : .secondary)
                    .accessibilityIdentifier("paotui.connectionStatus")
            }
            Text("在 Sela 对话中描述需求，选择地址和门店，再核对费用与订单。这里管理连接和本机记录。")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("当前仅隔离本机凭据版本，尚未证明对应稳定的美团账号。重新授权不会解除待核验提交的限制。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("paotui.credentialScopeExplanation")
            if !store.configured {
                Button("连接美团跑腿") { Task { await store.startAuthorization() } }
                    .buttonStyle(AgentButtonStyle()).disabled(store.busy).accessibilityIdentifier("paotui.connect")
            } else {
                Button("回到对话描述需求", action: onChat).buttonStyle(AgentButtonStyle())
                    .accessibilityIdentifier("paotui.openConversation")
                Button("检测跑腿连接") { Task { await store.refresh() } }.disabled(store.busy)
                    .accessibilityIdentifier("paotui.refresh")
                Button("重新授权跑腿") { Task { await store.startAuthorization() } }.disabled(store.busy)
            }
            if let link = store.authorizationLink {
                Link("前往美团授权", destination: link)
                Button("我已授权，检测连接") { Task { await store.finishAuthorization() } }
                    .buttonStyle(AgentButtonStyle()).disabled(store.busy).accessibilityIdentifier("paotui.finishAuthorization")
                Button("取消本次授权", role: .cancel) { store.cancelAuthorization() }.disabled(store.busy)
            }
            if store.busy { ProgressView("正在连接美团…") }
            if !store.message.isEmpty { AgentNotice(text: store.message, error: store.failed) }
            if !store.savedPreparations.isEmpty || store.preparationRecoveryIssue != nil {
                Button("恢复已保存的准备（\(store.savedPreparations.count)）") { recoveringPreparation = true }
                    .disabled(store.busy).accessibilityIdentifier("paotui.recoverPreparations")
            }
            if store.hasUnresolvedSubmission {
                AgentNotice(text: "上一笔跑腿提交结果仍需在美团核对。可以继续对话和询价，Sela 不会重复创建订单。", error: true)
                Link("打开美团核对已有订单", destination: store.chatOrderURL ?? URL(string: "https://i.meituan.com/")!)
            }
            Button("订单核验与本机记录") { reviewingOrders = true }
                .disabled(store.busy).accessibilityIdentifier("paotui.reviewOrders")
            PaotuiSafeDiagnosticsView(snapshot: store.diagnosticsSnapshot)
            if store.configured { Button("断开跑腿连接", role: .destructive) { disconnecting = true }.disabled(store.busy) }
            DisclosureGroup("旅行服务") { MeituanConnectionView().padding(.top, 16) }
        }
        .task { if store.configured && !store.ready { await store.refresh() } }
        .sheet(isPresented: $reviewingOrders) { PaotuiOrderReviewSheet() }
        .sheet(isPresented: $recoveringPreparation) {
            PaotuiPreparationRecoverySheet(canRestoreConversation: canRestoreConversation,
                onRestoreConversation: onRestoreConversation)
        }
        .confirmationDialog("清除这部手机的跑腿授权？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { try? store.disconnect() }
        }
    }
}

/// Restoration only reopens the original preparation. It never reuses a quote,
/// chooses an address, restores a historical card or issues a submit grant.
private struct PaotuiPreparationRecoverySheet: View {
    var canRestoreConversation: (UUID) -> Bool
    var onRestoreConversation: (UUID) -> Bool
    @ObservedObject private var store = MeituanPaotuiStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PaotuiSavedPreparationSummary?
    @State private var restoring = false
    @State private var discarding = false
    @State private var notice = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择一份本机保存的准备，明确恢复后回到原对话。需要重新读取并选择地址、核对门店和重新询价，再由你确认。恢复不会创建订单，也不会恢复历史卡片的操作权限。")
                        .font(.subheadline)
                }
                if !notice.isEmpty { Section { AgentNotice(text: notice, error: failed) } }
                if let issue = store.preparationRecoveryIssue {
                    Section { AgentNotice(text: issue, error: true) }
                }
                Section("已保存的准备") {
                    ForEach(store.savedPreparations) { saved in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(saved.serviceTitle ?? "待补充跑腿服务").font(.headline)
                            if !saved.goods.isEmpty { Text(saved.goods).font(.subheadline) }
                            Text(saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(saved.reviewDescription).font(.footnote).foregroundStyle(.secondary)
                            if !saved.credentialMatches {
                                Text("当前凭据版本与保存时不同。请使用原凭据连接后再恢复，或丢弃这份准备。")
                                    .font(.footnote).foregroundStyle(.orange)
                            } else if !canRestoreConversation(saved.conversationID) {
                                Text("原对话已不可用，无法在其他对话恢复。可以丢弃这份本机准备。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("恢复到原对话") { selected = saved; restoring = true }
                                .disabled(store.busy || !saved.credentialMatches || !canRestoreConversation(saved.conversationID))
                                .accessibilityIdentifier("paotui.preparation.restore." + saved.id.uuidString)
                            Button("丢弃这份准备", role: .destructive) { selected = saved; discarding = true }
                                .disabled(store.busy)
                                .accessibilityIdentifier("paotui.preparation.discard." + saved.id.uuidString)
                        }.padding(.vertical, 6)
                    }
                    if store.savedPreparations.isEmpty {
                        Text("没有已保存的跑腿准备。订单提交记录独立保留。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("恢复跑腿准备")
            .accessibilityIdentifier("paotui.preparationRecovery")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("恢复到原对话？", isPresented: $restoring, titleVisibility: .visible) {
                Button("恢复准备并打开原对话") { restore() }
                Button("取消", role: .cancel) { selected = nil }
            } message: {
                Text("只恢复需求。地址、门店和报价需重新核对；这一步不会下单。")
            }
            .confirmationDialog("丢弃这份本机准备？", isPresented: $discarding, titleVisibility: .visible) {
                Button("丢弃准备", role: .destructive) { discard() }
                Button("取消", role: .cancel) { selected = nil }
            } message: {
                Text("仅移除这份准备，不会取消美团订单、删除提交记录或解除待核验限制。")
            }
        }
    }

    private func restore() {
        guard let selected else { return }
        guard canRestoreConversation(selected.conversationID) else {
            notice = "原对话已不可用，这份准备未恢复。"; failed = true; self.selected = nil; return
        }
        do {
            _ = try store.restorePreparation(for: selected.conversationID)
            if onRestoreConversation(selected.conversationID) { dismiss() }
            else { notice = "准备已恢复到原对话，但暂时无法打开。请从历史对话进入并重新核对。"; failed = true }
        } catch { notice = error.localizedDescription; failed = true }
        self.selected = nil
    }

    private func discard() {
        guard let selected else { return }
        do { try store.discardSavedPreparation(for: selected.conversationID); notice = "已丢弃这份本机准备。"; failed = false }
        catch { notice = error.localizedDescription; failed = true }
        self.selected = nil
    }
}

/// Only the typed allow-list snapshot reaches this view. It has no access to a
/// quote, request, credential or provider response.
private struct PaotuiSafeDiagnosticsView: View {
    let snapshot: PaotuiDiagnosticsSnapshot
    var body: some View {
        DisclosureGroup("本机安全诊断") {
            VStack(alignment: .leading, spacing: 8) {
                Text("仅包含本机关联标识、阶段、耗时和结果分类，不代表美团订单或账号已验证。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("最近记录 \(snapshot.events.count)/\(snapshot.capacity) · 进行中 \(snapshot.activeOperationCount) · 已轮换 \(snapshot.droppedEventCount)")
                    .font(.caption).accessibilityIdentifier("paotui.diagnosticsCounts")
                ForEach(snapshot.events.suffix(8).reversed()) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.command.rawValue + " · " + event.phase.rawValue + " · " + event.result.rawValue)
                        if let duration = event.durationMilliseconds { Text("\(duration) ms") }
                    }.font(.caption.monospaced()).accessibilityIdentifier("paotui.diagnosticEvent")
                }
                if snapshot.events.isEmpty { Text("暂无本机诊断记录。").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        }.accessibilityIdentifier("paotui.safeDiagnostics")
    }
}

/// Local recovery only: records the person's report and never creates an order.
struct PaotuiOrderReviewSheet: View {
    @ObservedObject private var store = MeituanPaotuiStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PaotuiPendingReview?
    @State private var choosingConclusion = false
    @State private var notice = ""
    @State private var failed = false
    @State private var archiving = false
    @State private var reportedReferences: [UUID: String] = [:]

    private var maintenance: PaotuiJournalMaintenanceSnapshot { store.journalMaintenanceSnapshot }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("先在美团核对原提交账号下的订单，再逐笔记录你的判断。这里的人工记录不会被当成美团已确认的订单或付款状态，也不会重新发送订单。")
                        .font(.subheadline)
                    Link("打开美团核对订单", destination: URL(string: "https://i.meituan.com/")!)
                }
                if !notice.isEmpty {
                    Section { AgentNotice(text: notice, error: failed) }
                }
                Section("本机记录维护") {
                    if maintenance.isReadable {
                        Text("活动记录 \(maintenance.activeReceiptCount)/\(maintenance.activeCapacity) · 已归档 \(maintenance.archivedReceiptCount)")
                            .accessibilityIdentifier("paotui.receiptCounts")
                        Text("活动记录中：待核验 \(maintenance.unresolvedReceiptCount) · 已解决 \(maintenance.resolvedReceiptCount)")
                            .font(.subheadline).accessibilityIdentifier("paotui.unresolvedReceiptCount")
                    } else {
                        Text("记录计数暂不可用").accessibilityIdentifier("paotui.receiptCountsUnavailable")
                    }
                    Text("归档只整理已解决的本机记录，所有待核验提交会继续保留。归档不代表取消、付款或平台核验，也不会修改美团订单。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !maintenance.isReadable {
                        Text("记录暂时不可读，已停止归档并保留提交限制。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button("归档已解决的本机记录") { archiving = true }
                        .disabled(store.busy || !maintenance.canArchive)
                        .accessibilityIdentifier("paotui.archiveResolved")
                }
                Section("待核验提交") {
                    ForEach(store.pendingReviews) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            if let summary = record.requestSummary {
                                Text(summary).font(.headline)
                            } else {
                                Text("历史记录未保存需求摘要，请按提交时间核对。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            if let fee = record.deliveryFee {
                                Text("当时报价的跑腿费：" + fee.formatted(.number.precision(.fractionLength(0...2))) + " 元")
                                    .font(.subheadline)
                            }
                            Text("本机提交记录 · " + String(record.id.uuidString.prefix(8)))
                                .font(.caption).foregroundStyle(.secondary)
                            if !record.isCurrentAuthorization {
                                Text("这笔提交使用的是其他或未记录的凭据版本。请在提交时使用的美团账号核对；本机尚未验证稳定账号身份。")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            if let conclusion = record.lastConclusion, let reviewedAt = record.reviewedAt {
                                Text("上次人工记录：\(conclusion.title) · \(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text("来源：本人在 Sela 填写；未验证平台状态。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let reference = record.reportedOrderReference {
                                Text("本人报告的订单号：" + reference)
                                    .font(.footnote).accessibilityIdentifier("paotui.reportedOrderReference." + record.id.uuidString)
                            }
                            TextField("你查到的订单号（可不填）", text: Binding(
                                get: { reportedReferences[record.id] ?? record.reportedOrderReference ?? "" },
                                set: { reportedReferences[record.id] = $0 }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.asciiCapable).submitLabel(.done)
                                .disabled(store.busy)
                                .accessibilityIdentifier("paotui.reviewReference." + record.id.uuidString)
                            Text("仅记录你提供的订单号，未经美团验证，不用于平台查询、订单跳转或支付。请勿填写电话、链接或授权信息。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("记录这笔提交的核验结论") {
                                selected = record; choosingConclusion = true
                            }.disabled(store.busy).accessibilityIdentifier("paotui.review." + record.id.uuidString)
                        }.padding(.vertical, 6)
                    }
                    if store.pendingReviews.isEmpty {
                        Text(store.hasUnresolvedSubmission ?
                            "本机订单日志暂时不可读。提交限制继续保留；请先保留记录并在美团核对，重新连接不会清除此限制。" :
                            "没有待核验记录。已有订单和付款状态仍以美团为准；新订单需要重新询价并确认。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("订单核验")
            .accessibilityIdentifier("paotui.orderReview")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("记录这笔提交的人工判断", isPresented: $choosingConclusion, titleVisibility: .visible) {
                ForEach(PaotuiReviewConclusion.allCases) { conclusion in
                    Button(conclusion.title) { record(conclusion) }
                }
                Button("取消", role: .cancel) { selected = nil }
            } message: {
                Text("仅记录你的核验结论，不验证平台状态。选择“仍无法确定”将保留提交限制；其他待核验记录不会一并解除。")
            }
            .confirmationDialog("归档已解决的本机记录？", isPresented: $archiving, titleVisibility: .visible) {
                Button("归档 \(maintenance.resolvedReceiptCount) 条已解决记录") { archive() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("待核验记录会留在活动日志中。归档不执行取消、付款或平台核验。")
            }
        }
    }

    private func record(_ conclusion: PaotuiReviewConclusion) {
        guard let selected else { return }
        do {
            try store.recordReview(attemptID: selected.id, conclusion: conclusion,
                reportedOrderReference: reportedReferences[selected.id] ?? selected.reportedOrderReference)
            reportedReferences.removeValue(forKey: selected.id)
            notice = store.message; failed = false
        } catch {
            notice = error.localizedDescription; failed = true
        }
        self.selected = nil
    }

    private func archive() {
        do {
            let count = try store.archiveResolvedOrders()
            notice = "已归档 \(count) 条已解决的本机记录。待核验记录继续保留。"; failed = false
        } catch { notice = error.localizedDescription; failed = true }
    }
}
