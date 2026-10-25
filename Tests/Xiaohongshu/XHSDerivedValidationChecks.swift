import Foundation

/// Native OUTPUT controls for the self-derived predicate-reuse boundary.
/// Full oracles call the production normal false validator, not a copied schema.
@MainActor enum XHSDerivedValidationChecks {
    private struct Document: Codable { var version = 1; var runs: [XiaohongshuCollectionRun] }
    @MainActor private final class Checks {
        var count = 0, passed: [String] = [], failures: [String] = []
        func expect(_ value: Bool, _ label: String) throws {
            count += 1
            guard value else { failures.append(label); throw AgentError.message(label) }
            passed.append(label)
        }
        func write(_ url: URL, complete: Bool) throws {
            try JSONSerialization.data(withJSONObject: ["complete": complete, "checks": count, "passed": passed,
                "failures": failures, "normalFullNativeOracle": true, "privateNilTestHook": false,
                "phoneModelNetwork": false, "benchmark": false], options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func caught(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return String(reflecting: error) }
    }
    private static func segment(_ run: XiaohongshuCollectionRun, _ index: Int) throws -> XiaohongshuAnalysisSegment {
        let input = XiaohongshuAnalysisService.inputs(run.notes[index % run.notes.count])[0]
        let quote = String(input.excerpt.prefix(500))
        let id = UUID(uuidString: "13000000-0000-4000-8000-" + String(format: "%012llx", Int64(index + 1)))!
        return .init(id: id, createdAt: run.startedAt.addingTimeInterval(Double(index + 1)), inputs: [input],
            items: [.init(noteID: input.noteID, quote: quote, topic: String(quote.prefix(40)))])
    }
    @MainActor private final class Pair {
        let full: XiaohongshuCollectionStore, append: XiaohongshuCollectionStore
        let left: URL, right: URL, checks: Checks
        init(_ run: XiaohongshuCollectionRun, name: String, work: URL, checks: Checks) throws {
            self.checks = checks
            let folder = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            left = folder.appendingPathComponent("full.json"); right = folder.appendingPathComponent("append.json")
            let data = try encode(Document(runs: [run]))
            try data.write(to: left, options: .atomic); try data.write(to: right, options: .atomic)
            full = .init(url: left); append = .init(url: right)
            try checks.expect(full.runs.count == 1 && append.runs.count == 1, "Normal full init accepts " + name)
        }
        func oracle(_ id: String, _ label: String) throws {
            guard let a = try full.run(id: id), let b = try append.run(id: id) else { throw AgentError.message("Oracle current run missing") }
            try a.validate(); try b.validate()
            try checks.expect(try encode(a) == encode(b), "Complete returned/canonical native value: " + label)
            try checks.expect(try Data(contentsOf: left) == Data(contentsOf: right), "Complete fixed-metadata checkpoint Data: " + label)
            let reopened = XiaohongshuCollectionStore(url: right)
            try checks.expect(try encode(Document(runs: reopened.runs)) == Data(contentsOf: right), "Every step normal full native disk reopen: " + label)
            try checks.expect(try full.export(id: id) == append.export(id: id), "Every step complete full statistics/export: " + label)
        }
        func add(_ new: XiaohongshuAnalysisSegment, id: String, at: Date) throws {
            guard var value = try full.run(id: id) else { throw AgentError.message("Oracle base missing") }
            value.analysisSegments.append(new); value.updatedAt = at
            try value.validate(); try full.save(value)
            let returned = try append.appendAnalysis(new, taskID: id, updatedAt: at)
            try checks.expect(try encode(returned) == encode(value), "Actual append returns current complete native value")
            try oracle(id, "append")
        }
        func reject(_ new: XiaohongshuAnalysisSegment, id: String, at: Date) throws {
            let before = try Data(contentsOf: right), memory = try encode(Document(runs: append.runs))
            guard var value = try full.run(id: id) else { throw AgentError.message("Reject oracle base missing") }
            value.analysisSegments.append(new); value.updatedAt = at
            let a = caught { try full.save(value) }
            let b = caught { _ = try append.appendAnalysis(new, taskID: id, updatedAt: at) }
            try checks.expect(a != nil && a == b, "New segment/header error equals full native error")
            try checks.expect(try Data(contentsOf: right) == before && encode(Document(runs: append.runs)) == memory, "Rejected derived transaction has zero adoption")
            try oracle(id, "after rejected derived transaction")
        }
    }
    static func run(folder: URL, fixture: URL, report: URL) async throws -> Int {
        let checks = Checks(), work = folder.appendingPathComponent("derived-validation-controls")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fixture))
            guard doc.runs.count == 1 else { throw AgentError.message("Expected complete single-task fixture") }
            let seed = doc.runs[0]
            try checks.expect(seed.notes.count == 10 && seed.analysisSegments.isEmpty && seed.pages.count >= 2 && seed.checkpoint != nil,
                "Actual full cold10 fixture has multiple pages and checkpoint; empty analysis remains legal normal full state")
            try seed.validate()
            var base = seed
            base.analysisSegments = [try segment(seed, 0), try segment(seed, 1)]
            base.updatedAt = seed.updatedAt.addingTimeInterval(10)
            try base.validate()
            let pair = try Pair(base, name: "retained", work: work, checks: checks)
            try pair.oracle(seed.id, "two retained segments")

