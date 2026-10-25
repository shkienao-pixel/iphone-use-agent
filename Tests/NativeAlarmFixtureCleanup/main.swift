import Foundation

@MainActor final class AlarmManager {
    enum Authorization { case authorized, denied }
    enum State { case alerting, scheduled }
    struct Alarm { var id: UUID; var state: State }
    static let shared = AlarmManager()
    var authorizationState = Authorization.authorized
    var alarms: [Alarm] = []
    var stopped: [UUID] = []
    var shouldThrow = false
    var leavesTarget = false
    func stop(id: UUID) throws {
        stopped.append(id)
        if shouldThrow { throw AgentError.message("injected stop failure") }
        if !leavesTarget { alarms.removeAll { $0.id == id } }
    }
    func reset() { authorizationState = .authorized; alarms = []; stopped = []; shouldThrow = false; leavesTarget = false }
}

@main @MainActor struct Checks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let task = "D61E31CE-F87E-4ABC-A7CE-9F3275DEDFF5"
        let id = UUID(uuidString: "5CC6B4E7-059D-40C5-B18B-57A387AB7158")!
        let other = UUID()
        let key = task + ":digest"
        let receipt = FixtureReceipt(id: id, state: "completed", result: "已添加 Sela 闹钟：Sela测试-20261025-CardA09 · actual-time · 回执 " + id.uuidString)
        let manager = AlarmManager.shared
        let tools = FixtureSystemTools()
        func seed() { manager.reset(); manager.alarms = [.init(id: id, state: .alerting), .init(id: other, state: .scheduled)]; tools.readable = true; tools.receipts = [key: receipt] }
        func rejects(_ message: String) {
            do { _ = try tools.stopAlarmCardFixtureA09(); preconditionFailure(message) }
            catch { check(manager.stopped.isEmpty, message) }
        }
        seed(); tools.receipts = [:]; rejects("No receipt must not stop anything")
        seed(); tools.receipts = [UUID().uuidString + ":digest": receipt]; rejects("Wrong task namespace rejected")
        seed(); tools.receipts[key]?.id = other; rejects("Wrong actual alarm identity rejected")
        seed(); tools.receipts[key]?.state = "pending"; rejects("Unknown write cannot authorize cleanup")
        seed(); tools.receipts[key]?.result = "已添加 Sela 闹钟：another-alarm · actual-time"; rejects("Other title rejected")
        seed(); tools.readable = false; rejects("Unreadable receipts rejected")
        seed(); manager.authorizationState = .denied; rejects("Missing actual permission rejected")
        seed(); manager.alarms = [.init(id: other, state: .scheduled)]
        let absent = try tools.stopAlarmCardFixtureA09()
        check(absent.contains("未做操作") && manager.stopped.isEmpty, "Absent fixture is a no-op")
        seed(); manager.alarms[0].state = .scheduled; rejects("Scheduled alarms cannot be stopped by this alert-only cleanup")
        seed(); let before = tools.receipts
        let success = try tools.stopAlarmCardFixtureA09()
        check(success.contains("已停止"), "Confirmed stop reports success")
        check(manager.stopped == [id], "Exactly the known fixture ID is stopped once")
        check(manager.alarms.map(\.id) == [other], "Other owned alarm retained")
        check(tools.receipts == before, "Original creation receipts stay immutable")
        seed(); manager.shouldThrow = true
        do { _ = try tools.stopAlarmCardFixtureA09(); preconditionFailure("injected error") }
        catch { check(manager.stopped == [id] && manager.alarms.count == 2, "SDK failure is not retried") }
        seed(); manager.leavesTarget = true
        do { _ = try tools.stopAlarmCardFixtureA09(); preconditionFailure("unconfirmed post-state") }
        catch { check(manager.stopped == [id] && error.localizedDescription.contains("待核对"), "Unknown post-state is not success or a retry") }
        print("Native fixture alarm cleanup: \(count) exact production-guard checks passed; fake SDK only, no device or model")
    }
}
