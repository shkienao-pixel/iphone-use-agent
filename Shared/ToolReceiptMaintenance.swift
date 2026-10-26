import Foundation

/// A synchronous snapshot supplied by the task host. It carries no execution
/// authority and is used only while the MainActor prevents another dispatch.
struct ToolReceiptMaintenanceContext {
    let protectedTaskIDs: Set<UUID>
    let executionInFlight: Bool
    let taskStorageAvailable: Bool
}

struct ToolReceiptCleanupResult {
    let removed: Int
    let retained: Int
}

/// Task checkpoints, display history and idempotency receipts have different
/// lifetimes. Maintenance must never erase a resumable or uncertain operation.
enum ToolReceiptMaintenancePolicy {
    static func blockedReason(context: ToolReceiptMaintenanceContext, approvalPending: Bool,
                              receiptsReadable: Bool) -> String? {
        if approvalPending { return "请先结束当前工具确认，再清理回执" }
        if context.executionInFlight { return "请先暂停或结束正在执行的任务，再清理回执" }
        if !context.taskStorageAvailable || !receiptsReadable {
            return "任务或回执记录暂时不可读，已保留原文件；请先导出并处理存储问题"
        }
        return nil
    }

    static func mayRemove(key: String, state: String, context: ToolReceiptMaintenanceContext) -> Bool {
        guard state == "completed", let boundary = key.firstIndex(of: ":"),
              let taskID = UUID(uuidString: String(key[..<boundary])) else { return false }
        return !context.protectedTaskIDs.contains(taskID)
    }
}
