"""Check that stored display snapshots never gain task recovery controls."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
view = (root / "PhoneAgent/Views/ConversationTaskCard.swift").read_text()
saved = view[view.index("} else if let savedResult,"):view.index('Label("任务记录暂不可用"')]
for action in ("Button(", "retryTask(", "continueTask(", "stopTask(", "startAgent(", "bookFlight("):
    assert action not in saved, action
assert "NativeTaskResultCards(results: savedResult.results)" in saved
assert "savedResult.taskID == taskID, savedResult.valid" in saved
assert "历史结果" in saved
screen = (root / "PhoneAgent/Views/AssistantViews.swift").read_text()
assert "ConversationTaskCard(taskID: taskID, savedResult: message.nativeTaskResult)" in screen
vm = (root / "PhoneAgent/PhoneAgentViewModel.swift").read_text()
assert "conversation.retainTaskResult(record.nativeConversationSnapshot)" in vm
assert "stride(from: 0, to: history.records.count, by: 50)" in vm
assert "conversation.retainTaskResults(batch.map(\\.nativeConversationSnapshot))" in vm
assert "history.records.prefix(50)" not in vm
snapshot = (root / "Shared/NativeTaskResult.swift").read_text().split("struct NativeTaskSnapshot:", 1)[1]
for field in ("let goal:", "let logs:", "let checkpointStep:", "let token:", "let executionLane:"):
    assert field not in snapshot, field
print("Conversation snapshot wiring: existing message identity, startup backfill and display-only fallback verified; no UI/device acceptance")
