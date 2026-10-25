import Foundation

@MainActor enum RecoveryReceiptChecks {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        func rejects(_ work: () throws -> Void, _ label: String) { do { try work(); preconditionFailure(label) } catch { checks += 1 } }
        let first = UUID(), second = UUID()
        let request = SystemToolRequest(operation: .reminder_create, title: "Original confirmed request", notes: "Source note")
        let policy = RecoveryReceiptPolicy()
        expect(!policy.hasUnresolvedWrite(taskID: first), "An empty receipt ledger has no invented unknown writes")
        try policy.seed(request, taskID: first, state: "pending")
        expect(policy.hasUnresolvedWrite(taskID: first) && !policy.hasUnresolvedWrite(taskID: second), "Pending status is bound to the exact task UUID prefix")
        rejects({ _ = try policy.check(request, taskID: first) }, "An identical unknown write cannot be submitted again")
        var renamed = request; renamed.title = "A different title"
        expect(try! policy.key(for: request, taskID: first) != policy.key(for: renamed, taskID: first), "The title variant genuinely changes the production canonical digest")
        rejects({ _ = try policy.check(renamed, taskID: first) }, "Changing the title cannot bypass a task's pending write")
        var changedNote = request; changedNote.notes = "Different note"
        rejects({ _ = try policy.check(changedNote, taskID: first) }, "Changing notes cannot bypass a task's pending write")
        var changedList = request; changedList.list_name = "Another list"
        rejects({ _ = try policy.check(changedList, taskID: first) }, "Changing the target list cannot bypass a task's pending write")
        let calendar = SystemToolRequest(operation: .calendar_create, title: "Another operation", start: "2026-11-01T10:00:00+08:00", end: "2026-11-01T11:00:00+08:00")
        rejects({ _ = try policy.check(calendar, taskID: first) }, "Switching write operation cannot bypass an unknown task result")
        let search = SystemToolRequest(operation: .reminder_search, query: "Read current state")
        expect(try! policy.check(search, taskID: first) == nil, "Read-only queries remain available for checking actual state")
        expect(try! policy.check(renamed, taskID: second) == nil, "An unrelated task's new write is not mistaken for the pending task")
        let count = policy.receiptCount
        try policy.seed(renamed, taskID: first, state: "completed", result: "Known committed receipt")
        expect(try! policy.check(renamed, taskID: first) == "重复请求已跳过；之前的回执：Known committed receipt", "A completed identical receipt returns before the broader pending-write guard")
        expect(policy.receiptCount == count + 1 && policy.hasUnresolvedWrite(taskID: first), "Returning a known receipt does not clear another unknown write")
        var content = SystemToolRequest(operation: .content_create, title: "Local body", content: "Exact text")
        rejects({ _ = try policy.check(content, taskID: first) }, "Another content-writing digest cannot evade the pending task scope")
        content.content = "Changed body"
        rejects({ _ = try policy.check(content, taskID: first) }, "Changing body bytes also remains blocked")
        try policy.seed(request, taskID: first, state: "pending", result: "Not a completed state")
        rejects({ _ = try policy.check(request, taskID: first) }, "A pending entry with stray result text is not treated as a completed receipt")
        try policy.seed(request, taskID: first, state: "completed", result: "Resolved committed receipt")
        expect(!policy.hasUnresolvedWrite(taskID: first) && (try! policy.check(changedNote, taskID: first)) == nil, "Only resolving unknown receipt state permits a new write digest")
        let prefix = RecoveryReceiptPolicy()
        prefix.seedRaw(first.uuidString + "0:lookalike")
        expect(!prefix.hasUnresolvedWrite(taskID: first), "Similar string prefixes cannot collide with the UUID-plus-colon task boundary")
        prefix.readable = false
        expect(prefix.hasUnresolvedWrite(taskID: first) && prefix.hasUnresolvedWrite(taskID: second), "Unreadable ledgers remain unknown for every selected task")
        rejects({ _ = try prefix.check(request, taskID: first) }, "Unreadable receipt storage blocks writes")
        expect(try! prefix.check(search, taskID: first) == nil, "Unreadable receipt storage does not block read-only inspection")
        return checks
    }
}
