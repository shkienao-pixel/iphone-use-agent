import Foundation

/// The real production HTTP client and decoding run against the existing
/// in-memory fixture. Counts prove rejection happens before private-phone reads
/// or quote HTTP, rather than merely suppressing the final display.
@MainActor private final class ReferenceBackend {
    let fixture = Backend()
    var calls: [String: Int] = [:]
    var addressOverrides: [Int: String] = [:]
    var duplicateAddressID: Int?
    var pois: [[String: Any]]?
    func client(_ key: String) -> MeituanPaotuiClient {
        MeituanPaotuiClient(credential: key, transport: { request in
            let endpoint = request.url!.lastPathComponent
            self.calls[endpoint, default: 0] += 1
            let response = try self.fixture.respond(request)
            var data = try MeituanPaotuiClient.decode(response.0)
            if endpoint == "get_address_list" {
                var values = (data["userAddresses"] as! [[String: Any]]).map { row in
                    var row = row
                    if let id = row["id"] as? Int, let address = self.addressOverrides[id] { row["address"] = address }
                    return row
                }
                if let id = self.duplicateAddressID, var duplicate = values.first(where: { $0["id"] as? Int == id }) {
                    duplicate["address"] = "Ambiguous replacement for same saved ID"
                    values.append(duplicate)
                }
                data["userAddresses"] = values
            } else if endpoint == "search_poi", let pois = self.pois {
                data = ["result": ["pois": pois]]
            } else { return response }
            let inner = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
            let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "result": "SUCCESS", "data": String(decoding: inner, as: UTF8.self)])
            return (bytes, response.1)
        })
    }
    var privateReads: Int { calls["get_address_info_by_id", default: 0] }
    var quoteReads: Int { calls["delivery_preview", default: 0] }
    var placeReads: Int { calls["search_poi", default: 0] }
}

