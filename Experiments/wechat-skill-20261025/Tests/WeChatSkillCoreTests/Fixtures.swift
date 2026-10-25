import Foundation
import XCTest
@testable import WeChatSkillCore

@MainActor final class Fixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stream = UUID()
    let store: MemoryJournal
    let coordinator: SubmissionCoordinator
    let task: SkillTask
    let contact: ContactBinding
    var moment: MomentBinding?
    let message = "你好，明天见👋\n第二行保留。"

    init(goal: TaskGoal? = nil, store: MemoryJournal? = nil, mode: EvaluationMode = .offline) throws {
        let storage = store ?? MemoryJournal(); self.store = storage
        task = SkillTask(originalRequest: "fixture user request", contact: .init(keyword: "Alice", expectedAccount: "Alice_ID"),
                         goal: goal ?? .message(text: "你好，明天见👋\n第二行保留。", submit: true))
        contact = ContactBinding(account: "Alice_ID", name: "Alice", profile:
            FrameStamp(device: "fixture-phone", stream: stream, capturedAt: now.addingTimeInterval(-1),
                       confirmedAt: now.addingTimeInterval(-0.5), origin: .fixture))
        coordinator = try SubmissionCoordinator(storage: storage, mode: mode)
        if mode == .offline { try coordinator.bindContact(contact, task: task, now: now) }
        if case .moment = task.goal, mode == .offline {
            moment = try coordinator.bindMoment(candidates: [candidate()], task: task, frame: stamp(-0.2), now: now)
        }
    }
    func stamp(_ offset: Double = 0) -> FrameStamp {
        FrameStamp(device: "fixture-phone", stream: stream, capturedAt: now.addingTimeInterval(offset),
                   confirmedAt: now.addingTimeInterval(offset), origin: .fixture)
    }
    func candidate(_ id: String = "post-1", body: String = "嗨，正式介绍一下我们 👋", complete: Bool = true,
                   detail: Bool = true, year: Int? = nil) -> MomentCandidate {
        .init(localID: id, ownerAccount: "Alice_ID", dateLabel: "29 Sep", explicitYear: year,
              body: body, bodyComplete: complete, isDetail: detail)
    }
    func control(_ role: ControlRole, stamp: FrameStamp, id: String = "button") -> ObservedControl {
        .init(id: id, frameID: stamp.id, role: role,
              rect: .init(x: 0.8, y: 0.8, width: 0.1, height: 0.06), source: .fixture)
    }
    func scene(effect: Effect = .message("你好，明天见👋\n第二行保留。"), offset: Double = 0,
               items: [VisibleItem] = [], empty: Bool = true, anchors: [String] = []) -> SceneObservation {
        let frame = stamp(offset)
        let field = control(.textField, stamp: frame, id: "field")
        let button = control(effect.role, stamp: frame, id: "submit")
        return .init(frame: frame, account: contact.account, contactProofID: contact.proofID,
                     momentBindingID: effect.slot == "message" ? nil : moment?.id,
                     surface: effect == .like ? .momentActions : (effect.slot == "message" ? .chat : .momentComposer),
                     controls: [field, button],
                     draft: effect.text.map { .init(fieldID: "field", text: $0, kind: effect.slot == "message" ? .message : .momentComment) },
                     items: items, continuityAnchors: anchors, listVerifiedEmpty: empty,
                     correspondenceUnambiguous: true, like: .notLikedBySelf)
    }
    func reserve(_ effect: Effect, before: SceneObservation? = nil) throws -> DispatchTicket {
        let observation = before ?? scene(effect: effect)
        guard case .dispatch(let ticket) = try coordinator.reserve(task: task, effect: effect,
            observation: observation, controlID: "submit", now: now) else { throw SkillError.invalidTransition }
        return ticket
    }
    func dispatch(_ effect: Effect, before: SceneObservation? = nil) throws -> DispatchTicket {
        let observation = before ?? scene(effect: effect)
        let ticket = try reserve(effect, before: observation)
        _ = try coordinator.take(ticket, current: observation, now: now.addingTimeInterval(0.01))
        return ticket
    }
    func after(_ effect: Effect, items: [VisibleItem], empty: Bool = false, anchors: [String] = []) -> SceneObservation {
        var observation = scene(effect: effect, offset: 0.2, items: items, empty: empty, anchors: anchors)
        observation.draft = nil
        if effect.slot != "message" { observation.surface = .momentDetail }
        return observation
    }
}

func expectError(_ expected: SkillError? = nil, file: StaticString = #filePath, line: UInt = #line,
                 _ work: () throws -> Void) {
    XCTAssertThrowsError(try work(), file: file, line: line) { error in
        if let expected { XCTAssertEqual(error as? SkillError, expected, file: file, line: line) }
    }
}
