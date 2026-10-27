import Foundation
enum TaskOutcome: String { case running, paused, needsUser, completed, failed, stopped, preview; var label: String { rawValue } }
enum AgentPhase: String {
    case idle, preparing, observing, acting, awaitingApproval, paused, needsUser, completed, failed, stopped, preview
    var outcome: TaskOutcome { TaskOutcome(rawValue: rawValue) ?? .running }
}
struct PhoneTaskRecord { let id: UUID; let title: String }
