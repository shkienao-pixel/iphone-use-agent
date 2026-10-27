import Foundation
public class BGTask {
    public var expirationHandler: (() -> Void)?
    public var completions: [Bool] = []
    public var onCompletion: ((Bool) -> Void)?
    public init() {}
    public func setTaskCompleted(success: Bool) { completions.append(success); onCompletion?(success) }
}
public final class BGContinuedProcessingTask: BGTask {
    public let progress = Progress(totalUnitCount: 0)
    public var titles: [(String, String)] = []
    public func updateTitle(_ title: String, subtitle: String) { titles.append((title, subtitle)) }
}
public final class BGContinuedProcessingTaskRequest {
    public enum SubmissionStrategy { case queue, fail }
    public var strategy = SubmissionStrategy.queue
    public let identifier: String
    public let title: String
    public let subtitle: String
    public init(identifier: String, title: String, subtitle: String) { self.identifier = identifier; self.title = title; self.subtitle = subtitle }
}
// Match the scheduler's real nonisolated submission boundary. Its callbacks may
// arrive from arbitrary threads after the owning generation has already ended.
public final class BGTaskScheduler: @unchecked Sendable {
    public static let shared = BGTaskScheduler()
    private let lock = NSLock()
    private var storedHandlers: [String: (BGTask) -> Void] = [:]
    private var storedSubmitted: [BGContinuedProcessingTaskRequest] = []
    private var storedCancelled: [String] = []
    private var storedMainThreadSubmissions: [Bool] = []
    private var storedRegistrationAllowed = true
    private var storedSubmissionError: NSError?
    private var storedDeferCompletion = false
    private var deferredCompletions: [(Error?) -> Void] = []
    public var handlers: [String: (BGTask) -> Void] { lock.withLock { storedHandlers } }
    public var submitted: [BGContinuedProcessingTaskRequest] { lock.withLock { storedSubmitted } }
    public var cancelled: [String] { lock.withLock { storedCancelled } }
    public var mainThreadSubmissions: [Bool] { lock.withLock { storedMainThreadSubmissions } }
    public var registrationAllowed: Bool {
        get { lock.withLock { storedRegistrationAllowed } }
        set { lock.withLock { storedRegistrationAllowed = newValue } }
    }
    public var submissionError: NSError? {
        get { lock.withLock { storedSubmissionError } }
        set { lock.withLock { storedSubmissionError = newValue } }
    }
    public var deferCompletion: Bool {
        get { lock.withLock { storedDeferCompletion } }
        set { lock.withLock { storedDeferCompletion = newValue } }
    }
    public func register(forTaskWithIdentifier id: String, using: DispatchQueue?, launchHandler: @escaping (BGTask) -> Void) -> Bool {
        lock.withLock {
            precondition(storedHandlers[id] == nil, "Never register a continued identifier twice")
            guard storedRegistrationAllowed else { return false }
            storedHandlers[id] = launchHandler; return true
        }
    }
    public func submitTaskRequest(_ request: BGContinuedProcessingTaskRequest, completionHandler: @escaping (Error?) -> Void) {
        let response: (Bool, NSError?) = lock.withLock {
            storedSubmitted.append(request); storedMainThreadSubmissions.append(Thread.isMainThread)
            if storedDeferCompletion { deferredCompletions.append(completionHandler) }
            return (storedDeferCompletion, storedSubmissionError)
        }
        if !response.0 { completionHandler(response.1) }
    }
    public func submit(_ request: BGContinuedProcessingTaskRequest) throws {
        let failure = lock.withLock {
            storedSubmitted.append(request); storedMainThreadSubmissions.append(Thread.isMainThread)
            return storedSubmissionError
        }
        if let failure { throw failure }
    }
    public func completeDeferredSubmissions(error: NSError? = nil) {
        let callbacks = lock.withLock { let value = deferredCompletions; deferredCompletions = []; return value }
        for callback in callbacks { callback(error) }
    }
    public func completeNextDeferredSubmission(error: NSError? = nil) {
        let callback = lock.withLock { deferredCompletions.isEmpty ? nil : deferredCompletions.removeFirst() }
        callback?(error)
    }
    public func cancel(taskRequestWithIdentifier id: String) { lock.withLock { storedCancelled.append(id) } }
    public func reset() {
        lock.withLock {
            storedHandlers = [:]; storedSubmitted = []; storedCancelled = []; storedMainThreadSubmissions = []
            storedRegistrationAllowed = true; storedSubmissionError = nil; storedDeferCompletion = false; deferredCompletions = []
        }
    }
}
