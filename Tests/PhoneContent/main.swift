import Foundation

@MainActor
final class ClipboardFixture {
    var foreground = true
    var text: String?
    var writes = 0
    var reads = 0
    var counter = 0
    var corruptWrites = false
    var cancelOnWrite: (() -> Void)?
    var access: PhoneClipboardAccess {
        PhoneClipboardAccess(isForeground: { self.foreground }, write: { text, _ in
            self.writes += 1; self.counter += 1
            self.text = self.corruptWrites ? "unrelated" : text
            self.cancelOnWrite?()
        }, read: { self.reads += 1; return self.text }, changeCount: { self.counter })
    }
}

@main struct PhoneContentChecks {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1; guard condition() else { fatalError(message) }
        }
        func rejects(_ block: () throws -> Void, _ message: String) {
            var rejected = false; do { try block() } catch { rejected = true }; expect(rejected, message)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-content-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("content.json")
        let clipboard = ClipboardFixture()
        let store = PhoneContentStore(url: path, clipboard: clipboard.access)
        let text = "# 测试标题\r\n\r\n中文段落🙂 e\u{301}\n链接：https://example.com/a?x=1&y=2\r末尾\n"
        let artifact = try store.create(title: "中文正文", body: text)
        expect(artifact.lineBreakCount == 5, "CRLF must be one logical line break")
        expect(artifact.lineFeedCount == 4 && artifact.carriageReturnCount == 3, "Raw CR/LF counts preserve exact line endings")
        expect(Data(artifact.body.utf8) == Data(text.utf8), "Creation preserves exact original bytes")
        expect(artifact.sha256 == PhoneContentArtifact.digest(text), "Digest is computed over original UTF-8")
        expect(PhoneContentArtifact.validReference(artifact.reference), "Generated reference is unambiguous")
        expect(!PhoneContentArtifact.validReference(artifact.reference.uppercased()), "Mixed-case reference is not an alias")
        expect(!PhoneContentArtifact.validReference("../../content.json"), "References cannot be paths")
        rejects({ _ = try store.artifact(reference: artifact.reference + "x") }, "A changed digest cannot select content")
        rejects({ _ = try store.create(title: "", body: text) }, "Empty title is rejected")
        rejects({ _ = try store.create(title: "ok", body: "") }, "Empty body is rejected")
        rejects({ _ = try store.create(title: "ok", body: String(repeating: "中", count: 40_001)) }, "Oversize body is rejected without truncating")
        let composed = try PhoneContentArtifact(title: "NFC", body: "é")
        let decomposed = try PhoneContentArtifact(title: "NFD", body: "e\u{301}")
        expect(composed.body == decomposed.body && composed.sha256 != decomposed.sha256, "Canonically equivalent Unicode still has different exact-byte digests")
        var changed = artifact; changed.body += "x"
        rejects({ try changed.validate() }, "Corrupted content cannot retain old metadata")
        var badCount = artifact; badCount.lineBreakCount = 0
        rejects({ try badCount.validate() }, "Stored counts are independently revalidated")
        clipboard.foreground = false
        rejects({ _ = try store.prepareClipboard(reference: artifact.reference) }, "Background clipboard preparation is rejected")
        expect(clipboard.writes == 0 && clipboard.reads == 0, "Background attempts neither write nor read clipboard")
        expect(store.preparations.isEmpty, "Rejected background work has no successful receipt")
        clipboard.foreground = true
        let now = Date()
        var pendingWasDurable = false
        clipboard.cancelOnWrite = {
            if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
               let rows = object["preparations"] as? [[String: Any]], let row = rows.last {
                pendingWasDurable = row["state"] as? String == "preparing"
            }
        }
        let receipt = try store.prepareClipboard(reference: artifact.reference, now: now)
        clipboard.cancelOnWrite = nil
        expect(pendingWasDurable, "A pending checkpoint is durable before the clipboard side effect")
        expect(receipt.state == .prepared && receipt.changeCount == 1, "Preparation records actual clipboard write/read-back")
        expect(clipboard.writes == 1 && clipboard.reads == 1, "Preparation performs one exact full local read-back")
        expect(Data(clipboard.text!.utf8) == Data(text.utf8), "Chinese, emoji, Markdown, links and line endings survive the clipboard boundary")
        expect((try? store.clipboardLease(reference: artifact.reference, now: now.addingTimeInterval(1)))?.id == receipt.id, "Current session has the verified lease")
        rejects({ _ = try store.clipboardLease(reference: artifact.reference, now: now.addingTimeInterval(121)) }, "Expired lease cannot be reused")
        let readCount = clipboard.reads; clipboard.foreground = false
        _ = try store.clipboardLease(reference: artifact.reference, now: now.addingTimeInterval(1))
        expect(clipboard.reads == readCount, "Reading a preparation receipt never accesses background clipboard")
        let restored = PhoneContentStore(url: path, clipboard: clipboard.access)
        expect(restored.artifacts.count == 1 && restored.preparations.count == 1, "Phone content and preparation checkpoints survive process recreation")
        expect(Data(restored.artifacts[0].body.utf8) == Data(text.utf8), "Reload preserves exact saved content")
        rejects({ _ = try restored.clipboardLease(reference: artifact.reference) }, "Process restoration never restores paste authority")
        expect(restored.preparations[0].state == .prepared, "Historical local preparation is retained without claiming a target paste")
        let interruptedPath = folder.appendingPathComponent("interrupted.json")
        var interruptedDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var interruptedRows = interruptedDocument["preparations"] as! [[String: Any]]
        interruptedRows[0]["state"] = "preparing"; interruptedRows[0].removeValue(forKey: "changeCount")
        interruptedDocument["preparations"] = interruptedRows
        try JSONSerialization.data(withJSONObject: interruptedDocument).write(to: interruptedPath)
        let interruptedStore = PhoneContentStore(url: interruptedPath, clipboard: clipboard.access)
        expect(interruptedStore.preparations[0].state == .unknown, "A process crash during preparation is recovered as unknown")
        expect(clipboard.writes == 1, "Restoring unknown preparation never replays clipboard input")
        clipboard.foreground = true; clipboard.corruptWrites = true
        rejects({ _ = try store.prepareClipboard(reference: artifact.reference) }, "Actual read-back mismatch fails preparation")
        expect(store.preparations.last?.state == .unknown, "Interrupted or mismatched clipboard writes remain unknown")
        rejects({ _ = try store.clipboardLease(reference: artifact.reference) }, "A failed new preparation invalidates an older lease")
        let partial = PhoneContentComparison.compare("中文段落🙂", with: artifact, scope: .fragments)
        expect(partial.outcome == .partial, "Visible fragments cannot claim full correctness")
        expect(PhoneContentComparison.compare("别的正文", with: artifact, scope: .fragments).outcome == .mismatch, "An unrelated observed fragment cannot pass even partial content matching")
        expect(PhoneContentComparison.compare(text, with: artifact, scope: .fragments).outcome == .partial, "Fragment provenance cannot become full verification merely by matching")
        expect(PhoneContentComparison.compare(text, with: artifact, scope: .fullReadback).outcome == .exact, "Independent exact full read-back passes")
        expect(PhoneContentComparison.compare(text.replacingOccurrences(of: "\r\n", with: "\n"), with: artifact, scope: .fullReadback).outcome == .mismatch, "Line ending changes fail full correctness")
        expect(PhoneContentComparison.compare(nil, with: artifact, scope: .fullReadback).outcome == .unknown, "Missing text remains unknown")
        expect(PhoneContentComparison.compare("", with: artifact, scope: .fullReadback).outcome == .unknown, "Empty read-back does not prove success")
        expect(PhoneContentComparison.compare("é", with: decomposed, scope: .fullReadback).outcome == .mismatch, "Unicode normalization differences are detected")
        let corrupt = folder.appendingPathComponent("corrupt.json"); let bytes = Data("invalid".utf8); try bytes.write(to: corrupt)
        let broken = PhoneContentStore(url: corrupt, clipboard: clipboard.access)
        rejects({ _ = try broken.create(title: "new", body: "body") }, "Unreadable checkpoint store blocks writes")
        expect(!broken.error.isEmpty, "Unreadable store exposes a recoverable error")
        expect((try? Data(contentsOf: corrupt)) == bytes, "Corrupt source is preserved for recovery")
        clipboard.corruptWrites = false
        let beforeCancellation = clipboard.writes
        let cancelled = Task { @MainActor in
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try store.prepareClipboard(reference: artifact.reference)
        }
        cancelled.cancel()
        _ = await cancelled.result
        expect(clipboard.writes == beforeCancellation, "Cancellation never starts a later clipboard write")
        let long = String(repeating: "中文🙂\n", count: 1000)
        let longArtifact = try restored.create(title: "长文本离线材料", body: long)
        expect(longArtifact.characterCount == 4000 && longArtifact.lineBreakCount == 1000, "Long local material has reproducible counts")
        let request = try SystemToolRequest.decode("{\"operation\":\"content_create\",\"title\":\"中文\",\"content\":\"第一行\\n第二行🙂\"}")
        expect(request.content == "第一行\n第二行🙂", "Production system-tool parser preserves Unicode/newlines")
        let status = try SystemToolRequest.decode("{\"operation\":\"content_status\",\"artifact_ref\":\"" + artifact.reference + "\"}")
        expect(!status.operation.writes, "Metadata inspection is distinct from a clipboard write")
        rejects({ _ = try SystemToolRequest.decode("{\"operation\":\"content_prepare_clipboard\",\"artifact_ref\":\"" + artifact.reference + "\",\"content\":\"override\"}") }, "Prepare cannot silently replace the referenced body")
        rejects({ _ = try SystemToolRequest.decode("{\"operation\":\"calendar_search\",\"content\":\"private body\"}") }, "New body parameters cannot be smuggled to unrelated tools")
        rejects({ _ = try SystemToolRequest.decode("{\"operation\":\"content_create\",\"title\":\"中文\",\"content\":\"x\",\"readback\":\"verified\"}") }, "Model assertions cannot masquerade as target read-back")
        let evidenceTask = UUID(), foreignTask = UUID()
        let evidenceArtifact = try restored.create(title: "保存账本专用标题", body: "PRIVATE_EVIDENCE_BODY")
        func evidenceReceipt(_ task: UUID, _ value: PhoneContentArtifact, suffix: String = "digest") throws -> NativeContentEvidence.Receipt {
            let data = try JSONSerialization.data(withJSONObject: value.metadata, options: [.sortedKeys])
            return .init(key: task.uuidString + ":" + suffix, id: UUID(), state: "completed", result: String(decoding: data, as: UTF8.self))
        }
        let completed = try evidenceReceipt(evidenceTask, evidenceArtifact)
        let foreign = try evidenceReceipt(foreignTask, longArtifact)
        let inventory = NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed, foreign]) {
            try restored.artifact(reference: $0)
        }
        expect(inventory.contains(evidenceArtifact.reference) && inventory.contains(evidenceArtifact.title), "Durable inventory restores exact current-task title and complete reference")
        expect(!inventory.contains(longArtifact.reference) && !inventory.contains("PRIVATE_EVIDENCE_BODY"), "Inventory excludes other tasks and never emits bodies")
        expect(inventory.contains("\"completed_count\":1"), "Only current-task verified saves are counted")
        let duplicate = try evidenceReceipt(evidenceTask, evidenceArtifact, suffix: "other-receipt")
        expect(NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed, duplicate]) { try restored.artifact(reference: $0) }.contains("\"completed_count\":1"), "Multiple receipts never double-count one immutable artifact")
        let pendingID = UUID()
        let pending = NativeContentEvidence.Receipt(key: evidenceTask.uuidString + ":pending", id: pendingID, state: "pending", result: nil)
        let uncertain = NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed, pending, foreign]) { try restored.artifact(reference: $0) }
        expect(uncertain.contains(pendingID.uuidString) && uncertain.contains("unresolved_receipt_ids"), "Pending writes remain explicit instead of being reported as completed")
        let absent = NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed]) { _ in throw PhoneContentError.invalidReference }
        expect(absent.contains("\"completed_count\":0") && absent.contains("\"unavailable_content_receipts\":1"), "A missing artifact cannot become a confirmed save from a receipt alone")
        var damaged = evidenceArtifact; damaged.body += "changed"
        expect(NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed]) { _ in damaged }.contains("\"unavailable_content_receipts\":1"), "Actual body/hash integrity is checked before metadata becomes evidence")
        let bad = NativeContentEvidence.Receipt(key: evidenceTask.uuidString + ":bad", id: UUID(), state: "completed", result: completed.result!.replacingOccurrences(of: evidenceArtifact.title, with: "Wrong title"))
        expect(NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [bad]) { _ in evidenceArtifact }.contains("\"unavailable_content_receipts\":1"), "Mismatched receipt metadata is not promoted to verified evidence")
        let decomposedTitle = try PhoneContentArtifact(title: "e\u{301}", body: "same body")
        let titleReceipt = try evidenceReceipt(evidenceTask, decomposedTitle, suffix: "unicode-title")
        var normalizedTitle = decomposedTitle; normalizedTitle.title = "é"
        expect(NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [titleReceipt]) { _ in normalizedTitle }.contains("\"unavailable_content_receipts\":1"), "Canonically equivalent but byte-different titles cannot satisfy the durable receipt")
        expect(NativeContentEvidence.instructions(taskID: foreignTask, receipts: [completed]) { _ in evidenceArtifact }.isEmpty, "New task identity never receives an old task's inventory")
        let freshStore = PhoneContentStore(url: path, clipboard: clipboard.access)
        expect(NativeContentEvidence.instructions(taskID: evidenceTask, receipts: [completed]) { try freshStore.artifact(reference: $0) }.isEmpty == false, "A new store instance can reconstruct evidence without old logs or a session lease")
        let many = try (0..<100).map { try PhoneContentArtifact(title: "task-item-\($0)", body: "BODY_MUST_NOT_BE_SENT_\($0)") }
        let table = Dictionary(uniqueKeysWithValues: many.map { ($0.reference, $0) })
        let manyReceipts = try many.enumerated().map { try evidenceReceipt(evidenceTask, $0.element, suffix: "item-\($0.offset)") }
        let full = NativeContentEvidence.instructions(taskID: evidenceTask, receipts: manyReceipts) { reference in
            guard let value = table[reference] else { throw PhoneContentError.invalidReference }; return value
        }
        expect(full.contains("\"completed_count\":100") && many.allSatisfy { full.contains($0.reference) }, "All 100 supported saved artifacts retain full references without silent truncation")
        expect(!full.contains("BODY_MUST_NOT_BE_SENT"), "Even the maximum inventory contains metadata only")
        func noteReceipt(_ task: UUID, index: Int, folder: String = "测试目标") throws -> NativeContentEvidence.Receipt {
            let callback = UUID(), title = "周记录-\(index)"
            let result = try JSONSerialization.data(withJSONObject: ["source": "iPhone Shortcuts / Apple Notes",
                "shortcut_completed": true, "output_matches_requested_text": true, "expected_folder": folder,
                "folder_independently_verified": false, "receipt_id": callback.uuidString], options: [.sortedKeys])
            return .init(key: task.uuidString + ":" + String(format: "%064x", index), id: UUID(), state: "completed",
                result: String(decoding: result, as: UTF8.self),
                notesIdentity: .init(title: title, expectedFolder: folder, inputSHA256: String(repeating: "a", count: 64),
                    inputUTF8Bytes: title.utf8.count + 1 + 30, callbackID: callback))
        }
        func noteText(_ receipts: [NativeContentEvidence.Receipt]) -> String {
            NativeContentEvidence.instructions(taskID: evidenceTask, receipts: receipts) { _ in
                throw PhoneContentError.invalidReference
            }
        }
        func noteDocument(_ receipts: [NativeContentEvidence.Receipt]) throws -> [String: Any] {
            let line = noteText(receipts).components(separatedBy: "\n").first { $0.hasPrefix("{") && $0.contains("completed_shortcuts") }!
            return try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
        let weeks = try (1...53).map { try noteReceipt(evidenceTask, index: $0) }
        let notesDocument = try noteDocument(weeks)
        expect(notesDocument["identified_completed_callbacks"] as? Int == 53, "All 53 bound Notes callbacks survive log compaction without truncation")
        let noteRows = notesDocument["completed_shortcuts"] as! [[String: Any]]
        expect(Set(noteRows.compactMap { $0["title"] as? String }) == Set(weeks.map { $0.notesIdentity!.title }), "The Notes inventory retains exact submitted titles")
        expect(noteRows.allSatisfy { $0["expected_folder"] as? String == "测试目标" }, "Configured destination is recorded without claiming physical folder verification")
        expect(!noteText(weeks).contains("content\":") && noteText(weeks).contains("不能视为 Notes 读取工具"), "Notes evidence contains metadata and explicitly excludes an Apple Notes read capability")
        let encodedIdentity = try JSONEncoder().encode(weeks[0].notesIdentity!)
        let restoredIdentity = try JSONDecoder().decode(NativeContentEvidence.NotesIdentity.self, from: encodedIdentity)
        expect(restoredIdentity.callbackID == weeks[0].notesIdentity!.callbackID && restoredIdentity.inputSHA256 == weeks[0].notesIdentity!.inputSHA256, "Durable Notes identity round trips without old model logs")
        var legacyNotes = weeks
        for i in legacyNotes.indices { legacyNotes[i].notesIdentity = nil }
        let oldDocument = try noteDocument(legacyNotes)
        expect(oldDocument["identified_completed_callbacks"] as? Int == 0 && oldDocument["unidentified_completed_callbacks"] as? Int == 53, "Legacy success callbacks remain unidentified; planned titles never become completed evidence")
        expect(!(oldDocument["completed_shortcuts"] as! [[String: Any]]).contains { !$0.isEmpty }, "No title is synthesized for old Notes receipts")
        let foreignNote = try noteReceipt(foreignTask, index: 99)
        expect(!noteText(weeks + [foreignNote]).contains(foreignNote.notesIdentity!.title), "Notes inventory excludes every other task")
        let pendingNote = NativeContentEvidence.Receipt(key: weeks[0].key, id: weeks[0].id, state: "pending", result: weeks[0].result, notesIdentity: weeks[0].notesIdentity)
        expect(!noteText([pendingNote]).contains("completed_shortcuts") && noteText([pendingNote]).contains(weeks[0].id.uuidString), "A pending Notes write stays unresolved even if stale success text exists")
        let wrongCallback = NativeContentEvidence.NotesIdentity(title: "wrong binding", expectedFolder: "测试目标",
            inputSHA256: String(repeating: "a", count: 64), inputUTF8Bytes: 50, callbackID: UUID())
        var badBinding = weeks[0]; badBinding.notesIdentity = wrongCallback
        let badBindingDocument = try noteDocument([badBinding])
        expect(badBindingDocument["invalid_identity_receipts"] as? Int == 1, "A callback from a different attempt cannot identify a completed note")
        var malformedHash = weeks[0]
        malformedHash.notesIdentity = .init(title: "bad hash", expectedFolder: "测试目标", inputSHA256: "broken", inputUTF8Bytes: 50, callbackID: weeks[0].notesIdentity!.callbackID)
        let malformedHashDocument = try noteDocument([malformedHash])
        expect(malformedHashDocument["identified_completed_callbacks"] as? Int == 0, "Malformed input fingerprints are not evidence")
        let wrongFolder = try noteReceipt(evidenceTask, index: 90, folder: "é")
        var equivalentFolder = wrongFolder
        equivalentFolder.notesIdentity = .init(title: wrongFolder.notesIdentity!.title, expectedFolder: "e\u{301}", inputSHA256: wrongFolder.notesIdentity!.inputSHA256,
            inputUTF8Bytes: wrongFolder.notesIdentity!.inputUTF8Bytes, callbackID: wrongFolder.notesIdentity!.callbackID)
        let equivalentFolderDocument = try noteDocument([equivalentFolder])
        expect(equivalentFolderDocument["invalid_identity_receipts"] as? Int == 1, "Canonically equivalent but byte-different destinations do not satisfy the actual callback")
        let duplicateDocument = try noteDocument([weeks[0], weeks[0]])
        expect(duplicateDocument["identified_completed_callbacks"] as? Int == 1 && duplicateDocument["invalid_identity_receipts"] as? Int == 1, "Duplicate callback identities cannot inflate completed counts and remain explicit")
        var numericBoolean = weeks[0]
        numericBoolean = .init(key: numericBoolean.key, id: numericBoolean.id, state: "completed", result: numericBoolean.result!.replacingOccurrences(of: "\"shortcut_completed\":true", with: "\"shortcut_completed\":1"), notesIdentity: numericBoolean.notesIdentity)
        let numericBooleanDocument = try noteDocument([numericBoolean])
        expect(numericBooleanDocument["invalid_identity_receipts"] as? Int == 1, "Numeric flags cannot masquerade as a successful boolean callback")
        let oversized = try (1...2000).map { try noteReceipt(evidenceTask, index: $0, folder: String(repeating: "目", count: 160)) }
        expect(noteText(oversized).contains("超出可核验范围") && !noteText(oversized).contains("completed_shortcuts"), "An oversized inventory fails explicitly instead of silently dropping early notes")

        func healthReceipt(_ task: UUID, week: Int, scope: String) throws -> NativeContentEvidence.Receipt {
            let formatter = ISO8601DateFormatter()
            let start = Date(timeIntervalSince1970: 1_704_067_200 + Double((week - 1) * 7 * 86400))
            let from = formatter.string(from: start), to = formatter.string(from: start.addingTimeInterval(7 * 86400))
            let request = SystemToolRequest(operation: .health_query, query: scope, start: from, end: to)
            let source = try JSONSerialization.data(withJSONObject: ["source": "HealthKit", "type": scope,
                "start": from, "end": to, "coverage": "visible_data_only", "private_fixture": "private-health-fixture-marker"], options: [.sortedKeys])
            let id = UUID()
            let identity = try NativeContentEvidence.completedHealthRead(request, result: String(decoding: source, as: UTF8.self), receiptID: id)
            return .init(key: task.uuidString + ":health-read:" + id.uuidString, id: id, state: "completed",
                result: String(decoding: try JSONEncoder().encode(identity), as: UTF8.self), healthReadIdentity: identity)
        }
        func healthDocument(_ receipts: [NativeContentEvidence.Receipt]) throws -> [String: Any] {
            let line = noteText(receipts).components(separatedBy: "\n").first { $0.hasPrefix("{") && $0.contains("completed_health_reads") }!
            return try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
        let reads = try (1...21).flatMap { week in try ["steps", "sleep", "workouts"].map { try healthReceipt(evidenceTask, week: week, scope: $0) } }
        let readDocument = try healthDocument(reads)
        expect(readDocument["identified_completed_reads"] as? Int == 63, "All63 actual completion identities survive without model logs")
        expect(readDocument["complete_three_scope_ranges"] as? Int == 21, "Completed ranges require all three actual scopes")
        expect((readDocument["completed_health_reads"] as? [[String: Any]])?.count == 63, "Every actual read remains represented")
        expect(!noteText(reads).contains("private-health-fixture-marker"), "The durable inventory does not expose original Health values")
        let identityData = try JSONEncoder().encode(reads[0].healthReadIdentity!)
        let restoredHealthIdentity = try JSONDecoder().decode(NativeContentEvidence.HealthReadIdentity.self, from: identityData)
        expect(restoredHealthIdentity == reads[0].healthReadIdentity!, "Read identity metadata round trips without old log content")
        let sampleIdentity = reads[0].healthReadIdentity!
        let sampleRequest = SystemToolRequest(operation: .health_query, query: sampleIdentity.type, start: sampleIdentity.start, end: sampleIdentity.end)
        let source: [String: Any] = ["source": "HealthKit", "type": sampleIdentity.type, "start": sampleIdentity.start, "end": sampleIdentity.end, "coverage": "visible_data_only"]
        func rejectsSource(_ changed: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: changed) else { return false }
            let text = String(decoding: data, as: UTF8.self)
            return (try? NativeContentEvidence.completedHealthRead(sampleRequest, result: text, receiptID: UUID())) == nil
        }
        var wrong = source; wrong["type"] = "sleep"
        expect(rejectsSource(wrong), "A mismatched actual scope cannot create completion evidence")
        wrong = source; wrong["start"] = sampleIdentity.end
        expect(rejectsSource(wrong), "Actual dates must match the submitted request")
        wrong = source; wrong["coverage"] = "all_data"
        expect(rejectsSource(wrong), "Visible-only Health scope cannot become an all-data claim")
        wrong = source; wrong["source"] = "planned"
        expect(rejectsSource(wrong), "A plan cannot masquerade as an actual HealthKit result")
        let fractionalRequest = SystemToolRequest(operation: .health_query, query: "steps",
            start: "2024-01-01T00:00:00.125+08:00", end: "2024-01-02T00:00:00.125+08:00")
        let fractionalResult = "{\"source\":\"HealthKit\",\"type\":\"steps\",\"start\":\"2023-12-31T16:00:00.125Z\",\"end\":\"2024-01-01T16:00:00.125Z\",\"coverage\":\"visible_data_only\"}"
        let fractionalIdentity = try NativeContentEvidence.completedHealthRead(fractionalRequest, result: fractionalResult, receiptID: UUID())
        expect(fractionalIdentity.start == "2023-12-31T16:00:00.125Z", "Equivalent explicit time zones and fractional bounds bind to the actual result")
        let roundedResult = fractionalResult.replacingOccurrences(of: ".125", with: "")
        expect((try? NativeContentEvidence.completedHealthRead(fractionalRequest, result: roundedResult, receiptID: UUID())) == nil, "Rounded bounds cannot silently replace the requested instant")
        let duplicateReads = try healthDocument(reads + [reads[0]])
        expect(duplicateReads["identified_completed_reads"] as? Int == 63 && duplicateReads["invalid_read_receipts"] as? Int == 1, "Duplicate receipt identities stay explicit without inflating reads")
        let foreignRead = try healthReceipt(foreignTask, week: 90, scope: "steps")
        expect(!noteText(reads + [foreignRead]).contains(foreignRead.id.uuidString), "Other tasks never enter the read inventory")
        let pendingRead = NativeContentEvidence.Receipt(key: reads[0].key, id: reads[0].id, state: "pending",
            result: reads[0].result, healthReadIdentity: reads[0].healthReadIdentity)
        let pendingDocument = try healthDocument([pendingRead])
        expect(pendingDocument["identified_completed_reads"] as? Int == 0 && pendingDocument["invalid_read_receipts"] as? Int == 1, "An unfinished read receipt cannot establish a completion")
        let legacyRead = NativeContentEvidence.Receipt(key: evidenceTask.uuidString + ":legacy", id: UUID(), state: "completed",
            result: String(decoding: try JSONSerialization.data(withJSONObject: source), as: UTF8.self))
        let legacyReadDocument = try healthDocument([legacyRead])
        expect(legacyReadDocument["identified_completed_reads"] as? Int == 0 && legacyReadDocument["unidentified_read_receipts"] as? Int == 1, "Missing legacy identities are not backfilled from a plan")
        let alteredResult = NativeContentEvidence.Receipt(key: reads[0].key, id: reads[0].id, state: "completed",
            result: reads[0].result!.replacingOccurrences(of: sampleIdentity.result_sha256, with: String(repeating: "0", count: 64)), healthReadIdentity: reads[0].healthReadIdentity)
        let alteredDocument = try healthDocument([alteredResult])
        expect(alteredDocument["invalid_read_receipts"] as? Int == 1, "Persisted identity and completion result must remain bound")
        var wrongNamespace = reads[0]; wrongNamespace = .init(key: evidenceTask.uuidString + ":" + String(repeating: "a", count: 64), id: wrongNamespace.id, state: wrongNamespace.state, result: wrongNamespace.result, healthReadIdentity: wrongNamespace.healthReadIdentity)
        let wrongNamespaceDocument = try healthDocument([wrongNamespace])
        expect(wrongNamespaceDocument["invalid_read_receipts"] as? Int == 1, "Read metadata cannot masquerade as a write receipt")
        let repeatedFreshRead = try healthReceipt(evidenceTask, week: 1, scope: "steps")
        let freshReadDocument = try healthDocument(reads + [repeatedFreshRead])
        expect(freshReadDocument["identified_completed_reads"] as? Int == 64 && freshReadDocument["complete_three_scope_ranges"] as? Int == 21, "A genuinely new read has an independent identity and is never a cached call")
        let mixedNoteDocument = try noteDocument(weeks + reads)
        let mixedHealthDocument = try healthDocument(weeks + reads)
        expect(mixedNoteDocument["identified_completed_callbacks"] as? Int == 53, "Health evidence does not contaminate Notes completion counts")
        expect(mixedHealthDocument["identified_completed_reads"] as? Int == 63, "Notes writes cannot inflate completed Health reads")
        let oversizedReads = try (1...2000).map { try healthReceipt(evidenceTask, week: $0, scope: "steps") }
        expect(noteText(oversizedReads).contains("超出可核验范围") && !noteText(oversizedReads).contains("completed_health_reads"), "Oversized read inventories fail explicitly without losing early entries silently")
        print("\(count) phone-content checks passed. Production store, durable task evidence and request parser; injected Health results and synthetic clipboard only, no phone or real health/clipboard access.")
    }
}
