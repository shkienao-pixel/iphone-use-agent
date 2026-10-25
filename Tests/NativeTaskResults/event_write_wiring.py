"""Assert receipt provenance and commit ordering, without calling EventKit."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / "PhoneAgent/Services/SystemTools.swift").read_text()
pending = source.index('try save(key, Receipt(id: id, state: "pending"')
completed = source.index('try save(key, Receipt(id: id, state: "completed"')
for operation, item, following in [
    ("calendar", "event", "reminder_search"),
    ("reminder", "reminder", "contact_search"),
]:
    start = source.index("        case ." + operation + "_create:\n            guard let calendar")
    end = source.index("        case ." + following + ":", start)
    body = source[start:end]
    save = source.index("try events.save(" + item + ",", start, end)
    receipt = source.index("result = try NativeEventWriteReceipt(operation: ." + operation, start, end)
    assert pending < save < receipt < completed
    assert "Task.checkCancellation()" not in source[save:end]
    assert "systemItemID: " + item + ".calendarItemIdentifier" in body
    assert "collectionID: " + item + ".calendar.calendarIdentifier" in body
    assert "collectionName: " + item + ".calendar.title" in body
    assert item + ".url =" not in body, "Internal bookkeeping must not become a user-visible conference URL"
    assert body.count("try events.save(") == 1
    assert "request.title" not in body, "Creation receipt must use saved SDK title"
assert 'if receipt.state == "completed", let result = receipt.result' in source[:pending]
assert '此操作上次提交结果未确认' in source[:pending]
print("Event write receipt provenance/order checks passed; no EventKit or device invocation")
