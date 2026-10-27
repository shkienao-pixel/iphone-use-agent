import Foundation
import UIKit
import ActivityKit

@main struct ActivityHandoffChecks {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let suite = "sela-activity-guide-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TaskActivityController(defaults: defaults, terminalDisplayNanoseconds: 50_000_000)
        var guides = 0; controller.onFirstUseGuide = { guides += 1 }
        await controller.flush()
        let initial = PhoneTaskRecord(id: UUID(), title: "航班查询"), native = PhoneTaskRecord(id: UUID(), title: "已交接的原生任务")
        let initialSession = UUID(), nativeSession = UUID()
        func update(_ record: PhoneTaskRecord, phase: AgentPhase = .observing, session: UUID, releasing: Bool = false) async {
            controller.update(record: record, phase: phase, step: 1, action: nil, enabled: true, sessionID: session, releasing: releasing, canPause: true, canStop: true)
            await controller.flush()
        }
        await update(initial, session: initialSession)
        let original = Activity<AgentActivityAttributes>.activities[0]
        expect(guides == 1, "First activity offers a one-time guide without claiming permission was already completed")
        expect(original.content.relevanceScore == 100, "Character activity receives the primary relative display priority")
        expect(controller.represents(initial.id) && original.attributes.taskID == initial.id, "Foreground query starts an activity with its exact identity")
        expect(original.content.state.controlSessionID == initialSession, "Initial controls retain their exact process-local session")
        UIApplication.shared.applicationState = .background
        await update(native, session: nativeSession)
        expect(Activity<AgentActivityAttributes>.activities.count == 1 && original.endings == 0, "Background handoff updates existing activity without ending or requesting replacement")
        expect(original.content.state.displayTaskID == native.id && original.content.state.taskTitle == native.title, "Proxy routes open link to the current displayed task")
        expect(original.content.state.controlSessionID == nil && original.content.state.canPause == false && original.content.state.canStop == false, "Background display proxy grants no controls against immutable old attributes")
        expect(!controller.represents(native.id), "Display proxy never claims the new task's control identity")
        UIApplication.shared.applicationState = .active
        await update(native, session: nativeSession)
        expect(original.endings == 1 && Activity<AgentActivityAttributes>.activities.count == 2, "Foreground refresh replaces immutable attributes with a new exact activity")
        let replacement = Activity<AgentActivityAttributes>.activities[1]
        expect(controller.represents(native.id) && replacement.content.state.controlSessionID == nativeSession, "Foreground replacement restores controls only for actual matching session")
        await update(native, phase: .paused, session: nativeSession, releasing: true)
        expect(replacement.endings == 0 && replacement.content.state.canPause == false, "Cancellation cleanup remains represented while input release settles")
        await update(native, phase: .completed, session: nativeSession)
        expect(replacement.endings == 0 && replacement.content.state.completed == true, "Actual completion first displays a truthful green terminal state")
        expect(!UIApplication.shared.assertions.isEmpty, "Finite display cleanup time does not restart task execution or request continuous background work")
        expect(replacement.content.state.controlSessionID == nil, "Completed display has no execution authority")
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(replacement.endings == 1 && UIApplication.shared.assertions.isEmpty, "Terminal marker ends after its short display and balances finite cleanup time")
        // Presentation-only first-use preview uses no engine or task controls.
        UIApplication.shared.applicationState = .active
        expect(await controller.startPreview(), "Idle user can start a character-only first-use preview")
        let preview = Activity<AgentActivityAttributes>.activities.last!
        expect(controller.previewing && preview.content.state.isPreview == true, "Preview is explicitly marked as presentation-only")
        expect(preview.content.state.controlSessionID == nil && preview.content.state.canPause == false && preview.content.state.canStop == false,
               "A preview never acquires pause/stop task authority")
        expect(preview.content.state.taskTitle == "Sela 角色预览" && preview.content.state.status.contains("未执行任务"),
               "Preview cannot be mistaken for a running or completed business task")
        expect(!controller.previewMessage.contains("已授权") && controller.previewMessage.contains("允许"),
               "Creating an activity explains first-use permission without claiming the user already completed it")
        expect(!controller.represents(preview.attributes.taskID), "A preview never represents a controllable task")
        await update(initial, session: initialSession)
        expect(!controller.previewing && preview.endings == 1 && controller.represents(initial.id), "An actual task takes over and ends the preview without being overwritten")
        expect(!(await controller.startPreview()), "An existing real task presentation prevents preview creation")
        await update(initial, phase: .completed, session: initialSession)
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(await controller.startPreview(), "Preview is available again after the actual task ends")
        let onReturn = Activity<AgentActivityAttributes>.activities.last!
        for phase in ["observing", "acting", "needsUser", "paused", "completed", "stale", "failed"] {
            controller.updatePreview(phase: phase); await controller.flush()
            expect(controller.previewing && onReturn.content.state.phase == phase && onReturn.endings == 0,
                   "Preview can display \(phase) without ending or executing business work")
        }
        controller.applicationBecameActive(); await controller.flush()
        expect(!controller.previewing && onReturn.endings == 1, "Returning to Sela cleans up the exact preview activity")
        ActivityAuthorizationInfo.enabled = false; controller.refreshAvailability()
        let blockedPreview = await controller.startPreview()
        expect(!controller.activitiesAvailable && !blockedPreview, "System-disabled activities do not trigger a misleading preview success")
        ActivityAuthorizationInfo.enabled = true; controller.refreshAvailability()
        expect(await controller.startPreview(), "A user can retry preview after changing system settings")
        let disabledPreview = Activity<AgentActivityAttributes>.activities.last!
        controller.update(record: nil, phase: .idle, step: 0, action: nil, enabled: false, sessionID: initialSession,
            releasing: false, canPause: false, canStop: false)
        await controller.flush()
        expect(!controller.previewing && disabledPreview.endings == 1, "Turning task-status display off also ends the preview")
        await update(initial, session: initialSession)
        let reused = Activity<AgentActivityAttributes>.activities.last!
        await update(initial, phase: .failed, session: initialSession)
        expect(reused.content.state.phase == "failed" && reused.endings == 0, "Failure also remains briefly visible without execution controls")
        let newSession = UUID()
        await update(initial, phase: .preparing, session: newSession)
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(reused.endings == 0 && reused.content.state.controlSessionID == newSession,
               "Late terminal timeout cannot end a new run reusing the same task activity")
        expect(UIApplication.shared.assertions.isEmpty, "New work cancels the old finite terminal-cleanup assertion")
        UIApplication.shared.applicationState = .background
        await update(initial, phase: .stopped, session: newSession)
        controller.update(record: nil, phase: .idle, step: 0, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        await controller.flush()
        expect(reused.endings == 0 && reused.content.state.controlSessionID == nil,
               "An idle model refresh does not erase the brief stopped marker or revive controls")
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(reused.endings == 1 && UIApplication.shared.assertions.isEmpty,
               "Background terminal cleanup finishes without delaying actual task cancellation")
        UIApplication.shared.applicationState = .active
        await update(initial, phase: .observing, session: newSession)
        let queuedTerminal = Activity<AgentActivityAttributes>.activities.last!
        controller.update(record: initial, phase: .completed, step: 2, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        // No await: the model's empty refresh arrives before ActivityKit applied
        // the completion update and before the expiry token exists.
        controller.update(record: nil, phase: .idle, step: 0, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        await controller.flush()
        expect(queuedTerminal.endings == 0 && queuedTerminal.content.state.completed == true,
               "Queued nil refresh cannot erase a terminal marker before its display token is created")
        controller.update(record: native, phase: .completed, step: 0, action: nil, enabled: true, sessionID: nativeSession,
            releasing: false, canPause: false, canStop: false)
        await controller.flush()
        expect(queuedTerminal.endings == 0 && queuedTerminal.content.state.displayTaskID == initial.id,
               "An unrelated historical terminal record cannot replace the latest real run's terminal marker")
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(guides == 1, "Repeated activities never repeat the already-shown first-use explanation")
        await update(initial, phase: .observing, session: newSession)
        let suspendedTerminal = Activity<AgentActivityAttributes>.activities.last!
        var terminalUpdateEntered = false
        var resumeTerminalUpdate: CheckedContinuation<Void, Never>?
        suspendedTerminal.beforeUpdate = {
            terminalUpdateEntered = true
            await withCheckedContinuation { resumeTerminalUpdate = $0 }
        }
        controller.update(record: initial, phase: .completed, step: 2, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        while !terminalUpdateEntered { await Task.yield() }
        controller.update(record: nil, phase: .idle, step: 0, action: nil, enabled: false, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        expect(!controller.hasTaskPresentation, "Disabling during an awaited terminal update immediately revokes presentation ownership")
        resumeTerminalUpdate?.resume(); suspendedTerminal.beforeUpdate = nil
        await controller.flush()
        expect(!controller.hasTaskPresentation && suspendedTerminal.endings == 1,
               "Late terminal update cannot restore disabled presentation ownership after the activity is removed")
        expect(UIApplication.shared.assertions.isEmpty,
               "Late terminal update cannot recreate a terminal cleanup assertion after display was disabled")
        expect(await controller.startPreview(), "Idle preview remains usable after disabling during an awaited terminal update")
        controller.stopPreview(); await controller.flush()
        controller.update(record: initial, phase: .observing, step: 1, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: true, canStop: true)
        controller.update(record: initial, phase: .completed, step: 2, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        await controller.flush()
        let rapidCompletion = Activity<AgentActivityAttributes>.activities.last!
        expect(controller.hasTaskPresentation && rapidCompletion.content.state.completed == true && rapidCompletion.endings == 0,
               "A still-current completion retains its marker when queued immediately behind the initial active update")
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        expect(!controller.hasTaskPresentation && rapidCompletion.endings == 1 && UIApplication.shared.assertions.isEmpty,
               "Queued rapid completion cleans up its marker and finite assertion normally")
        await update(initial, phase: .observing, session: newSession)
        let supersededTerminal = Activity<AgentActivityAttributes>.activities.last!
        terminalUpdateEntered = false; resumeTerminalUpdate = nil
        supersededTerminal.beforeUpdate = {
            terminalUpdateEntered = true
            await withCheckedContinuation { resumeTerminalUpdate = $0 }
        }
        controller.update(record: initial, phase: .completed, step: 2, action: nil, enabled: true, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        while !terminalUpdateEntered { await Task.yield() }
        controller.update(record: nil, phase: .idle, step: 0, action: nil, enabled: false, sessionID: newSession,
            releasing: false, canPause: false, canStop: false)
        let resumedSession = UUID()
        controller.update(record: initial, phase: .observing, step: 1, action: nil, enabled: true, sessionID: resumedSession,
            releasing: false, canPause: true, canStop: true)
        resumeTerminalUpdate?.resume(); supersededTerminal.beforeUpdate = nil
        await controller.flush()
        let resumedActivity = Activity<AgentActivityAttributes>.activities.last!
        expect(controller.hasTaskPresentation && controller.represents(initial.id) && supersededTerminal.endings == 1,
               "An older disabled update cannot clear a newer run's presentation ownership while the queue drains")
        expect(resumedActivity.content.state.controlSessionID == resumedSession && UIApplication.shared.assertions.isEmpty,
               "Only the new run's live controls survive the delayed terminal and disable operations")
        await update(initial, phase: .completed, session: resumedSession)
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()
        print("PASS: \(checks) actual activity controller foreground/background handoff and control identity checks")
    }
}
