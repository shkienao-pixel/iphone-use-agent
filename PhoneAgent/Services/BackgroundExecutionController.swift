import Foundation
import Combine
import UIKit
import BackgroundTasks

/// A user-started workload retains process-local authority only. The scheduler
/// keeps this process alive; it never recreates work from an archived task.
@MainActor final class BackgroundExecutionController: ObservableObject {
    struct Work: Equatable {
        let id: UUID
        let sessionID: UUID
        var completedUnits: Int64 = 0
    }
    struct DiagnosticSnapshot: Codable, Equatable, Sendable {
        let isContinuationPending: Bool
        let isContinuationActive: Bool
        let finiteAssertionActive: Bool
        let workloadCount: Int
        var dictionary: [String: Any] {
            ["isContinuationPending": isContinuationPending, "isContinuationActive": isContinuationActive,
             "finiteAssertionActive": finiteAssertionActive, "workloadCount": workloadCount]
        }
    }
    var diagnosticSnapshot: DiagnosticSnapshot {
        .init(isContinuationPending: generation != nil && requestIdentifier != nil && continued == nil,
              isContinuationActive: continued != nil, finiteAssertionActive: assertion != .invalid, workloadCount: work.count)
    }
    @Published private(set) var error = ""
    var onExpiration: (([Work]) -> Void)?
    /// Create the custom character activity before the scheduler's system UI.
    /// The finite assertion is already held while this presentation settles.
    var beforeContinuationSubmission: (() async -> Void)?
    private var work: [Work] = []
    private var blockedSessions = Set<UUID>()
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var generation: UUID?
    private var requestIdentifier: String?
    private var continued: BGContinuedProcessingTask?
    private var completedUnits: Int64 = 0
    private var lastUnits: [UUID: Int64] = [:]
    private let presentationWaitNanoseconds: UInt64
    private var presentationDeadline: Task<Void, Never>?
    private var submittedGeneration: UUID?
    // Keep submit/cancel ordered even if the host ends work before an
    // asynchronous submission has reached the scheduler.
    private let submissionQueue = DispatchQueue(label: "dev.sela.background-submission")
    private var expirationDepth = 0
    private struct Lease {
        let requestIdentifier: String?
        let continued: BGContinuedProcessingTask?
        let assertion: UIBackgroundTaskIdentifier
    }
    // The configured Foundation request is handed to exactly one serial queue
    // and is never mutated after this ownership transfer.
    private struct SubmissionRequest: @unchecked Sendable { let value: BGContinuedProcessingTaskRequest }

    init(presentationWaitNanoseconds: UInt64 = 500_000_000) {
        self.presentationWaitNanoseconds = presentationWaitNanoseconds
    }

    func synchronize(_ next: [Work]) {
        let liveSessions = Set(next.map(\.sessionID))
        blockedSessions.formIntersection(liveSessions)
        work = next.filter { !blockedSessions.contains($0.sessionID) }
        guard !work.isEmpty else { finish(success: true); return }
        let settledSessions = Set(lastUnits.keys).subtracting(work.map(\.sessionID))
        completedUnits += Int64(settledSessions.count)
        for session in settledSessions { lastUnits.removeValue(forKey: session) }
        for item in work {
            let previous = lastUnits[item.sessionID] ?? 0
            completedUnits += max(0, item.completedUnits - previous)
            lastUnits[item.sessionID] = item.completedUnits
        }
        if generation == nil, expirationDepth == 0, UIApplication.shared.applicationState == .active { begin() }
        updateProgress()
    }

    func becameActive() {
        // A foreground return may renew a denied finite assertion, but never
        // silently restart a workload the OS or the user explicitly cancelled.
        // `work` excludes blocked sessions. Feeding it back as a fresh host
        // snapshot would accidentally forget tombstones for still-settling
        // cancelled sessions.
        if generation == nil, expirationDepth == 0, !work.isEmpty,
           UIApplication.shared.applicationState == .active { begin() }
        if generation != nil, assertion == .invalid, continued == nil { beginAssertion() }
    }

