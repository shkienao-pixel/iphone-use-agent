import Foundation

@main struct WakeTimingStandalone {
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let stress = arguments.contains("--stress")
        let rounds = Int(argument("--rounds") ?? "1") ?? 0
        guard (1...50).contains(rounds) else { throw AgentError.message("WakeTiming --rounds must be 1...50") }
        let directory = argument("--report-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("WakeTimingStandalone-" + UUID().uuidString)
        var settings = AgentSettings(); settings.startDelay = 0; settings.stepInterval = 0.4
        PrivacyConsent.grant(settings); defer { PrivacyConsent.revoke() }
        var checks = 0
        for round in 1...rounds {
            checks += try await WakeTimingChecks.run(settings: settings,
                reportDirectory: directory.appendingPathComponent("round-\(round)", isDirectory: true), stressMode: stress)
        }
        print("WakeTiming standalone: \(checks) checks in \(rounds) round(s), stress=\(stress). No phone, BLE or model request was made.")
    }
}
