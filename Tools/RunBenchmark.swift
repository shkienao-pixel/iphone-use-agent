import Foundation

/// Reads every exported attempt; malformed files fail the report rather than
/// silently disappearing from the success denominator.
@main struct RunBenchmarkTool {
    enum InputError: Error { case usage }
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Benchmark report was not generated: check arguments and every input record. No unreadable attempt was silently excluded.\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 4 else {
            print("Usage: run-benchmark before-directory after-directory output.json")
            throw InputError.usage
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func read(_ path: String) throws -> [AgentRunMetrics] {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try urls.map { try decoder.decode(AgentRunMetrics.self, from: Data(contentsOf: $0)) }
        }
        let before = try read(CommandLine.arguments[1]), after = try read(CommandLine.arguments[2])
        struct Report: Codable {
            var generatedAt = Date()
            var beforeAttempts: [AgentRunMetrics]
            var afterAttempts: [AgentRunMetrics]
            var comparison: RunBenchmarkComparison
        }
        let result = RunBenchmarkComparison.compare(before: before, after: after)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Report(beforeAttempts: before, afterAttempts: after, comparison: result))
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        print("Evidence: \(result.before.executionKind.rawValue) → \(result.after.executionKind.rawValue)")
        print("Before: n=\(result.before.samples), median=\(result.before.medianSeconds)s, range=\(result.before.minimumSeconds)...\(result.before.maximumSeconds)s, verified=\(result.before.verifiedSuccesses)/\(result.before.samples)")
        print("After: n=\(result.after.samples), median=\(result.after.medianSeconds)s, range=\(result.after.minimumSeconds)...\(result.after.maximumSeconds)s, verified=\(result.after.verifiedSuccesses)/\(result.after.samples)")
        print("Comparable scope: \(result.comparable); correctness accepted: \(result.correctnessAccepted); eligible for device acceptance: \(result.eligibleForDeviceAcceptance)")
        for reason in result.unavailableReasons { print("Unavailable: " + reason) }
        print(result.interpretation)
    }
}
