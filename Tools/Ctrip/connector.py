#!/usr/bin/env python3
"""Ctrip official read-only query connector; credentials stay in macOS Keychain."""
from __future__ import annotations

import argparse
import hmac
import html
import json
import os
from pathlib import Path
import queue
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib import error, parse, request

API_URL = "https://externalcallback.ctrip.com/skills/api/crew/skillhub/searchInfo"
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_QUERY_CHARS = 4096
MAX_TOKEN_CHARS = 4096
MAX_REQUEST_BYTES = 96 * 1024
DEFAULT_QUERY = "上海一日游有哪些值得去的景点？"
DEFAULT_HELPER = Path(__file__).resolve().parent / ".build" / "keychain-helper"


class ConnectorError(Exception):
    """Only fixed, credential-free messages may be raised as ConnectorError."""


def sanitize_text(text: str, token: str) -> str:
    """Remove exact credentials; suppress content containing escaped credentials."""
    if not token:
        return text
    cleaned = text.replace(token, "[授权信息已隐藏]")
    candidates = {cleaned}
    for _ in range(3):
        decoded_candidates = set()
        for candidate in candidates:
            expanded = html.unescape(candidate)
            for normalized in (parse.unquote(expanded), parse.unquote_plus(expanded)):
                normalized = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m[1], 16)), normalized)
                normalized = re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m[1], 16)), normalized)
                for encoded, decoded in ((r'\/', '/'), (r'\"', '"'), (r'\\', '\\'),
                                         (r'\n', '\n'), (r'\r', '\r'), (r'\t', '\t')):
                    normalized = normalized.replace(encoded, decoded)
                if token in normalized:
                    return "携程返回内容包含编码后的授权信息，已隐藏整段内容。"
                decoded_candidates.add(normalized)
        candidates = decoded_candidates
    return cleaned


def validate_query(query_text: Any) -> str:
    if not isinstance(query_text, str) or not query_text.strip():
        raise ConnectorError("请输入查询内容。")
    if len(query_text) > MAX_QUERY_CHARS:
        raise ConnectorError("查询内容最多 4096 个字符。")
    return query_text.strip()


def validate_token(token: Any) -> str:
    if not isinstance(token, str) or not token.strip():
        raise ConnectorError("请输入携程授权码。")
    token = token.strip()
    if not 8 <= len(token.encode("utf-8")) <= MAX_TOKEN_CHARS or any(not 33 <= ord(char) <= 126 for char in token):
        raise ConnectorError("授权码格式不正确。")
    return token


def extract_result(payload: Any, token: str) -> str:
    """Accept only official result/string or result.content/string, never state."""
    if not isinstance(payload, dict):
        raise ConnectorError("携程返回了无法识别的数据格式。")
    if payload.get("success") is False:
        raise ConnectorError("携程未完成本次查询，请检查授权或稍后重试。")
    if "code" in payload and payload["code"] not in (None, 0, 200, "0", "200", "SUCCESS", "success", "OK", "ok"):
        raise ConnectorError("携程未完成本次查询，请检查授权或稍后重试。")
    if payload.get("error") not in (None, False, "", {}):
        raise ConnectorError("携程未完成本次查询，请检查授权或稍后重试。")
    result = payload.get("result")
    if isinstance(result, dict):
        result = result.get("content")
    if not isinstance(result, str) or not result.strip():
        raise ConnectorError("携程没有返回可显示的查询结果，请稍后重试。")
    return sanitize_text(result.strip(), token)


