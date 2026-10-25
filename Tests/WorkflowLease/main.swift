import Foundation
@main struct WorkflowLeaseChecksMain {
    @MainActor static func main() async throws {
        let report = ProcessInfo.processInfo.environment["WORKFLOW_LEASE_REPORT"].map { URL(fileURLWithPath:$0) }
        let count = try await WorkflowLeaseChecks.run(reportURL:report)
        print("WorkflowLease: \(count) checks passed")
    }
}
