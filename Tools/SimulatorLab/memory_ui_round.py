#!/usr/bin/env python3
"""Actual native draft provenance and unsaved-memory UI checks; no model."""
import json
import live

title = "Sela测试-记忆来源"
body = "Sela测试-20261025-记忆来源\n这是手动编辑的文件草稿。\n中文、海棠 🌸 和末尾换行。\n"


def snapshot(name):
    shot = live.capture(name)
    return shot, open(shot["tree"]).read()


def memories():
    path = live.container() / "Library/Application Support/PhoneAgent/Memories/memories.json"
    return json.loads(path.read_text())["records"] if path.exists() else []


def main():
    session = json.loads(live.SESSION_FILE.read_text())
    live.ui("launch_sela")
    assert live.read_state()["model_ready"] and live.read_state()["continuous_execution"]
    before = memories()
    live.ui("terminate_sela")
    live.sim("launch", live.DEVICE, live.BUNDLE, "--sela-device-debug", session["appSession"], "--ui-page", "workbench")
    live.ui("activate_app")
    _, tree = snapshot("memory-fix-workbench")
    assert "value: 我的记录" in tree
    live.ui("type_text", identifier="记录标题", elementType="textField", text="\b" * 4 + title)
    live.ui("tap", identifier="收起键盘")
    live.ui("tap", identifier="文件")
    live.ui("swipe_up")
    live.ui("type_text", identifier="可编辑的文件内容", elementType="textField", text=body)
    live.ui("tap", identifier="收起键盘")
    live.ui("tap", identifier="保存成记忆")
    fixed, tree = snapshot("memory-source-fixed")
    assert "来源：记录与文件 · 文件草稿" in tree and "来源：AI 整理" not in tree
    live.ui("tap", identifier="允许在相关任务中引用", elementType="switch")
    live.ui("tap", identifier="取消")
    _, tree = snapshot("memory-unsaved-alert")
    assert "记忆尚未保存" in tree and "继续编辑" in tree and "放弃修改" in tree
    live.ui("tap", identifier="继续编辑")
    continued, tree = snapshot("memory-continued-editing")
    assert "label: '允许在相关任务中引用', value: 0" in tree
    assert memories() == before
    live.ui("tap", identifier="取消")
    live.ui("tap", identifier="放弃修改")
    assert memories() == before
    snapshot("memory-after-discard")
    live.ui("tap", identifier="保存成记忆")
    _, tree = snapshot("memory-reopened-after-discard")
    assert "label: '允许在相关任务中引用', value: 1" in tree
    live.ui("tap", identifier="保存记忆到本机")
    after = memories()
    assert len(after) == len(before) + 1
    new = next(x for x in after if x["title"] == title)
    assert new["text"].encode() == body.strip().encode() and new["source"] == "记录与文件 · 文件草稿" and new["enabled"]
    live.write(live.OUT / "memory-source-save-verification.json", {"correctSourceVisibleAndPersisted": True,
        "matchesExistingOuterWhitespaceNormalization": True, "continueEditingKeptDraft": True, "discardDidNotWrite": True,
        "reopenRestoredInitialValue": True, "newRecord": new, "sourceScreenshot": fixed,
        "continuedScreenshot": continued, "entry": "Existing debug Workbench entry, actual production memory editor/store",
        "realAutomaticLearning": False, "modelInvoked": False})
    print("PASS: truthful native memory source, continue/discard draft handling and saved normalized text")


if __name__ == "__main__":
    main()
