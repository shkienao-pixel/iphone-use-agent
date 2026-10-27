import Foundation
import UIKit
import BackgroundTasks

@main struct BackgroundExecutionChecks {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        func settle() async { for _ in 0..<3 { try? await Task.sleep(nanoseconds: 1_000_000); await Task.yield() } }
        let app = UIApplication.shared, scheduler = BGTaskScheduler.shared
        func reset() { app.reset(); scheduler.reset() }
        let first = BackgroundExecutionController.Work(id: UUID(), sessionID: UUID())
        let second = BackgroundExecutionController.Work(id: UUID(), sessionID: UUID())
        reset()
        let controller = BackgroundExecutionController()
        var expired: [[BackgroundExecutionController.Work]] = []
        controller.onExpiration = { expired.append($0) }
        controller.synchronize([])
        expect(!controller.diagnosticSnapshot.isContinuationActive && !controller.diagnosticSnapshot.isContinuationPending && !controller.diagnosticSnapshot.finiteAssertionActive,
               "Idle diagnostics cannot claim that any background continuation was granted")
        expect(app.assertions.isEmpty && scheduler.submitted.isEmpty, "Idle app does not acquire execution time")
        controller.synchronize([first]); await settle()
        expect(controller.diagnosticSnapshot.isContinuationPending && !controller.diagnosticSnapshot.isContinuationActive && controller.diagnosticSnapshot.finiteAssertionActive,
               "Submitted pending work is distinct from a granted continuation in diagnostics")
        expect(app.assertions.count == 1 && scheduler.submitted.count == 1, "Foreground user work acquires finite assertion before continued grant")
        let request = scheduler.submitted[0], oldHandler = scheduler.handlers[scheduler.submitted[0].identifier]!
        expect(scheduler.mainThreadSubmissions == [false], "Scheduler submission never runs on the main thread")
        expect(request.strategy == .fail, "Already-started work never enters a deferred replay queue")
        expect(request.identifier.hasPrefix((Bundle.main.bundleIdentifier ?? "dev.agentmouse") + ".continued."), "Continued identifier is scoped to this bundle")
        let obsoleteAssertion = app.assertions.values.first!
        app.applicationState = .background
        let continued = BGContinuedProcessingTask(); oldHandler(continued)
        expect(controller.diagnosticSnapshot.isContinuationActive && !controller.diagnosticSnapshot.isContinuationPending && !controller.diagnosticSnapshot.finiteAssertionActive,
               "Only an actual scheduler launch handler marks continuous execution active")
        expect(app.assertions.isEmpty && app.ended.count == 1, "Granted continued execution balances the temporary UIKit assertion")
        expect(continued.progress.completedUnitCount == 0 && continued.progress.totalUnitCount == 1, "Pending cloud work remains incomplete")
        obsoleteAssertion()
        expect(expired.isEmpty, "Obsolete finite timeout cannot expire a live continued grant")
        var progressed = first; progressed.completedUnits = 3
        controller.synchronize([progressed, second])
        expect(continued.progress.completedUnitCount == 3 && continued.progress.totalUnitCount == 5, "Progress comes from actual completed engine steps")
        controller.synchronize([second])
        expect(continued.progress.completedUnitCount == 4 && continued.progress.totalUnitCount == 5, "A settled sibling contributes one processed-work unit")
        controller.synchronize([]); await settle()
        expect(continued.completions == [true] && continued.progress.isFinished, "Last settled workload completes its grant once")
        expect(scheduler.cancelled.contains(request.identifier), "Completion cancels a not-yet-delivered scheduler request")

