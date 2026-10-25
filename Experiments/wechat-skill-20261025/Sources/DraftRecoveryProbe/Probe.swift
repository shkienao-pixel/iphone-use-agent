import Foundation
import WeChatSkillCore

/// Offline semantic fixture only. No device, model, network or live mode exists.
@main struct DraftRecoveryProbe {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3, ["seed", "resume", "seed-result", "resume-result"].contains(args[1]) else { throw SkillError.invalidTask }
        if args[1].contains("result") { try resultRecovery(args); return }
        let store = try FileDraftCheckpoint(directory: URL(fileURLWithPath: args[2], isDirectory: true))
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        let stream = UUID(), profileID = UUID(), device = "offline-fixture-phone"
        func profile(at time: Date) -> ContactBinding {
            .init(proofID: profileID, account: "Alice_ID", name: "Alice", profile:
                .init(device: device, stream: stream, capturedAt: time.addingTimeInterval(-0.2),
                      confirmedAt: time.addingTimeInterval(-0.1), origin: .fixture))
        }
        func scope(task: SkillTask) -> DraftScope {
            .init(taskID: task.id, purpose: .message, device: device, stream: stream, account: "Alice_ID", contactProofID: profileID)
        }
        func observation(_ text: String, task: SkillTask, at time: Date) -> DraftObservation {
            let frame = FrameStamp(device: device, stream: stream, capturedAt: time, confirmedAt: time, origin: .fixture)
            let field = ObservedControl(id: "current-process-field", frameID: frame.id, role: .textField,
                rect: .init(x: 0.2, y: 0.5, width: 0.5, height: 0.08), source: .fixture)
            return .init(frame: frame, scope: scope(task: task), fieldBindingID: UUID(), field: field, controls: [field],
                text: text, complete: true, ownership: text.isEmpty ? .empty : .taskOwned, focused: true,
                fieldKind: .message, selection: .caretAtEnd, composing: false)
        }
        var result: [String: Any] = ["process_id": ProcessInfo.processInfo.processIdentifier,
                                     "origin": "fixture", "device_input_performed": false]
        if args[1] == "seed" {
            let task = SkillTask(originalRequest: "Offline fixture: fill hello without submitting",
                contact: .init(keyword: "Alice", expectedAccount: "Alice_ID"), goal: .message(text: "hello", submit: false))
            let preparation = try DraftPreparation(task: task, scope: scope(task: task), mode: .offline,
                checkpointStorage: store, contact: profile(at: baseline), now: baseline)
            let before = observation("", task: task, at: baseline.addingTimeInterval(0.1))
            guard case .action(let ticket) = try preparation.next(before, keyboardAvailable: true, now: baseline.addingTimeInterval(0.11))
            else { throw SkillError.invalidTransition }
            guard case .inputASCII(_, let text) = try preparation.take(ticket, current: before, keyboardAvailable: true,
                now: baseline.addingTimeInterval(0.12)), text == "hello" else { throw SkillError.invalidAction }
            // The action is intentionally discarded. The next process must
            // treat the durable intent as uncertain, never as a completed input.
            result["status"] = "intent_saved_no_io"; result["planned_text"] = text
        } else {
            guard args.count == 4, let saved = try store.load(), saved.origin == .fixture else { throw SkillError.wrongProvenance }
            let now = baseline.addingTimeInterval(1)
            let preparation = try DraftPreparation.restore(task: saved.task, scope: scope(task: saved.task), mode: .offline,
                storage: store, contact: profile(at: now), now: now)
            let current = observation(args[3], task: saved.task, at: now.addingTimeInterval(0.2))
            switch try preparation.next(current, keyboardAvailable: true, now: now.addingTimeInterval(0.21)) {
            case .hold(let reason): result["status"] = "hold"; result["reason"] = reason.rawValue
            case .verified(let text, _): result["status"] = "verified_readback"; result["text"] = text
            case .action(let ticket):
                guard case .inputASCII(_, let text) = try preparation.take(ticket, current: current, keyboardAvailable: true,
                    now: now.addingTimeInterval(0.22)) else { throw SkillError.invalidAction }
                result["status"] = "suffix_action_no_io"; result["planned_text"] = text
            case .needsClipboardPreparation: throw SkillError.unavailableInput
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor private static func resultRecovery(_ args: [String]) throws {
        let store = try FileJournal(directory: URL(fileURLWithPath: args[2], isDirectory: true))
        let baseline = Date(timeIntervalSince1970: 1_800_000_000), stream = UUID()
        let device = "offline-fixture-phone"
        var output: [String: Any] = ["process_id": ProcessInfo.processInfo.processIdentifier,
                                     "origin": "fixture", "device_input_performed": false]
        if args[1] == "seed-result" {
            let task = SkillTask(originalRequest: "Offline fixture: send hello", contact: .init(keyword: "Alice", expectedAccount: "Alice_ID"),
                                 goal: .message(text: "hello", submit: true))
            let contact = ContactBinding(account: "Alice_ID", name: "Alice", profile:
                .init(device: device, stream: stream, capturedAt: baseline.addingTimeInterval(-0.2),
                      confirmedAt: baseline.addingTimeInterval(-0.1), origin: .fixture))
            let coordinator = try SubmissionCoordinator(storage: store, mode: .offline)
            try coordinator.bindContact(contact, task: task, now: baseline)
            let frame = FrameStamp(device: device, stream: stream, capturedAt: baseline.addingTimeInterval(0.1),
                                   confirmedAt: baseline.addingTimeInterval(0.1), origin: .fixture)
            let field = ObservedControl(id: "field", frameID: frame.id, role: .textField,
                rect: .init(x: 0.2, y: 0.8, width: 0.5, height: 0.06), source: .fixture)
            let send = ObservedControl(id: "send", frameID: frame.id, role: .sendMessage,
                rect: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.06), source: .fixture)
            let before = SceneObservation(frame: frame, account: contact.account, contactProofID: contact.proofID, surface: .chat,
                controls: [field,send], draft: .init(fieldID: field.id, text: "hello", kind: .message), listVerifiedEmpty: true,
                correspondenceUnambiguous: true, landmarks: [.init(kind: .conversationStart, text: "fixture start", frameID: frame.id, source: .fixture)])
            guard case .dispatch(let ticket) = try coordinator.reserve(task: task, effect: .message("hello"), observation: before,
                controlID: send.id, now: baseline.addingTimeInterval(0.11)) else { throw SkillError.invalidTransition }
            _ = try coordinator.take(ticket, current: before, now: baseline.addingTimeInterval(0.12)) // discarded, no I/O
            output["status"] = "effect_intent_saved_no_io"
        } else {
            guard args.count == 4, ["missing", "pending", "normal"].contains(args[3]), let record = try store.load().records.first,
                  record.before.frame.origin == .fixture else { throw SkillError.wrongProvenance }
            let now = (record.recoveryReviews?.last?.reviewedAt ?? baseline).addingTimeInterval(1)
            let contact = ContactBinding(account: "Alice_ID", name: "Alice", profile:
                .init(device: device, stream: stream, capturedAt: now.addingTimeInterval(-0.2),
                      confirmedAt: now.addingTimeInterval(-0.1), origin: .fixture))
            let reader = try RecoveredResultReader(storage: store, operationID: record.id, task: record.task,
                                                   contact: contact, mode: .offline, now: now)
            let frame = FrameStamp(device: device, stream: stream, capturedAt: now.addingTimeInterval(0.2),
                                   confirmedAt: now.addingTimeInterval(0.2), origin: .fixture)
            let items: [VisibleItem] = args[3] == "missing" ? [] : [.init(id: "fresh-process-result", text: "hello", author: .myself,
                                                                          state: args[3] == "pending" ? .pending : .normal)]
            let after = SceneObservation(frame: frame, account: contact.account, contactProofID: contact.proofID, surface: .chat,
                items: items, listVerifiedEmpty: items.isEmpty, correspondenceUnambiguous: true,
                landmarks: [.init(kind: .conversationStart, text: "fixture start", frameID: frame.id, source: .fixture, followingItemID: items.first?.id)])
            switch try reader.observe(after, now: now.addingTimeInterval(0.3)) {
            case .verified: output["status"] = "effect_verified"
            case .failed: output["status"] = "effect_failed"
            case .uncertain(let reason): output["status"] = "effect_uncertain"; output["reason"] = reason
            }
            output["operation_count"] = try store.load().records.count
            output["review_count"] = try store.load().records[0].recoveryReviews?.count
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
