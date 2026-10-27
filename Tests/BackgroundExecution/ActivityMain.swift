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
        expect(controller.hasTaskPresentation && controller.represents(initial.id) && supersededTerminal.endings == 0,
               "A superseded disable preserves the existing activity for a newer foreground run")
        expect(resumedActivity === supersededTerminal && resumedActivity.content.state.controlSessionID == resumedSession && UIApplication.shared.assertions.isEmpty,
               "The reused activity grants controls only to the new run after the delayed terminal and disable operations")
        await update(initial, phase: .completed, session: resumedSession)
        try? await Task.sleep(nanoseconds: 70_000_000); await controller.flush()

        // An older disabled refresh may be queued while ActivityKit is still
        // applying an update. A newer task can take ownership before the app
        // leaves the foreground, but the serial queue might not drain until the
        // app has backgrounded, where an ended activity cannot be recreated.
        UIApplication.shared.applicationState = .active
        let backgroundRace = TaskActivityController(defaults: defaults, terminalDisplayNanoseconds: 50_000_000)
        await backgroundRace.flush()
        let earlierTask = PhoneTaskRecord(id: UUID(), title: "旧任务")
        let newerTask = PhoneTaskRecord(id: UUID(), title: "新任务")
        let earlierSession = UUID(), newerSession = UUID()
        backgroundRace.update(record: earlierTask, phase: .observing, step: 1, action: nil,
                              enabled: true, sessionID: earlierSession, releasing: false, canPause: true, canStop: true)
        await backgroundRace.flush()
        let inheritedActivity = Activity<AgentActivityAttributes>.activities.last!
        var oldUpdateEntered = false
        var resumeOldUpdate: CheckedContinuation<Void, Never>?
        inheritedActivity.beforeUpdate = {
            oldUpdateEntered = true
            await withCheckedContinuation { resumeOldUpdate = $0 }
        }
        backgroundRace.update(record: earlierTask, phase: .acting, step: 2, action: "测试",
                              enabled: true, sessionID: earlierSession, releasing: false, canPause: true, canStop: true)
        while !oldUpdateEntered { await Task.yield() }
        backgroundRace.update(record: nil, phase: .idle, step: 0, action: nil,
                              enabled: false, sessionID: earlierSession, releasing: false, canPause: false, canStop: false)
        backgroundRace.update(record: newerTask, phase: .observing, step: 1, action: nil,
                              enabled: true, sessionID: newerSession, releasing: false, canPause: true, canStop: true)
        expect(backgroundRace.hasTaskPresentation, "Newer task takes presentation ownership before the queued operations drain")
        UIApplication.shared.applicationState = .background
        resumeOldUpdate?.resume(); inheritedActivity.beforeUpdate = nil
        await backgroundRace.flush()
        expect(inheritedActivity.endings == 0, "An obsolete queued disable must not end the only activity once a newer task takes over")
        expect(backgroundRace.hasTaskPresentation && inheritedActivity.content.state.displayTaskID == newerTask.id,
               "The newer background task is represented by the surviving activity")
        expect(inheritedActivity.content.state.controlSessionID == nil && inheritedActivity.content.state.canPause == false && inheritedActivity.content.state.canStop == false,
               "A reused background activity never exposes controls for the earlier task identity")
        backgroundRace.update(record: nil, phase: .idle, step: 0, action: nil,
                              enabled: false, sessionID: newerSession, releasing: false, canPause: false, canStop: false)
        expect(!backgroundRace.hasTaskPresentation, "A current disable immediately revokes presentation ownership")
        await backgroundRace.flush()
        expect(inheritedActivity.endings == 1, "A current disable still ends the activity")
        UIApplication.shared.applicationState = .active
        backgroundRace.update(record: newerTask, phase: .observing, step: 1, action: nil,
                              enabled: true, sessionID: newerSession, releasing: false, canPause: true, canStop: true)
        await backgroundRace.flush()
        let foregroundActivity = Activity<AgentActivityAttributes>.activities.last!
        expect(backgroundRace.represents(newerTask.id) && foregroundActivity.content.state.controlSessionID == newerSession,
               "A foreground restart creates a matching activity with only the new task's controls")
        backgroundRace.update(record: nil, phase: .idle, step: 0, action: nil,
                              enabled: false, sessionID: newerSession, releasing: false, canPause: false, canStop: false)
        await backgroundRace.flush()

        // A newer task can also arrive after the system has already accepted
        // an end call. That operation cannot be recalled, so it is essential
        // not to advertise a missing activity while the app is in background.
        var pauseEnd = false, endStarted = false
        var resumeEnd: CheckedContinuation<Void, Never>?
        let endingRace = TaskActivityController(defaults: defaults, terminalDisplayNanoseconds: 50_000_000) { activity, content, policy in
            if pauseEnd {
                pauseEnd = false; endStarted = true
                await withCheckedContinuation { resumeEnd = $0 }
            }
            await activity.end(content, dismissalPolicy: policy)
        }
        await endingRace.flush()
        let finishingTask = PhoneTaskRecord(id: UUID(), title: "正在关闭的任务")
        let arrivingTask = PhoneTaskRecord(id: UUID(), title: "随后到来的任务")
        let finishingSession = UUID(), arrivingSession = UUID()
        endingRace.update(record: finishingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: finishingSession, releasing: false, canPause: true, canStop: true)
        await endingRace.flush()
        let endingActivity = Activity<AgentActivityAttributes>.activities.last!
        pauseEnd = true
        endingRace.update(record: nil, phase: .idle, step: 0, action: nil,
                          enabled: false, sessionID: finishingSession, releasing: false, canPause: false, canStop: false)
        while !endStarted { await Task.yield() }
        endingRace.update(record: arrivingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: true, canStop: true)
        UIApplication.shared.applicationState = .background
        resumeEnd?.resume()
        await endingRace.flush()
        expect(endingActivity.endings == 1 && !endingRace.represents(arrivingTask.id),
               "An already-issued end really finishes and cannot create a new background activity")
        expect(!endingRace.hasTaskPresentation && !endingRace.error.isEmpty,
               "A missing background activity is reported as unavailable rather than claimed as showing")
        // The host can settle to an enabled but empty idle snapshot while the
        // activity is unavailable; no task remains that needs foreground repair.
        endingRace.update(record: nil, phase: .idle, step: 0, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: false, canStop: false)
        await endingRace.flush()
        expect(!endingRace.hasTaskPresentation && endingRace.error.isEmpty,
               "An enabled idle snapshot clears the obsolete missing-activity message")
        // A new active snapshot in the background still cannot create an
        // activity; it must recreate the unavailable state until foreground.
        endingRace.update(record: arrivingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: true, canStop: true)
        await endingRace.flush()
        expect(!endingRace.hasTaskPresentation && !endingRace.error.isEmpty,
               "A later background task correctly reports that its activity still needs foreground recovery")
        UIApplication.shared.applicationState = .active
        // Match PhoneAgentViewModel.refreshBackgroundExecution(): the host
        // refreshes the current task immediately after the foreground callback.
        endingRace.applicationBecameActive()
        endingRace.update(record: arrivingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: true, canStop: true)
        await endingRace.flush()
        let recoveredActivity = Activity<AgentActivityAttributes>.activities.last!
        expect(endingRace.hasTaskPresentation && endingRace.represents(arrivingTask.id) && endingRace.error.isEmpty,
               "Returning to foreground recreates the latest pending task activity")
        expect(recoveredActivity !== endingActivity && recoveredActivity.content.state.controlSessionID == arrivingSession && recoveredActivity.content.state.canPause == true && recoveredActivity.content.state.canStop == true,
               "The recreated activity owns only the arriving task and its current controls")
        endingRace.update(record: nil, phase: .idle, step: 0, action: nil,
                          enabled: false, sessionID: arrivingSession, releasing: false, canPause: false, canStop: false)
        expect(!endingRace.hasTaskPresentation, "Latest explicit disable immediately revokes the recovered presentation")
        await endingRace.flush()
        expect(recoveredActivity.endings == 1, "Latest explicit disable ends the recovered activity")

        // A newer disabled snapshot must supersede a queued foreground refresh.
        endingRace.update(record: finishingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: finishingSession, releasing: false, canPause: true, canStop: true)
        await endingRace.flush()
        let secondEndingActivity = Activity<AgentActivityAttributes>.activities.last!
        pauseEnd = true; endStarted = false; resumeEnd = nil
        endingRace.update(record: nil, phase: .idle, step: 0, action: nil,
                          enabled: false, sessionID: finishingSession, releasing: false, canPause: false, canStop: false)
        while !endStarted { await Task.yield() }
        endingRace.update(record: arrivingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: true, canStop: true)
        UIApplication.shared.applicationState = .background
        resumeEnd?.resume(); await endingRace.flush()
        expect(secondEndingActivity.endings == 1 && !endingRace.hasTaskPresentation && !endingRace.error.isEmpty,
               "A second in-flight end also retains an explicitly unavailable deferred state")
        UIApplication.shared.applicationState = .active
        let countBeforeCancellation = Activity<AgentActivityAttributes>.activities.count
        endingRace.applicationBecameActive()
        endingRace.update(record: arrivingTask, phase: .observing, step: 1, action: nil,
                          enabled: true, sessionID: arrivingSession, releasing: false, canPause: true, canStop: true)
        endingRace.update(record: nil, phase: .idle, step: 0, action: nil,
                          enabled: false, sessionID: arrivingSession, releasing: false, canPause: false, canStop: false)
        await endingRace.flush()
        expect(!endingRace.hasTaskPresentation && endingRace.error.isEmpty && Activity<AgentActivityAttributes>.activities.count == countBeforeCancellation,
               "A newer disable cancels the queued foreground refresh and clears the unavailable message")
        print("PASS: \(checks) actual activity controller foreground/background handoff and control identity checks")
    }
}
