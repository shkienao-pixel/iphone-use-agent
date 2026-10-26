import Foundation
import Combine
import EventKit
import Contacts
import Photos
import AlarmKit
import SwiftUI
import CryptoKit
import UIKit

struct ToolApproval: Identifiable {
    var id = UUID()
    let request: SystemToolRequest
    var localOnly = false
    var taskID: UUID? = nil
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
    private struct Receipt: Codable {
        var id: UUID
        var state: String
        var result: String?
        var notesIdentity: NativeContentEvidence.NotesIdentity? = nil
        var healthReadIdentity: NativeContentEvidence.HealthReadIdentity? = nil
    }
    private var receipts: [String: Receipt] = [:]
    private var readable = true
    let contentStore = PhoneContentStore.shared
    #if DEBUG
    /// Operator cleanup of the one known alarm-card fixture. Not an Agent tool.
    func stopAlarmCardFixtureA09() throws -> String {
        let taskID = UUID(uuidString: "D61E31CE-F87E-4ABC-A7CE-9F3275DEDFF5")!
        let alarmID = UUID(uuidString: "5CC6B4E7-059D-40C5-B18B-57A387AB7158")!
        let title = "Sela测试-20261025-CardA09"
        guard readable, receipts.contains(where: { key, receipt in
            key.hasPrefix(taskID.uuidString + ":") && receipt.id == alarmID && receipt.state == "completed"
                && receipt.result?.hasPrefix("已添加 Sela 闹钟：" + title + " · ") == true
        }) else { throw AgentError.message("测试闹钟的完成回执不匹配，未做操作") }
        guard AlarmManager.shared.authorizationState == .authorized else {
            throw AgentError.message("测试闹钟没有系统授权，未做操作")
        }
        let before = try AlarmManager.shared.alarms
        guard let alarm = before.first(where: { $0.id == alarmID }) else { return "测试闹钟已不在列表，未做操作" }
        guard case .alerting = alarm.state else { throw AgentError.message("测试闹钟未处于提醒状态，未做操作") }
        try AlarmManager.shared.stop(id: alarmID)
        let after = try AlarmManager.shared.alarms
        guard !after.contains(where: { $0.id == alarmID }),
              Set(after.map(\.id)) == Set(before.map(\.id)).subtracting([alarmID]) else {
            throw AgentError.message("已发出测试闹钟停止操作，结果仍待核对；未再次操作")
        }
        return "已停止 CardA09 测试闹钟；其他闹钟 ID 保持不变"
    }
    #endif
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
    func receiptMaintenanceBlockedReason(_ context: ToolReceiptMaintenanceContext) -> String? {
        ToolReceiptMaintenancePolicy.blockedReason(context: context, approvalPending: pending != nil,
                                                   receiptsReadable: readable)
    }
    @discardableResult
    func clearReceipts(context: ToolReceiptMaintenanceContext) throws -> ToolReceiptCleanupResult {
        if let reason = receiptMaintenanceBlockedReason(context) { throw AgentError.message(reason) }
        let retained = receipts.filter { !ToolReceiptMaintenancePolicy.mayRemove(key: $0.key, state: $0.value.state, context: context) }
        let removed = receipts.count - retained.count
        // Unknown writes and every recoverable task retain their original keys
        // and payloads. Publish only after the atomic replacement succeeds.
        if removed > 0 { try persistReceipts(retained) }
        error = ""
        return ToolReceiptCleanupResult(removed: removed, retained: retained.count)
    }
    func completedTaskReceipts(taskID: UUID) -> [String] {
        guard readable else { return [] }
        let prefix = taskID.uuidString + ":"
        return receipts.sorted { $0.key < $1.key }.compactMap { key, receipt in
            guard key.hasPrefix(prefix), receipt.state == "completed" else { return nil }
            return receipt.result
        }
    }
    func decide(_ accepted: Bool, expectedID: UUID? = nil) {
        guard expectedID == nil || pending?.id == expectedID else { return }
        let continuation = approval; approval = nil; pending = nil; continuation?.resume(returning: accepted)
    }
    func hasUnresolvedWrite(taskID: UUID) -> Bool {
        guard readable else { return true }
        let prefix = taskID.uuidString + ":"
        return receipts.contains { $0.key.hasPrefix(prefix) && $0.value.state == "pending" }
    }
    func taskContentEvidence(taskID: UUID) -> String {
        guard readable else { return "宿主工具回执暂时不可读；不能推断已保存内容或自动重建。" }
        let evidence = receipts.map { NativeContentEvidence.Receipt(key: $0.key, id: $0.value.id,
            state: $0.value.state, result: $0.value.result, notesIdentity: $0.value.notesIdentity,
            healthReadIdentity: $0.value.healthReadIdentity) }
        return NativeContentEvidence.instructions(taskID: taskID, receipts: evidence) {
            try contentStore.artifact(reference: $0)
        }
    }
    func execute(_ request: SystemToolRequest, taskID: UUID, localOnly: Bool = false, requiresConfirmation: Bool = true, allowsPermissionPrompt: Bool = true) async throws -> String {
        try request.validate(); try Task.checkCancellation()
        if request.operation == .meituan_query {
            guard MeituanConnectionStore.verified, MeituanConnectionStore.endpoint == MeituanTravelClient.endpoint.absoluteString else { throw AgentError.message("请先连接并检测美团旅行服务") }
        }
        if request.operation == .meituan_paotui {
            guard MeituanPaotuiStore.shared.configured else { throw AgentError.message("请先连接美团跑腿") }
        }
        if request.operation == .ctrip_query {
            guard CtripStore.enabled, CtripStore.hasCredential else { throw AgentError.message("请先在设置中配置并启用携程连接") }
        }
        if requiresConfirmation || localOnly {
        guard approval == nil else { throw AgentError.message("已有工具请求在等待确认") }
        let token = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                approval = continuation; pending = ToolApproval(id: token, request: request, localOnly: localOnly, taskID: taskID)
                if Task.isCancelled { decide(false) }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.pending?.id == token { self?.decide(false) } } }
        try Task.checkCancellation()
        guard accepted else { throw ToolDecisionError.declined }
        }
        if request.operation.writes {
            guard readable else { throw AgentError.message(error) }
        }
        if request.operation == .health_query {
            guard readable else { throw AgentError.message("健康读取完成账本暂不可用，原回执文件已保留；未重新读取") }
            guard receipts.count < 2000 else { throw AgentError.message("工具回执已达容量上限，请先导出核对；未派发新的健康读取") }
        }
        // Wait before permission requests, preflight or recording a possible
        // write. This holds the same unsubmitted action; it never retries one.
        switch request.operation {
        case .calendar_search, .calendar_create, .reminder_search, .reminder_create,
             .contact_search, .photo_search, .alarm_list, .alarm_create, .notes_create,
             .health_query, .music_search, .music_play, .music_pause, .music_resume,
             .music_status, .location_current:
            try await NativeForegroundGate.waitUntilActive { UIApplication.shared.applicationState == .active }
        default: break
        }
        if !allowsPermissionPrompt { try BackgroundToolPolicy.validate(request) }
        try await authorize(request.operation); try Task.checkCancellation(); try request.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var canonical = request
        // Input material is byte-exact. Canonicalizing its title/body could make
        // visually similar but different requests share a receipt.
        if ![.content_create, .notes_create].contains(request.operation) {
            canonical.title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }
        if request.operation.writes { canonical.query = nil }
        if request.operation == .alarm_create { canonical.end = nil; canonical.notes = nil }
        if request.operation == .reminder_create { canonical.end = nil }
        canonical.calendar_name = request.calendar_name.map(NativeCollectionTarget.normalized)
        canonical.list_name = request.list_name.map(NativeCollectionTarget.normalized)
        if let date = SystemToolRequest.date(request.start) { canonical.start = ISO8601DateFormatter().string(from: date) }
        if let date = SystemToolRequest.date(request.end) { canonical.end = ISO8601DateFormatter().string(from: date) }
        let bytes = try encoder.encode(canonical)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let key = taskID.uuidString + ":" + digest
        if let receipt = receipts[key], request.operation.writes && request.operation != .content_prepare_clipboard {
            if receipt.state == "completed", let result = receipt.result { return "重复请求已跳过；之前的回执：" + result }
            // A crash/cancellation can occur after the OS commits but before this file updates.
            // Never repeat an uncertain write automatically, even on a new session.
            throw AgentError.message("此操作上次提交结果未确认，请先检查目标应用或本机正文，再决定下一步；没有重复创建")
        }
        if request.operation.writes, hasUnresolvedWrite(taskID: taskID) {
            throw AgentError.message("这项任务仍有提交结果待核验；不能通过更改标题、备注或目标重新写入。请先核对实际结果，没有重复创建")
        }
        let id = UUID()
        // Resolve deterministic setup failures before recording a possible OS
        // commit. A pending receipt still protects every actual save attempt.
        let targetCalendar: EKCalendar?
        if request.operation == .calendar_create {
            targetCalendar = try writableTarget(.event, named: canonical.calendar_name)
        } else if request.operation == .reminder_create {
            targetCalendar = try writableTarget(.reminder, named: canonical.list_name)
        } else { targetCalendar = nil }
        let notesInvocation: NotesShortcutInvocation?
        if request.operation == .notes_create {
            notesInvocation = try NotesShortcutBridge.shared.preflight(taskID: taskID, digest: digest,
                title: request.title!, body: request.content!, folderName: request.folder_name)
        } else { notesInvocation = nil }
        let notesIdentity = notesInvocation.map { invocation in
            NativeContentEvidence.NotesIdentity(title: request.title!, expectedFolder: invocation.configuration.folderName,
                inputSHA256: SHA256.hash(data: Data(invocation.text.utf8)).map { String(format: "%02x", $0) }.joined(),
                inputUTF8Bytes: invocation.text.utf8.count, callbackID: invocation.id)
        }
        if request.operation.writes {
            guard receipts.count < 2000 else { throw AgentError.message("工具回执已达容量上限，请先在隐私设置中导出并清理回执") }
            try save(key, Receipt(id: id, state: "pending", result: nil, notesIdentity: notesIdentity))
        }
        let result: String
        switch request.operation {
        case .notes_create:
            result = try await NotesShortcutBridge.shared.run(notesInvocation!)
        case .health_query, .music_search, .music_play, .music_pause, .music_resume, .music_status, .location_current:
            result = try await NativeSystemTools.shared.execute(request)
        case .meituan_query:
            let credential = MeituanConnectionStore.credential
            guard MeituanConnectionStore.verified, MeituanConnectionStore.endpoint == MeituanTravelClient.endpoint.absoluteString else { throw AgentError.message("美团旅行连接尚未就绪") }
            let answer = try await MeituanTravelClient(token: credential).query(request.query!)
            guard credential == MeituanConnectionStore.credential, MeituanConnectionStore.verified else { throw AgentError.message("美团授权已改变，本次结果未采用") }
            result = "来源：美团官方酒旅接口，仅查询，不代表已预订或付款。\n" + answer
        case .meituan_paotui:
            result = "来源：美团跑腿官方接口，仅查询与询价，尚未下单。\n" + (try await MeituanPaotuiStore.shared.tool(request.query!))
        case .ctrip_query:
            let credential = CtripStore.apiKey()
            guard CtripStore.enabled, !credential.isEmpty else { throw AgentError.message("携程连接已关闭或授权码不可用") }
            let connectionMode = CtripStore.connectionMode
            let answer = try await CtripClient(apiKey: credential, apiEndpoint: connectionMode.endpoint).query(query: request.query!)
            try Task.checkCancellation()
            guard CtripStore.enabled, CtripStore.apiKey() == credential, CtripStore.connectionMode == connectionMode else { throw AgentError.message("携程授权已改变，本次结果未采用") }
            result = "来源：携程问道官方接口\n查询时间：\(ISO8601DateFormatter().string(from: Date()))\n以下为旅行查询参考信息，不代表已预订或付款：\n" + answer
        case .content_create:
            let artifact = try contentStore.create(title: request.title!, body: request.content!)
            result = try contentStore.status(reference: artifact.reference)
        case .content_prepare_clipboard:
            let receipt = try contentStore.prepareClipboard(reference: request.artifact_ref!)
            result = try contentStore.status(reference: request.artifact_ref!) + "\n" + receipt.detail
        case .content_status:
            result = try contentStore.status(reference: request.artifact_ref!)
        case .calendar_search:
            let predicate = events.predicateForEvents(withStart: SystemToolRequest.date(request.start)!, end: SystemToolRequest.date(request.end)!, calendars: nil)
            let matches = events.events(matching: predicate).filter { matchesQuery($0.title ?? "", request.query) }.sorted { $0.startDate < $1.startDate }
            result = json(matches.prefix(20).map { ["title": $0.title ?? "", "start": iso($0.startDate), "end": iso($0.endDate), "calendar": $0.calendar.title] }, total: matches.count)
        case .calendar_create:
            guard let calendar = targetCalendar, calendar.allowsContentModifications else { throw AgentError.message("目标日历已不可写入") }
            let event = EKEvent(eventStore: events); event.calendar = calendar; event.title = canonical.title
            event.startDate = SystemToolRequest.date(request.start); event.endDate = SystemToolRequest.date(request.end)
            event.notes = request.notes
            try Task.checkCancellation(); try events.save(event, span: .thisEvent, commit: true)
            result = try NativeEventWriteReceipt(operation: .calendar, receiptID: id,
                systemItemID: event.calendarItemIdentifier, collectionID: event.calendar.calendarIdentifier,
                title: event.title ?? "", collectionName: event.calendar.title,
                start: iso(event.startDate), end: iso(event.endDate)).serialized()
        case .reminder_search:
            let predicate = events.predicateForReminders(in: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in events.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) } }
            try Task.checkCancellation()
            let matches = reminders.filter { matchesQuery($0.title ?? "", request.query) }
            result = json(matches.prefix(20).map { ["title": $0.title ?? "", "list": $0.calendar.title, "completed": $0.isCompleted ? "true" : "false", "due": $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map(iso) ?? "未指定"] }, total: matches.count)
        case .reminder_create:
            guard let calendar = targetCalendar, calendar.allowsContentModifications else { throw AgentError.message("目标提醒列表已不可写入") }
            let reminder = EKReminder(eventStore: events); reminder.calendar = calendar; reminder.title = canonical.title; reminder.notes = request.notes
            if let date = SystemToolRequest.date(request.start) {
                var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                components.calendar = Calendar.current; components.timeZone = TimeZone.current; reminder.dueDateComponents = components
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
            try Task.checkCancellation(); try events.save(reminder, commit: true)
            let actualDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            guard reminder.dueDateComponents == nil || actualDue != nil else {
                throw AgentError.message("提醒已提交，但实际到期时间无法核对；请先检查提醒事项，没有重复创建")
            }
            result = try NativeEventWriteReceipt(operation: .reminder, receiptID: id,
                systemItemID: reminder.calendarItemIdentifier, collectionID: reminder.calendar.calendarIdentifier,
                title: reminder.title ?? "", collectionName: reminder.calendar.title,
                due: actualDue.map(iso)).serialized()
        case .contact_search:
            let keyword = request.query!
            let matches = try await Task.detached(priority: .userInitiated) {
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
                let values = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: keyword), keysToFetch: keys)
                return (values.prefix(20).map { contact in
                    ["name": contact.familyName + contact.givenName, "organization": contact.organizationName,
                     "phone": contact.phoneNumbers.prefix(3).map { $0.value.stringValue }.joined(separator: ", "),
                     "email": contact.emailAddresses.prefix(3).map { String($0.value) }.joined(separator: ", ")]
                }, values.count)
            }.value
            try Task.checkCancellation()
            result = json(matches.0, total: matches.1)
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
            result = "已添加 Sela 闹钟：\(title) · \(request.start!) · 回执 \(id.uuidString)"
        }
        if request.operation.writes {
            do { try save(key, Receipt(id: id, state: "completed", result: result, notesIdentity: notesIdentity)) }
            catch { throw AgentError.message("系统操作已提交，但回执保存失败。请人工检查结果，恢复后不会重复提交") }
        } else if request.operation == .health_query {
            // Record actual completed reads only. Each SDK invocation has a new
            // identity: this is neither a read cache nor a pending write.
            try Task.checkCancellation()
            guard receipts.count < 2000 else { throw AgentError.message("健康读取已返回，但完成回执容量不足；请核对结果，不能自动重新读取") }
            let identity = try NativeContentEvidence.completedHealthRead(request, result: result, receiptID: id)
            let metadata = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
            do {
                try save(taskID.uuidString + ":health-read:" + id.uuidString,
                    Receipt(id: id, state: "completed", result: metadata, healthReadIdentity: identity))
            } catch { throw AgentError.message("健康读取已返回，但完成回执保存失败；请保留未知状态，不能自动重新读取") }
        }
        try Task.checkCancellation()
        return request.operation == .ctrip_query ? result : String(result.prefix(12000))
    }
    private func authorize(_ operation: SystemToolRequest.Operation) async throws {
        switch operation {
        case .notes_create:
            break // Explicit helper configuration is checked before persisting a possible write.
        case .health_query, .music_search, .music_play, .music_pause, .music_resume, .music_status, .location_current:
            break // NativeSystemTools requests exactly the OS scope for this approved operation.
        case .meituan_query:
            guard MeituanConnectionStore.verified else { throw AgentError.message("请先检测美团连接") }
        case .meituan_paotui:
            guard MeituanPaotuiStore.shared.configured else { throw AgentError.message("请先连接美团跑腿") }
        case .ctrip_query:
            guard CtripStore.enabled, CtripStore.hasCredential else { throw AgentError.message("携程连接已关闭或尚未配置授权码") }
        case .content_create, .content_prepare_clipboard, .content_status:
            break // Local files/foreground clipboard need no private system-data permission.
        case .calendar_search, .calendar_create:
            guard try await NativeEventAccess.shared.request(.event) else { throw AgentError.message("没有日历访问权限") }; events.reset()
        case .reminder_search, .reminder_create:
            guard try await NativeEventAccess.shared.request(.reminder) else { throw AgentError.message("没有提醒事项访问权限") }; events.reset()
        case .contact_search:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .notDetermined { _ = try await contacts.requestAccess(for: .contacts) }
            guard [.authorized, .limited].contains(CNContactStore.authorizationStatus(for: .contacts)) else { throw AgentError.message("没有联系人访问权限") }
        case .photo_search:
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
            guard [.authorized, .limited].contains(status) else { throw AgentError.message("没有照片访问权限") }
        case .alarm_create, .alarm_list:
            guard try await AlarmManager.shared.requestAuthorization() == .authorized else { throw AgentError.message("没有闹钟访问权限") }
        }
    }
    private func writableTarget(_ type: EKEntityType, named name: String?) throws -> EKCalendar {
        let candidates = events.calendars(for: type)
        let defaultID = (type == .event ? events.defaultCalendarForNewEvents : events.defaultCalendarForNewReminders())?.calendarIdentifier
        let target = try NativeCollectionTarget.select(candidates.map {
            NativeCollectionTarget.Descriptor(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications)
        }, named: name, defaultID: defaultID, label: type == .event ? "日历" : "提醒列表")
        guard let calendar = candidates.first(where: { $0.calendarIdentifier == target.id }) else {
            throw AgentError.message("目标位置已改变，请重新核对")
        }
        return calendar
    }
    private func save(_ key: String, _ receipt: Receipt) throws {
        var updated = receipts; updated[key] = receipt
        try persistReceipts(updated)
    }
    private func persistReceipts(_ updated: [String: Receipt]) throws {
        let data = try JSONEncoder().encode(updated)
        guard updated.count <= 2000, data.count <= 5_000_000 else {
            throw AgentError.message("工具回执达到容量上限，请先导出并清理已结束任务的回执；未删除未核验记录")
        }
        let folder = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; var excluded = folder; try excluded.setResourceValues(values)
        #if os(iOS)
        try data.write(to: receiptURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: receiptURL, options: .atomic)
        #endif
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
    @Environment(\.dismiss) private var dismiss
    private var taskRecord: PhoneTaskRecord? {
        guard let id = approval.taskID else { return nil }
        return model.backgroundTasks.record(id) ?? model.history.records.first { $0.id == id }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(approval.request.operation.label, systemImage: approval.request.operation.writes ? "pencil" : "magnifyingglass").font(.title2.bold())
                    if let taskRecord { Text("任务：" + taskRecord.title).font(.subheadline).foregroundStyle(.secondary) }
                    Text(approval.request.preview).textSelection(.enabled).agentPanel()
                    if !approval.localOnly { Text(approval.request.confirmationExplanation).foregroundStyle(.secondary) }
                    if approval.localOnly {
                        Text("结果接收方：本机 Sela").font(.footnote).foregroundStyle(.secondary)
                    } else if approval.request.operation == .ctrip_query {
                        Text("查询接收方：携程 · \(CtripStore.connectionMode.endpoint.host ?? "ctrip.com")\n结果接收方：\(PrivacyConsent.recipient(model.settings))")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("接收方：\(PrivacyConsent.recipient(model.settings))").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }.safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(approval.localOnly ? "确认本地试用" : approval.request.confirmationLabel) { model.tools.decide(true, expectedID: approval.id) }.buttonStyle(AgentButtonStyle())
                    Button(approval.localOnly ? "取消试用" : "拒绝并暂停") { model.tools.decide(false, expectedID: approval.id) }.buttonStyle(AgentButtonStyle(primary: false))
                    if !approval.localOnly, let taskID = approval.taskID {
                        Button("停止这项任务", role: .destructive) {
                            guard model.tools.pending?.id == approval.id else { return }
                            model.stopTask(taskID)
                        }.frame(minHeight: 44)
                    }
                }.disabled(model.tools.pending?.id != approval.id).padding(20).background(AgentPalette.background)
            }.navigationTitle("确认工具操作").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled().tint(AgentPalette.accent)
            .onChange(of: model.tools.pending?.id) { _, id in if id != approval.id { dismiss() } }
    }
}