class NoRedirectHandler(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ConnectorError("携程接口返回重定向，已停止请求。")


def call_ctrip(query_text: str, token: str, opener=None, timeout: float = 45.0) -> str:
    """One fixed HTTPS POST, default TLS verification, no proxies or redirects.

    The caller returns within timeout even if DNS or a slow response blocks its
    daemon worker. An injected opener permits completely offline verification.
    """
    query_text = validate_query(query_text)
    token = validate_token(token)
    if timeout <= 0 or timeout > 45:
        raise ConnectorError("请求时限设置不正确。")
    opener = opener or request.build_opener(request.ProxyHandler({}), NoRedirectHandler())
    body = json.dumps({"inputs": {"token": token, "query": query_text}}, ensure_ascii=False).encode("utf-8")
    req = request.Request(API_URL, data=body, method="POST", headers={
        "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/json",
        "User-Agent": "PhoneAgent-Ctrip/1.0",
    })
    deadline = time.monotonic() + timeout
    output: queue.Queue = queue.Queue(maxsize=1)

    def worker():
        try:
            with opener.open(req, timeout=timeout) as response:
                status = getattr(response, "status", None)
                if not isinstance(status, int) or not 200 <= status < 300:
                    raise ConnectorError("携程接口 HTTP 请求失败，请稍后重试。")
                final_url = response.geturl()
                if final_url != API_URL:
                    raise ConnectorError("携程接口地址发生变化，已停止请求。")
                raw_length = response.headers.get("Content-Length")
                if raw_length:
                    try:
                        if int(raw_length) > MAX_RESPONSE_BYTES:
                            raise ConnectorError("携程返回内容过大，已停止接收。")
                    except ValueError:
                        raise ConnectorError("携程返回了无法识别的响应。")
                chunks = []
                size = 0
                while True:
                    if time.monotonic() >= deadline:
                        raise ConnectorError("携程查询超时，请稍后重试。")
                    chunk = response.read(min(65536, MAX_RESPONSE_BYTES + 1 - size))
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > MAX_RESPONSE_BYTES:
                        raise ConnectorError("携程返回内容过大，已停止接收。")
                    chunks.append(chunk)
                try:
                    payload = json.loads(b"".join(chunks).decode("utf-8"))
                except (UnicodeError, ValueError):
                    raise ConnectorError("携程返回了无法识别的数据格式。")
                result = extract_result(payload, token)
                output.put((True, result))
        except ConnectorError as exc:
            output.put((False, str(exc)))
        except error.HTTPError as exc:
            code = exc.code
            exc.close()
            if code in (401, 403):
                message = "携程授权未通过，请检查授权码及申请状态。"
            elif code == 429:
                message = "携程请求过于频繁，请稍后重试。"
            elif 300 <= code < 400:
                message = "携程接口返回重定向，已停止请求。"
            else:
                message = "携程接口 HTTP 请求失败，请稍后重试。"
            output.put((False, message))
        except Exception:
            output.put((False, "暂时无法连接携程，请检查网络或稍后重试。"))

    threading.Thread(target=worker, name="ctrip-query", daemon=True).start()
    try:
        success, value = output.get(timeout=max(0.001, deadline - time.monotonic()))
    except queue.Empty:
        raise ConnectorError("携程查询超时，请稍后重试。")
    if not success:
        raise ConnectorError(value)
    return value


class KeychainStore:
    def __init__(self, helper: str | Path):
        self.helper = str(Path(helper).expanduser().resolve())

    def _run(self, action: str, secret: str | None = None) -> str:
        try:
            result = subprocess.run([self.helper, action], input=secret,
                                    capture_output=True, text=True, timeout=20,
                                    check=False)
        except Exception:
            raise ConnectorError("无法访问本机钥匙串，请检查辅助程序及系统授权。")
        if result.returncode != 0:
            raise ConnectorError("无法访问本机钥匙串，请检查系统授权后重试。")
        return result.stdout

    def configured(self) -> bool:
        try:
            value = json.loads(self._run("status"))
        except (ValueError, TypeError):
            raise ConnectorError("钥匙串状态无法读取。")
        if not isinstance(value, dict) or not isinstance(value.get("configured"), bool):
            raise ConnectorError("钥匙串状态无法读取。")
        return value["configured"]

    def get(self) -> str:
        return validate_token(self._run("get"))

    def set(self, token: str) -> None:
        token = validate_token(token)
        try:
            value = json.loads(self._run("set", token))
        except (ValueError, TypeError):
            raise ConnectorError("授权码保存状态无法确认。")
        if not isinstance(value, dict) or value.get("configured") is not True:
            raise ConnectorError("授权码未能保存到本机钥匙串。")


class ConnectorService:
    def __init__(self, store, query_fn: Callable = call_ctrip):
        self.store = store
        self.query_fn = query_fn
        self.lock = threading.Lock()
        self.state_lock = threading.Lock()
        self.test_state = "idle"
        self.last_error = None

    def status(self) -> dict:
        with self.state_lock:
            state, last_error = self.test_state, self.last_error
        try:
            configured = self.store.configured()
        except ConnectorError as exc:
            return {"configured": False, "test_state": state, "error": str(exc)}
        return {"configured": configured, "test_state": state, "error": last_error}

    def _perform(self, query_text: str, token: str | None, save: bool) -> str:
        query_text = validate_query(query_text)
        if token is not None:
            token = validate_token(token)
        if not self.lock.acquire(blocking=False):
            raise ConnectorError("已有携程查询正在进行，请稍候。")
        try:
            with self.state_lock:
                self.test_state, self.last_error = "running", None
            if save:
                self.store.set(token)
            if token is None:
                token = self.store.get()
            result = self.query_fn(query_text, token)
            if not isinstance(result, str) or not result.strip():
                raise ConnectorError("携程没有返回可显示的查询结果。")
            result = sanitize_text(result, token)
            with self.state_lock:
                self.test_state, self.last_error = "ok", None
            return result
        except ConnectorError as exc:
            with self.state_lock:
                self.test_state, self.last_error = "error", str(exc)
            raise
        except Exception:
            message = "携程查询未完成，请稍后重试。"
            with self.state_lock:
                self.test_state, self.last_error = "error", message
            raise ConnectorError(message)
        finally:
            token = None
            self.lock.release()

    def query(self, query_text: str, token: str | None = None) -> str:
        return self._perform(query_text, token, False)

    def save_and_test(self, token: str, query_text: str) -> str:
        return self._perform(query_text, token, True)


PAGE = r'''<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>携程官方查询接入</title>
<style nonce="__NONCE__">
:root{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#182836;background:#f3f7fb}*{box-sizing:border-box}body{margin:0;padding:32px 18px}main{max-width:760px;margin:auto}section{background:white;border:1px solid #dce6f0;border-radius:18px;padding:26px;margin:18px 0;box-shadow:0 8px 30px #233e6210}h1{font-size:28px;margin:0 0 14px}h2{font-size:19px;margin:0 0 14px}p{line-height:1.8;color:#536272}label{display:block;font-weight:600;margin:18px 0 8px}input,textarea{font:inherit;width:100%;padding:12px;border:1px solid #bccbdb;border-radius:9px;background:#fbfdff}textarea{height:90px;resize:vertical}button{font:inherit;background:#0869ce;color:white;border:0;border-radius:9px;padding:12px 19px;margin:16px 8px 0 0;cursor:pointer}button.secondary{background:#e9f2fb;color:#105492}button:disabled{opacity:.5;cursor:wait}#status{font-size:14px;color:#335d80}#result{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.8}#error{color:#b12222}small{color:#647889;line-height:1.7}#result:empty{display:none}
</style>
<main><h1>携程官方查询接入</h1><p>把刚申请的携程授权码保存在这台 Mac 的系统钥匙串，再运行一次官方查询验证。</p>
<section><h2>授权与验证</h2><div id="status">正在读取钥匙串状态…</div>
<form id="setup" autocomplete="off"><label for="token">携程授权码</label><input type="password" id="token" name="ctrip-authorization" autocomplete="off" spellcheck="false" maxlength="4096" placeholder="仅在本机页面输入，不要发送到聊天">
<small>授权码不写入项目文件、终端参数或日志，页面不会显示已保存的值。</small>
<label for="query">验证查询</label><textarea id="query" maxlength="4096">上海一日游有哪些值得去的景点？</textarea>
<button id="save" type="submit">保存到钥匙串并查询</button><button id="again" class="secondary" type="button">使用已保存授权码查询</button>
</form><p><small>点击按钮后，仅向携程官方 HTTPS 接口发送本次查询。此处只做旅行信息查询，不执行下单或付款。结果仅在当前页面显示。</small></p>
<div id="error" role="alert"></div></section><section><h2>查询结果</h2><div id="result" aria-live="polite"></div><small id="hint">保存后将在这里显示携程的实际返回结果。</small></section></main>
<script nonce="__NONCE__">
'use strict';
const csrf = __CSRF__;
const tokenInput = document.getElementById('token');
const queryInput = document.getElementById('query');
const result = document.getElementById('result');
const errorBox = document.getElementById('error');
const statusBox = document.getElementById('status');
const buttons = [document.getElementById('save'),document.getElementById('again')];
async function refreshStatus(){
 try {const r=await fetch('/api/status',{cache:'no-store'});const s=await r.json();
 statusBox.textContent=(s.configured?'钥匙串：已保存授权码':'钥匙串：尚未保存授权码')+' · '+({idle:'尚未验证',running:'查询中',ok:'查询验证成功',error:'上次查询未完成'}[s.test_state]||'状态未知');
 if(s.error)errorBox.textContent=s.error;
 }catch{statusBox.textContent='无法读取本机状态，请刷新页面。';}
}
async function run(save){
 let token='';
 const query=queryInput.value;
 if(save){token=tokenInput.value;tokenInput.value='';if(!token.trim()){errorBox.textContent='请输入携程授权码。';return;}}
 buttons.forEach(b=>b.disabled=true);errorBox.textContent='';result.textContent='';document.getElementById('hint').textContent='正在查询携程，请稍候…';
 try{const body=save?{token,query}:{query};const pending=fetch(save?'/api/save-and-test':'/api/query',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body),cache:'no-store'});token='';if(save)body.token='';
 const response=await pending;const data=await response.json();
 if(!response.ok||!data.ok)throw new Error(data.error||'携程查询未完成。');
 result.textContent=data.result;document.getElementById('hint').textContent='以上为携程官方接口返回的旅行信息。';
 }catch(e){errorBox.textContent=e.message||'查询未完成，请稍后重试。';document.getElementById('hint').textContent='未获得可显示的查询结果。';}
 finally{token='';tokenInput.value='';buttons.forEach(b=>b.disabled=false);await refreshStatus();}
}
document.getElementById('setup').addEventListener('submit',e=>{e.preventDefault();run(true);});
document.getElementById('again').addEventListener('click',()=>run(false));refreshStatus();
</script></html>'''


def create_server(service: ConnectorService, port: int = 0) -> ThreadingHTTPServer:
    csrf = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(24)

    class Handler(BaseHTTPRequestHandler):
        server_version = "LocalCtrip"
        sys_version = ""

        def log_message(self, *args):
            pass

        def _origin(self):
            return "http://127.0.0.1:" + str(self.server.server_address[1])

        def _valid_host(self):
            return self.headers.get_all("Host", []) == ["127.0.0.1:" + str(self.server.server_address[1])]

        def _valid_origin(self, required=False):
            origins = self.headers.get_all("Origin", [])
            return origins == [self._origin()] or (not required and not origins)

        def _send(self, status, value, html_page=False):
            raw = value.encode("utf-8") if html_page else json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8" if html_page else "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'nonce-" + nonce + "'; style-src 'nonce-" + nonce + "'; connect-src 'self'; img-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if not self._valid_host() or not self._valid_origin():
                self._send(403, {"ok": False, "error": "本机访问校验失败。"})
            elif self.path == "/":
                self._send(200, PAGE.replace("__NONCE__", nonce).replace("__CSRF__", json.dumps(csrf)), True)
            elif self.path == "/api/status":
                self._send(200, service.status())
            else:
                self._send(404, {"ok": False, "error": "页面不存在。"})

        def do_POST(self):
            if not self._valid_host() or not self._valid_origin(required=True):
                self._send(403, {"ok": False, "error": "本机访问校验失败。"})
                return
            supplied_csrf = self.headers.get_all("X-CSRF-Token", [])
            if len(supplied_csrf) != 1 or not hmac.compare_digest(supplied_csrf[0].encode("utf-8"), csrf.encode("ascii")):
                self._send(403, {"ok": False, "error": "页面安全校验失败，请刷新后重试。"})
                return
            if self.path not in ("/api/save-and-test", "/api/query"):
                self._send(404, {"ok": False, "error": "接口不存在。"})
                return
            if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                self._send(415, {"ok": False, "error": "请求格式不正确。"})
                return
            try:
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or self.headers.get("Transfer-Encoding"):
                    raise ValueError()
                length = int(lengths[0])
                if length < 1 or length > MAX_REQUEST_BYTES:
                    raise ValueError()
                self.connection.settimeout(10)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError()
                payload = json.loads(body.decode("utf-8"))
                body = b""
                if not isinstance(payload, dict):
                    raise ValueError()
            except Exception:
                self._send(400, {"ok": False, "error": "请求内容不正确或过大。"})
                return
            try:
                if self.path == "/api/save-and-test":
                    token = payload.pop("token", None)
                    result = service.save_and_test(token, payload.get("query"))
                    token = None
                else:
                    result = service.query(payload.get("query"))
                self._send(200, {"ok": True, "result": result})
            except ConnectorError as exc:
                self._send(400, {"ok": False, "error": str(exc)})
            except Exception:
                self._send(500, {"ok": False, "error": "本机查询未完成，请稍后重试。"})
            finally:
                payload.clear()

    class LocalServer(ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, request_socket, client_address):
            pass

        def get_request(self):
            sock, addr = super().get_request()
            sock.settimeout(10)
            return sock, addr

    return LocalServer(("127.0.0.1", port), Handler)


def read_ui_status(port: int) -> dict:
    if not 1 <= port <= 65535:
        raise ConnectorError("本机页面端口不正确。")
    try:
        opener = request.build_opener(request.ProxyHandler({}), NoRedirectHandler())
        with opener.open("http://127.0.0.1:" + str(port) + "/api/status", timeout=25) as response:
            raw = response.read(4097)
            if len(raw) > 4096:
                raise ValueError()
            value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict) or not isinstance(value.get("configured"), bool):
            raise ValueError()
        if value.get("test_state") not in ("idle", "running", "ok", "error"):
            raise ValueError()
        return {"configured": value["configured"], "test_state": value["test_state"],
                "error": None if not value.get("error") else "上次操作未完成，请查看本机配置页面。"}
    except Exception:
        raise ConnectorError("无法读取本机配置页面状态，请检查端口及服务是否运行。")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="携程官方只读查询连接器；授权码仅通过本机页面录入钥匙串。")
    parser.add_argument("--keychain-helper", default=os.environ.get("PHONEAGENT_CTRIP_KEYCHAIN_HELPER", str(DEFAULT_HELPER)))
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup-ui", help="打开本机授权码输入及验证服务")
    setup.add_argument("--port", type=int, default=0)
    status = sub.add_parser("status", help="只读取无敏感配置状态")
    status.add_argument("--ui-port", type=int, help="读取正在运行的配置页测试状态")
    query_command = sub.add_parser("query", help="使用钥匙串授权码执行携程只读查询")
    query_command.add_argument("text")
    args = parser.parse_args(argv)
    try:
        if args.command == "status" and args.ui_port is not None:
            print(json.dumps(read_ui_status(args.ui_port), ensure_ascii=False))
            return 0
        service = ConnectorService(KeychainStore(args.keychain_helper))
        if args.command == "status":
            print(json.dumps(service.status(), ensure_ascii=False))
        elif args.command == "query":
            print(json.dumps({"ok": True, "result": service.query(args.text)}, ensure_ascii=False))
        elif args.command == "setup-ui":
            if not 0 <= args.port <= 65535:
                raise ConnectorError("本机页面端口不正确。")
            server = create_server(service, args.port)
            print(json.dumps({"url": "http://127.0.0.1:" + str(server.server_address[1]) + "/", "pid": os.getpid()}, ensure_ascii=False), flush=True)
            try:
                server.serve_forever(poll_interval=0.25)
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
        return 0
    except ConnectorError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    except Exception:
        print(json.dumps({"ok": False, "error": "本机连接器未能完成操作。"}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
