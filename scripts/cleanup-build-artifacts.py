#!/usr/bin/env python3
"""Bound disposable Xcode output. Dry-run unless --apply; never delete evidence."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

GIB = 1024 ** 3
GENERATED = (
    "Build", "ModuleCache.noindex", "Index.noindex", "CompilationCache.noindex",
    "SymbolCache.noindex", "SDKStatCaches.noindex", "SDKExplicitPrecompiledModules",
    "SwiftExplicitPrecompiledModules", "ExplicitPrecompiledModules",
)
PROJECTS = {"PhoneAgent.xcodeproj", "NativePanelRunner.xcodeproj"}
PRUNE = {".app", ".appex", ".framework", ".bundle", ".xcresult", ".xcarchive", ".xcappdata"}
TEST_PREFIXES = ("pdf-preflight-checks.", "context-lease-checks.", "conversation-control-checks.",
                 "conversation-reference-checks.", "input-release-checks.", "conversation-task-ownership.",
                 "manual-ownership-checks.", "chat-evidence-checks.", "xiaohongshu-checks.")


def contains(parent, child):
    return parent == child or parent in child.parents


def read_plist(path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        return {}


def allocated(path):
    result = subprocess.run(["/usr/bin/du", "-sk", str(path)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise RuntimeError("Cannot measure " + str(path))
    return int(result.stdout.split()[0]) * 1024


def snapshot_activity(root):
    """Fail closed if process/open-file inspection is unavailable."""
    ps = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,command="], text=True,
                        capture_output=True, timeout=30, check=True)
    processes = {}
    for line in ps.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    ancestors = {os.getpid()}
    pid = os.getppid()
    while pid and pid not in ancestors:
        ancestors.add(pid)
        pid = processes.get(pid, (0, ""))[0]
    top = [p for p in root.iterdir() if p.is_dir() and not p.is_symlink()]
    active = set()
    for pid, (_, command) in processes.items():
        if pid in ancestors:
            continue
        for p in top:
            if str(p) + "/" in command or command.endswith(str(p)):
                active.add(p)
    for owner, path in inspect_open_files():
        if owner not in ancestors:
            if contains(root, path):
                # An open test result or app in the same session protects
                # that session's build, even after xcodebuild has exited.
                relative = path.relative_to(root)
                if relative.parts:
                    active.add(root / relative.parts[0])
    return active, [value[1] for value in processes.values()]


def inspect_open_files():
    opened = subprocess.run(["/usr/sbin/lsof", "-nP", "-Fpn"], text=True,
                            capture_output=True, timeout=45)
    if opened.returncode not in (0, 1) or not opened.stdout.startswith("p"):
        raise RuntimeError("Open-file inspection unavailable; cleanup skipped")
    result, owner = [], None
    for line in opened.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            owner = int(line[1:])
        elif line.startswith("n/"):
            result.append((owner, Path(line[1:].removesuffix(" (deleted)"))))
    return result


def cleanup_chrome_clones(base, opened, apply, now=None):
    """Reap only verified, idle Chrome code-sign copies, never Chrome profiles."""
    if base.name != "com.google.Chrome.code_sign_clone" or base.is_symlink() or base.resolve() != base:
        raise RuntimeError("Unexpected Chrome clone root")
    if not base.is_dir():
        return []
    now = time.time() if now is None else now
    clones = []
    for path in base.glob("code_sign_clone.*"):
        if not path.is_dir() or path.is_symlink() or path.resolve() != path:
            continue
        entries = list(path.iterdir())
        bundle = path / "Google Chrome.app.bundle"
        if entries != [bundle] or bundle.is_symlink() or bundle.resolve() != bundle:
            continue
        info = read_plist(bundle / "Contents/Info.plist")
        if info.get("CFBundleIdentifier") == "com.google.Chrome":
            clones.append((path.stat().st_mtime, path))
    result = []
    for stamp, path in sorted(clones, reverse=True)[2:]:
        if now - stamp < 2 * 3600 or any(contains(path, p) for p in opened):
            continue
        size = allocated(path)
        if path.stat().st_mtime != stamp:
            continue
        if apply:
            shutil.rmtree(path)
        result.append({"path": str(path), "bytes": size, "deleted": apply})
    return result


def cleanup_test_caches(temp, commands, opened, apply, now=None):
    """Preserve failed-test evidence; reap only its regenerable compiler cache."""
    now = time.time() if now is None else now
    result = []
    for work in temp.iterdir():
        if (not work.name.startswith(TEST_PREFIXES) or not work.is_dir()
                or work.is_symlink() or work.resolve() != work):
            continue
        cache = work / "module-cache"
        if not cache.is_dir() or cache.is_symlink() or cache.resolve() != cache:
            continue
        if now - max(work.stat().st_mtime, cache.stat().st_mtime) < 2 * 3600:
            continue
        if any(str(work) in command for command in commands) or any(contains(work, p) for p in opened):
            continue
        size = allocated(cache)
        if apply:
            shutil.rmtree(cache)
        result.append({"path": str(cache), "bytes": size, "deleted": apply})
    return result


def discover(root):
    artifacts = []
    for base, dirs, files in os.walk(root, followlinks=False):
        path = Path(base)
        dirs[:] = [d for d in dirs if not (path / d).is_symlink()
                   and Path(d).suffix not in PRUNE and d not in (".git", "node_modules")]
        meta = read_plist(path / "info.plist") if "info.plist" in files else {}
        workspace = Path(str(meta.get("WorkspacePath", "")))
        if workspace.name not in PROJECTS or path.resolve() != path:
            continue
        children = [path / name for name in GENERATED
                    if (path / name).is_dir() and not (path / name).is_symlink()]
        if not children:
            continue
        groups = set()
        product_metadata = []
        for app in (path / "Build/Products").glob("*/*.app"):
            info = read_plist(app / "Info.plist")
            bundle = info.get("CFBundleIdentifier")
            if bundle:
                # Native test sessions may mint a unique bundle ID each time.
                # Retaining two *per session ID* would defeat the storage cap.
                family = "native-test-runner" if workspace.name == "NativePanelRunner.xcodeproj" else bundle
                groups.add((workspace.name, family, info.get("DTPlatformName", app.parent.name)))
                product_metadata.append(app / "Info.plist")
        stamps = [path / "info.plist", path / ".build-retention-touch",
                  path / "Build/Intermediates.noindex/XCBuildData/build.db"] + children + product_metadata
        modified = max(p.stat().st_mtime for p in stamps if p.exists())
        last_access = meta.get("LastAccessedDate")
        if isinstance(last_access, datetime.datetime):
            modified = max(modified, last_access.replace(tzinfo=datetime.timezone.utc).timestamp())
        artifacts.append({"path": path, "children": children, "groups": groups,
                          "modified": modified, "bytes": sum(allocated(p) for p in children)})
        # Everything below a known DerivedData root is generated. Do not scan
        # module caches, app bundles, and dependency checkouts again.
        dirs[:] = []
    return artifacts


def pinned(path, root):
    current = path
    while contains(root, current):
        if any((current / name).exists() for name in
               (".keep-build", ".build-verified.lock", ".build-retention.lock")):
            return True
        if current == root:
            break
        current = current.parent
    return False


def plan_cleanup(root, artifacts, active, protect=(), now=None, budget=8 * GIB,
                 keep=2, min_age=2 * 3600, max_age=48 * 3600):
    now = time.time() if now is None else now
    active = set(active) | set(protect)
    kept = set()
    grouped = {}
    for item in artifacts:
        for group in item["groups"]:
            grouped.setdefault(group, []).append(item)
    for items in grouped.values():
        for item in sorted(items, key=lambda x: x["modified"], reverse=True)[:keep]:
            kept.add(item["path"])
    projected = sum(item["bytes"] for item in artifacts)
    selected, preserved = [], []
    for item in sorted(artifacts, key=lambda x: x["modified"]):
        path = item["path"]
        reason = None
        if any(contains(p, path) or contains(path, p) for p in active):
            reason = "active session or explicitly protected"
        elif pinned(path, root):
            reason = "pinned or build lock"
        elif path in kept:
            reason = "latest versions for platform/bundle"
        elif now - item["modified"] < min_age:
            reason = "recent build grace period"
        elif projected <= budget and now - item["modified"] < max_age:
            reason = "within cache budget and retention age"
        if reason:
            preserved.append({"path": str(path), "bytes": item["bytes"], "reason": reason})
        else:
            selected.append(item)
            projected -= item["bytes"]
    return selected, preserved, projected


def safe_child(root, derived, child):
    return (root.resolve() == root and contains(root, derived) and derived != root
            and derived.resolve() == derived and child.parent == derived
            and child.name in GENERATED and not child.is_symlink()
            and child.resolve() == child)


def cleanup_downloads(home, commands, apply, budget=GIB):
    # Download-only caches; never touch installed packages, npx environments,
    # browser profiles, credentials, app databases, or model weights.
    installer = re.compile(r"(?:^|[ /])((?:npm|npx)(?:-cli\.js)?|pnpm|pip3?(?:\.\d+)?|uv)(?:\s|$)")
    if any(installer.search(command) for command in commands):
        return [{"reason": "package manager active; download cache cleanup skipped"}]
    result = []
    for path in (home / ".npm/_cacache", home / "Library/Caches/pip"):
        if not path.is_dir() or path.is_symlink() or path.resolve() != path:
            continue
        size = allocated(path)
        if size > budget:
            if apply:
                shutil.rmtree(path)
            result.append({"path": str(path), "bytes": size, "deleted": apply})
    return result


def run(args):
    root = args.root.absolute()
    if root.name != "output" or root.is_symlink() or root.resolve() != root:
        raise RuntimeError("Root must be a real project output directory, not a symlink")
    if not (root.parent / "PhoneAgent.xcodeproj/project.pbxproj").is_file():
        raise RuntimeError("No PhoneAgent project beside output; cleanup refused")
    root.mkdir(exist_ok=True)
    args.log_dir.mkdir(parents=True, exist_ok=True)
    with (args.log_dir / "cleanup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"status": "already_running", "deleted_bytes": 0}
        active, commands = snapshot_activity(root)
        artifacts = discover(root)
        selected, preserved, projected = plan_cleanup(
            root, artifacts, active, [p.absolute() for p in args.protect],
            budget=int(args.budget_gib * GIB), keep=args.keep,
            min_age=args.min_age_hours * 3600, max_age=args.max_age_hours * 3600)
        # Recheck activity after discovery, which can take time on a large tree.
        if args.apply and selected:
            active_now, commands = snapshot_activity(root)
            active |= active_now
        deleted, skipped = [], []
        for item in selected:
            path = item["path"]
            current = next((x for x in discover_one(root, path)), None)
            if (current is None or current["modified"] != item["modified"] or pinned(path, root)
                    or any(contains(p, path) or contains(path, p) for p in active)):
                skipped.append(str(path))
                continue
            for child in item["children"]:
                if not safe_child(root, path, child):
                    raise RuntimeError("Unsafe generated path: " + str(child))
                if args.apply and child.exists():
                    shutil.rmtree(child)
            deleted.append({"path": str(path), "bytes": item["bytes"]})
        downloads = cleanup_downloads(Path.home(), commands, args.apply) if args.download_caches else []
        clones, test_caches = [], []
        if args.chrome_clones or args.test_temp_caches:
            user_temp = Path(subprocess.check_output(
                ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True, timeout=10).strip()).resolve()
            # Limit this extra cleanup to the operating system's per-user
            # temporary X directory, never a user-supplied arbitrary tree.
            if user_temp.name != "T" or user_temp.parts[:4] != ("/", "private", "var", "folders"):
                raise RuntimeError("Unexpected per-user temporary directory")
            opened = [p for _, p in inspect_open_files()]
            if args.chrome_clones:
                clone_root = user_temp.parent / "X/com.google.Chrome.code_sign_clone"
                clones = cleanup_chrome_clones(clone_root, opened, args.apply)
            if args.test_temp_caches:
                test_caches = cleanup_test_caches(user_temp, commands, opened, args.apply)
        result = {"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "status": "applied" if args.apply else "dry_run", "root": str(root),
                  "budget_gib": args.budget_gib, "keep_per_platform_bundle": args.keep,
                  "build_cache_bytes_before": sum(x["bytes"] for x in artifacts),
                  "projected_build_cache_bytes": sum(x["bytes"] for x in artifacts) - sum(x["bytes"] for x in deleted),
                  "deleted_bytes": sum(x["bytes"] for x in deleted) if args.apply else 0,
                  "selected": deleted, "preserved": preserved, "skipped_after_recheck": skipped,
                  "download_caches": downloads, "chrome_clones": clones, "test_temp_caches": test_caches,
                  "free_bytes": shutil.disk_usage(root).free}
        result["over_budget_with_protected_builds"] = result["projected_build_cache_bytes"] > args.budget_gib * GIB
        # Bound maintenance's own logs: one current report plus one previous
        # report, rather than an ever-growing stream of full inventories.
        report = args.log_dir / "latest.json"
        if report.exists():
            report.replace(args.log_dir / "previous.json")
        temp = args.log_dir / "latest.json.tmp"
        temp.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        temp.replace(report)
        (args.log_dir / "latest-error.json").unlink(missing_ok=True)
        return result


def discover_one(root, path):
    # Reuse the same metadata and boundary checks for the last-moment check.
    # A tiny wrapper avoids scanning the complete output tree a second time.
    if path.exists() and contains(root, path):
        return discover(path)
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1] / "output")
    parser.add_argument("--log-dir", type=Path,
                        default=Path.home() / "Library/Logs/SelaBuildMaintenance")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--protect", action="append", default=[], type=Path)
    parser.add_argument("--budget-gib", type=float, default=8)
    parser.add_argument("--keep", type=int, default=2)
    parser.add_argument("--min-age-hours", type=float, default=2)
    parser.add_argument("--max-age-hours", type=float, default=48)
    parser.add_argument("--download-caches", action="store_true")
    parser.add_argument("--chrome-clones", action="store_true")
    parser.add_argument("--test-temp-caches", action="store_true")
    args = parser.parse_args()
    if args.keep < 2 or args.budget_gib <= 0 or args.min_age_hours < 1 or args.max_age_hours < args.min_age_hours:
        parser.error("Keep at least two builds, a positive budget, and at least one hour of grace")
    try:
        result = run(args)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        try:
            args.log_dir.mkdir(parents=True, exist_ok=True)
            (args.log_dir / "latest-error.json").write_text(json.dumps({
                "time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "status": "skipped_safely", "error": str(error)[:2000]}, indent=2) + "\n")
        except OSError:
            pass
        print("Build maintenance skipped safely: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({key: result[key] for key in
                      ("status", "deleted_bytes", "build_cache_bytes_before", "free_bytes") if key in result}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
