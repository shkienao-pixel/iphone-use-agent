#!/usr/bin/env python3
"""Manage one isolated Sela simulator; never select 'booted' or a physical device."""
import argparse
import datetime as dt
import fcntl
import json
from pathlib import Path
import plistlib
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "output/simulator-lab"
CONFIG = LAB / "environment.json"
BUILD = LAB / "app"
APP = BUILD / "build/Build/Products/Debug-iphonesimulator/PhoneAgent.app"
DEVICE_NAME = "Sela Test Lab - iPhone 13 Pro"
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro"
BUNDLE = "com.example.phoneagent"


def run(args, *, capture=False, log=None, timeout=600):
    args = [str(a) for a in args]
    if log:
        print(f"日志：{log}", flush=True)
        with Path(log).open("w") as stream:
            result = subprocess.run(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        if result.returncode:
            print("\n".join(Path(log).read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
            raise subprocess.CalledProcessError(result.returncode, args)
        return ""
    return subprocess.check_output(args, cwd=ROOT, text=True, timeout=min(timeout, 60)) if capture else subprocess.check_call(args, cwd=ROOT, timeout=timeout)


def sim(*args, capture=False):
    return run(["xcrun", "simctl", *args], capture=capture)


def now():
    return dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(timespec="seconds")


def save(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def devices():
    return [(runtime, device) for runtime, group in json.loads(sim("list", "-j", "devices", "available", capture=True))["devices"].items() for device in group]


def managed_device(create=False):
    available = devices()
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        matches = [(runtime, d) for runtime, d in available if d["udid"] == config["udid"]]
        if len(matches) != 1 or matches[0][1]["name"] != DEVICE_NAME or matches[0][1]["deviceTypeIdentifier"] != DEVICE_TYPE:
            raise RuntimeError("专用模拟器身份已改变或不可用；保留现有记录，请检查 environment.json。")
        return config, matches[0][1]
    if not create:
        raise RuntimeError("尚未搭建环境；请先运行 setup。")
    runtimes = [r for r in json.loads(sim("list", "-j", "runtimes", capture=True))["runtimes"]
                if r.get("isAvailable") and r.get("platform") == "iOS" and tuple(map(int, r["version"].split("."))) >= (27, 0)
                and any(d["identifier"] == DEVICE_TYPE for d in r.get("supportedDeviceTypes", []))]
    if not runtimes:
        raise RuntimeError("需要 Xcode 的 iOS 27 或更新运行时，且支持 iPhone 13 Pro。")
    runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
    matches = [(r, d) for r, d in available if d["name"] == DEVICE_NAME]
    if len(matches) > 1:
        raise RuntimeError("存在多个同名测试实例，请先核对，避免选错设备。")
    if matches:
        runtime_id, device = matches[0]
        if device["deviceTypeIdentifier"] != DEVICE_TYPE:
            raise RuntimeError("同名模拟器机型不符，未修改。")
        udid = device["udid"]
    else:
        runtime_id = runtime["identifier"]
        udid = sim("create", DEVICE_NAME, DEVICE_TYPE, runtime_id, capture=True).strip()
        device = next(d for _, d in devices() if d["udid"] == udid)
    config = {"name": DEVICE_NAME, "udid": udid, "deviceType": DEVICE_TYPE, "runtime": runtime_id,
              "createdAt": now(), "bundleIdentifier": BUNDLE, "mode": "local UI and offline logic; no model credentials imported"}
    save(CONFIG, config)
    return config, device


def boot():
    config, device = managed_device(create=True)
    if device["state"] != "Booted":
        sim("boot", config["udid"])
    sim("bootstatus", config["udid"], "-b")
    return config


def build(force=False, source_root=ROOT):
    receipt = LAB / "build.json"
    if APP.exists() and receipt.exists() and not force and json.loads(receipt.read_text()).get("simulatorSigning") == "ad_hoc":
        revision = (BUILD / "source-revision.txt").read_text()
        result = subprocess.run(["python3", str(ROOT / "scripts/source-manifest.py"), "check", str(source_root), str(BUILD),
                                 "--expected-revision", revision], cwd=ROOT, capture_output=True, text=True)
        if result.returncode == 0:
            print("已安装构建的源码身份仍匹配。", flush=True)
            return
    BUILD.mkdir(parents=True, exist_ok=True)
    lock = BUILD / ".build-verified.lock"
    lock.mkdir()  # Also protects this build from the repository's storage maintenance.
    try:
        receipt.unlink(missing_ok=True)
        run(["python3", ROOT / "scripts/source-manifest.py", "create", source_root, BUILD])
        manifest_path = BUILD / "source-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["signing"] = "ad-hoc simulator signing; no physical-device signing or acceptance"
        save(manifest_path, manifest)
        revision = (BUILD / "source-revision.txt").read_text()
        print("编译 Sela 模拟器版本…", flush=True)
        run(["xcodebuild", "-project", source_root / "PhoneAgent.xcodeproj", "-scheme", "PhoneAgent", "-configuration", "Debug",
             "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", BUILD / "build", "-jobs", "2",
             f"ARCHS={platform.machine()}", "ONLY_ACTIVE_ARCH=YES",
             "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-", f"PHONE_AGENT_SOURCE_REVISION={revision}",
             "PHONE_AGENT_HARNESS_VERSION=reliability-v4", "build"], log=LAB / "build.log")
        run(["python3", ROOT / "scripts/source-manifest.py", "check", source_root, BUILD, "--expected-revision", revision])
        with (APP / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info["CFBundleIdentifier"] != BUNDLE:
            raise RuntimeError("构建的 Bundle ID 不匹配，未安装。")
        run(["codesign", "--verify", "--deep", "--strict", APP])
        save(receipt, {"builtAt": now(), "sourceRevision": revision, "sourceRoot": str(source_root), "version": info.get("CFBundleShortVersionString"),
                                 "build": info.get("CFBundleVersion"), "app": str(APP), "simulatorSigning": "ad_hoc"})
    finally:
        lock.rmdir()


def launch(config):
    sim("install", config["udid"], APP)
    sim("launch", "--terminate-running-process", f"--stdout={LAB / 'app-stdout.log'}", f"--stderr={LAB / 'app-stderr.log'}",
        config["udid"], BUNDLE, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN")


def show(config):
    contents = Path(run(["xcode-select", "-p"], capture=True).strip()).parent
    candidates = [contents / "Applications/DeviceHub.app", contents / "Applications/Device Hub.app",
                  contents / "Developer/Applications/Simulator.app"]
    app = next((p for p in candidates if p.exists()), None)
    if not app:
        raise RuntimeError("未找到 Xcode 的 Device Hub / Simulator 窗口。")
    run(["open", "-a", app, "--args", "-CurrentDeviceUDID", config["udid"]])


def screenshot(config, filename=None):
    destination = Path(filename).expanduser().resolve() if filename else LAB / "latest.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    sim("io", config["udid"], "screenshot", destination)
    print(f"截图：{destination}", flush=True)


def smoke(config, only_testing=None):
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    result = LAB / "runs" / stamp
    result.mkdir(parents=True)
    save(LAB / "latest-smoke.json", {"passed": False, "status": "running", "startedAt": now(), "result": str(result)})
    try:
        run(["xcodebuild", "-project", ROOT / "Tools/SimulatorLab/SimulatorLabRunner.xcodeproj", "-scheme", "SimulatorLabRunner",
             "-destination", f"platform=iOS Simulator,id={config['udid']}", "-derivedDataPath", LAB / "runner-build",
             "-resultBundlePath", result / "smoke.xcresult", "-parallel-testing-enabled", "NO", "-jobs", "2",
             "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "90",
             "-maximum-test-execution-time-allowance", "120",
             "-collect-test-diagnostics", "never",
             *[f"-only-testing:{name}" for name in (only_testing or [])],
             "CODE_SIGNING_ALLOWED=NO", "test"], log=result / "test.log")
    except subprocess.CalledProcessError:
        failure = {"passed": False, "finishedAt": now(), "device": config, "scope": "UI only"}
        if (result / "smoke.xcresult").exists():
            try:
                summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                                          result / "smoke.xcresult"], capture=True))
                save(result / "test-summary.json", summary)
                failure["testSummary"] = summary
                run(["xcrun", "xcresulttool", "export", "attachments", "--path", result / "smoke.xcresult",
                     "--output-path", result / "screenshots"], capture=True)
            except subprocess.CalledProcessError:
                failure["evidenceExportFailed"] = True
        save(result / "verification.json", failure)
        save(LAB / "latest-smoke.json", {"passed": False, "status": "failed", "finishedAt": now(), "result": str(result)})
        raise
    summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result / "smoke.xcresult"], capture=True))
    save(result / "test-summary.json", summary)
    run(["xcrun", "xcresulttool", "export", "attachments", "--path", result / "smoke.xcresult",
         "--output-path", result / "screenshots"], capture=True)
    save(result / "verification.json", {"passed": True, "finishedAt": now(), "device": config,
                                        "build": json.loads((LAB / "build.json").read_text()),
                                        "testSummary": summary,
                                        "scope": ["normal home", "sidebar and tools navigation", "unsent draft and relaunch", "keyboard and draft navigation"],
                                        "notCovered": ["live model/API", "ESP32 BLE/HID", "real cross-app automation", "background endurance"]})
    save(LAB / "latest-smoke.json", {"passed": True, "finishedAt": now(), "result": str(result)})
    print(f"界面检查通过：{result}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", default="run", choices=["setup", "run", "build", "smoke", "screenshot", "status", "stop"])
    parser.add_argument("--output", help="截图输出路径（仅 screenshot）")
    parser.add_argument("--source-root", type=Path, default=ROOT, help="测试固定源码快照；仅构建来源改变，仍使用专用模拟器")
    parser.add_argument("--only-testing", action="append", help="选择 XCTest 用例，可重复指定")
    args = parser.parse_args()
    LAB.mkdir(parents=True, exist_ok=True)
    with (LAB / ".lab.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("另一个 Sela 模拟器操作正在运行，请等待其完成。")
        if args.action == "status":
            config, device = managed_device()
            print(json.dumps({**config, "state": device["state"], "appBuilt": APP.exists()}, ensure_ascii=False, indent=2))
            return
        if args.action == "stop":
            config, device = managed_device()
            if device["state"] == "Booted":
                sim("shutdown", config["udid"])
            return
        if args.action == "build":
            build(force=True, source_root=args.source_root.resolve())
            return
        config = boot()
        if args.action == "screenshot":
            screenshot(config, args.output)
            return
        if args.action == "setup":
            sim("ui", config["udid"], "appearance", "light")
            sim("status_bar", config["udid"], "override", "--time", "09:41", "--batteryState", "charged", "--batteryLevel", "100")
        build(source_root=args.source_root.resolve())
        launch(config)
        if args.action == "smoke":
            smoke(config, args.only_testing)
            launch(config)
        show(config)
        print(f"环境就绪：{config['name']} ({config['udid']})", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Sela 模拟器操作未完成：{error}", file=sys.stderr)
        sys.exit(1)