            // These are EXTERNAL complete Run inputs: neither normal init nor
            // generic save may inherit caller claims or validate only the last.
            var cases: [(String, XiaohongshuCollectionRun)] = []
            var bad = base; bad.analysisSegments[0].kind = "full_note_summary"; cases.append(("first-old-kind", bad))
            bad = base; bad.analysisSegments[0].inputs[0].visibleTextSHA256 = String(repeating: "0", count: 64); cases.append(("first-old-hash", bad))
            bad = base; bad.analysisSegments[0].items[0].topic = "fabricated unsupported phrase"; cases.append(("first-old-quote", bad))
            bad = base; bad.analysisSegments[0].excluded = []; cases.append(("first-old-excluded", bad))
            bad = base; bad.pages[bad.pages.count - 1].number += 100; cases.append(("late-page-order", bad))
            bad = base; bad.pages[bad.pages.count - 1].elements[0].rect.width = -1; cases.append(("late-page-shape", bad))
            bad = base; bad.pages[bad.pages.count - 1].scopeVersion = 99; cases.append(("late-page-unknown-proof-version", bad))
            bad = base; bad.checkpoint?.shareID = ""; cases.append(("checkpoint-share", bad))
            bad = base; bad.checkpoint?.elapsedSeconds = -1; cases.append(("checkpoint-negative-elapsed", bad))
            bad = base; bad.checkpoint?.visitedCandidateKeys = Array(repeating: "candidate", count: 4001); cases.append(("checkpoint-visited-budget", bad))
            bad = base; bad.version = 99; cases.append(("unknown-run-version", bad))
            for (name, value) in cases {
                let nativeError = caught { try value.validate() }
                try checks.expect(nativeError != nil && caught { _ = try ValidatedXiaohongshuCollectionRun(validating: value) } == nativeError,
                    "Ordinary wrapper validates all old predicates: " + name)
                let disk = try Data(contentsOf: pair.right), memory = try encode(Document(runs: pair.append.runs))
                try checks.expect(caught { try pair.append.save(value) } == nativeError, "Generic save never trusts externally supplied old predicate: " + name)
                try checks.expect(try Data(contentsOf: pair.right) == disk && encode(Document(runs: pair.append.runs)) == memory, "Invalid old predicate preserves actual Store: " + name)
                let path = work.appendingPathComponent("invalid-" + name + ".json")
                let data = try encode(Document(runs: [value])); try data.write(to: path, options: .atomic)
                let rejected = XiaohongshuCollectionStore(url: path)
                try checks.expect(rejected.runs.isEmpty && rejected.error != nil && caught { _ = try rejected.run(id: seed.id) } != nil,
                    "Disk init runs full native validation and refuses invalid old state: " + name)
                try checks.expect(try Data(contentsOf: path) == data, "Rejected disk archive stays untouched: " + name)
                try pair.oracle(seed.id, "after invalid external old predicate " + name)
            }