    private func begin() {
        let token = UUID(); generation = token
        completedUnits = 0; lastUnits = Dictionary(uniqueKeysWithValues: work.map { ($0.sessionID, $0.completedUnits) })
        beginAssertion()
        let identifier = (Bundle.main.bundleIdentifier ?? "dev.agentmouse") + ".continued." + token.uuidString
        requestIdentifier = identifier
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, !self.work.isEmpty,
                      let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false); return
                }
                self.continued = continued
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.expire(expected: token) }
                }
                self.error = ""; self.updateProgress(); self.endAssertion()
            }
        }) else {
            requestIdentifier = nil
            error = "系统暂未允许持续后台运行；当前任务会使用系统提供的有限后台时间"
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Sela 正在处理任务", subtitle: "切换应用后继续处理")
        // Work already started in response to the user. Never queue a second
        // execution or wait to replay the action after this process is gone.
        request.strategy = .fail
        if let beforeContinuationSubmission {
            Task { @MainActor [weak self] in
                await beforeContinuationSubmission()
                self?.submit(request, token: token)
            }
            // Presentation is best effort. A stalled ActivityKit queue must not
            // withhold the system's continuous background execution grant.
            presentationDeadline = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: self.presentationWaitNanoseconds) } catch { return }
                self.submit(request, token: token)
            }
        } else { submit(request, token: token) }
    }

    private func submit(_ request: BGContinuedProcessingTaskRequest, token: UUID) {
        guard generation == token, !work.isEmpty, submittedGeneration != token else { return }
        submittedGeneration = token
        presentationDeadline?.cancel(); presentationDeadline = nil
        if #available(iOS 27.0, *) {
            let submission = SubmissionRequest(value: request)
            submissionQueue.async { [weak self] in
                BGTaskScheduler.shared.submitTaskRequest(submission.value) { [weak self] failure in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if failure != nil { self.submissionFailed() }
                    }
                }
            }
        } else {
            do { try BGTaskScheduler.shared.submit(request) }
            catch { submissionFailed() }
        }
    }

    private func submissionFailed() {
        requestIdentifier = nil
        error = "系统暂未允许持续后台运行；当前任务会使用系统提供的有限后台时间"
    }

    private func beginAssertion() {
        guard assertion == .invalid, let token = generation else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Sela active tasks") { [weak self] in
            guard let self, self.generation == token else { return }
            if self.continued == nil, UIApplication.shared.applicationState != .active { self.expire(expected: token) }
            else { self.endAssertion() }
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        let previous = assertion; assertion = .invalid
        UIApplication.shared.endBackgroundTask(previous)
    }

    private func updateProgress() {
        guard let continued else { return }
        // Report real completed engine steps; a pending network request remains
        // incomplete. No elapsed-time percentage or synthetic progress heartbeat.
        continued.progress.totalUnitCount = max(1, completedUnits + Int64(work.count))
        continued.progress.completedUnitCount = completedUnits
        continued.updateTitle("Sela 正在处理任务", subtitle: work.count == 1 ? "正在查询或执行，请稍候" : "正在处理 \(work.count) 项任务")
    }

    private func expire(expected token: UUID) {
        guard generation == token else { return }
        let expired = work
        blockedSessions.formUnion(work.map(\.sessionID))
        // Revoke process authority immediately, but retain the old OS lease
        // until synchronous cancellation and checkpoint callbacks have run.
        // Those callbacks can reenter synchronize; they must not complete a new
        // generation or start another grant inside the expiring cohort.
        let oldLease = detachLease()
        expirationDepth += 1
        error = "系统已结束本次后台运行，进度已保留；回到 Sela 后可继续"
        onExpiration?(expired)
        expirationDepth -= 1
        complete(oldLease, success: false)
        work.removeAll { blockedSessions.contains($0.sessionID) }
        if expirationDepth == 0, generation == nil, !work.isEmpty,
           UIApplication.shared.applicationState == .active { begin(); updateProgress() }
    }

    private func finish(success: Bool) {
        complete(detachLease(), success: success)
    }
    private func detachLease() -> Lease {
        // Clear identity before invoking platform completion or host callbacks;
        // late delivery from a previous run cannot affect a newer request.
        generation = nil; submittedGeneration = nil
        presentationDeadline?.cancel(); presentationDeadline = nil
        let lease = Lease(requestIdentifier: requestIdentifier, continued: continued, assertion: assertion)
        requestIdentifier = nil; continued = nil; assertion = .invalid
        lastUnits = [:]; completedUnits = 0
        return lease
    }
    private func complete(_ lease: Lease, success: Bool) {
        if let identifier = lease.requestIdentifier {
            submissionQueue.async { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
        if let continued = lease.continued {
            continued.expirationHandler = nil
            if success { continued.progress.completedUnitCount = continued.progress.totalUnitCount }
            continued.setTaskCompleted(success: success)
        }
        if lease.assertion != .invalid { UIApplication.shared.endBackgroundTask(lease.assertion) }
    }
}
