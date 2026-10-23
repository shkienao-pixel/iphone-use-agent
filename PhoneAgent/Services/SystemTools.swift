import Foundation
import Combine
import EventKit
import Contacts
import Photos
import AlarmKit
import SwiftUI
import CryptoKit

struct ToolApproval: Identifiable {
    var id = UUID()
    let request: SystemToolRequest
}
private struct AgentAlarmMetadata: AlarmMetadata { var title: String }

@MainActor
final class SystemTools: ObservableObject {
    @Published private(set) var pending: ToolApproval?
    @Published private(set) var error = ""
    private let events = EKEventStore()
    private let contacts = CNContactStore()
    private var approval: CheckedContinuation<Bool, Never>?
    private var receiptURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneAgent/tool-receipts.json")
    }
    private struct Receipt: Codable { var id: UUID; var state: String; var result: String? }
    private var receipts: [String: Receipt] = [:]
    private var readable = true
    init() {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        do {
            guard (try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: receiptURL))
            guard receipts.count <= 2000, receipts.values.allSatisfy({ ["pending", "completed"].contains($0.state) && ($0.state == "pending" || $0.result != nil) }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        catch { readable = false; self.error = "工具回执暂时无法读取，写入工具已禁用以避免重复创建" }
    }
    func exportReceipts() throws -> Data {
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            guard (try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw AgentError.message("回执文件过大，请连接电脑保留文件") }; return try Data(contentsOf: receiptURL)
        }
        return try JSONEncoder().encode(receipts)
    }
    func clearReceipts() throws {
        guard pending == nil else { throw AgentError.message("请先结束当前工具请求") }
        if FileManager.default.fileExists(atPath: receiptURL.path) { try FileManager.default.removeItem(at: receiptURL) }
        receipts = [:]; readable = true; error = ""
    }
    func decide(_ accepted: Bool) {
        let continuation = approval; approval = nil; pending = nil; continuation?.resume(returning: accepted)
    }
    func execute(_ request: SystemToolRequest, taskID: UUID) async throws -> String {
        try request.validate(); try Task.checkCancellation()
        guard approval == nil else { throw AgentError.message("已有工具请求在等待确认") }
        let token = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approval = continuation; pending = ToolApproval(id: token, request: request)
                if Task.isCancelled { decide(false) }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.pending?.id == token { self?.decide(false) } } }
        try Task.checkCancellation()
        guard accepted else { throw ToolDecisionError.declined }
        if request.operation.writes {
            guard readable else { throw AgentError.message(error) }
        }
        try await authorize(request.operation); try Task.checkCancellation(); try request.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = request
        canonical.title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if request.operation.writes { canonical.query = nil }
        if request.operation == .alarm_create { canonical.end = nil; canonical.notes = nil }
        if request.operation == .reminder_create { canonical.end = nil }
        if let date = SystemToolRequest.date(request.start) { canonical.start = ISO8601DateFormatter().string(from: date) }
        if let date = SystemToolRequest.date(request.end) { canonical.end = ISO8601DateFormatter().string(from: date) }
        let bytes = try encoder.encode(canonical)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let key = taskID.uuidString + ":" + digest
        if let receipt = receipts[key], request.operation.writes {
            if let result = receipt.result { return "重复请求已跳过；之前的回执：" + result }
            // A crash/cancellation can occur after the OS commits but before this file updates.
            // Never repeat an uncertain write automatically, even on a new session.
            throw AgentError.message("此操作上次提交结果未确认，请人工检查日历/提醒/闹钟后再决定；没有重复创建")
        }
        let id = UUID()
        if request.operation.writes {
            guard receipts.count < 2000 else { throw AgentError.message("工具回执已达容量上限，请先在隐私设置中导出并清理回执") }
            try save(key, Receipt(id: id, state: "pending", result: nil))
        }
        let result: String
        switch request.operation {
        case .calendar_search:
            let predicate = events.predicateForEvents(withStart: SystemToolRequest.date(request.start)!, end: SystemToolRequest.date(request.end)!, calendars: nil)
            let matches = events.events(matching: predicate).filter { matchesQuery($0.title ?? "", request.query) }.sorted { $0.startDate < $1.startDate }
            result = json(matches.prefix(20).map { ["title": $0.title ?? "", "start": iso($0.startDate), "end": iso($0.endDate), "calendar": $0.calendar.title] }, total: matches.count)
        case .calendar_create:
            guard let calendar = events.defaultCalendarForNewEvents, calendar.allowsContentModifications else { throw AgentError.message("没有可写入的默认日历") }
            let event = EKEvent(eventStore: events); event.calendar = calendar; event.title = canonical.title
            event.startDate = SystemToolRequest.date(request.start); event.endDate = SystemToolRequest.date(request.end)
            event.notes = request.notes; event.url = URL(string: "phoneagent://receipt/" + id.uuidString)
            try Task.checkCancellation(); try events.save(event, span: .thisEvent, commit: true)
            result = "已添加日程：\(event.title ?? "") · \(iso(event.startDate)) · 回执 \(id.uuidString)"
        case .reminder_search:
            let predicate = events.predicateForReminders(in: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in events.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) } }
            try Task.checkCancellation()
            let matches = reminders.filter { matchesQuery($0.title ?? "", request.query) }
            result = json(matches.prefix(20).map { ["title": $0.title ?? "", "completed": $0.isCompleted ? "true" : "false", "due": $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map(iso) ?? "未指定"] }, total: matches.count)
        case .reminder_create:
            guard let calendar = events.defaultCalendarForNewReminders(), calendar.allowsContentModifications else { throw AgentError.message("没有可写入的默认提醒列表") }
            let reminder = EKReminder(eventStore: events); reminder.calendar = calendar; reminder.title = canonical.title; reminder.notes = request.notes
            reminder.url = URL(string: "phoneagent://receipt/" + id.uuidString)
            if let date = SystemToolRequest.date(request.start) {
                var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                components.calendar = Calendar.current; components.timeZone = TimeZone.current; reminder.dueDateComponents = components
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
            try Task.checkCancellation(); try events.save(reminder, commit: true)
            result = "已添加提醒：\(reminder.title ?? "") · 回执 \(id.uuidString)"
        case .contact_search:
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let fetch = CNContactFetchRequest(keysToFetch: keys); fetch.predicate = CNContact.predicateForContacts(matchingName: request.query!)
            var rows: [[String: String]] = []; var count = 0
            try contacts.enumerateContacts(with: fetch) { contact, stop in
                count += 1
                if rows.count < 20 { rows.append(["name": contact.familyName + contact.givenName, "organization": contact.organizationName,
                    "phone": contact.phoneNumbers.prefix(3).map { $0.value.stringValue }.joined(separator: ", "), "email": contact.emailAddresses.prefix(3).map { String($0.value) }.joined(separator: ", ")]) }
                if count >= 100 { stop.pointee = true }
            }
            result = json(rows, total: count)
        case .photo_search:
            let options = PHFetchOptions(); options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", SystemToolRequest.date(request.start)! as NSDate, SystemToolRequest.date(request.end)! as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = 1000
            let assets = PHAsset.fetchAssets(with: options); var rows: [[String: String]] = []; var total = 0
            assets.enumerateObjects { asset, _, _ in
                let name = PHAssetResource.assetResources(for: asset).first?.filename ?? ""
                guard self.matchesQuery(name, request.query) else { return }; total += 1
                if rows.count < 20 { rows.append(["file": name, "date": asset.creationDate.map(self.iso) ?? "未知", "size": "\(asset.pixelWidth)×\(asset.pixelHeight)", "type": asset.mediaType == .video ? "video" : "image"]) }
            }
            result = json(rows, total: total) + "\n仅授权可见照片的元数据；最多扫描 1000 项，不含图像内容。"
        case .alarm_list:
            let alarms = try AlarmManager.shared.alarms
            result = (String(data: try encoder.encode(Array(alarms.prefix(20))), encoding: .utf8) ?? "[]") + "\n本 App 闹钟总数：\(alarms.count)，返回前 20 项"
        case .alarm_create:
            let title = canonical.title!
            let presentation = AlarmPresentation(alert: .init(title: LocalizedStringResource(stringLiteral: title)))
            let attributes = AlarmAttributes(presentation: presentation, metadata: AgentAlarmMetadata(title: title), tintColor: .blue)
            try Task.checkCancellation()
            _ = try await AlarmManager.shared.schedule(id: id, configuration: .alarm(schedule: .fixed(SystemToolRequest.date(request.start)!), attributes: attributes))
            // Do not check cancellation before persisting a committed write receipt.
            result = "已添加 Phone Agent 闹钟：\(title) · \(request.start!) · 回执 \(id.uuidString)"
        }
        if request.operation.writes {
            do { try save(key, Receipt(id: id, state: "completed", result: result)) }
            catch { throw AgentError.message("系统操作已提交，但回执保存失败。请人工检查结果，恢复后不会重复提交") }
        }
        try Task.checkCancellation()
        return String(result.prefix(12000))
    }
    private func authorize(_ operation: SystemToolRequest.Operation) async throws {
        switch operation {
        case .calendar_search, .calendar_create:
            guard try await events.requestFullAccessToEvents() else { throw AgentError.message("没有日历访问权限") }
        case .reminder_search, .reminder_create:
            guard try await events.requestFullAccessToReminders() else { throw AgentError.message("没有提醒事项访问权限") }
        case .contact_search:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined { _ = try await contacts.requestAccess(for: .contacts) }
            guard [.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts)) else { throw AgentError.message("没有联系人访问权限") }
        case .photo_search:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard [.authorized, .limited].contains(status) else { throw AgentError.message("没有照片访问权限") }
        case .alarm_create, .alarm_list:
            guard try await AlarmManager.shared.requestAuthorization() == .authorized else { throw AgentError.message("没有闹钟访问权限") }
        }
    }
    private func save(_ key: String, _ receipt: Receipt) throws {
        var updated = receipts; updated[key] = receipt
        let folder = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; var excluded = folder; try excluded.setResourceValues(values)
        try JSONEncoder().encode(updated).write(to: receiptURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        receipts = updated
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func matchesQuery(_ content: String, _ query: String?) -> Bool { query == nil || query!.isEmpty || content.localizedCaseInsensitiveContains(query!) }
    private func json(_ rows: [[String: String]], total: Int) -> String {
        let object: [String: Any] = ["matches": rows, "matched_count": total, "returned_count": rows.count, "truncated": total > rows.count]
        return (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "无可用结果"
    }
}

struct ToolApprovalView: View {
    @EnvironmentObject private var model: PhoneAgentViewModel
    let approval: ToolApproval
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(approval.request.operation.label, systemImage: approval.request.operation.writes ? "pencil" : "magnifyingglass").font(.title2.bold())
                    Text(approval.request.preview).textSelection(.enabled).agentPanel()
                    Text(approval.request.operation.writes ? "确认后将通过系统接口创建这项内容。请核对标题、日期和时区。" : "确认后读取授权范围内的匹配数据，结果会发送到当前 AI 服务用于继续任务。") .foregroundStyle(.secondary)
                    Text("接收方：\(PrivacyConsent.recipient(model.settings))").font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(approval.request.operation.writes ? "确认创建" : "允许读取并发送") { model.tools.decide(true) }.buttonStyle(AgentButtonStyle())
                    Button("拒绝并暂停") { model.tools.decide(false) }.buttonStyle(AgentButtonStyle(primary: false))
                    Button("停止任务", role: .destructive) { model.stop() }.frame(minHeight: 44)
                }.padding(20).background(AgentPalette.background)
            }.navigationTitle("确认工具操作").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled().tint(AgentPalette.accent)
    }
}
