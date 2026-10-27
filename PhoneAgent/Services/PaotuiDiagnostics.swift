import Foundation

/// This is an allow-list, not a general logger. Provider text, credentials,
/// fingerprints, request bodies and user-entered details have no field here.
enum PaotuiDiagnosticCommand: String, Codable, CaseIterable {
    case hostText, hostCard, toolQuery, beginTurn, updatePreparation
    case readAddresses, readPlaces, requestQuote, readStatus
    case confirmOrder, submitOrder, recordReview, clearPreparation
    case restorePreparation, discardPreparation, archiveResolved, credentialChanged
}

enum PaotuiDiagnosticPhase: String, Codable, CaseIterable {
    case connection, collecting, clarifying, readyForReview, reading, quoted
    case awaitingConfirmation, submitting, outcome, readFailed, closed
    case recovery, maintenance, host
}

enum PaotuiDiagnosticResult: String, Codable, CaseIterable {
    case started, succeeded, failed, cancelled, stale, rejected
    case created, notDispatched, outcomeUnknown
}

/// Correlation identifiers are strongly typed. In particular, credentialEpoch
/// identifies a local authorization generation, never a provider account.
struct PaotuiDiagnosticContext: Codable, Equatable {
    var conversationID: UUID?
    var sessionID: UUID?
    var revision: UInt64?
    var quoteID: UUID?
    var attemptID: UUID?
    var credentialEpoch: UUID?
    var taskID: UUID?
    var invocationID: UUID?

    init(conversationID: UUID? = nil, sessionID: UUID? = nil, revision: UInt64? = nil,
         quoteID: UUID? = nil, attemptID: UUID? = nil, credentialEpoch: UUID? = nil,
         taskID: UUID? = nil, invocationID: UUID? = nil) {
        self.conversationID = conversationID; self.sessionID = sessionID; self.revision = revision
        self.quoteID = quoteID; self.attemptID = attemptID; self.credentialEpoch = credentialEpoch
        self.taskID = taskID; self.invocationID = invocationID
    }

    var isValid: Bool {
        (revision == nil || sessionID != nil) &&
        (invocationID == nil || taskID != nil) &&
        (conversationID == nil || taskID == nil)
    }

    /// A completion may add identifiers learned after dispatch, but cannot
    /// silently change the origin recorded at the beginning of the operation.
    fileprivate func merging(_ other: Self) -> Self? {
        var value = self
        func merged<T: Equatable>(_ first: T?, _ second: T?) -> T?? {
            if let first, let second, first != second { return nil }
            return .some(second ?? first)
        }
        guard let conversationID = merged(conversationID, other.conversationID),
              let sessionID = merged(sessionID, other.sessionID),
              let revision = merged(revision, other.revision),
              let quoteID = merged(quoteID, other.quoteID),
              let attemptID = merged(attemptID, other.attemptID),
              let credentialEpoch = merged(credentialEpoch, other.credentialEpoch),
              let taskID = merged(taskID, other.taskID),
              let invocationID = merged(invocationID, other.invocationID) else { return nil }
        value.conversationID = conversationID; value.sessionID = sessionID; value.revision = revision
        value.quoteID = quoteID; value.attemptID = attemptID; value.credentialEpoch = credentialEpoch
        value.taskID = taskID; value.invocationID = invocationID
        return value.isValid ? value : nil
    }
}

struct PaotuiDiagnosticEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let timestampMilliseconds: UInt64
    let command: PaotuiDiagnosticCommand
    let phase: PaotuiDiagnosticPhase
    let result: PaotuiDiagnosticResult
    let context: PaotuiDiagnosticContext
    let durationMilliseconds: UInt64?

    fileprivate init(id: UUID = UUID(), timestampMilliseconds: UInt64,
                     command: PaotuiDiagnosticCommand, phase: PaotuiDiagnosticPhase,
                     result: PaotuiDiagnosticResult, context: PaotuiDiagnosticContext,
                     durationMilliseconds: UInt64?) {
        self.id = id; self.timestampMilliseconds = timestampMilliseconds
        self.command = command; self.phase = phase; self.result = result
        self.context = context; self.durationMilliseconds = durationMilliseconds
    }

    fileprivate var isValid: Bool {
        context.isValid && (result != .started || durationMilliseconds == nil) &&
        (durationMilliseconds.map { $0 <= PaotuiDiagnostics.maximumDurationMilliseconds } ?? true)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        timestampMilliseconds = try values.decode(UInt64.self, forKey: .timestampMilliseconds)
        command = try values.decode(PaotuiDiagnosticCommand.self, forKey: .command)
        phase = try values.decode(PaotuiDiagnosticPhase.self, forKey: .phase)
        result = try values.decode(PaotuiDiagnosticResult.self, forKey: .result)
        context = try values.decode(PaotuiDiagnosticContext.self, forKey: .context)
        durationMilliseconds = try values.decodeIfPresent(UInt64.self, forKey: .durationMilliseconds)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid diagnostic event"))
        }
    }
}

struct PaotuiDiagnosticsSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let capacity: Int
    let droppedEventCount: UInt64
    let activeOperationCount: Int
    let generatedAtMilliseconds: UInt64
    let events: [PaotuiDiagnosticEvent]

    /// The same safe object is used by the native diagnostics UI and DEBUG
    /// device output; neither adapter needs access to business objects.
    var jsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    var jsonString: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate init(capacity: Int, droppedEventCount: UInt64, activeOperationCount: Int,
                     generatedAtMilliseconds: UInt64, events: [PaotuiDiagnosticEvent]) {
        schemaVersion = 1; self.capacity = capacity; self.droppedEventCount = droppedEventCount
        self.activeOperationCount = activeOperationCount; self.generatedAtMilliseconds = generatedAtMilliseconds
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        capacity = try values.decode(Int.self, forKey: .capacity)
        droppedEventCount = try values.decode(UInt64.self, forKey: .droppedEventCount)
        activeOperationCount = try values.decode(Int.self, forKey: .activeOperationCount)
        generatedAtMilliseconds = try values.decode(UInt64.self, forKey: .generatedAtMilliseconds)
        events = try values.decode([PaotuiDiagnosticEvent].self, forKey: .events)
        guard schemaVersion == 1, (1...PaotuiDiagnostics.maximumCapacity).contains(capacity),
              (0...capacity).contains(activeOperationCount), events.count <= capacity else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid diagnostic snapshot"))
        }
    }
}

struct PaotuiDiagnosticSpan {
    fileprivate let id: UUID
    fileprivate let command: PaotuiDiagnosticCommand
    fileprivate let phase: PaotuiDiagnosticPhase
    fileprivate let context: PaotuiDiagnosticContext
    fileprivate let startedAt: Date
}

@MainActor final class PaotuiDiagnostics {
    nonisolated static let maximumCapacity = 512
    nonisolated static let maximumDurationMilliseconds: UInt64 = 86_400_000
    private let clock: PaotuiClock
    let capacity: Int
    private var events: [PaotuiDiagnosticEvent] = []
    private var activeSpans = Set<UUID>()
    private var droppedEventCount: UInt64 = 0

    init(clock: PaotuiClock? = nil, capacity: Int = 128) {
        self.clock = clock ?? .system
        self.capacity = min(Self.maximumCapacity, max(1, capacity))
    }

    var snapshot: PaotuiDiagnosticsSnapshot {
        .init(capacity: capacity, droppedEventCount: droppedEventCount,
              activeOperationCount: activeSpans.count,
              generatedAtMilliseconds: Self.timestamp(clock.now()), events: events)
    }

    @discardableResult
    func record(command: PaotuiDiagnosticCommand, phase: PaotuiDiagnosticPhase,
                result: PaotuiDiagnosticResult, context: PaotuiDiagnosticContext = .init(),
                durationMilliseconds: UInt64? = nil) -> Bool {
        let event = PaotuiDiagnosticEvent(timestampMilliseconds: Self.timestamp(clock.now()),
            command: command, phase: phase, result: result, context: context, durationMilliseconds: durationMilliseconds)
        guard event.isValid else { return false }
        if events.count == capacity {
            events.removeFirst()
            if droppedEventCount < UInt64.max { droppedEventCount += 1 }
        }
        events.append(event)
        return true
    }

    func start(command: PaotuiDiagnosticCommand, phase: PaotuiDiagnosticPhase,
               context: PaotuiDiagnosticContext = .init()) -> PaotuiDiagnosticSpan? {
        guard activeSpans.count < capacity, context.isValid else { return nil }
        let span = PaotuiDiagnosticSpan(id: UUID(), command: command, phase: phase, context: context, startedAt: clock.now())
        guard record(command: command, phase: phase, result: .started, context: context) else { return nil }
        activeSpans.insert(span.id)
        return span
    }

    @discardableResult
    func finish(_ span: PaotuiDiagnosticSpan, result: PaotuiDiagnosticResult,
                context: PaotuiDiagnosticContext? = nil) -> Bool {
        guard activeSpans.contains(span.id), result != .started,
              let finalContext = span.context.merging(context ?? .init()) else { return false }
        activeSpans.remove(span.id)
        let elapsed = clock.now().timeIntervalSince(span.startedAt) * 1_000
        let duration = elapsed.isFinite && elapsed > 0 ?
            UInt64(min(elapsed, Double(Self.maximumDurationMilliseconds)).rounded(.down)) : 0
        return record(command: span.command, phase: span.phase, result: result,
                      context: finalContext, durationMilliseconds: duration)
    }

    private static func timestamp(_ date: Date) -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value > 0 else { return 0 }
        // The precision-safe JSON integer range also keeps conversion bounded.
        return UInt64(min(value, 9_007_199_254_740_991).rounded(.down))
    }
}
