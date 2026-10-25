"""Three bounded native-notification fixture rounds; no business/model execution."""
import json
from pathlib import Path
import subprocess
import time

from .live import DEVICE, OUT, capture, command, read_state, ui, write


def activate():
    ui("activate_app")
    for _ in range(40):
        state = read_state()
        if state["active"]:
            return state
        time.sleep(0.2)
    raise RuntimeError("App did not become active; inspect current UI before replaying any fixture")


def app_rss():
    value = 0
    for row in subprocess.check_output(["ps", "-axo", "rss=,args="], text=True).splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and DEVICE in fields[1] and "/PhoneAgent.app/PhoneAgent" in fields[1]:
            value += int(fields[0])
    return value


def main():
    activate()
    initial = command("notification_status")["notification_checks"]
    assert initial["enabled"] and "已允许" in initial["authorization"]
    results = []
    for index in range(1, 4):
        if index > 1:
            activate()
        before_rss = app_rss()
        command("notification_fixture", "background_A")
        ui("home")
        time.sleep(4)
        image = capture("notification-round-" + str(index) + "-banner", bundle="com.apple.springboard")
        tree = Path(image["tree"]).read_text()
        assert "任务已完成" in tree and "海棠通知 A" in tree, "Actual OS banner was not observed"
        activate()
        state = command("notification_status")
        actual = state["notification_checks"]
        assert not state["model_ready"] and state["phase"] == "idle" and not state["chat_loading"]
        assert not actual["pending"] and actual["delivered"] == [actual["lastSubmittedID"]]
        assert actual["reservations"] == initial["reservations"] + index
        command("notification_fixture", "repeat_last")
        repeated = command("notification_status")["notification_checks"]
        assert actual == repeated, "Repeated state publication changed notification receipts"
        result = {"round": index, "scope": "Production policy, durable reservation, OS delivery and real banner using fixed synthetic task data",
                  "engineExecuted": False, "bannerObserved": True, "eightRepeatedUpdatesDidNotDuplicate": True,
                  "notification": actual, "beforeAppRSSKiB": before_rss, "afterAppRSSKiB": app_rss()}
        write(OUT / ("notification-round-" + str(index) + ".json"), result)
        results.append(result)
        print(json.dumps({"round": index, "delivered": 1, "newReservation": 1, "duplicate": False}, ensure_ascii=False), flush=True)
    assert len({r["notification"]["lastSubmittedID"] for r in results}) == 3
    write(OUT / "notification-rounds-verification.json", {"passed": 3, "rounds": results,
          "notAcceptanceFor": "Real model conversation/tool calls or real task execution"})


if __name__ == "__main__":
    main()
