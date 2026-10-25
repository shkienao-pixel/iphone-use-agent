import Foundation

enum AgentError: Error { case message(String) }

/// Host-only, generated non-sensitive records. This measures the real local
/// store transaction and fsync path, not phone navigation or model latency.
@main struct WorkflowDiagnosticsBenchmark {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-diagnostics-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = 3, observations = 96, retained = 64
        var samples: [Double] = [], finalCounts: [Int] = [], indexBytes: [Int] = []
        for run in 0..<runs {
            var policy = WorkflowDiagnosticsPolicy.default
            policy.maximumRecords = retained
            let directory = root.appendingPathComponent("run-\(run)")
            let store = WorkflowDiagnosticsStore(directory: directory, policy: policy)
            guard store.error == nil else { throw WorkflowDiagnosticsError.unavailable }
            let captureID = UUID()
            let start = ProcessInfo.processInfo.systemUptime
            for observation in 0..<observations {
                let now = Date()
                let elements = (0..<24).map { index in
                    PhoneUIElement(id: "generated.\(observation).\(index)",
                        label: "Synthetic record \(observation), row \(index): " + String(repeating: "non-sensitive data ", count: 4),
                        rect: .init(x: 0.1, y: 0.08 + Double(index) * 0.03, width: 0.7, height: 0.02), source: "ocr")
                }
                let snapshot = PhoneUISnapshot(deviceKey: "generated-benchmark-device", scene: "benchmark.synthetic",
                    elements: elements, capturedAt: now, blockingOverlay: false)
                _ = try store.record(jpeg: Data(), context: .init(workflowID: "synthetic-benchmark", boundary: .observed,
                    captureID: captureID, capturedAt: now, confirmedAt: now, snapshot: snapshot))
            }
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            finalCounts.append(store.records.count)
            indexBytes.append(try Data(contentsOf: directory.appendingPathComponent("index.json")).count)
            guard store.records.count == retained,
                  WorkflowDiagnosticsStore(directory: directory).records == store.records else {
                throw WorkflowDiagnosticsError.invalidArchive
            }
        }
        let sorted = samples.sorted()
        let result: [String: Any] = ["schema": 1, "scope": "host-only synthetic metadata transactions with atomic index and fsync",
            "phoneAcceptance": false, "modelCalls": 0, "buildOptimization": "-O", "runs": runs,
            "observationsPerRun": observations, "elementsPerObservation": 24, "retainedRecords": retained,
            "milliseconds": samples, "medianMilliseconds": sorted[sorted.count / 2],
            "finalRecordCounts": finalCounts, "finalIndexBytes": indexBytes,
            "host": ProcessInfo.processInfo.operatingSystemVersionString]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
