"""Sela's local, authenticated adapter to the three official office CLIs.

Only installation, authorization, status and disconnect are exposed. There is
no arbitrary shell/command endpoint and no message or order is sent here.
"""
from __future__ import annotations

import base64
import hmac
import hashlib
import io
import json
import os
import platform
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import threading
import tarfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import urlopen
import uuid

ROOT = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get("SELA_CONNECTION_RUNTIME", str(ROOT.parent / "cli-runtime")))
DATA = Path(os.environ.get("SELA_CONNECTION_DATA", str(ROOT / "private")))
DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(DATA, 0o700)
PORT = int(os.environ.get("SELA_CONNECTION_PORT", "8792"))
PAIRING = DATA / "pairing.json"
if not PAIRING.exists():
    fd = os.open(PAIRING, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump({"endpoint": f"http://127.0.0.1:{PORT}", "token": secrets.token_urlsafe(32)}, stream)
CONFIG = json.loads(PAIRING.read_text())
TOKEN = CONFIG["token"]

SERVICES = {
    "feishu": {"bin": "lark-cli", "package": "@larksuite/cli@1.0.98", "hosts": ("feishu.cn", "larksuite.com")},
    "dingtalk": {"bin": "dws", "package": "dingtalk-workspace-cli@1.0.65", "hosts": ("dingtalk.com",)},
    "wecom": {"bin": "wecom-cli", "package": "@wecom/cli@1.3.4", "hosts": ("work.weixin.qq.com", "open.work.weixin.qq.com")},
}
JOBS = {}
LOCK = threading.RLock()
DISCONNECTED_FILE = DATA / "disconnected.json"
try:
    DISCONNECTED = set(json.loads(DISCONNECTED_FILE.read_text())) & SERVICES.keys()
except (OSError, ValueError, TypeError):
    DISCONNECTED = set()


def set_disconnected(service, value):
    with LOCK:
        DISCONNECTED.add(service) if value else DISCONNECTED.discard(service)
        temporary = DATA / ".disconnected.tmp"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(sorted(DISCONNECTED), stream)
        temporary.replace(DISCONNECTED_FILE)


def environment():
    # No provider tokens are inherited from the agent or its shell.
    keys = ("PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR")
    env = {key: os.environ[key] for key in keys if key in os.environ}
    env["PATH"] = str(RUNTIME / "node_modules/.bin") + os.pathsep + env.get("PATH", "/usr/bin:/bin")
    env["WECOM_CLI_CONFIG_DIR"] = str(DATA / "wecom")
    env["DWS_CONFIG_DIR"] = str(DATA / "dingtalk")
    env["NO_COLOR"] = "1"
    return env


def executable(service):
    standalone = ROOT / "bin" / SERVICES[service]["bin"]
    if standalone.is_file() and os.access(standalone, os.X_OK):
        return str(standalone)
    architecture = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x64"
    paths = {
        "feishu": RUNTIME / "node_modules/@larksuite/cli/bin/lark-cli",
        "dingtalk": RUNTIME / "node_modules/dingtalk-workspace-cli/vendor/dws",
        "wecom": RUNTIME / f"node_modules/@wecom/cli-darwin-{architecture}/bin/wecom-cli",
    }
    path = paths[service]
    return str(path) if path.is_file() and os.access(path, os.X_OK) else None


def install_native(job):
    service = job["service"]
    architecture = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "amd64"
    sources = {
        ("feishu", "arm64"): ("https://github.com/larksuite/cli/releases/download/v1.0.98/lark-cli-1.0.98-darwin-arm64.tar.gz", "ee4a3209bbf8b74ea5c00a07d0da89b79f5e7f6abfd518a8b2d78a7a4f7e3f40"),
        ("feishu", "amd64"): ("https://github.com/larksuite/cli/releases/download/v1.0.98/lark-cli-1.0.98-darwin-amd64.tar.gz", "44a4ff98e969385fc4bb4d701735ba319307e50560fa6c4c956178d70ccc3525"),
        ("dingtalk", "arm64"): ("https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/releases/download/v1.0.65/dws-darwin-arm64.tar.gz", "8550c9c42a2018204761db923911321a56df9bedcacf3d42baffae00ccd7bc44"),
        ("dingtalk", "amd64"): ("https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/releases/download/v1.0.65/dws-darwin-amd64.tar.gz", "6afdd8dcb093ea0c7aa9d0e76371f44308aa6ee9f8a44bf0d2b010bb2e3c8244"),
    }
    if service == "wecom":
        arch = "arm64" if architecture == "arm64" else "x64"
        metadata = json.load(urlopen(f"https://registry.npmjs.org/@wecom/cli-darwin-{arch}/1.3.4", timeout=20))
        url, digest = metadata["dist"]["tarball"], metadata["dist"]["integrity"]
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org":
            raise RuntimeError("install")
    else:
        url, digest = sources[(service, architecture)]
    archive = bytearray()
    deadline = time.monotonic() + 240
    with urlopen(url, timeout=20) as response:
        while True:
            if job.get("cancelled") or time.monotonic() > deadline:
                raise RuntimeError("cancelled" if job.get("cancelled") else "timeout")
            chunk = response.read(262144)
            if not chunk:
                break
            archive.extend(chunk)
            if len(archive) > 100_000_000:
                raise RuntimeError("install")
    actual = ("sha512-" + base64.b64encode(hashlib.sha512(archive).digest()).decode()) if service == "wecom" else hashlib.sha256(archive).hexdigest()
    if not hmac.compare_digest(actual, digest):
        raise RuntimeError("install")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
        members = [m for m in package.getmembers() if Path(m.name).name == SERVICES[service]["bin"] and m.isfile() and m.size < 200_000_000]
        if len(members) != 1:
            raise RuntimeError("install")
        data = package.extractfile(members[0]).read()
    folder = ROOT / "bin"; folder.mkdir(exist_ok=True)
    target = folder / SERVICES[service]["bin"]
    temporary = folder / ("." + service + ".download")
    temporary.write_bytes(data); temporary.chmod(0o755); temporary.replace(target)


def run(service, arguments, timeout=12):
    binary = executable(service)
    if not binary:
        return 127, ""
    result = subprocess.run([binary, *arguments], cwd=DATA, env=environment(), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode, result.stdout[:131072].decode("utf-8", "replace")


def json_output(text):
    # Some CLI versions print a banner before their JSON result.
    for offset, value in enumerate(text):
        if value == "{":
            try:
                return json.JSONDecoder().raw_decode(text[offset:])[0]
            except ValueError:
                continue
    return {}


def authenticated(service, code, output):
    if code != 0:
        return False
    if service == "wecom":
        return output.strip() == "authorized"
    obj = json_output(output)
    if service == "dingtalk":
        value = obj.get("data", obj)
        return value.get("authenticated") is True and not value.get("reason")
    value = obj.get("data", obj)
    identity = value.get("identities", {}).get("user", {})
    if identity.get("available") is True:
        return True
    if value.get("authenticated") is True or value.get("logged_in") is True:
        return True
    # lark-cli's text status prints explicit identity/authorization states.
    return bool(re.search(r"(?im)^\s*(?:Status|状态)\s*[:：]\s*(?:authenticated|authorized|已登录|已授权)\s*$", output))


def status(service):
    installed = executable(service) is not None
    base = {"service": service, "installed": installed, "connected": False, "state": "missing", "message": "先安装官方 CLI"}
    if not installed:
        return base
    if service in DISCONNECTED:
        return dict(base, state="disconnected", message="已从 Sela 断开")
    with LOCK:
        active = next((j for j in JOBS.values() if j["service"] == service and j["state"] in ("running", "authorizing")), None)
    if active:
        return dict(base, state="authorizing", message=active["message"], jobID=active["id"])
    arguments = {"feishu": ["auth", "status", "--json"], "dingtalk": ["auth", "status", "--readonly", "--format", "json"],
                 "wecom": ["auth", "show", "--status"]}[service]
    try:
        code, output = run(service, arguments)
        connected = authenticated(service, code, output)
        return dict(base, connected=connected, state="connected" if connected else "login",
                    message="官方 CLI 授权有效" if connected else "完成官方账号授权后即可连接")
    except subprocess.TimeoutExpired:
        return dict(base, state="error", message="CLI 状态检查超时，请重试")
    except OSError:
        return dict(base, state="error", message="CLI 无法启动，请重新安装")


def authorization_url(service, output):
    for candidate in reversed(re.findall(r"https://[^\s\x1b<>\"']+", output)):
        candidate = candidate.rstrip(".,)，）]")
        parsed = urlsplit(candidate)
        host = (parsed.hostname or "").lower()
        if (not parsed.username and not parsed.password and "/document/" not in parsed.path and "/docs/" not in parsed.path
                and any(word in candidate.lower() for word in ("auth", "login", "device", "verify", "activate"))
                and any(host == h or host.endswith("." + h) for h in SERVICES[service]["hosts"])):
            # URLs are returned only to the paired native app, never logged.
            return candidate
    return None


def public_job(job):
    with LOCK:
        result = {k: job[k] for k in ("id", "service", "state", "message")}
        if job.get("url"):
            result["authorizationURL"] = job["url"]
        if job.get("verificationCode"):
            result["verificationCode"] = job["verificationCode"]
        qr = job.get("qr")
        try:
            if qr and qr.is_file() and qr.stat().st_size < 524288:
                result["qrCode"] = base64.b64encode(qr.read_bytes()).decode()
        except OSError:
            pass
        return result


def stream_command(job, command):
    process = subprocess.Popen(command, cwd=DATA, env=environment(), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    job["process"] = process
    chunks = bytearray()

    def read_output():
        while True:
            chunk = process.stdout.read1(2048)
            if not chunk:
                return
            # Keep only a bounded in-memory tail; never persist raw CLI output.
            chunks.extend(chunk)
            if len(chunks) > 131072:
                del chunks[:-131072]
            url = authorization_url(job["service"], chunks.decode("utf-8", "replace"))
            code = re.search(r'(?i)(?:user_code|userCode|用户代码)["\s]*[:：=]["\s]*([A-Z0-9-]{4,20})', chunks.decode("utf-8", "replace")) if job["service"] == "dingtalk" else None
            if code:
                job["verificationCode"] = code.group(1)
            if url:
                with LOCK:
                    job["url"] = url
                    job["state"] = "authorizing"
                    job["message"] = "请在官方页面或 App 中确认授权"

    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()
    deadline = time.monotonic() + (300 if job["kind"] == "login" else 240)
    while process.poll() is None:
        if job.get("cancelled") or time.monotonic() > deadline:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise RuntimeError("cancelled" if job.get("cancelled") else "timeout")
        time.sleep(0.2)
    reader.join(timeout=1)
    return process.returncode, chunks.decode("utf-8", "replace")


def work(job):
    service = job["service"]
    try:
        if job["kind"] == "install":
            install_native(job)
            if not executable(service):
                raise RuntimeError("install")
            job.update(state="complete", message="官方 CLI 已安装，可以登录连接")
            return
        set_disconnected(service, False)
        binary = executable(service)
        if not binary:
            raise RuntimeError("missing")
        if service == "feishu":
            # Only initialize a new app when no CLI app configuration exists.
            code, config = run(service, ["auth", "status", "--json"])
            obj = json_output(config)
            has_app = bool(obj.get("appId") or obj.get("app_id"))
            if code != 0 or not has_app:
                job["message"] = "先在飞书完成应用配置，再确认账号授权"
                code, _ = stream_command(job, [binary, "config", "init", "--new"])
                if code:
                    raise RuntimeError("login")
            command = [binary, "auth", "login", "--recommend"]
        elif service == "dingtalk":
            command = [binary, "auth", "login", "--device", "--no-browser"]
        else:
            job["qr"] = DATA / (job["id"] + ".png")
            command = [binary, "auth", "init", "--noninteractive", "--no-browser", "--output-qrcode", str(job["qr"])]
        job.pop("url", None)
        code, _ = stream_command(job, command)
        if code:
            raise RuntimeError("login")
        # Do not infer connectivity solely from a process successfully exiting.
        job["state"] = "checking"
        verified = status(service)
        if not verified["connected"]:
            raise RuntimeError("verify")
        job.update(state="complete", message="账号授权已验证，可以使用此连接")
    except Exception as error:
        kind = str(error)
        messages = {"node": "请先在 Mac 安装 Node.js 18 或更新版本", "missing": "请先安装官方 CLI",
                    "install": "安装未完成，请检查网络后重试", "timeout": "授权或安装已超时，请重新发起",
                    "cancelled": "已取消本次操作", "verify": "尚未验证到有效授权，请检测连接或重新登录"}
        job.update(state="cancelled" if job.get("cancelled") else "error",
                   message=messages.get(kind, "授权未完成，请检查账号权限或管理员审批后重试"))
    finally:
        job.pop("process", None)
        if job["state"] not in ("running", "authorizing"):
            job.pop("url", None)
            job.pop("verificationCode", None)
            if job.get("qr"):
                job["qr"].unlink(missing_ok=True)


def start_job(service, kind):
    with LOCK:
        for job in JOBS.values():
            if job["state"] in ("running", "authorizing", "checking"):
                if job["service"] == service and job["kind"] == kind:
                    return public_job(job)
                raise ValueError("请先完成或取消当前连接操作")
        job = {"id": str(uuid.uuid4()), "service": service, "kind": kind, "state": "running",
               "message": "正在安装官方 CLI…" if kind == "install" else "正在发起官方账号授权…"}
        JOBS[job["id"]] = job
        # Bound metadata retained by this long-lived helper.
        while len(JOBS) > 32:
            JOBS.pop(next(iter(JOBS)))
        threading.Thread(target=work, args=(job,), daemon=True).start()
        return public_job(job)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, data):
        content = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def authorized(self):
        allowed = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
        public_host = os.environ.get("SELA_CONNECTION_PUBLIC_HOST", "")
        if public_host and re.fullmatch(r"[a-z0-9.-]+", public_host): allowed.add(public_host)
        valid_host = self.headers.get("Host") in allowed
        supplied = self.headers.get("Authorization", "")
        return valid_host and not self.headers.get("Origin") and hmac.compare_digest(supplied, "Bearer " + TOKEN)

    def handle_request(self):
        if not self.authorized():
            return self.reply(403, {"error": "连接服务配对未通过"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.reply(400, {"error": "无效请求"})
        if self.headers.get("Transfer-Encoding") or not 0 <= length <= 1024:
            return self.reply(413, {"error": "请求过长"})
        if self.command == "POST":
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
        parts = urlsplit(self.path).path.strip("/").split("/")
        try:
            if self.command == "GET" and parts == ["v1", "health"]:
                return self.reply(200, {"name": "Sela connections", "version": 1})
            if len(parts) == 4 and parts[:2] == ["v1", "services"] and parts[2] in SERVICES:
                service, action = parts[2:]
                if self.command == "GET" and action == "status":
                    return self.reply(200, status(service))
                if self.command == "POST" and action in ("install", "login"):
                    return self.reply(202, start_job(service, action))
                if self.command == "POST" and action == "disconnect":
                    set_disconnected(service, True)
                    for job in JOBS.values():
                        if job["service"] == service and job["state"] in ("running", "authorizing", "checking"):
                            job["cancelled"] = True
                    return self.reply(200, status(service))
            if len(parts) in (3, 4) and parts[:2] == ["v1", "jobs"] and parts[2] in JOBS:
                job = JOBS[parts[2]]
                if self.command == "GET" and len(parts) == 3:
                    return self.reply(200, public_job(job))
                if self.command == "POST" and parts[3:] == ["cancel"]:
                    job["cancelled"] = True
                    return self.reply(200, {"ok": True})
            return self.reply(404, {"error": "没有这个连接入口"})
        except ValueError as error:
            return self.reply(409, {"error": str(error)})
        except Exception:
            return self.reply(500, {"error": "连接服务暂时无法完成此操作，请重试"})

    do_GET = handle_request
    do_POST = handle_request


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
