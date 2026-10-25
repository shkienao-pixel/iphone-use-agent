"""Real OS notification cold-start regression, bounded to three synthetic records."""
import json
from pathlib import Path
import subprocess
import time

from .live import DEVICE, OUT, capture, command, read_state, ui, write
from .notification_open import open_center, swipe_notification
from .notification_rounds import activate


def app_pids():
    result = []
    for line in subprocess.check_output(["ps", "-axo", "pid=,args="], text=True).splitlines():
        row = line.strip().split(None, 1)
        if len(row) == 2 and DEVICE in row[1] and "/PhoneAgent.app/PhoneAgent" in row[1]:
            result.append(int(row[0]))
    return result


def main():
    results = []
    for index, letter in enumerate(["A", "B", "A"], 1):
        launched = time.time()
        ui("launch_sela")
        for _ in range(40):
            state = read_state()
            if state["active"] and state["date"] > launched:
                break
            time.sleep(0.2)
        assert state["phase"] == "idle" and not state["model_ready"] and state["notification_enabled"]
        command("notification_fixture", "background_" + letter)
        ui("home")
        time.sleep(4)
        banner = capture("cold-" + str(index) + "-banner", bundle="com.apple.springboard")
        assert "海棠通知 " + letter in Path(banner["tree"]).read_text()
        activate()
        status = command("notification_status")["notification_checks"]
        assert status["lastSubmittedID"] in status["delivered"]
        if letter == "A":
            command("notification_fixture", "prepare_B")
        previous = app_pids()
        assert len(previous) == 1
        ui("terminate_sela")
        assert not app_pids(), "App must actually exit before the OS notification launch"
        label = "cold-" + str(index)
        trace = swipe_notification(label, "海棠通知 " + letter, open_center(label))
        # No activate/launch calls are permitted here: only the notification may
        # create the new App process. Give state restoration time to finish.
        seen = []
        stable_since = None
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            current = app_pids()
            if current and set(current).isdisjoint(previous):
                if current != seen:
                    seen = current; stable_since = time.monotonic()
                elif time.monotonic() - stable_since >= 3:
                    break
            else:
                stable_since = None
            time.sleep(0.2)
        assert seen and stable_since and time.monotonic() - stable_since >= 3, "Notification launch did not leave a stable new process"
        shot = capture(label + "-opened")
        tree = Path(shot["tree"]).read_text()
        assert "海棠通知 " + letter + "：仅核验系统通知及任务跳转" in tree
        assert "海棠通知 " + letter + " · 通知展示夹具已结算" in tree
        result = {"round": index, "target": letter, "AppTerminatedBeforeTap": True,
                  "oldPIDs": previous, "newPIDs": seen, "notificationOnlyLaunchedNewProcess": True,
                  "correctTaskUI": True, "trace": trace, "screenshot": shot,
                  "scope": "Actual OS notification response and cold saved-task UI; synthetic task fixture, no model or business engine execution"}
        write(OUT / (label + "-verification.json"), result)
        results.append(result)
        print(json.dumps({"coldRound": index, "opened": letter, "newProcess": seen, "passed": True}), flush=True)
    write(OUT / "cold-start-verification.json", {"passed": 3, "results": results,
          "regression": "No UIKit state-restoration SIGABRT after completion-handler callbacks were moved to MainActor"})


if __name__ == "__main__":
    main()
