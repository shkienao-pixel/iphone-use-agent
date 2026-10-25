import Foundation

@main struct NotesShortcutChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func fails(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let config = NotesShortcutConfiguration(createShortcut: "Sela测试-Notes-Create & + 中文", folderName: "Sela测试-文件夹")
        let now = Date(), taskID = UUID(), digest = String(repeating: "a", count: 64)
        let invocation = try NotesShortcutInvocation(taskID: taskID, digest: digest, title: "Sela测试-标题", body: "中文 😀 & + ? #\n第二行\n", configuration: config, now: now)
        let launch = URLComponents(url: invocation.launchURL, resolvingAgainstBaseURL: false)!
        let values = Dictionary(uniqueKeysWithValues: launch.queryItems!.map { ($0.name, $0.value!) })
        check(values["text"]!.utf8.elementsEqual(invocation.text.utf8), "Exact Unicode and newline URL roundtrip")
        check(values["name"] == config.createShortcut && launch.scheme == "shortcuts" && launch.path == "/run-shortcut", "Fixed public entry")
        check(values["x-success"] == invocation.callbackURL(.success).absoluteString && values["x-cancel"] != nil && values["x-error"] != nil, "All outcomes bound")
        func callback(_ invocation: NotesShortcutInvocation, _ status: NotesShortcutInvocation.Status = .success,
                      output: String? = nil, extra: [URLQueryItem] = []) -> URL {
            var url = URLComponents(url: invocation.callbackURL(status), resolvingAgainstBaseURL: false)!
            if status == .success { url.queryItems!.append(URLQueryItem(name: "result", value: output ?? invocation.text)) }
            url.queryItems! += extra; return url.url!
        }
        let success = callback(invocation)
        check(invocation.callback(from: success, now: now)?.output == invocation.text, "Bound output accepted")
        check(invocation.callback(from: success, now: now.addingTimeInterval(181)) == nil, "Expired result ignored")
        var wrong = URLComponents(url: success, resolvingAgainstBaseURL: false)!
        wrong.path = "/" + UUID().uuidString
        check(invocation.callback(from: wrong.url!, now: now) == nil, "Wrong nonce ignored")
        for key in ["task", "digest", "status"] {
            var parts = URLComponents(url: success, resolvingAgainstBaseURL: false)!
            parts.queryItems = parts.queryItems!.map { $0.name == key ? URLQueryItem(name: key, value: "wrong") : $0 }
            check(invocation.callback(from: parts.url!, now: now) == nil, "Wrong binding ignored: " + key)
        }
        check(invocation.callback(from: callback(invocation, extra: [URLQueryItem(name: "task", value: taskID.uuidString)]), now: now) == nil, "Duplicate query rejected")
        check(invocation.callback(from: callback(invocation, extra: [URLQueryItem(name: "untrusted", value: "execute")]), now: now) == nil, "Unknown query rejected")
        check(invocation.callback(from: callback(invocation, output: String(repeating: "x", count: 32001)), now: now) == nil, "Oversized result rejected")
        check(invocation.callback(from: callback(invocation, .cancel), now: now)?.status == .cancel, "Cancel parsed without data")
        check(invocation.callback(from: callback(invocation, .error, extra: [URLQueryItem(name: "errorMessage", value: "test")]), now: now)?.status == .error, "Error parsed")
        check(invocation.callback(from: callback(invocation, extra: [URLQueryItem(name: "errorMessage", value: "ambiguous")]), now: now) == nil, "Conflicting success rejected")
        var session = NotesShortcutSession(); try session.begin(invocation)
        check(fails { try session.begin(invocation) }, "Concurrent handoff blocked")
        check(session.take(wrong.url!, now: now) == nil && session.active?.id == invocation.id, "Invalid callback cannot consume attempt")
        check(session.take(success, now: now) != nil && session.active == nil, "Accepted result consumed once")
        check(session.take(success, now: now) == nil, "Replay ignored")
        check(fails { try session.begin(invocation) }, "Consumed invocation cannot be run again")
        let another = try NotesShortcutInvocation(taskID: taskID, digest: digest, title: "Sela测试-标题", body: "第二次", configuration: config)
        try session.begin(another)
        check(session.take(success, now: now) == nil && session.active?.id == another.id, "Old callback cannot finish new attempt")
        check(!session.cancel(id: UUID()) && session.active != nil, "Wrong cancellation cannot stop another attempt")
        check(session.cancel(id: another.id) && session.take(callback(another), now: now) == nil, "Late callback after stop ignored")
        check(fails { _ = try NotesShortcutInvocation(taskID: taskID, digest: digest, title: "a\nb", body: "test", configuration: config) }, "Multiline title rejected")
        check(fails { _ = try NotesShortcutInvocation(taskID: taskID, digest: "invalid", title: "a", body: "test", configuration: config) }, "Invalid digest rejected")

        let suite = "NotesShortcutChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date()
        let bridge = NotesShortcutBridge(defaults: defaults, now: { clock }), app = UIApplication.shared
        check(bridge.configuration == nil, "No implicit configuration")
        try bridge.configure(config)
        check(bridge.configuration == config, "Explicit configuration persisted")
        let defaultTarget = try bridge.preflight(taskID: taskID, digest: digest, title: "a", body: "test")
        check(defaultTarget.configuration.folderName == config.folderName, "Unnamed target uses configured host default")
        check(fails { _ = try bridge.preflight(taskID: taskID, digest: digest, title: "a", body: "test", folderName: "other") }, "No silent target fallback")
        func makeAttempt(body: String = "正文\n") throws -> NotesShortcutInvocation {
            try bridge.preflight(taskID: taskID, digest: digest, title: "Sela测试-标题", body: body, folderName: config.folderName)
        }
        let attempt = try makeAttempt()
        let run = Task { try await bridge.run(attempt) }
        while !bridge.running { await Task.yield() }
        check(app.urls.last == attempt.launchURL && app.leases.count == 1, "Actual bridge opens once with lease")
        check(fails { try bridge.configure(config) }, "Configuration frozen while running")
        bridge.handle(callback(attempt))
        let receipt = try await run.value
        check(receipt.contains("\"output_matches_requested_text\":true") && !bridge.running && app.leases.isEmpty, "Actual bridge completes and releases lease")
        let openedCount = app.urls.count
        bridge.handle(callback(attempt))
        check(app.urls.count == openedCount && !bridge.running, "Actual bridge never replays late callbacks")

        let stopAttempt = try makeAttempt()
        let stopped = Task { try await bridge.run(stopAttempt) }
        while !bridge.running { await Task.yield() }
        stopped.cancel()
        bridge.handle(callback(stopAttempt))
        do { _ = try await stopped.value; preconditionFailure("Cancellation must throw") } catch is CancellationError { checks += 1 }
        bridge.handle(callback(stopAttempt))
        check(!bridge.running && app.leases.isEmpty, "Stopped bridge stays settled after late callback")

        let mismatchAttempt = try makeAttempt()
        let mismatch = Task { try await bridge.run(mismatchAttempt) }
        while !bridge.running { await Task.yield() }
        bridge.handle(callback(mismatchAttempt, output: "not the submitted note"))
        do { _ = try await mismatch.value; preconditionFailure("Unknown output must not succeed") }
        catch NotesShortcutError.unverifiedOutput { checks += 1 }
        check(app.leases.isEmpty, "Mismatch releases lease")

        let normalizedAttempt = try makeAttempt(body: "e\u{301}")
        let normalized = Task { try await bridge.run(normalizedAttempt) }
        while !bridge.running { await Task.yield() }
        bridge.handle(callback(normalizedAttempt, output: "Sela测试-标题\né"))
        do { _ = try await normalized.value; preconditionFailure("Canonical equality must not replace byte equality") }
        catch NotesShortcutError.unverifiedOutput { checks += 1 }

        app.opened = false
        let unavailableAttempt = try makeAttempt()
        do { _ = try await bridge.run(unavailableAttempt); preconditionFailure("Failed open must throw") }
        catch NotesShortcutError.unavailable { checks += 1 }
        check(!bridge.running && app.leases.isEmpty, "Failed open settles without retry")
        app.opened = true
        let permissionAttempt = try makeAttempt()
        let permissionWait = Task { try await bridge.run(permissionAttempt) }
        while !bridge.running { await Task.yield() }
        app.leases.values.first!()
        while !app.leases.isEmpty { await Task.yield() }
        check(bridge.running, "Expired background processing is not a failed system permission wait")
        clock = clock.addingTimeInterval(85)
        bridge.handle(callback(permissionAttempt))
        _ = try await permissionWait.value
        check(!bridge.running && app.leases.isEmpty, "Same attempt resumes after long first privacy sheet")
        let expiredAttempt = try makeAttempt()
        let expired = Task { try await bridge.run(expiredAttempt) }
        while !bridge.running { await Task.yield() }
        clock = clock.addingTimeInterval(181); bridge.becameActive()
        do { _ = try await expired.value; preconditionFailure("Expired lease must throw") }
        catch NotesShortcutError.interrupted { checks += 1 }
        bridge.handle(callback(expiredAttempt))
        check(!bridge.running && app.leases.isEmpty, "Expired lease ignores late result")
        print("Notes shortcut: \(checks) protocol and actual-bridge lifecycle checks passed")
    }
}
