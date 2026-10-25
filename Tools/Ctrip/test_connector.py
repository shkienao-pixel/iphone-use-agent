"""Offline transport and browser-boundary checks. Never access real credentials."""
import http.client
import io
import json
import re
import threading
import time
import unittest
from urllib.parse import quote

import connector as c

TOKEN = "fixture-Ctrip/Key+abcdefgh"


class Response(io.BytesIO):
    status = 200
    headers = {}

    def geturl(self):
        return c.API_URL


class Opener:
    def __init__(self, response):
        self.response = response
        self.sent = None

    def open(self, req, timeout):
        self.sent = req
        return self.response


class MemoryStore:
    def __init__(self):
        self.value = None

    def configured(self):
        return self.value is not None

    def get(self):
        if self.value is None:
            raise c.ConnectorError("尚未配置")
        return self.value

    def set(self, value):
        self.value = value


class ProtocolTests(unittest.TestCase):
    def test_result_only(self):
        self.assertEqual(c.extract_result({"result": "真实结果", "state": {"token": TOKEN}}, TOKEN), "真实结果")
        self.assertEqual(c.extract_result({"result": {"content": "正文", "token": TOKEN}}, TOKEN), "正文")
        for payload in ({"state": {"content": "内部内容"}}, {"data": {"result": "不采用"}}, {"result": 42}):
            with self.subTest(payload=payload), self.assertRaises(c.ConnectorError):
                c.extract_result(payload, TOKEN)

    def test_business_errors_do_not_echo(self):
        for extra in ({"error": TOKEN}, {"code": 403}, {"success": False}):
            with self.assertRaises(c.ConnectorError) as caught:
                c.extract_result(dict(result=TOKEN, **extra), TOKEN)
            self.assertNotIn(TOKEN, str(caught.exception))

    def test_encoded_credentials_are_removed(self):
        variants = [TOKEN, quote(TOKEN, safe=""), "".join("\\u%04x" % ord(ch) for ch in TOKEN)]
        for variant in variants:
            result = c.extract_result({"result": "授权=" + variant}, TOKEN)
            self.assertNotIn(TOKEN, result)
            self.assertNotIn(variant, result)

    def test_fixed_https_body(self):
        opener = Opener(Response(json.dumps({"result": "查询结果"}).encode()))
        self.assertEqual(c.call_ctrip("上海景点", TOKEN, opener=opener), "查询结果")
        self.assertEqual(opener.sent.full_url, c.API_URL)
        self.assertEqual(opener.sent.method, "POST")
        self.assertEqual(json.loads(opener.sent.data), {"inputs": {"token": TOKEN, "query": "上海景点"}})
        self.assertNotIn(TOKEN, opener.sent.full_url)

    def test_response_origin_and_size(self):
        changed = Response(b'{"result":"ignored"}')
        changed.geturl = lambda: "https://example.org/"
        large = Response(b"x" * (c.MAX_RESPONSE_BYTES + 1))
        for response in (changed, large):
            with self.assertRaises(c.ConnectorError):
                c.call_ctrip("上海景点", TOKEN, opener=Opener(response))

    def test_redirect_is_rejected(self):
        with self.assertRaises(c.ConnectorError):
            c.NoRedirectHandler().redirect_request(None, None, 302, "", {}, "https://example.org/")

    def test_timeout_is_bounded(self):
        class Slow:
            def open(self, req, timeout):
                time.sleep(0.15)
                return Response(b'{"result":"late"}')
        started = time.monotonic()
        with self.assertRaises(c.ConnectorError):
            c.call_ctrip("上海景点", TOKEN, opener=Slow(), timeout=0.02)
        self.assertLess(time.monotonic() - started, 0.12)

    def test_invalid_credentials(self):
        for token in ("", "short", "授权码不入聊天", "abcd efghijk", "a" * 4097):
            with self.subTest(length=len(token)), self.assertRaises(c.ConnectorError):
                c.validate_token(token)


class BrowserBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.service = c.ConnectorService(self.store, query_fn=lambda query, token: "测试结果 " + token)
        self.server = c.create_server(self.service)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def send(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        result = response.status, dict(response.getheaders()), response.read().decode()
        conn.close()
        return result

    def test_csrf_host_origin_and_safe_status(self):
        status, headers, page = self.send("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertIn("no-store", headers["Cache-Control"])
        self.assertEqual(self.send("GET", "/", headers={"Host": "evil.invalid"})[0], 403)
        csrf = json.loads(re.search(r"const csrf = (.+);", page)[1])
        body = json.dumps({"token": TOKEN, "query": "仅供测试的查询"})
        base = {"Origin": f"http://127.0.0.1:{self.port}", "Content-Type": "application/json"}
        self.assertEqual(self.send("POST", "/api/save-and-test", body, base)[0], 403)
        valid = dict(base, **{"X-CSRF-Token": csrf})
        foreign = dict(valid, Origin="https://evil.invalid")
        self.assertEqual(self.send("POST", "/api/save-and-test", body, foreign)[0], 403)
        self.assertIsNone(self.store.value)
        status, _, result = self.send("POST", "/api/save-and-test", body, valid)
        self.assertEqual(status, 200)
        self.assertNotIn(TOKEN, result)
        self.assertEqual(self.store.value, TOKEN)
        _, _, state = self.send("GET", "/api/status")
        self.assertEqual(json.loads(state)["test_state"], "ok")
        for private in (TOKEN, "仅供测试的查询", "测试结果"):
            self.assertNotIn(private, state)


if __name__ == "__main__":
    unittest.main()
