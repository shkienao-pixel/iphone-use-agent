import Foundation

final class Backend {
    var items: [String: String] = [ModelCredentialRepository.legacyAccount: "synthetic-legacy"]
    var binding: String? = "https://a.fixture.invalid/custom"
    var failRead: String?, failWrite = false, failDelete: String?
    var writes = 0, deletes = 0, legacyReads = 0
    var repository: ModelCredentialRepository {
        .init(read: { account in
            if self.failRead == account { throw AgentError.message("synthetic-read-failure") }
            if account == ModelCredentialRepository.legacyAccount { self.legacyReads += 1 }
            return self.items[account]
        }, write: { account, key in
            if self.failWrite { throw AgentError.message("synthetic-write-failure") }
            self.writes += 1; self.items[account] = key
        }, delete: { account in
            if self.failDelete == account { throw AgentError.message("synthetic-delete-failure") }
            self.deletes += 1; self.items.removeValue(forKey: account)
        }, legacyEndpoint: { self.binding }, clearLegacyEndpoint: { self.binding = nil })
    }
}

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ label: String) {
    do { guard try value() else { fatalError("FAIL: " + label) }; checks += 1 }
    catch { fatalError("FAIL: " + label) }
}
func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("FAIL: " + label) } catch { checks += 1 }
}
let a = "https://a.fixture.invalid/custom", b = "https://b.fixture.invalid/proxy?api-version=fixture"
let backend = Backend()
func save(endpoint: String, model: String = "synthetic-model", key: String) throws {
    let request = try ModelConnectionSaveRequest(endpoint: endpoint, model: model, key: key,
        validateEndpoint: ModelEndpointPolicy.url)
    try backend.repository.save(request.key, for: request.endpoint)
}

for endpoint in ["", "  ", "http://a.fixture.invalid/custom", "not-a-url", "https:///custom", "https://user:pass@a.fixture.invalid/custom", "https://a.fixture.invalid/custom#fragment", "https://a.fixture.invalid:99999/custom"] {
    rejects("invalid endpoint rejected") { try save(endpoint: endpoint, key: "synthetic-new") }
}
rejects("blank model rejected") { try save(endpoint: a, model: "  ", key: "synthetic-new") }
rejects("blank key rejected") { try save(endpoint: a, key: " \n") }
check(backend.writes == 0 && backend.deletes == 0, "validation failures never mutate storage")
check(try backend.repository.key(for: a) == "synthetic-legacy", "legacy exact endpoint remains readable")
check(try backend.repository.key(for: b).isEmpty, "new endpoint never inherits legacy key")
check(try backend.repository.key(for: a + "/other").isEmpty, "credential binding includes complete path")
try save(endpoint: b, key: " synthetic-b \n")
check(try backend.repository.key(for: b) == "synthetic-b", "custom HTTPS proxy path remains supported")
check(try backend.repository.key(for: a) == "synthetic-legacy", "saving provider B preserves provider A legacy key")
check(backend.binding == a && backend.items[ModelCredentialRepository.legacyAccount] == "synthetic-legacy", "new save does not rewrite legacy provenance")
try save(endpoint: a, key: "synthetic-a-new")
check(try backend.repository.key(for: a) == "synthetic-a-new", "scoped replacement wins for exact endpoint")
check(backend.items[ModelCredentialRepository.legacyAccount] == "synthetic-legacy", "replacement preserves original legacy item")
let oldItems = backend.items
backend.failWrite = true
rejects("failed save reported") { try save(endpoint: a, key: "synthetic-failed") }
check(backend.items == oldItems, "failed save preserves prior credentials")
backend.failWrite = false
let reads = backend.legacyReads
backend.failRead = ModelCredentialRepository.account(for: a)
rejects("scoped read failure does not fall back") { _ = try backend.repository.key(for: a) }
check(backend.legacyReads == reads, "locked scoped credential never resurrects legacy")
backend.failRead = nil
backend.failDelete = ModelCredentialRepository.account(for: a)
rejects("failed scoped removal reported") { try backend.repository.remove(for: a) }
check(backend.items == oldItems && backend.binding == a, "failed scoped removal leaves all credentials and provenance")
backend.failDelete = ModelCredentialRepository.legacyAccount
rejects("failed legacy removal reported") { try backend.repository.remove(for: a) }
check(backend.binding == a, "legacy provenance retained when removal fails")
backend.failDelete = nil
try backend.repository.remove(for: a)
check(try backend.repository.key(for: a).isEmpty, "explicit removal cannot resurrect legacy key")
check(backend.binding == nil && backend.items[ModelCredentialRepository.legacyAccount] == nil, "explicit removal clears only matching legacy binding")
check(try backend.repository.key(for: b) == "synthetic-b", "removing A preserves B")
try backend.repository.remove(for: b)
check(try backend.repository.key(for: b).isEmpty, "exact scoped removal disables B")
check(ModelCredentialRepository.account(for: a) != ModelCredentialRepository.account(for: b), "endpoint accounts remain independent")

var draft = ModelCredentialDraft()
draft.loadSaved("synthetic-auto-a", for: a)
draft.endpointChanged(to: b, savedKey: "")
check(draft.value.isEmpty && !draft.manuallyEdited, "automatically loaded old key never follows new destination")
draft.endpointChanged(to: a, savedKey: "synthetic-auto-a")
check(draft.value == "synthetic-auto-a", "switching back reloads only the exact endpoint saved key")
draft.edit("synthetic-unsaved")
for endpoint in ["h", "https:", "https://", b] { draft.endpointChanged(to: endpoint, savedKey: "synthetic-other") }
check(draft.value == "synthetic-unsaved", "typing an address preserves explicit unsaved input")
check(draft.retainedAfterEndpointChange && draft.endpoint == b, "retained input identifies the current destination")
draft.endpointChanged(to: b, savedKey: "synthetic-other")
check(draft.value == "synthetic-unsaved", "repeated endpoint notification does not reset draft")
draft.loadSaved("synthetic-saved", for: b)
check(!draft.manuallyEdited && !draft.retainedAfterEndpointChange, "successful save resets draft provenance")
draft.endpointChanged(to: a, savedKey: "")
check(draft.value.isEmpty, "saved key cannot silently move after save")
draft.edit(""); draft.endpointChanged(to: b, savedKey: "synthetic-b")
check(draft.value == "synthetic-b", "empty input does not prevent exact-endpoint credential reload")
print("Model credential checks passed: \(checks)")
