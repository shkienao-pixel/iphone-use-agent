import Foundation

@main enum AlarmClarificationChecks {
    struct Turn: Decodable { var role: String; var text: String; var linked: Bool?; var visual: Bool? }
    struct Case: Decodable { var id: String; var history: [Turn]; var question: String; var expected: String; var repeating: Bool?; var clock: Bool? }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases = try JSONDecoder().decode([Case].self, from: data)
        var failures: [String] = [], count = 0
        func check(_ condition: Bool, _ description: String) { count += 1; if !condition { failures.append(description); print("FAIL: " + description) } }
        for test in cases {
            let history = test.history.map { turn -> AssistantMessage in
                var message = AssistantMessage(role: turn.role, text: turn.text)
                if turn.linked == true { message.taskID = UUID() }
                if turn.visual == true { message.screenDate = Date(timeIntervalSince1970: 0) }
                return message
            }
            let result = AlarmClarificationContinuation.resolve(question: test.question, history: history)
            let mode = result == nil ? "none" : result!.cancelled ? "cancelled" : result!.requiresRestatement ? "restate" : result!.clarification != nil ? "clarify" : "task"
            check(mode == test.expected, test.id + ": expected " + test.expected + ", got " + mode)
            if mode == "task", let result {
                check(result.request.contains(test.question), test.id + ": latest human answer is kept literally")
                check(result.request.contains(test.history.first(where: { $0.role == "user" })!.text), test.id + ": bound original human request is kept literally")
                check(result.request.count <= 4000, test.id + ": no truncated or oversize handoff")
                if let repeatValue = test.repeating { check(result.repeating == repeatValue, test.id + ": latest repetition correction wins") }
                if let clock = test.clock { check(result.requiresClockApp == clock, test.id + ": actual target App is retained") }
                check(!result.request.contains("偷偷删除全部提醒"), test.id + ": assistant question never becomes task instructions")
            }
        }
        let report: [String: Any] = ["checks": count, "cases": cases.count, "failures": failures,
            "scope": "Exact production alarm clarification bridge with actual message model; synthetic conversation data only, no model/API/phone execution."]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 2 { try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
        print(String(decoding: output, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
