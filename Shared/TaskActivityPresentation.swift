enum TaskActivityPresentation {
    static func label(phase: String?, isStale: Bool) -> String {
        if isStale { return "待核对" }
        switch phase {
        case "preparing": return "Prepare"
        case "acting": return "Working"
        case "awaitingApproval": return "Confirm"
        case "needsUser": return "Your turn"
        case "paused": return "Paused"
        case "completed": return "Done"
        case "failed": return "Error"
        case "stopped": return "Stopped"
        case "idle", "preview": return "Ready"
        default: return "Thinking"
        }
    }

    static func portraitPhase(phase: String?, isStale: Bool) -> String {
        // Staleness needs its own static mark; it must not look like an active
        // task waiting for user input, or keep a completed/working badge.
        isStale ? "stale" : (phase ?? "thinking")
    }
}
