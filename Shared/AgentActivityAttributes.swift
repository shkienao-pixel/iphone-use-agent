import Foundation
import ActivityKit

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var step: Int
        var updatedAt: Date
        // Optional fields let an older, still-visible activity decode without
        // accidentally acquiring control authority after an app update.
        var controlSessionID: UUID? = nil
        var canPause: Bool? = nil
        var canStop: Bool? = nil
        var completed: Bool? = nil
        var phase: String? = nil
        var taskTitle: String? = nil
        /// The current display target may change while the immutable activity
        /// attributes still point to its originating request. This grants links,
        /// never button authority, to an in-process background handoff.
        var displayTaskID: UUID? = nil
        /// Explicit presentation-only preview: never a saved or running task.
        var isPreview: Bool? = nil
    }
    var taskID: UUID
}
