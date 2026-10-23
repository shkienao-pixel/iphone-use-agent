import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError("Model history check failed: \(message)") }
    checks += 1
}

func event(_ step: Int, _ title: String, _ detail: String) -> AgentLogEntry {
    AgentLogEntry(step: step, title: title, detail: detail)
}

func instruction(_ history: [AgentLogEntry]) -> String {
    // The production request uses this same instruction builder before JSON
    // serialization. No model, credential or transport is used by these checks.
    ModelHistoryContext.instruction(task: "新建并核对备忘录", width: 591, height: 1280,
        history: history, formatRetry: true, memoryContext: "历史仅参考",
        harnessContext: #"{"scene":"notes"}"#)
}

let operations = [
    event(1, "手机工具", "打开备忘录"),
    event(1, "手机工具回执", "已打开备忘录列表"),
    event(2, "点击", "新建空白备忘录"),
    event(3, "按键 paste", "在空白正文粘贴准备的全文"),
    event(4, "点击", "实际正文已显示，完成编辑"),
    event(5, "补充要求", "保留官方来源，不要重建备忘录"),
    event(6, "工具回执", "已保存本机任务进展"),
    event(7, "子任务确认完成", "标题和正文已核对"),
    event(8, "本地布局需重新观察", "返回入口被遮挡；点击未发送"),
    event(9, "停止", "蓝牙连接已变化，上一步可能部分执行"),
    event(9, "恢复任务", "先核对实际内容，不重放粘贴"),
    event(10, "工具任务中断", "工具拒绝了未授权的写入"),
    event(11, "模型回复诊断", "无效回复没有执行"),
    event(12, "点击", "重新打开唯一标题核对保存")
]
let noise = ["本地布局耗时", "模型耗时", "手机工具耗时", "取屏耗时", "输入执行耗时", "复用已核对画面", "等待最新画面", "唤醒最新画面", "画面已恢复"]
var noisy: [AgentLogEntry] = []
for operation in operations {
    noisy.append(operation)
    for title in noise { noisy.append(event(operation.step, title, "仅诊断，不是任务进展")) }
}
for index in 0..<100 { noisy.append(event(12, noise[index % noise.count], "尾部诊断 \(index)")) }
let cleanInstruction = instruction(operations)
let noisyInstruction = instruction(noisy)
check(noisyInstruction == cleanInstruction, "noise injection must not alter the actual model instruction")
check(ModelHistoryContext.recentEntries(noisy).map(\.id) == operations.map(\.id),
      "actions, receipts, progress, amendment and failure must remain in original order")
for operation in operations {
    check(noisyInstruction.contains(operation.detail), "missing semantic detail: \(operation.title)")
}
for title in noise { check(!noisyInstruction.contains(title), "diagnostic leaked into history: \(title)") }
check(noisyInstruction.contains("无效回复没有执行"), "format failure must remain distinguishable from executed input")
check(noisyInstruction.contains("历史仅参考") && noisyInstruction.contains(#"{"scene":"notes"}"#),
      "memory and harness context survive the builder extraction")

// Keep action/receipt pairs for the latest twelve decisions, rather than just
// the latest twelve log rows. Earlier decisions still have a bounded window.
let paired = (1...20).flatMap { step in
    [event(step, "手机工具", "动作 \(step)"), event(step, "手机工具回执", "结果 \(step)")]
}
let selected = ModelHistoryContext.recentEntries(paired)
check(selected.count == 24, "latest twelve decisions retain both actions and receipts")
check(selected.first?.step == 9 && selected.last?.step == 20, "older decisions leave the history window")
check(selected.map(\.detail) == paired.suffix(24).map(\.detail), "history remains chronological")
let crowded = (1...100).map { event(1, "新业务事件", "同一步进展 \($0)") }
check(ModelHistoryContext.recentEntries(crowded).count == 36, "single-step event volume is bounded")
check(ModelHistoryContext.recentEntries(crowded).last?.detail == "同一步进展 100", "unknown event types are preserved")
let longEntry = instruction([event(1, "工具回执", String(repeating: "文", count: 4001))])
check(longEntry.contains("不可推断缺失内容"), "large receipts retain an explicit truncation notice")

// Replay a repository-owned simulation on every run. Its paste at step 6 must
// survive to step 16 despite wake/frame polling around every step. This fixture
// is synthetic test data, not a recording or evidence of phone execution.
struct ReplayFixture: Decodable {
    struct Log: Decodable {
        let step: Int
        let title: String
        let detail: String
    }
    let logs: [Log]
}
guard CommandLine.arguments.count == 2,
      let path = CommandLine.arguments.dropFirst().first,
      FileManager.default.fileExists(atPath: path) else {
    fatalError("Supply an existing model history replay fixture; replay checks cannot be skipped")
}
let fixture = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let replayLogs = fixture.logs.map { event($0.step, $0.title, $0.detail) }
let replayInstruction = instruction(replayLogs)
check(replayInstruction.contains("6: 按键 paste"), "simulated Notes replay retains the issued paste at step 6")
check(replayInstruction.contains("模拟：正文已显示且键盘已收起"), "simulated Notes replay retains the paste-result event")
check(replayInstruction.contains("模拟：正文及示例来源链接可见"), "simulated Notes replay retains final verification event")
check(!replayInstruction.contains("唤醒最新画面"), "simulated Notes replay excludes pointer wake diagnostics")

print("PASS: \(checks) model history checks")
