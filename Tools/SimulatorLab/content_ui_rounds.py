#!/usr/bin/env python3
"""Bounded native UI store/clipboard checks; never calls a model or Agent."""
import hashlib
import json
import re
import subprocess
import time

import live


def document():
    path = live.container() / "Library/Application Support/PhoneAgent/phone-content.json"
    return json.loads(path.read_text()) if path.exists() else {"artifacts": [], "preparations": []}


def rss():
    rows = subprocess.check_output(["ps", "-axo", "rss=,args="], text=True)
    return sum(int(row.split(None, 1)[0]) for row in rows.splitlines()
               if live.DEVICE in row and "/PhoneAgent.app/PhoneAgent" in row)


def capture(name):
    result = live.capture(name)
    return result, open(result["tree"]).read()


def start_workbench():
    session = json.loads(live.SESSION_FILE.read_text())
    live.ui("terminate_sela")
    live.sim("launch", live.DEVICE, live.BUNDLE, "--sela-device-debug", session["appSession"], "--ui-page", "workbench")
    live.ui("activate_app")


def create(round_number, title, body):
    start_workbench()
    _, tree = capture(f"round-{round_number}-initial")
    assert "value: 我的记录" in tree
    live.ui("type_text", identifier="记录标题", elementType="textField", text="\b" * 4 + title)
    live.ui("tap", identifier="收起键盘")
    live.ui("tap", identifier="文件")
    live.ui("swipe_up")
    _, tree = capture(f"round-{round_number}-empty")
    assert "label: '可编辑的文件内容', placeholderValue:" in tree
    live.ui("type_text", identifier="可编辑的文件内容", elementType="textField", text=body)
    live.ui("tap", identifier="收起键盘")
    before = document()
    live.ui("tap", identifier="保存当前正文")
    frame, tree = capture(f"round-{round_number}-saved")
    after = document()
    assert len(after["artifacts"]) == len(before["artifacts"]) + 1
    artifact = after["artifacts"][-1]
    assert artifact["title"] == title and artifact["body"].encode() == body.encode(), "Saved input differs; no preparation attempted"
    live.write(live.OUT / f"round-{round_number}-saved.json", artifact)
    return artifact, frame, tree


def prepare(round_number, body, artifact):
    # Saving and preparation are separate, acknowledged user-visible actions.
    live.ui("swipe_up")
    frame, tree = capture(f"round-{round_number}-before-prepare")
    references = re.findall(r"content:[0-9a-f-]{36}:[0-9a-f]{64}", tree)
    assert len(set(references)) == 1, "Copy only a complete real on-screen reference"
    reference = references[0]
    parts = reference.split(":")
    digest = hashlib.sha256(body.encode()).hexdigest()
    assert parts[1].lower() == artifact["id"].lower() and parts[2] == digest == artifact["sha256"]
    before = document()
    live.ui("tap", identifier="准备粘贴这段正文")
    prepared_frame, prepared_tree = capture(f"round-{round_number}-prepared")
    actual = subprocess.check_output(["xcrun", "simctl", "pbpaste", live.DEVICE])
    assert actual == body.encode(), "Independent simulator clipboard differs"
    after = document()
    assert len(after["artifacts"]) == len(before["artifacts"])
    assert len(after["preparations"]) == len(before["preparations"]) + 1
    receipt = after["preparations"][-1]
    assert receipt["artifactReference"] == reference and receipt["state"] == "prepared"
    assert "已在本机准备正文，并核对剪贴板全文" in prepared_tree
    live.write(live.OUT / f"round-{round_number}-prepared.json", {"referenceFromActualUI": reference,
        "independentSavedAndClipboardUTF8Match": True, "sha256": digest, "utf8Bytes": len(actual),
        "receipt": receipt, "screenshot": prepared_frame, "sourceScreenshot": frame,
        "scope": "Production PhoneContentStore and UIKit pasteboard through actual Workbench UI; debug entry; no model/Agent/tool routing or target paste"})
    return reference


def main():
    first = json.loads((live.OUT / "round-1-input.json").read_text())
    fixtures = [first,
        {"title": "Sela测试-本机-2", "body": "Sela测试-20261025-本机正文-2\n组合字符 NFD: Cafe\u0301；NFC: Café。\n保留空行：\n\n海棠 🌸 与家庭 👨‍👩‍👧。\n"},
        {"title": "Sela测试-本机-3", "body": "Sela测试-20261025-本机正文-3\n符号：<source> & \"引号\" '单引号' \\反斜线。\n链接：https://example.com/测试?q=花&n=3#片段\n\n结束。\n"}]
    results = []
    for number, fixture in enumerate(fixtures, 1):
        live.write(live.OUT / f"round-{number}-input.json", fixture)
        before_rss = rss()
        if number == 1:
            artifact = json.loads((live.OUT / "round-1-saved.json").read_text())
            assert document()["artifacts"][-1] == artifact
        else:
            artifact, _, _ = create(number, fixture["title"], fixture["body"])
        reference = prepare(number, fixture["body"], artifact)
        state = live.read_state()
        assert state["phase"] == "idle" and not state["chat_loading"] and not state["tool_pending"]
        result = {"round": number, "artifactID": artifact["id"], "reference": reference,
                  "beforeAppRSSKiB": before_rss, "afterAppRSSKiB": rss(), "engineRemainedIdle": True,
                  "modelExecuted": False, "exactSavedUTF8AndClipboard": True}
        results.append(result)
        live.write(live.OUT / "content-rounds-progress.json", {"passed": len(results), "results": results})
    live.write(live.OUT / "content-rounds-verification.json", {"passed": 3, "results": results,
        "notAcceptanceFor": "Real model tool routing/parameters, SystemToolCoordinator receipts, content_status, target paste/save/send or long-term memory trend"})
    print("PASS: 3 native Workbench save/clipboard rounds with independent UTF-8/SHA256 readback; no model calls")


if __name__ == "__main__":
    main()