@main private struct TaskReferenceChecks {
    private static var checks = 0
    private static func expect(_ value: Bool, _ label: String) {
        checks += 1; precondition(value, label)
    }
    private static func input(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private static func object(_ value: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
    }
    private static func rows(_ value: String) throws -> [[String: Any]] {
        try object(value)["records"] as! [[String: Any]]
    }
    private static func buy(_ recipient: String, sender: String? = nil) throws -> String {
        var fields: [String: Any] = ["action": "preview_buy", "recipient": recipient, "goods": "本次水一瓶"]
        if let sender { fields["sender"] = sender } else { fields["nearby"] = true }
        return try input(fields)
    }
    private static func poi(_ id: String, name: String, near: Bool = false) -> [String: Any] {
        ["id": id, "name": name, "address": "实际门店地址 " + name,
         "location": near ? "113.935457,22.518482" : "114.2,22.7",
         "addr_info": [["level_desc": "city", "admin_code": "440300"]]]
    }
    @MainActor private static func rejectBeforePrivateReads(_ store: MeituanPaotuiStore,
        backend: ReferenceBackend, task: UUID, query: String, label: String) async {
        let phones = backend.privateReads, quotes = backend.quoteReads
        do { _ = try await store.tool(query, taskID: task); preconditionFailure(label) }
        catch { checks += 1 }
        expect(backend.privateReads == phones && backend.quoteReads == quotes,
               label + " must fail before private-phone or quote HTTP")
    }
    @MainActor private static func addressRead(_ store: MeituanPaotuiStore, task: UUID,
                                              keyword: String? = nil) async throws -> [String: Any] {
        var fields: [String: Any] = ["action": "addresses"]
        if let keyword { fields["keyword"] = keyword }
        return try object(await store.tool(input(fields), taskID: task))
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paotui-task-references-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = ReferenceBackend()
        backend.fixture.addressCount = 45
        let store = MeituanPaotuiStore(connection: PaotuiFixtureRuntime.connection(),
            receiptURL: directory.appendingPathComponent("orders.json"), clientFactory: backend.client)
        try store.installCredential("offline-reference-fixture")

        // A workbench read does not issue any task a usable address reference.
        try await store.loadAddresses()
        let freshTask = UUID()
        await rejectBeforePrivateReads(store, backend: backend, task: freshTask,
            query: try buy("address:1"), label: "A fresh task borrowed a workbench recipient")
        await rejectBeforePrivateReads(store, backend: backend, task: freshTask,
            query: try buy("address:1", sender: "address:2"), label: "A fresh task borrowed two workbench addresses")

        // A task can use only references actually exported after filtering.
        let filteredTask = UUID(), borrower = UUID()
        let filtered = try await addressRead(store, task: filteredTask, keyword: "Fixture address 1")
        let filteredRows = filtered["records"] as! [[String: Any]]
        let filteredRefs = Set(filteredRows.map { $0["reference"] as! String })
        expect(filteredRefs.contains("address:1") && !filteredRefs.contains("address:2"),
               "Fixture gives the owner address:1 while the filter withholds address:2")
        expect(filteredRows.count <= 20 && filtered["total"] as? Int == 11,
               "Filtered result reports its actual matching total and output cap")
        await rejectBeforePrivateReads(store, backend: backend, task: borrower,
            query: try buy("address:1"), label: "Task B borrowed task A's returned recipient")
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try buy("address:2"), label: "An owner used a non-returned filtered recipient")
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try buy("address:1", sender: "address:2"), label: "An owner used a non-returned saved sender")
        let send = try input(["action": "preview_send", "recipient": "address:1", "sender": "address:2",
                              "goods": "文件一份", "category": "document", "weight": 0.5])
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: send, label: "Send preview borrowed a non-returned saved sender")
        let searches = backend.placeReads
        await rejectBeforePrivateReads(store, backend: backend, task: borrower,
            query: try input(["action": "search", "keyword": "测试门店", "city": "深圳", "recipient": "address:1"]),
            label: "Search borrowed another task's saved recipient")
        expect(backend.placeReads == searches, "Borrowed search recipient is rejected before POI HTTP")

        // References retained privately beyond the 20 exported rows are not
        // grants. Each task's later turns retain only its legitimately issued set.
        let cappedTask = UUID()
        let capped = try await addressRead(store, task: cappedTask)
        let cappedRows = capped["records"] as! [[String: Any]]
        let cappedRefs = Set(cappedRows.map { $0["reference"] as! String })
        expect(cappedRows.count == 20 && capped["total"] as? Int == 45 && capped["truncated"] as? Bool == true,
               "Provider address cache is larger than the exact exported set")
        expect(!cappedRefs.contains("address:1"), "Oldest saved address lies outside this task's exported page")
        await rejectBeforePrivateReads(store, backend: backend, task: cappedTask,
            query: try buy("address:1"), label: "The source cache authorized a non-exported 21st-or-later recipient")
        let ownedCappedRef = cappedRows[0]["reference"] as! String
        await rejectBeforePrivateReads(store, backend: backend, task: cappedTask,
            query: try buy(ownedCappedRef, sender: "address:1"), label: "The source cache authorized a non-exported saved sender")
        let cappedQuote = try rows(await store.tool(buy(ownedCappedRef), taskID: cappedTask))
        expect(cappedQuote.count == 1 && cappedQuote[0]["service"] as? String == "buy",
               "An exactly returned capped-page reference remains usable on a later turn")

        let search = try await store.tool(input(["action": "search", "keyword": "本任务门店", "city": "深圳",
                                                "recipient": "address:1"]), taskID: filteredTask)
        let poiRef = try rows(search)[0]["reference"] as! String
        let ownQuote = try rows(await store.tool(buy("address:1", sender: poiRef), taskID: filteredTask))
        expect(ownQuote.count == 1 && ownQuote[0]["goods"] as? String == "本次水一瓶",
               "A legitimate address -> search -> preview flow retains this task's real references across beginTurn")
        await rejectBeforePrivateReads(store, backend: backend, task: borrower,
            query: try buy("address:1", sender: poiRef), label: "An unrelated task borrowed another task's address and POI")
        _ = try await addressRead(store, task: borrower, keyword: "Fixture address 2")
        let independent = try rows(await store.tool(buy("address:2"), taskID: borrower))
        expect(independent.count == 1 && independent[0]["recipient"] as? String == "Fixture address 2 101",
               "Another task independently reads its own address and receives its own valid quote")

        // Even reinstalling the same authorization revokes every old grant.
        try store.installCredential("offline-reference-fixture")
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try buy("address:1"), label: "An old address grant survived a new authorization epoch")
        _ = try await addressRead(store, task: filteredTask, keyword: "Fixture address 1")
        let afterAuthorization = try rows(await store.tool(buy("address:1"), taskID: filteredTask))
        expect(afterAuthorization.count == 1, "A fresh read under the new authorization allows a new preview")

        // Another task cannot silently change the snapshot to which an old
        // issued saved-address ID resolves. Unchanged IDs retain their grants.
        let unchangedTask = UUID()
        _ = try await addressRead(store, task: unchangedTask, keyword: "Fixture address 45")
        backend.addressOverrides[1] = "Fixture address 1 changed only in another task"
        let refreshed = try await addressRead(store, task: borrower, keyword: "Fixture address 1")
        let refreshedRows = refreshed["records"] as! [[String: Any]]
        expect(refreshedRows.contains { $0["reference"] as? String == "address:1" &&
            ($0["address"] as? String)?.contains("changed only in another task") == true },
               "Another task really received changed metadata under the exact same saved ID")
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try buy("address:1"), label: "An old grant silently adopted unseen same-ID saved-address metadata")
        let unchangedQuote = try rows(await store.tool(buy("address:45"), taskID: unchangedTask))
        expect(unchangedQuote[0]["recipient"] as? String == "Fixture address 45 101",
               "Refreshing changed address:1 does not revoke unchanged address:45")
        _ = try await addressRead(store, task: filteredTask, keyword: "Fixture address 1")
        let reread = try rows(await store.tool(buy("address:1"), taskID: filteredTask))
        expect(reread[0]["recipient"] as? String == "Fixture address 1 changed only in another task 101",
               "The original task can use the changed saved-address snapshot only after its own reread")

        // The second page has changed same-ID data beyond the 20 rendered
        // records. The unchanged old POI is also omitted: its old grant remains
        // valid, while the changed POI must wait for a real re-export.
        let originalShop = poi("same-shop", name: "原门店"), stableShop = poi("stable-shop", name: "未变化门店")
        backend.pois = [originalShop, stableShop]
        let initialPOIs = try rows(await store.tool(input(["action": "search", "keyword": "第一批门店", "city": "深圳"]), taskID: filteredTask))
        let initialPOIRefs = Set(initialPOIs.map { $0["reference"] as! String })
        let initialStableAddress = initialPOIs.first { $0["reference"] as? String == "poi:stable-shop" }!["address"] as! String
        expect(initialPOIRefs == ["poi:same-shop", "poi:stable-shop"], "Both initial POI snapshots were really exported")
        let changedShop = poi("same-shop", name: "未导出的替换门店")
        backend.pois = (0..<20).map { poi("new-shop-\($0)", name: "近处新门店\($0)", near: true) } + [changedShop, stableShop]
        let secondPOIs = try object(await store.tool(input(["action": "search", "keyword": "第二批门店", "city": "深圳"]), taskID: filteredTask))
        let secondPOIRefs = Set((secondPOIs["records"] as! [[String: Any]]).map { $0["reference"] as! String })
        expect(secondPOIs["total"] as? Int == 22 && secondPOIRefs.count == 20 &&
            !secondPOIRefs.contains("poi:same-shop") && !secondPOIRefs.contains("poi:stable-shop"),
               "The changed and unchanged same-ID POIs are both retained privately but not rendered")
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try buy("address:1", sender: "poi:same-shop"), label: "An old issued POI ID adopted an unseen replacement snapshot")
        let stableQuote = try rows(await store.tool(buy("address:1", sender: "poi:stable-shop"), taskID: filteredTask))
        expect(stableQuote[0]["sender"] as? String == initialStableAddress, "An unchanged omitted POI retains its previously exported snapshot grant")
        backend.pois = [changedShop]
        let replacementRows = try rows(await store.tool(input(["action": "search", "keyword": "重新查看替换门店", "city": "深圳"]), taskID: filteredTask))
        let exportedReplacement = try rows(await store.tool(buy("address:1", sender: "poi:same-shop"), taskID: filteredTask))
        expect(exportedReplacement[0]["sender"] as? String == replacementRows[0]["address"] as? String,
               "Actual re-export authorizes the new same-ID POI snapshot")

        // Ambiguous duplicate provider IDs are rejected before cache mutation;
        // they cannot silently choose a first/last snapshot or erase old grants.
        backend.duplicateAddressID = 1
        await rejectBeforePrivateReads(store, backend: backend, task: borrower,
            query: try input(["action": "addresses"]), label: "Duplicate provider saved IDs were silently accepted")
        backend.duplicateAddressID = nil
        let afterDuplicateAddress = try rows(await store.tool(buy("address:1"), taskID: filteredTask))
        expect(afterDuplicateAddress[0]["recipient"] as? String == "Fixture address 1 changed only in another task 101",
               "Rejected duplicate addresses leave the prior cache and original task grant intact")
        backend.pois = [poi("stable-shop", name: "歧义门店甲"), poi("stable-shop", name: "歧义门店乙")]
        await rejectBeforePrivateReads(store, backend: backend, task: filteredTask,
            query: try input(["action": "search", "keyword": "歧义门店", "city": "深圳"]),
            label: "Duplicate provider POI IDs were silently accepted")
        let afterDuplicatePOI = try rows(await store.tool(buy("address:1", sender: "poi:stable-shop"), taskID: filteredTask))
        expect(afterDuplicatePOI[0]["sender"] as? String == initialStableAddress,
               "Rejected duplicate POIs leave the prior snapshot and issued grant intact")
        expect(backend.fixture.submissions.isEmpty, "Reference validation tests never submit orders")
        print("PASS: \(checks) actual-source task address/POI export ownership, filtered/capped refs, snapshot replacement, duplicate IDs, private-read preflight and authorization-epoch checks; offline only")
    }
}