            // Generic rebase must replace the private full-validated base, not
            // preserve a stale witness for the old raw keyword/history fields.
            var rebased = try pair.append.run(id: seed.id)!
            let originalKeywords = rebased.notes[0].matchedKeywords
            try checks.expect(!originalKeywords.isEmpty, "Actual fixture raw keyword coverage is initially nonempty")
            rebased.notes[0].matchedKeywords = [] // Conservative raw coverage change; OCR/source/text remain exact.
            try checks.expect(rebased.notes[0].matchedKeywords != originalKeywords, "Rebase changes actual raw keyword coverage, not an already-unknown count")
            rebased.pages[rebased.pages.count - 1].viewport += "-legal-rebase"
            rebased.checkpoint?.visitedCandidateKeys.append("legal-rebased-candidate")
            rebased.events.append(.init(at: base.updatedAt, kind: "synthetic_rebase", detail: "legally updated local progress"))
            rebased.updatedAt = base.updatedAt.addingTimeInterval(1)
            try rebased.validate(); try pair.full.save(rebased); try pair.append.save(rebased)
            try pair.oracle(seed.id, "complete generic rebase")
            try pair.add(segment(seed, 2), id: seed.id, at: rebased.updatedAt.addingTimeInterval(1))
            let afterRebase = try pair.append.run(id: seed.id)!
            try checks.expect(afterRebase.notes[0].matchedKeywords.isEmpty && afterRebase.notes[0].matchedKeywords != originalKeywords && afterRebase.pages.last?.viewport == rebased.pages.last?.viewport && afterRebase.checkpoint == rebased.checkpoint && afterRebase.events == rebased.events,
                "Derived append inherits the actual latest full-validated raw/progress after generic save")

            var escaped = afterRebase
            escaped.analysisSegments[0].kind = "poisoned copy"
            escaped.pages[0].number = -1; escaped.checkpoint?.width = 0
            try checks.expect(caught { try escaped.validate() } != nil, "External projected copy is independently invalid")
            try pair.add(segment(seed, 3), id: seed.id, at: rebased.updatedAt.addingTimeInterval(2))
            try checks.expect(try pair.append.run(id: seed.id)!.pages == afterRebase.pages, "External raw copy mutation never reaches private wrapper")

            var new = try segment(seed, 4); new.inputs[0].partCount += 1
            try pair.reject(new, id: seed.id, at: rebased.updatedAt.addingTimeInterval(3))
            new = try segment(seed, 5); new.items[0].topic = "invented new topic"
            try pair.reject(new, id: seed.id, at: rebased.updatedAt.addingTimeInterval(3))
            // Invalid segment wins before the pre-existing nonfinite-Date
            // encoder failure. No extra finite-date header rule is introduced.
            new = try segment(seed, 6); new.kind = "full_note_summary"
            try pair.reject(new, id: seed.id, at: Date(timeIntervalSince1970: .infinity))
            try pair.reject(try segment(seed, 0), id: seed.id, at: rebased.updatedAt.addingTimeInterval(3))
            try pair.reject(try segment(seed, 7), id: seed.id, at: seed.startedAt.addingTimeInterval(-1))

            var conflicting = afterRebase
            conflicting.task.fields = conflicting.task.fields.count > 1 ? Array(conflicting.task.fields.dropLast()) : [.title, .body]
            try conflicting.validate()
            try checks.expect(caught { try pair.append.save(conflicting) } == String(reflecting: XiaohongshuCollectionError.conflictingTask),
                "Normal full valid rebase task conflict retains original type")
            conflicting.analysisSegments[0].scope = "all_content"
            try checks.expect(caught { try pair.append.save(conflicting) } == String(reflecting: XiaohongshuCollectionError.invalidDocument),
                "Invalid retained segment is rejected before changed-task conflict")
            try pair.oracle(seed.id, "after all error-order controls")
            try checks.write(report, complete: true)
            return checks.count
        } catch {
            checks.failures.append(String(reflecting: error)); try? checks.write(report, complete: false)
            do {
                let retained = report.deletingLastPathComponent().appendingPathComponent("derived-failure-fixtures-" + UUID().uuidString)
                try FileManager.default.copyItem(at: work, to: retained)
            } catch let copying {
                try? Data(String(reflecting: copying).utf8).write(to: report.deletingLastPathComponent().appendingPathComponent("derived-fixture-copy-error.txt"), options: .atomic)
            }
            throw error
        }
    }
}
