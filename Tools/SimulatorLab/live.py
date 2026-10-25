#!/usr/bin/env python3
"""Local operator transport for the dedicated simulator. Never prints credentials."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
OUT = (ROOT / os.environ.get("SELA_TEST_OUTPUT", "output/simulator-live-model-20261025")).resolve()
if not OUT.is_relative_to(ROOT / "output"):
    raise RuntimeError("Test artifacts must stay inside this workspace output directory")
PRIMARY_DEVICE = "911137A1-574C-4CAF-B1C2-062E268C95A3"
DEVICE = PRIMARY_DEVICE
BUNDLE = "com.example.phoneagent"
SESSION_FILE = OUT / "active-session.json"
if os.environ.get("SELA_ACTIVITY_LAB") == "1":
    activity_lab = json.loads((OUT / "island-environment.json").read_text())
    if activity_lab.get("name") != "Sela Island Lab - iPhone 17 Pro":
        raise RuntimeError("Unexpected activity fixture destination")
    DEVICE = activity_lab["udid"]
    SESSION_FILE = OUT / "island-session.json"


def sim(*args):
    result = subprocess.run(["xcrun", "simctl", *map(str, args)], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError("simctl operation failed, exit=" + str(result.returncode))
    return result.stdout.strip()


def credential():
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        for line in (ROOT / ".env.local").read_text().splitlines():
            match = re.match(r"^\s*(?:export\s+)?OPENAI_API_KEY\s*=\s*(.*?)\s*$", line)
            if match:
                parts = shlex.split(match.group(1), comments=True)
                key = parts[0] if parts else ""
                break
    if not key or len(key) > 4096 or not all(33 <= ord(c) <= 126 for c in key):
        raise RuntimeError("Existing credential is missing or malformed; no value was logged")
    return key


def safe(value):
    # Provider error messages can include a credential fragment on HTTP 401.
    if isinstance(value, str):
        return re.sub(r"sk-[A-Za-z0-9_.-]{5,}", "[credential omitted]", value)
    if isinstance(value, dict):
        return {k: safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [safe(v) for v in value]
    return value


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(safe(value), ensure_ascii=False, indent=2) + "\n")
    temp.replace(path)


def container():
    return Path(sim("get_app_container", DEVICE, BUNDLE, "data"))


def read_state():
    session = json.loads(SESSION_FILE.read_text())
    state = json.loads((container() / "Documents/SelaDeviceDebug/state.json").read_text())
    if state.get("session") != session["appSession"]:
        raise RuntimeError("App debug session mismatch; do not resend a pending operation")
    if abs(time.time() - state.get("date", 0)) > 15:
        raise RuntimeError("App state is stale; inspect its current process before restarting")
    return safe(state)


def ui_root():
    return Path(sim("get_app_container", DEVICE, "com.example.sela.simulatorlive.xctrunner", "data")) / "Documents/NativeAcceptance"


def ui(operation, timeout=55, **fields):
    session = json.loads(SESSION_FILE.read_text())
    processes = subprocess.check_output(["ps", "-axo", "args="], text=True)
    prefix = Path.home() / "Library/Developer/CoreSimulator/Devices" / DEVICE / "data/Containers/Bundle/Application"
    container_id = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
    # ps also contains shells/scripts that quote this path. Match the actual
    # executable at the beginning of argv, before reading or writing UI files.
    executable = re.compile(r"^" + re.escape(str(prefix)) + "/" + container_id +
        r"/SimulatorLiveOperatorUITests-Runner\.app/SimulatorLiveOperatorUITests-Runner(?:\s|$)")
    if not any(executable.match(row.strip()) for row in processes.splitlines()):
        raise RuntimeError("UI operator has ended; start a fresh test session before writing commands")
    root = ui_root()
    ready = json.loads((root / "ready.json").read_text())
    if ready.get("session") != session["uiSession"] or not ready.get("ready"):
        raise RuntimeError("UI operator session mismatch")
    path = root / "command.json"
    if path.exists():
        raise RuntimeError("An unconsumed UI command exists; inspect before issuing another")
    token = str(uuid.uuid4()).upper()
    payload = {"id": token, "session": session["uiSession"], "operation": operation,
               "expiresAt": time.time() + 60, **fields}
    write(path, payload)
    result_path = root / ("result-" + token + ".json")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result_path.exists():
            result = safe(json.loads(result_path.read_text()))
            write(OUT / "ui-events" / (token + ".json"), {"operation": operation, "result": result})
            if not result.get("ok"):
                raise RuntimeError("UI operator rejected command: " + str(result.get("error", "unknown")))
            return result
        time.sleep(0.15)
    raise RuntimeError("UI acknowledgment timed out; inspect its current handle/state before retrying")


def capture(name, bundle=None):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", name):
        raise RuntimeError("Invalid snapshot name")
    result = ui("snapshot", **({"bundle": bundle} if bundle else {}))
    root = ui_root()
    destination = OUT / "screenshots"
    destination.mkdir(exist_ok=True)
    import shutil
    shutil.copy2(root / result["image"], destination / (name + ".png"))
    shutil.copy2(root / result["tree"], destination / (name + ".txt"))
    return {"image": str(destination / (name + ".png")), "tree": str(destination / (name + ".txt")), "frameID": result["frameID"]}


def command(operation, value=None, timeout=15):
    session = json.loads(SESSION_FILE.read_text())
    root = container() / "Documents/SelaDeviceDebug"
    path = root / "command.json"
    if path.exists():
        raise RuntimeError("An unconsumed App command exists; inspect it before issuing another")
    token = str(uuid.uuid4())
    payload = {"id": token, "session": session["appSession"], "operation": operation, "expiresAt": time.time() + 12}
    if value is not None:
        payload["value"] = value
    write(path, payload)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = read_state()
            if state.get("command") == token:
                write(OUT / "operator-events" / (token + ".json"), {"operation": operation, "state": state})
                if state.get("error"):
                    raise RuntimeError("App rejected operator command: " + state["error"])
                return state
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    raise RuntimeError("No command acknowledgment; inspect the real state before any retry")


def verify_import():
    if DEVICE != PRIMARY_DEVICE:
        raise RuntimeError("Credential authorization is limited to the primary simulator")
    root = container()
    receipt = json.loads((root / "Documents/model-config-import.receipt.json").read_text())
    state = read_state()
    if not (receipt.get("credentialVerified") and receipt.get("sourceRemoved") and state.get("model_ready")):
        raise RuntimeError("Import has not passed independent Keychain readback")
    if not state.get("continuous_execution"):
        raise RuntimeError("Credential import changed or disabled the expected long-task policy")
    removed = not (root / "Documents/model-config.once.json").exists()
    if not removed:
        raise RuntimeError("Plaintext provisioning payload cleanup is incomplete")
    write(OUT / "keychain-import.json", {"receipt": receipt, "state": state,
          "destination": "Dedicated simulator Sela Keychain", "plaintextPayloadRemoved": removed})
    lab = ROOT / "output/simulator-lab/environment.json"
    metadata = json.loads(lab.read_text())
    metadata.update({"mode": "live OpenAI integration; synthetic fixtures only", "model": "gpt-6.1-sol", "credentialInSimulatorKeychain": True})
    write(lab, metadata)
    return {"imported": True, "credentialVerified": True, "plaintextPayloadRemoved": True,
            "modelReady": True, "continuousExecution": True, "consentReady": state.get("consent_ready", False)}


def import_credential():
    if DEVICE != PRIMARY_DEVICE:
        raise RuntimeError("Credential authorization is limited to the primary simulator")
    root = container()
    documents = root / "Documents"
    payload_path = documents / "model-config.once.json"
    receipt_path = documents / "model-config-import.receipt.json"
    if payload_path.exists():
        raise RuntimeError("An existing provisioning payload was preserved; do not overwrite it")
    session = {"appSession": str(uuid.uuid4()), "uiSession": str(uuid.uuid4()), "device": DEVICE,
               "bundle": BUNDLE, "createdAt": dt.datetime.now(dt.timezone.utc).isoformat()}
    write(SESSION_FILE, session)
    if receipt_path.exists():
        write(OUT / "prior-import-receipt.json", json.loads(receipt_path.read_text()))
        receipt_path.unlink()
    data = json.dumps({"version": 1, "apiKey": credential()}).encode()
    descriptor = os.open(payload_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        sim("launch", "--terminate-running-process", DEVICE, BUNDLE, "--import-model-config-once",
            "--sela-device-debug", session["appSession"], "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                receipt = json.loads(receipt_path.read_text())
                # A previous process's atomic state file may still exist during
                # this new process's initialization. Wait without replaying import.
                raw = json.loads((root / "Documents/SelaDeviceDebug/state.json").read_text())
                if raw.get("session") != session["appSession"] or abs(time.time() - raw.get("date", 0)) > 15:
                    time.sleep(0.2)
                    continue
                state = safe(raw)
                if receipt.get("credentialVerified") and receipt.get("sourceRemoved") and state.get("model_ready"):
                    return verify_import()
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.2)
        raise RuntimeError("No verified import receipt; the temporary payload has been removed")
    finally:
        if payload_path.exists():
            payload_path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["import", "verify-import", "state", "command"])
    parser.add_argument("--operation")
    parser.add_argument("--value")
    parser.add_argument("--value-file", type=Path)
    args = parser.parse_args()
    if args.action == "import":
        result = import_credential()
    elif args.action == "verify-import":
        result = verify_import()
    elif args.action == "state":
        result = read_state()
    else:
        if not args.operation:
            parser.error("command requires --operation")
        value = args.value_file.read_text() if args.value_file else args.value
        result = command(args.operation, value)
    print(json.dumps(safe(result), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print decoder payloads, subprocess arguments or credential values.
        print(json.dumps({"ok": False, "errorType": type(error).__name__, "error": safe(str(error))}, ensure_ascii=False))
        raise SystemExit(1)
