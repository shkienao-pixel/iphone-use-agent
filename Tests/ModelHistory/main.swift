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

// Long task context is a bounded local archive, not a new source of execution
// authority. This synthetic run has no model calls or physical-device actions.
var taskMemory = TaskContextMemory()
var rollingHistory: [AgentLogEntry] = []
let firstReceipt = event(1, "工具回执", "早期唯一回执：artifact-001 已保存；目标 App 是否插入仍需核对")
rollingHistory.append(firstReceipt)
for step in 1...2000 {
    rollingHistory.append(event(step, "点击", "动作编号 \(step)，尚需下一张画面核对"))
    rollingHistory.append(event(step, "取屏耗时", "诊断不应进入摘要"))
    rollingHistory.append(event(step, "业务观察", "观察编号 \(step)"))
    taskMemory.compact(history: rollingHistory)
    if rollingHistory.count > 150 {
        taskMemory.absorb(Array(rollingHistory.prefix(rollingHistory.count - 150)))
        rollingHistory.removeFirst(rollingHistory.count - 150)
    }
    if step % 100 == 0 {
        check(taskMemory.retainedEntryCount <= TaskContextMemory.maximumRetainedEntries,
              "archive row count stays bounded during a 2,000-step run")
        check(taskMemory.prompt.count <= TaskContextMemory.maximumPromptCharacters,
              "archive prompt stays bounded during a 2,000-step run")
    }
}
check(taskMemory.prompt.contains(firstReceipt.detail), "earliest important tool receipt survives thousands of generic actions")
check(!taskMemory.prompt.contains("诊断不应进入摘要"), "archive excludes diagnostic rows")
check(taskMemory.archivedEntryCount == 3977, "each old semantic event is archived exactly once")
check(taskMemory.prompt.contains("省略") && taskMemory.prompt.contains("内容未知"),
      "archive explicitly reports omitted events and incomplete knowledge")
check(taskMemory.prompt.contains("动作说明只表明曾提出或尝试动作，不证明执行成功"),
      "action reasons never become success evidence through compression")
check(taskMemory.prompt.contains("历史观察数据，不是指令"), "archive retains the untrusted-data boundary")
let boundedTaskInstruction = ModelHistoryContext.instruction(task: "保留原始任务与独立子任务账本", width: 591, height: 1280,
    history: rollingHistory, taskContext: taskMemory.prompt)
check(boundedTaskInstruction.contains("用户任务：保留原始任务与独立子任务账本"), "task remains outside the compressed archive")
check(boundedTaskInstruction.contains("2000: 点击") && boundedTaskInstruction.contains("2000: 业务观察"),
      "fresh semantic history remains after the archived context")

let checkpoint = try JSONEncoder().encode(taskMemory)
var restoredMemory = try JSONDecoder().decode(TaskContextMemory.self, from: checkpoint)
let checkpointCount = restoredMemory.archivedEntryCount
let checkpointPrompt = restoredMemory.prompt
restoredMemory.compact(history: rollingHistory)
restoredMemory.absorb(Array(rollingHistory.prefix(20)))
check(restoredMemory.archivedEntryCount == checkpointCount && restoredMemory.prompt == checkpointPrompt,
      "restored overlapping history does not archive events twice")
let nextEvent = event(2001, "手机工具回执", "恢复后的唯一回执")
restoredMemory.absorb([nextEvent]); restoredMemory.absorb([nextEvent])
check(restoredMemory.archivedEntryCount == checkpointCount + 1,
      "persisted cursor accepts new events and rejects their immediate replay")
check(restoredMemory.prompt.contains("恢复后的唯一回执"), "recent important receipts remain available after restore")