        app.applicationState = .active
        let next = BackgroundExecutionController.Work(id: first.id, sessionID: UUID())
        controller.synchronize([next]); await settle()
        expect(scheduler.submitted.count == 2 && scheduler.submitted[1].identifier != request.identifier, "A replacement run registers a fresh scheduler identity")
        let stale = BGContinuedProcessingTask(); oldHandler(stale)
        expect(stale.completions == [false] && expired.isEmpty, "A late old grant cannot acquire authority over a new run")
        let nextGrant = BGContinuedProcessingTask(); scheduler.handlers[scheduler.submitted[1].identifier]!(nextGrant)
        let oldExpiration = nextGrant.expirationHandler!
        var checkpointed = false
        controller.onExpiration = { work in
            expect(nextGrant.completions.isEmpty, "Expiration cancels and checkpoints host work before completing its OS grant")
            expired.append(work); checkpointed = true
        }
        nextGrant.onCompletion = { _ in expect(checkpointed, "OS completion follows the host checkpoint boundary") }
        oldExpiration(); await settle()
        expect(expired.count == 1 && expired[0] == [next], "OS cancellation delivers the exact current workload and generation")
        expect(nextGrant.completions == [false], "Cancellation completes the scheduler grant as unsuccessful")
        controller.synchronize([next]); controller.becameActive()
        expect(scheduler.submitted.count == 2, "An expired session never silently restarts when the app becomes active")
        let newer = BackgroundExecutionController.Work(id: first.id, sessionID: UUID())
        controller.synchronize([newer]); await settle()
        expect(scheduler.submitted.count == 3, "An explicitly new run can proceed after prior expiration")
        oldExpiration(); await settle()
        expect(expired.count == 1, "A late old expiration cannot cancel the replacement run")
        controller.synchronize([])

        reset()
        scheduler.submissionError = NSError(domain: "test.scheduler", code: 4)
        let fallback = BackgroundExecutionController(); var fallbackExpired: [BackgroundExecutionController.Work] = []
        fallback.onExpiration = {
            expect(!app.assertions.isEmpty, "Finite expiration retains execution time through synchronous host cancellation and saving")
            fallbackExpired = $0
        }
        fallback.synchronize([first]); await settle()
        expect(!fallback.error.isEmpty && app.assertions.count == 1, "A denied continuous grant retains finite background time and reports its limitation")
        app.applicationState = .background
        app.assertions.values.first!()
        expect(fallbackExpired == [first] && app.assertions.isEmpty, "Finite expiry saves only the exact still-running work and releases assertion")
        app.applicationState = .active; fallback.synchronize([first])
        expect(scheduler.submitted.count == 1, "Fallback expiration also blocks implicit restart")

        reset()
        let foreground = BackgroundExecutionController(); var foregroundExpired = false
        foreground.onExpiration = { _ in foregroundExpired = true }
        foreground.synchronize([first]); await settle(); app.assertions.values.first!()
        expect(!foregroundExpired && app.assertions.isEmpty, "Finite assertion expiry in foreground does not cancel useful foreground work")
        foreground.becameActive()
        expect(app.assertions.count == 1, "Foreground return renews a missing finite assertion")
        foreground.synchronize([])
        let completedLate = BGContinuedProcessingTask(); scheduler.handlers[scheduler.submitted[0].identifier]!(completedLate)
        expect(completedLate.completions == [false], "Work completed before grant delivery cannot be resurrected")

        reset()
        app.applicationState = .background
        let cold = BackgroundExecutionController(); cold.synchronize([first])
        expect(app.assertions.isEmpty && scheduler.submitted.isEmpty, "A background-only snapshot cannot invent a user-started continuation")
        app.applicationState = .active; cold.becameActive(); await settle()
        expect(app.assertions.count == 1 && scheduler.submitted.count == 1, "Actual foreground work can obtain execution time")
        cold.synchronize([])
        expect(app.assertions.isEmpty, "Every temporary assertion is balanced")
        reset()
        let ordered = BackgroundExecutionController()
        var presentationGate: CheckedContinuation<Void, Never>?
        ordered.beforeContinuationSubmission = { await withCheckedContinuation { presentationGate = $0 } }
        ordered.synchronize([first]); await settle()
        expect(app.assertions.count == 1 && scheduler.submitted.isEmpty && presentationGate != nil,
               "Finite execution time is protected while the custom character activity is created first")
        presentationGate?.resume(); await settle()
        expect(scheduler.submitted.count == 1, "System continuation submits only after character presentation settles")
        ordered.synchronize([])

        reset()
        let finishedWhilePresenting = BackgroundExecutionController()
        var latePresentation: CheckedContinuation<Void, Never>?
        finishedWhilePresenting.beforeContinuationSubmission = { await withCheckedContinuation { latePresentation = $0 } }
        finishedWhilePresenting.synchronize([first]); await settle()
        finishedWhilePresenting.synchronize([])
        latePresentation?.resume(); await settle()
        expect(scheduler.submitted.isEmpty && app.assertions.isEmpty,
               "Late presentation completion cannot submit a background task after the workload ended")
        reset()
        let blockedPresentation = BackgroundExecutionController(presentationWaitNanoseconds: 1_000_000)
        var blockedGate: CheckedContinuation<Void, Never>?
        blockedPresentation.beforeContinuationSubmission = { await withCheckedContinuation { blockedGate = $0 } }
        blockedPresentation.synchronize([first]); await settle()
        try? await Task.sleep(nanoseconds: 10_000_000); await settle()
        expect(scheduler.submitted.count == 1 && app.assertions.count == 1,
               "A stalled ActivityKit presentation cannot block continuous background submission past the deadline")
        blockedGate?.resume(); await settle()
        expect(scheduler.submitted.count == 1, "Late presentation completion and timeout race submit exactly once")
        blockedPresentation.synchronize([])

        reset()
        let endedBeforeDeadline = BackgroundExecutionController(presentationWaitNanoseconds: 50_000_000)
        var endedGate: CheckedContinuation<Void, Never>?
        endedBeforeDeadline.beforeContinuationSubmission = { await withCheckedContinuation { endedGate = $0 } }
        endedBeforeDeadline.synchronize([first]); await settle()
        endedBeforeDeadline.synchronize([])
        try? await Task.sleep(nanoseconds: 60_000_000); await settle()
        endedGate?.resume(); await settle()
        expect(scheduler.submitted.isEmpty && app.assertions.isEmpty,
               "Cancelled deadline and late presentation completion cannot submit ended work")
        reset()
        scheduler.deferCompletion = true
        let reentrant = BackgroundExecutionController()
        reentrant.synchronize([first]); await settle()
        let reentrantRequest = scheduler.submitted[0]
        let reentrantGrant = BGContinuedProcessingTask(); scheduler.handlers[reentrantRequest.identifier]!(reentrantGrant)
        let replacement = BackgroundExecutionController.Work(id: first.id, sessionID: UUID())
        var oldCleanupFinished = false
        reentrant.onExpiration = { _ in
            reentrant.synchronize([])
            reentrant.synchronize([replacement])
            expect(scheduler.submitted.count == 1 && app.assertions.isEmpty,
                   "Expiration callback reentry cannot dispatch new work before its checkpoint boundary")
            expect(reentrantGrant.completions.isEmpty, "Reentrant synchronization cannot complete the detached expiring lease")
            oldCleanupFinished = true
        }
        reentrantGrant.onCompletion = { _ in expect(oldCleanupFinished, "Detached old lease finishes only after all reentrant checkpoint callbacks return") }
        reentrantGrant.expirationHandler!(); await settle()
        expect(scheduler.submitted.count == 2 && app.assertions.count == 1,
               "A newly authorized foreground generation may start after expiration cleanup")
        let replacementRequest = scheduler.submitted[1]
        expect(scheduler.cancelled.contains(reentrantRequest.identifier) && !scheduler.cancelled.contains(replacementRequest.identifier),
               "Old expiration cleanup cancels only its own submission")
        scheduler.completeNextDeferredSubmission(error: NSError(domain: "late.old.callback", code: 7)); await settle()
        expect(reentrant.diagnosticSnapshot.finiteAssertionActive && !reentrant.error.contains("暂未允许"),
               "Delayed submission callbacks cannot release the replacement generation's finite assertion")
        let replacementGrant = BGContinuedProcessingTask(); scheduler.handlers[replacementRequest.identifier]!(replacementGrant)
        expect(reentrant.diagnosticSnapshot.isContinuationActive && replacementGrant.completions.isEmpty,
               "Replacement grant remains live after old callback and completion cleanup")
        reentrant.synchronize([]); await settle()
        expect(replacementGrant.completions == [true], "Replacement generation completes its own grant exactly once")
        print("PASS: \(checks) background grant, generation, cancellation, progress and fallback checks")
    }
}