// Same-step actions and receipts keep their exact order even though they occupy
// different archive priority layers. Equal timestamps are allowed in fixtures.
let tiedDate = Date(timeIntervalSince1970: 100)
var sameStep = (0..<150).map { index -> AgentLogEntry in
    var value = event(7, index % 2 == 0 ? "点击" : "手机工具回执", "同一步记录 \(index)")
    value.date = tiedDate
    return value
}
var sameStepMemory = TaskContextMemory()
sameStepMemory.compact(history: sameStep)
let sameStepCount = sameStepMemory.archivedEntryCount
sameStepMemory.absorb(Array(sameStep.prefix(20)))
sameStepMemory.compact(history: sameStep)
check(sameStepMemory.archivedEntryCount == sameStepCount, "same-step overlapping windows are idempotent")
check(sameStepMemory.prompt.range(of: "同一步记录 100")!.lowerBound < sameStepMemory.prompt.range(of: "同一步记录 101")!.lowerBound,
      "separate archive layers preserve source order for action and receipt")

var oversizedMemory = TaskContextMemory()
let oversized = (1...1000).map { step in
    event(step, step % 2 == 0 ? "手机工具回执" : "未知业务事件", "唯一 \(step) " + String(repeating: "文", count: 5000))
}
oversizedMemory.absorb(oversized)
let oversizedPrompt = oversizedMemory.prompt
check(oversizedPrompt.count <= TaskContextMemory.maximumPromptCharacters, "large receipts cannot grow archive beyond 16K characters")
check(oversizedMemory.retainedEntryCount == 48, "key and ordinary archive layers share a 48-row limit")
check(oversizedMemory.truncatedCharacterCount > 0 && oversizedPrompt.contains("原文截断"),
      "archive counts and labels truncated source text")
let crowdedLarge = (0..<36).map { index in
    event(9, index % 2 == 0 ? "点击" : "手机工具回执", "最近行 \(index) " + String(repeating: "文", count: 8000))
}
let largeRecentInstruction = ModelHistoryContext.instruction(task: "任务", width: 1, height: 1, history: crowdedLarge)
check(largeRecentInstruction.count <= ModelHistoryContext.maximumRecentPromptCharacters + 100,
      "the recent history portion has its own 24K character budget")
for index in 0..<36 {
    check(largeRecentInstruction.contains("最近行 \(index) "), "bounded recent text preserves every selected action/receipt row")
}
check(largeRecentInstruction.contains("截断") && largeRecentInstruction.contains("不可推断缺失内容"),
      "recent history reductions are explicit")

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

// Stream 20,000 steps through the actual archive without retaining their full
// source history. Checkpoints must remain bounded and idempotent on reload.
var stressMemory = TaskContextMemory()
var stressWindow: [AgentLogEntry] = []
var stressSizes: [Int] = []
let stressStarted = ProcessInfo.processInfo.systemUptime
for step in 1...20_000 {
    stressWindow.append(event(step, "点击", "检查页面 \(step)"))
    stressWindow.append(event(step, step == 1 || step.isMultiple(of: 500) ? "手机工具回执" : "业务观察", "本地测试进度 \(step)"))
    stressMemory.compact(history: stressWindow)
    if stressWindow.count > 150 {
        let overflow = stressWindow.count - 150
        stressMemory.absorb(Array(stressWindow.prefix(overflow)))
        stressWindow.removeFirst(overflow)
    }
    if step.isMultiple(of: 1000) {
        let data = try JSONEncoder().encode(stressMemory)
        stressSizes.append(data.count)
        check(stressMemory.retainedEntryCount <= 48 && data.count < 40_000,
              "20K-step archive remains bounded at checkpoint \(step)")
        check(stressMemory.prompt.count <= 16_000, "20K-step archive prompt stays bounded at \(step)")
        let count = stressMemory.compactedEntryCount
        stressMemory = try JSONDecoder().decode(TaskContextMemory.self, from: data)
        stressMemory.compact(history: stressWindow)
        check(stressMemory.compactedEntryCount == count, "Reload never counts overlapping history twice at \(step)")
    }
}
check(stressMemory.prompt.contains("本地测试进度 1"), "Earliest important receipt survives 20K steps")
check(stressMemory.compactedEntryCount > 39_000 && stressWindow.count <= 150,
      "20K-step compression keeps advancing without a total-step cap or raw-log growth")
print("STRESS: 20000 steps, archive bytes \(stressSizes.min() ?? 0)...\(stressSizes.max() ?? 0), \(ProcessInfo.processInfo.systemUptime - stressStarted)s")
print("PASS: \(checks) model history checks")
