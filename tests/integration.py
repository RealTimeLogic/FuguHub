from __future__ import annotations

import base64
import contextlib
import hashlib
import http.cookiejar
import io
import json
import os
import quopri
import re
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
import warnings
import zipfile
import zlib
from pathlib import Path


os.environ.pop("SSLKEYLOGFILE", None)

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ROOT = ROOT / ".test-runtime"
MAKO = shutil.which("mako")
CHROME_CANDIDATES = (
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    Path(r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"),
    Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
)


class TestFailure(RuntimeError):
    pass


class SmtpCaptureServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, failures: int = 0) -> None:
        self.messages: list[bytes] = []
        self.attempts: list[bytes] = []
        self.failures_remaining = failures
        super().__init__(("127.0.0.1", 0), SmtpCaptureHandler)


class SmtpCaptureHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        self.wfile.write(b"220 localhost FuguHub test SMTP\r\n")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            command = line.decode("ascii", "replace").strip()
            verb = command.split(" ", 1)[0].upper()
            if verb in ("EHLO", "HELO"):
                self.wfile.write(b"250-localhost\r\n250 SIZE 104857600\r\n")
            elif verb in ("MAIL", "RCPT", "RSET", "NOOP"):
                self.wfile.write(b"250 OK\r\n")
            elif verb == "DATA":
                self.wfile.write(b"354 End data with <CRLF>.<CRLF>\r\n")
                chunks: list[bytes] = []
                while True:
                    data = self.rfile.readline()
                    if data == b".\r\n" or not data:
                        break
                    if data.startswith(b".."):
                        data = data[1:]
                    chunks.append(data)
                message = b"".join(chunks)
                self.server.attempts.append(message)  # type: ignore[attr-defined]
                if self.server.failures_remaining > 0:  # type: ignore[attr-defined]
                    self.server.failures_remaining -= 1  # type: ignore[attr-defined]
                    self.wfile.write(b"451 Temporary test failure\r\n")
                else:
                    self.server.messages.append(message)  # type: ignore[attr-defined]
                    self.wfile.write(b"250 Queued\r\n")
            elif verb == "QUIT":
                self.wfile.write(b"221 Bye\r\n")
                return
            else:
                self.wfile.write(b"502 Unsupported command\r\n")


@contextlib.contextmanager
def smtp_capture_server(failures: int = 0):
    server = SmtpCaptureServer(failures)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def remove_tree(path: Path) -> None:
    for attempt in range(10):
        if not path.exists():
            return
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if attempt == 9:
                raise
            time.sleep(0.2)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


class MakoProcess:
    def __init__(
        self,
        home: Path,
        mount: str = "",
        extra_loads: tuple[str, ...] = (),
        application: str = "cms",
        extra_args: tuple[str, ...] = (),
    ) -> None:
        self.home = home
        self.mount = mount
        self.extra_loads = extra_loads
        self.application = application
        self.extra_args = extra_args
        self.proc: subprocess.Popen[str] | None = None
        self.lines: list[str] = []
        self.port: int | None = None

    def start(self) -> "MakoProcess":
        check(bool(MAKO), "mako executable was not found on PATH")
        app_arg = (
            f"-l{self.mount}::{self.application}"
            if self.mount
            else f"-l::{self.application}"
        )
        self.proc = subprocess.Popen(
            [str(MAKO), app_arg, *self.extra_loads, *self.extra_args],
            cwd=self.home,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

        def read_output() -> None:
            assert self.proc and self.proc.stdout
            for line in self.proc.stdout:
                self.lines.append(line.rstrip())
                match = re.search(r"Server listening on IPv4 port (\d+)", line)
                if match:
                    self.port = int(match.group(1))

        threading.Thread(target=read_output, daemon=True).start()
        deadline = time.time() + 15
        expected_apps = 1 + len(self.extra_loads)
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise TestFailure("Mako exited during startup:\n" + "\n".join(self.lines))
            loaded_apps = sum(
                1
                for line in self.lines
                if re.match(r'^Loading .+ as ".+" : (?:ok|failed:)', line)
            )
            if self.port and loaded_apps >= expected_apps:
                return self
            time.sleep(0.05)
        raise TestFailure("Timed out waiting for Mako:\n" + "\n".join(self.lines))

    @property
    def origin(self) -> str:
        check(self.port is not None, "Mako has not started")
        return f"http://127.0.0.1:{self.port}"

    @property
    def base(self) -> str:
        return self.origin + (f"/{self.mount}/" if self.mount else "/")

    def stop(self) -> None:
        if not self.proc or self.proc.poll() is not None:
            return
        self.proc.terminate()
        try:
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)

    def __enter__(self) -> "MakoProcess":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.stop()


class HeadlessPage:
    def __init__(self, chrome: Path, url: str, profile: Path) -> None:
        self.chrome = chrome
        self.url = url
        self.profile = profile
        self.proc: subprocess.Popen[str] | None = None
        self.debug_port: int | None = None
        self.socket_url: str | None = None

    @staticmethod
    def _target_url(url: str) -> tuple[str, str, int | None, str, str]:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
        if port is None:
            port = 443 if parsed.scheme == "https" else 80 if parsed.scheme == "http" else None
        return (
            parsed.scheme.lower(),
            (parsed.hostname or "").lower(),
            port,
            parsed.path or "/",
            parsed.query,
        )

    def start(self) -> "HeadlessPage":
        remove_tree(self.profile)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.debug_port = listener.getsockname()[1]
        self.proc = subprocess.Popen(
            [
                str(self.chrome),
                "--headless=new",
                "--disable-gpu",
                "--no-sandbox",
                f"--remote-debugging-port={self.debug_port}",
                f"--user-data-dir={self.profile}",
                self.url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 15
        endpoint = f"http://127.0.0.1:{self.debug_port}/json/list"
        expected_url = self._target_url(self.url)
        try:
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    raise TestFailure("headless browser exited during startup")
                try:
                    with urllib.request.urlopen(endpoint, timeout=1) as response:
                        targets = json.load(response)
                    page = next(
                        (
                            target
                            for target in targets
                            if target.get("type") == "page"
                            and self._target_url(target.get("url", "")) == expected_url
                        ),
                        None,
                    )
                    if page and page.get("webSocketDebuggerUrl"):
                        self.socket_url = page["webSocketDebuggerUrl"]
                        return self
                except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError):
                    pass
                time.sleep(0.1)
            raise TestFailure("timed out waiting for the headless browser")
        except Exception:
            self.stop()
            raise

    def evaluate(self, expression: str) -> object:
        check(bool(self.socket_url), "headless browser is not connected")
        encoded = base64.b64encode(expression.encode()).decode("ascii")
        result = subprocess.run(
            [
                "node",
                str(ROOT / "tests" / "cdp_eval.js"),
                str(self.socket_url),
                encoded,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        check(
            result.returncode == 0,
            "DevTools evaluation failed: " + (result.stderr or result.stdout),
        )
        return json.loads(result.stdout)

    def wait_for(self, expression: str, timeout: float = 15) -> object:
        deadline = time.time() + timeout
        last: object = None
        while time.time() < deadline:
            last = self.evaluate(expression)
            if last:
                return last
            time.sleep(0.2)
        raise TestFailure(f"browser condition timed out: {expression}; last={last!r}")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        remove_tree(self.profile)

    def __enter__(self) -> "HeadlessPage":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.stop()


class Browser:
    def __init__(
        self, origin: str, default_headers: dict[str, str] | None = None
    ) -> None:
        self.origin = origin
        self.default_headers = dict(default_headers or {})
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(self.jar),
            urllib.request.HTTPRedirectHandler(),
        )

    def request(
        self,
        path: str,
        *,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        method: str | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        url = path if path.startswith("http") else self.origin + path
        request_headers = dict(self.default_headers)
        request_headers.update(headers or {})
        request = urllib.request.Request(
            url, data=data, headers=request_headers, method=method
        )
        try:
            response = self.opener.open(request, timeout=8)
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers.items()), exc.read()
        with response:
            return response.status, dict(response.headers.items()), response.read()

    def form(
        self,
        path: str,
        fields: dict[str, str],
        *,
        multipart: bool = False,
        files: dict[str, tuple[str, bytes, str]] | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        if multipart or files:
            boundary = "----FuguHubTest" + uuid.uuid4().hex
            chunks: list[bytes] = []
            for name, value in fields.items():
                chunks.extend(
                    (
                        f"--{boundary}\r\n".encode(),
                        f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                        str(value).encode(),
                        b"\r\n",
                    )
                )
            for name, (filename, content, file_type) in (files or {}).items():
                chunks.extend(
                    (
                        f"--{boundary}\r\n".encode(),
                        (
                            f'Content-Disposition: form-data; name="{name}"; '
                            f'filename="{filename}"\r\n'
                        ).encode(),
                        f"Content-Type: {file_type}\r\n\r\n".encode(),
                        content,
                        b"\r\n",
                    )
                )
            chunks.append(f"--{boundary}--\r\n".encode())
            body = b"".join(chunks)
            content_type = f"multipart/form-data; boundary={boundary}"
        else:
            body = urllib.parse.urlencode(fields).encode()
            content_type = "application/x-www-form-urlencoded"
        request_headers = dict(headers or {})
        request_headers["Content-Type"] = content_type
        return self.request(
            path,
            data=body,
            headers=request_headers,
            method="POST",
        )


class McpClient:
    def __init__(
        self, browser: Browser, endpoint: str, token: str, origin: str | None = None
    ) -> None:
        self.browser = browser
        self.endpoint = endpoint
        self.token = token
        self.origin = origin
        self.session_id: str | None = None
        self.request_id = 0

    def _post(self, payload: dict) -> tuple[int, dict[str, str], dict]:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id
        if self.origin:
            headers["Origin"] = self.origin
        status, response_headers, body = self.browser.request(
            self.endpoint,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST",
        )
        parsed = json.loads(body.decode()) if body else {}
        return status, response_headers, parsed

    def initialize(self) -> dict:
        self.request_id += 1
        status, headers, result = self._post(
            {
                "jsonrpc": "2.0",
                "id": self.request_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "FuguHub integration tests", "version": "1"},
                },
            }
        )
        check(status == 200, f"MCP initialize returned HTTP {status}: {result}")
        self.session_id = next(
            (value for key, value in headers.items() if key.lower() == "mcp-session-id"),
            None,
        )
        check(bool(self.session_id), "MCP initialize did not return a session id")
        check("result" in result, f"MCP initialize failed: {result}")
        return result["result"]

    def rpc(self, method: str, params: dict | None = None) -> dict:
        self.request_id += 1
        status, _, result = self._post(
            {
                "jsonrpc": "2.0",
                "id": self.request_id,
                "method": method,
                "params": params or {},
            }
        )
        check(status == 200, f"MCP {method} returned HTTP {status}: {result}")
        check("error" not in result, f"MCP {method} protocol error: {result}")
        return result["result"]

    def call(self, name: str, arguments: dict | None = None) -> dict:
        return self.rpc("tools/call", {"name": name, "arguments": arguments or {}})


def mcp_structured(result: dict) -> dict:
    value = result.get("structuredContent")
    check(isinstance(value, dict), f"MCP tool result has no structured content: {result}")
    return value


def configure_mcp(browser: Browser, base: str, token: str) -> None:
    code, _, body = admin_post(
        browser,
        base,
        "mcp/",
        {"action": "save", "token": token},
    )
    check(code == 200, f"saving the MCP token failed: {body[:500]!r}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fresh_runtime(name: str) -> Path:
    path = RUNTIME_ROOT / name
    remove_tree(path)
    path.mkdir(parents=True)
    for directory in ("cms", "themes", "assets", "docs"):
        source = ROOT / directory
        destination = path / directory
        if source.exists():
            ignore = shutil.ignore_patterns(".preload", ".lua") if directory == "assets" else None
            shutil.copytree(source, destination, ignore=ignore)
        else:
            destination.mkdir()
    (path / "data").mkdir()
    return path


def text(body: bytes, headers: dict[str, str]) -> str:
    encoding = next(
        (value for key, value in headers.items() if key.lower() == "content-encoding"),
        "",
    )
    if encoding.lower() == "deflate":
        try:
            body = zlib.decompress(body, -zlib.MAX_WBITS)
        except zlib.error:
            body = zlib.decompress(body)
    return body.decode("utf-8", "replace")


def csrf_from(body: bytes) -> str:
    match = re.search(rb"name=['\"]_csrf['\"] value=['\"]([^'\"]+)", body)
    check(
        bool(match),
        f"admin page did not contain a CSRF token: {body[:1000]!r}",
    )
    return match.group(1).decode()


def form_login(
    browser: Browser, path: str, username: str, password: str
) -> tuple[int, dict[str, str], bytes]:
    code, _, login_body = browser.request(path)
    check(code == 200 and b"ba_seed" in login_body,
          f"login challenge was not presented at {path}: HTTP {code}")
    seed = re.search(rb"name='ba_seed' value='([^']*)'", login_body)
    seedkey = re.search(rb"name='ba_seedkey' value='([^']*)'", login_body)
    check(bool(seed and seedkey), "login challenge fields are missing")
    digest = hashlib.sha1(password.encode() + seed.group(1)).hexdigest()
    return browser.form(
        path,
        {
            "ba_username": username,
            "ba_password": digest,
            "ba_seed": seed.group(1).decode(),
            "ba_seedkey": seedkey.group(1).decode(),
        },
    )


def admin_get(browser: Browser, base: str, path: str) -> tuple[str, str]:
    status, headers, body = browser.request(base + "admin/" + path)
    check(status == 200, f"GET admin/{path} returned {status}")
    return csrf_from(body), text(body, headers)


def admin_post(
    browser: Browser,
    base: str,
    path: str,
    fields: dict[str, str],
    *,
    multipart: bool = False,
    token: str | None = None,
) -> tuple[int, dict[str, str], bytes]:
    if token is None:
        token, _ = admin_get(browser, base, path)
    payload = dict(fields)
    payload["_csrf"] = token
    return browser.form(base + "admin/" + path, payload, multipart=multipart)


def create_content(
    browser: Browser,
    base: str,
    *,
    path: str,
    title: str,
    body: str,
    render_mode: str = "html",
    content_type: str = "page",
    status: str = "published",
    cache_policy: str = "default",
    category_ids: list[int] | None = None,
) -> None:
    fields = {
        "type": content_type,
        "status": status,
        "title": title,
        "path": path,
        "render_mode": render_mode,
        "cache_policy": cache_policy,
        "meta_description": "",
        "head_html": "",
        "body_html": body,
    }
    for category_id in category_ids or []:
        fields[f"category_{category_id}"] = "1"
    code, _, response = admin_post(
        browser,
        base,
        "content/new",
        fields,
        multipart=True,
    )
    check(code == 200, f"creating {path} failed with {code}: {response[:300]!r}")


def create_lsp_test_pages(browser: Browser, base: str) -> None:
    pages = (
        (
            "/lsp-basic/",
            "LSP Basic",
            """<section id="lsp-basic">
<?lsp local answer = 6 * 7 ?>
<p>Expression result: <?lsp= answer ?></p>
<p>Request method: <?lsp= request:method() ?></p>
</section>""",
        ),
        (
            "/lsp-state-a/",
            "LSP State A",
            """<?lsp
page.count = (page.count or 0) + 1
response:write("<p data-lsp-state='a' data-lsp-count='", page.count, "'>State A</p>")
?>""",
        ),
        (
            "/lsp-state-b/",
            "LSP State B",
            """<?lsp
page.count = (page.count or 0) + 1
response:write("<p data-lsp-state='b' data-lsp-count='", page.count, "'>State B</p>")
?>""",
        ),
        (
            "/lsp-runtime/",
            "LSP Runtime",
            """<?lsp
local threadOk = app.db and app.db.thread and "writer-thread-ok" or "writer-thread-missing"
local eventsOk = app.cms and type(app.cms.emit) == "function" and "events-ok" or "events-missing"
response:write("<p data-lsp-base='", app.baseUri, "' data-lsp-url='", app.url("/lsp-basic/"),
               "'>", threadOk, " ", eventsOk, "</p>")
?>""",
        ),
    )
    for path, title, body in pages:
        create_content(
            browser,
            base,
            path=path,
            title=title,
            body=body,
            render_mode="lsp",
            cache_policy="no-cache",
        )


def verify_lsp_test_pages(browser: Browser, public_base: str) -> None:
    code, headers, body = browser.request(public_base + "lsp-basic/", headers={"Accept-Encoding": "deflate"})
    rendered = text(body, headers)
    check(
        code == 200 and "Expression result: 42" in rendered and "Request method: GET" in rendered,
        f"{public_base}lsp-basic/ did not execute database LSP",
    )

    state_a_counts = []
    for _ in range(2):
        code, headers, body = browser.request(public_base + "lsp-state-a/")
        rendered = text(body, headers)
        match = re.search(r"data-lsp-state='a' data-lsp-count='(\d+)'", rendered)
        check(
            code == 200 and bool(match),
            f"LSP state A marker is missing (status {code}): {rendered[:2000]}",
        )
        state_a_counts.append(int(match.group(1)))
    check(state_a_counts == [1, 2], f"LSP page table did not persist: {state_a_counts}")

    code, headers, body = browser.request(public_base + "lsp-state-b/")
    rendered = text(body, headers)
    check(
        code == 200 and "data-lsp-state='b' data-lsp-count='1'" in rendered,
        "LSP page tables are not isolated by content page",
    )

    code, headers, body = browser.request(public_base + "lsp-runtime/")
    rendered = text(body, headers)
    expected_url = public_base + "lsp-basic/"
    check(code == 200 and "writer-thread-ok events-ok" in rendered, "CMS APIs are missing from database LSP")
    check(
        f"data-lsp-base='{public_base}'" in rendered and f"data-lsp-url='{expected_url}'" in rendered,
        f"database LSP generated a non-mount-safe URL for {public_base}",
    )


def database_path(runtime: Path) -> Path:
    return runtime / "data" / "cms.sqlite.db"


def install_zip_theme(runtime: Path) -> None:
    source = runtime / "themes" / "default"
    destination = runtime / "themes" / "zipped.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in source.rglob("*"):
            if file.is_file():
                data = file.read_bytes()
                if file.name == "style.css":
                    data += b"\n/* zipped-theme-marker */\n"
                archive.writestr(file.relative_to(source).as_posix(), data)
    with zipfile.ZipFile(runtime / "themes" / "broken.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("style.css", "/* incomplete theme */")


def install_assets_zip(runtime: Path) -> None:
    (runtime / "assets" / "probe.txt").write_text("directory-assets", encoding="ascii")
    with zipfile.ZipFile(runtime / "assets.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for file in (runtime / "assets").rglob("*"):
            if file.is_file() and file.name != "probe.txt":
                archive.write(file, file.relative_to(runtime / "assets").as_posix())
        archive.writestr("probe.txt", "zip-assets")


def install_plugin_fixtures(runtime: Path) -> None:
    plugins = runtime / "plugins"
    base = plugins / "base-service"
    (base / ".lua").mkdir(parents=True)
    (base / ".lua" / "service.lua").write_text(
        """local service = { value = "dependency-service", loads = 1 }
return service
""",
        encoding="ascii",
    )
    (base / ".preload").write_text(
        """local first = pluginreq "service"
local second = require "service"
local pluginApp = app

return {
   id = "base-service",
   start = function(ctx)
      local probeDir = ba.create.dir("plugin-probe")
      probeDir:setfunc(function(env, relpath)
         if relpath ~= "" then return false end
         env.response:json {
            id = ctx.id,
            value = first.value,
            moduleCached = first == second,
            dataIo = ctx.dataIo ~= nil,
            baseUri = pluginApp.baseUri
         }
         return true
      end)
      ctx:mount("plugin-probe", probeDir)
      ctx:trace("fixture started")
      return first
   end,
   stop = function(ctx)
      ctx:trace("fixture stopped")
   end
}
""",
        encoding="ascii",
    )

    consumer_preload = """return {
   id = "consumer",
   requires = { "base-service" },
   start = function(ctx)
      local service = ctx:requirePlugin("base-service")
      local saved = ""
      ctx.admin:addPage {
         id = "status",
         label = "Plugin Status",
         path = "",
         order = 900,
         handler = function(env)
            if env.request:method() == "POST" then
               saved = tostring(ctx.admin:postData(env).value or "")
            end
            return ctx.admin:layout(env, "Plugin Status", function()
               env.response:write("<section id='plugin-status' class='panel'>",
                  service.value, "<form method='post'>")
               ctx.admin:csrfField(env)
               env.response:write("<input name='value'><button>Save</button></form>",
                  "<span id='plugin-saved'>", saved, "</span></section>")
            end)
         end
      }
   end
}
"""
    with zipfile.ZipFile(plugins / "consumer.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(".preload", consumer_preload)

    broken = plugins / "broken"
    broken.mkdir()
    (broken / ".preload").write_text(
        """return {
   id = "broken",
   start = function()
      error("intentional fixture failure")
   end
}
""",
        encoding="ascii",
    )

    blocked = plugins / "blocked"
    blocked.mkdir()
    (blocked / ".preload").write_text(
        """return {
   id = "blocked",
   requires = { "broken" },
   start = function()
      error("blocked plugin must not start")
   end
}
""",
        encoding="ascii",
    )


def plugin_source(name: str) -> Path:
    for directory in ("plugins", "xplugins"):
        source = ROOT / directory / name
        if source.is_dir():
            return source
    raise AssertionError(f"plugin source is unavailable: {name}")


def install_identity_plugin(runtime: Path) -> None:
    plugins = runtime / "plugins"
    plugins.mkdir(exist_ok=True)
    shutil.copytree(
        plugin_source("identity-access"),
        plugins / "identity-access",
    )
    probe = plugins / "identity-probe"
    probe.mkdir()
    (probe / ".preload").write_text(
        """return {
   id = "identity-probe",
   requires = { "identity-access" },
   start = function(ctx)
      local identity = ctx:requirePlugin("identity-access")
      local endpoint = ba.create.dir("identity-probe")
      local authenticator
      local authorizer
      local function rebuildSecurity()
         authenticator = identity.newDavAuthenticator {
            realm = "FuguHub Identity Test"
         }
         authorizer = identity.newAuthorizer {
            probe = {
               urls = { "/*" },
               methods = { "GET" },
               roles = { "probe-user" }
            }
         }
      end
      rebuildSecurity()
      ctx:own(identity.onChange(rebuildSecurity))
      endpoint:setfunc(function(env, relpath)
         if not authenticator:authenticate(env.request, relpath) then
            return true
         end
         if not authorizer:authorize(
            env.request, env.request:method(), "/" .. (relpath ~= "" and relpath or "probe")) then
            env.response:senderror(403, "Forbidden")
            return true
         end
         env.response:json {
            user = identity.currentUser(env),
            allowed = identity.hasRole(env, "probe-user")
         }
         return true
      end)
      ctx:mount("identity-probe", endpoint)
   end
}
""",
        encoding="ascii",
    )


def install_file_services_plugin(runtime: Path) -> None:
    install_identity_plugin(runtime)
    shutil.copytree(
        plugin_source("file-services"),
        runtime / "plugins" / "file-services",
    )


def install_large_file_mailer_plugin(runtime: Path) -> None:
    install_file_services_plugin(runtime)
    shutil.copytree(
        plugin_source("large-file-mailer"),
        runtime / "plugins" / "large-file-mailer",
    )
    probe = runtime / "plugins" / "mailer-probe"
    probe.mkdir()
    (probe / ".preload").write_text(
        r'''return {
   id = "mailer-probe",
   requires = { "large-file-mailer" },
   start = function(ctx)
      local mailer = ctx:requirePlugin("large-file-mailer")
      local endpoint = ba.create.dir "mailer-probe"
      endpoint:setfunc(function(env, relpath)
         if relpath == "parse" then
            local message, err = mailer.parseTemplate(
               "From: sender@example.test\r\n" ..
               "To: receiver@example.test\r\n" ..
               "Subject: Parser fixture\r\n" ..
               "Content-Type: text/plain; charset=utf-8\r\n" ..
               "Content-Transfer-Encoding: 7bit\r\n\r\n" ..
               "Parsed body")
            env.response:json {
               ok = message ~= nil,
               error = err,
               subject = message and message.subject,
               body = message and (message.txtbody or message.body)
            }
            return true
         end
         local bulkCount = relpath:match("^create%-bulk%-(%d+)$")
         if bulkCount then
            bulkCount = tonumber(bulkCount)
            if bulkCount < 1 or bulkCount > 2000 then
               env.response:senderror(400, "Bulk fixture count is out of range")
               return true
            end
            local recipients = {}
            for index = 1, bulkCount do
               recipients[index] = {
                  email = string.format("bulk-%04d@example.test", index),
                  firstName = "Bulk",
                  lastName = tostring(index)
               }
            end
            local job = mailer.createJob {
               sender = "mail-sender",
               deliveryMode = "email",
               subject = "Bulk dry run {{LAST_NAME}}",
               textBody = "Hello {{FIRST_NAME}} {{LAST_NAME}}",
               htmlBody = "",
               recipients = recipients,
               files = {}
            }
            env.response:json { ok = true, job = job }
            return true
         end
         if relpath == "create-attachment" or relpath == "create-link" or
            relpath == "create-protected-link" or
            relpath == "create-draft-attachment" or
            relpath == "create-draft-link" then
            local mode = relpath:find("attachment", 1, true) and "attachment" or "link"
            local job = mailer.createJob {
               sender = "mail-sender",
               deliveryMode = mode,
               subject = "Mailer {{NAME}}",
               textBody = mode == "link" and "Hello {{NAME}}" or
                  "Hello {{NAME}}\n{{DOWNLOAD_LINKS}}",
               htmlBody = mode == "link" and "<p>Hello {{NAME}}</p>" or
                  "<p>Hello {{NAME}}</p>{{DOWNLOAD_LINKS}}",
               linkPassword = relpath == "create-protected-link" and "grant-password" or "",
               recipients = {
                  { email = "recipient@example.test", firstName = "Test",
                     lastName = "Recipient" }
               },
               files = { "/mailer-fixture.txt" }
            }
            if not relpath:find("draft", 1, true) then
               job = assert(mailer.queueJob(job.id))
            end
            env.response:json { ok = true, job = job }
            return true
         end
         local queueId = relpath:match("^queue/(%d+)$")
         if queueId then
            local job, err = mailer.queueJob(queueId)
            env.response:json { ok = job ~= nil, job = job, error = err }
            return true
         end
         local id = relpath:match("^job/(%d+)$")
         if id then
            local job, err = mailer.jobDetails(id)
            env.response:json { ok = job ~= nil, job = job, error = err }
            return true
         end
         local cancelId = relpath:match("^cancel/(%d+)$")
         if cancelId then
            local job, err = mailer.cancelJob(cancelId)
            env.response:json { ok = job ~= nil, job = job, error = err }
            return true
         end
         return false
      end)
      ctx:mount("mailer-probe", endpoint)
   end
}
''',
        encoding="ascii",
    )


def digest_get(url: str, username: str, password: str) -> tuple[int, bytes]:
    manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    manager.add_password(None, url, username, password)
    opener = urllib.request.build_opener(
        urllib.request.HTTPDigestAuthHandler(manager),
        urllib.request.HTTPBasicAuthHandler(manager),
    )
    try:
        with opener.open(url, timeout=8) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def digest_request(
    url: str,
    username: str,
    password: str,
    *,
    method: str,
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
    manager.add_password(None, url, username, password)
    opener = urllib.request.build_opener(
        urllib.request.HTTPDigestAuthHandler(manager),
        urllib.request.HTTPBasicAuthHandler(manager),
    )
    request = urllib.request.Request(
        url, data=data, headers=headers or {}, method=method
    )
    try:
        with opener.open(request, timeout=8) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers.items()), exc.read()


def identity_api_post(
    browser: Browser,
    server: MakoProcess,
    token: str,
    fields: dict[str, str],
) -> tuple[int, dict]:
    payload = dict(fields)
    payload["_csrf"] = token
    code, _, body = browser.form(
        server.base + "admin/plugins/identity-access/api/",
        payload,
    )
    return code, json.loads(body)


def verify_identity_plugin(
    server: MakoProcess,
    runtime: Path,
    *,
    browser_ui: bool,
) -> None:
    browser = Browser(server.origin)
    admin_url = server.base + "admin/plugins/identity-access/"
    code, headers, body = browser.request(admin_url)
    rendered = text(body, headers)
    shared_admin_script = (
        urllib.parse.urlsplit(server.base).path + "admin/admin.js"
    )
    check(
        code == 200
        and "Identity and Access" in rendered
        and "Loading identity data" in rendered
        and "admin.js" in rendered
        and "admin.css" in rendered,
        f"identity admin shell failed ({code}): {rendered[:1000]}",
    )
    check(
        f'src="{shared_admin_script}"' in rendered
        or f"src='{shared_admin_script}'" in rendered,
        f"identity admin shell omitted the shared admin client: {rendered[:1000]}",
    )
    token = csrf_from(body)

    code, headers, shared_script = browser.request(
        server.base + "admin/admin.js"
    )
    check(
        code == 200
        and "javascript" in headers.get("Content-Type", "").lower()
        and b"FuguHubAdmin" in shared_script
        and b"Admin Login - CMS Admin" in shared_script,
        f"shared admin JavaScript failed ({code}): {shared_script[:500]!r}",
    )

    code, _, dashboard = browser.request(server.base + "admin/")
    check(
        code == 200
        and b"Users &amp; Access" in dashboard
        and b">Users<" not in dashboard,
        "running Identity Access plugin did not replace standalone Users navigation",
    )
    code, _, content_page = browser.request(server.base + "admin/content/")
    check(
        code == 200
        and b"Users &amp; Access" in content_page
        and b">Users<" not in content_page,
        "admin LSP shell did not use the plugin-aware identity navigation",
    )

    code, headers, script = browser.request(admin_url + "admin.js")
    check(
        code == 200
        and "javascript" in headers.get("Content-Type", "").lower()
        and b'fetch("api/"' in script
        and b"FuguHubAdmin.readJson" in script,
        f"protected identity JavaScript failed ({code}): {script[:500]!r}",
    )
    code, headers, stylesheet = browser.request(admin_url + "admin.css")
    check(
        code == 200
        and "text/css" in headers.get("Content-Type", "").lower()
        and b".identity-columns" in stylesheet
        and b"container-type: inline-size" in stylesheet
        and b"@container (max-width: 820px)" in stylesheet,
        f"protected identity CSS failed ({code}): {stylesheet[:500]!r}",
    )

    api_url = admin_url + "api/"
    code, _, body = browser.request(api_url)
    initial = json.loads(body)
    check(
        code == 200
        and initial["ok"] is True
        and initial["users"] in ([], {})
        and any(role["name"] == "authenticated" for role in initial["roles"]),
        f"identity API initial state failed ({code}): {initial}",
    )
    code, _, _ = browser.form(api_url, {"action": "save-role", "name": "x"})
    check(code == 403, "identity API accepted a POST without CSRF")

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-role",
            "name": "probe-user",
            "description": "May access the identity test endpoint",
        },
    )
    check(
        code == 200
        and result["ok"] is True
        and any(role["name"] == "probe-user" for role in result["roles"]),
        f"identity role creation failed ({code}): {result}",
    )

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Identity Test",
            "email": "identity@example.test",
            "password": "initial-password",
            "max_users": "3",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(
        code == 200
        and result["ok"] is True
        and result["users"][0]["username"] == "identitytest"
        and result["users"][0]["roles"] == ["authenticated", "probe-user"],
        f"identity user creation failed ({code}): {result}",
    )

    with contextlib.closing(sqlite3.connect(runtime / "data" / "cms.sqlite.db")) as conn:
        credential_row = conn.execute(
            "SELECT encrypted_base64 FROM identity_credentials WHERE id=1"
        ).fetchone()
        columns = {
            row[1]
            for table in (
                "identity_profiles",
                "identity_roles",
                "identity_user_roles",
                "identity_audit",
            )
            for row in conn.execute(f"PRAGMA table_info({table})")
        }
        serialized = "\n".join(
            str(row)
            for table in (
                "identity_profiles",
                "identity_roles",
                "identity_user_roles",
                "identity_audit",
            )
            for row in conn.execute(f"SELECT * FROM {table}")
        )
    check(
          credential_row is not None
          and len(credential_row[0]) > 16
          and "password" not in columns
          and "initial-password" not in serialized,
          "identity SQLite tables exposed a password")
    check(
        not (runtime / "data" / "admin-users.encrypted").exists()
        and not (runtime / "data" / "plugins" / "identity-access" / "users.encrypted").exists(),
        "identity credentials escaped the CMS SQLite database",
    )

    probe_url = server.base + "identity-probe/"
    code, _ = digest_get(probe_url, "identitytest", "wrong-password")
    check(code in (401, 403), f"identity probe accepted a bad password: {code}")
    code, body = digest_get(probe_url, "identitytest", "initial-password")
    check(
        code == 200
        and json.loads(body) == {"user": "identitytest", "allowed": True},
        f"identity DAV authenticator/role guard failed ({code}): {body[:500]!r}",
    )

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Profile Only Update",
            "email": "changed@example.test",
            "password": "",
            "max_users": "3",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(
        code == 200 and result["users"][0]["displayName"] == "Profile Only Update",
        f"passwordless profile update failed ({code}): {result}",
    )
    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Profile Only Update",
            "email": "changed@example.test",
            "password": "",
            "max_users": "4",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(code == 200 and result["users"][0]["maxUsers"] == 4,
          f"passwordless session-policy update failed ({code}): {result}")

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Profile Only Update",
            "email": "changed@example.test",
            "password": "",
            "disabled": "1",
            "max_users": "3",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(code == 200 and result["users"][0]["disabled"] is True,
          f"identity user disable failed ({code}): {result}")
    code, _ = digest_get(probe_url, "identitytest", "initial-password")
    check(code in (401, 403), f"disabled identity user retained access: {code}")
    with contextlib.closing(sqlite3.connect(runtime / "data" / "cms.sqlite.db")) as conn:
        check(conn.execute(
            "SELECT count(*) FROM identity_credentials"
        ).fetchone()[0] == 1,
              "disabling a user removed its TPM-protected disabled record")

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Profile Only Update",
            "email": "changed@example.test",
            "password": "",
            "max_users": "3",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(
        code == 400 and "new password is required" in result["error"].lower(),
        f"identity re-enable did not require a password ({code}): {result}",
    )
    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "save-user",
            "username": "identitytest",
            "display_name": "Profile Only Update",
            "email": "changed@example.test",
            "password": "replacement-password",
            "max_users": "3",
            "inactive": "1200",
            "role_probe-user": "1",
        },
    )
    check(code == 200 and result["users"][0]["disabled"] is False,
          f"identity user re-enable failed ({code}): {result}")
    code, body = digest_get(probe_url, "identitytest", "replacement-password")
    check(
        code == 200,
        f"re-enabled identity user could not authenticate: {code}, {body[:500]!r}",
    )

    if browser_ui:
        chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
        if chrome:
            dom = run_headless_dom(
                chrome,
                admin_url,
                RUNTIME_ROOT / "identity-chrome-profile",
                virtual_time_ms=3000,
            )
            check(
                "New User" in dom
                and "New Role" in dom
                and "Profile Only Update" in dom
                and "Loading identity data" not in dom,
                "identity client-side admin application did not render",
            )

    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "delete-user",
            "username": "identitytest",
        },
    )
    check(code == 200 and result["users"] in ([], {}),
          f"identity user deletion failed ({code}): {result}")
    code, result = identity_api_post(
        browser,
        server,
        token,
        {
            "action": "delete-role",
            "name": "probe-user",
        },
    )
    check(
        code == 200
        and not any(role["name"] == "probe-user" for role in result["roles"]),
        f"identity role deletion failed ({code}): {result}",
    )


def test_identity_plugin() -> None:
    runtime = fresh_runtime("identity-root")
    install_identity_plugin(runtime)
    with MakoProcess(runtime) as server:
        verify_identity_plugin(server, runtime, browser_ui=True)

    named_runtime = fresh_runtime("identity-named")
    install_identity_plugin(named_runtime)
    with MakoProcess(named_runtime, mount="mybase") as server:
        verify_identity_plugin(server, named_runtime, browser_ui=False)
        code, _, _ = Browser(server.origin).request(
            "/admin/plugins/identity-access/"
        )
        check(code == 404, "named identity admin page leaked into the server root")


def test_identity_database_reset() -> None:
    runtime = fresh_runtime("identity-storage-mismatch")
    install_identity_plugin(runtime)
    database = runtime / "data" / "cms.sqlite.db"

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        identity_url = server.base + "admin/plugins/identity-access/"
        code, _, page = browser.request(identity_url)
        check(code == 200, "identity mismatch fixture page was unavailable")
        token = csrf_from(page)
        code, result = identity_api_post(
            browser,
            server,
            token,
            {
                "action": "save-user",
                "username": "orphanedidentity",
                "password": "orphaned-password",
                "max_users": "3",
                "inactive": "1200",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"identity mismatch fixture creation failed: {result}")

    with contextlib.closing(sqlite3.connect(database)) as conn:
        check(conn.execute(
            "SELECT count(*) FROM identity_credentials"
        ).fetchone()[0] == 1, "identity credential row was not created")
    check(
        not (runtime / "data" / "admin-users.encrypted").exists()
        and not (runtime / "data" / "plugins" / "identity-access" / "users.encrypted").exists(),
        "identity state was split outside SQLite",
    )
    previous_database = runtime / "data" / "x.cms.sqlite.db"
    database.rename(previous_database)

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, dashboard = browser.request(server.base + "admin/")
        check(
            code == 200
            and b"Admin authentication is disabled" in dashboard
            and b"Plugin identity-access is unavailable" not in dashboard,
            f"fresh database did not return to clean bootstrap mode: {dashboard[:1500]!r}",
        )
        code, _, body = browser.request(
            server.base + "admin/plugins/identity-access/api/"
        )
        check(code == 200 and json.loads(body)["users"] in ([], {}),
              "fresh database inherited users from external identity state")

    check(database.is_file() and previous_database.is_file(),
          "database reset did not preserve the old database and create a new one")


def test_identity_legacy_migration() -> None:
    runtime = fresh_runtime("identity-legacy-migration")
    writer = runtime / "legacy-writer"
    writer.mkdir()
    (writer / ".preload").write_text(
        "local home=assert(ba.openio('home'))\n"
        "local data=assert(ba.mkio(home,'data'))\n"
        "local tju=ba.tpm.jsonuser('makocms-admin',true)\n"
        "local encrypted=tju.setuser('legacyadmin',{pwd='legacy-password',roles={'cms-admin'}})\n"
        "local file=assert(data:open('admin-users.encrypted','wb'))\n"
        "assert(file:write(encrypted))\n"
        "file:close()\n",
        encoding="ascii",
    )
    with MakoProcess(runtime, application="legacy-writer"):
        pass
    legacy_file = runtime / "data" / "admin-users.encrypted"
    check(legacy_file.is_file(), "legacy administrator fixture was not created")

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, dashboard = form_login(
            browser, "/admin/", "legacyadmin", "legacy-password"
        )
        check(code == 200 and b"Dashboard" in dashboard,
              "migrated legacy administrator could not log in")
    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        check(conn.execute(
            "SELECT count(*) FROM identity_credentials"
        ).fetchone()[0] == 1, "legacy credentials were not migrated into SQLite")
        check(conn.execute(
            "SELECT count(*) FROM identity_user_roles "
            "WHERE username='legacyadmin' AND role_name='cms-admin'"
        ).fetchone()[0] == 1, "legacy administrator role was not migrated")
    check(not legacy_file.exists(),
          "legacy external credential file remained after migration")


def test_identity_first_admin_bootstrap() -> None:
    runtime = fresh_runtime("identity-first-admin")
    install_identity_plugin(runtime)

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        admin_url = server.base + "admin/plugins/identity-access/"
        code, _, dashboard = browser.request(server.base + "admin/")
        check(
            code == 200
            and b"Configure a CMS administrator" in dashboard
            and b"/admin/plugins/identity-access/" in dashboard,
            "empty Identity Access setup notice did not lead to Users & Access",
        )

        code, _, page = browser.request(admin_url)
        check(code == 200, "first Identity Access administrator page was unavailable")
        token = csrf_from(page)

        chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
        if chrome:
            dom = run_headless_dom(
                chrome,
                admin_url,
                RUNTIME_ROOT / "identity-bootstrap-chrome-profile",
                virtual_time_ms=3000,
            )
            check(
                "Create First CMS Administrator" in dom
                and "Create and Enable" in dom
                and "New User" not in dom,
                "empty Identity Access UI did not render the bootstrap form",
            )

        code, result = identity_api_post(
            browser,
            server,
            token,
            {
                "action": "bootstrap-cms-admin",
                "username": "firstadmin",
                "password": "first-password",
            },
        )
        check(
            code == 200
            and result["ok"] is True
            and result["cmsAdmin"]["enabled"] is True
            and len(result["users"]) == 1
            and "cms-admin" in result["users"][0]["roles"],
            f"first Identity Access administrator bootstrap failed ({code}): {result}",
        )

        anonymous = Browser(server.origin)
        code, _, login_page = anonymous.request(server.base + "admin/")
        check(
            code == 200 and b"Admin Login" in login_page,
            "first Identity Access administrator did not protect CMS administration",
        )

        login = Browser(server.origin)
        code, _, dashboard = form_login(
            login, server.base + "admin/", "firstadmin", "first-password"
        )
        check(
            code == 200
            and b"Dashboard" in dashboard
            and b"Admin authentication is disabled" not in dashboard,
            "first Identity Access administrator could not log in",
        )

        code, _, identity_page = login.request(admin_url)
        token = csrf_from(identity_page)
        code, result = identity_api_post(
            login,
            server,
            token,
            {
                "action": "save-role",
                "name": "session-test",
                "description": "Session invalidation regression role",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"session test role creation failed ({code}): {result}")
        code, result = identity_api_post(
            login,
            server,
            token,
            {
                "action": "save-user",
                "username": "firstadmin",
                "password": "",
                "max_users": "3",
                "inactive": "1200",
                "role_cms-admin": "1",
                "role_session-test": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"role addition failed ({code}): {result}")
        code, _, dashboard = login.request(server.base + "admin/")
        check(
            code == 200 and b"Dashboard" in dashboard and b"ba_seed" not in dashboard,
            "adding a role terminated the affected administrator session",
        )

        code, _, identity_page = login.request(admin_url)
        token = csrf_from(identity_page)
        code, result = identity_api_post(
            login,
            server,
            token,
            {
                "action": "save-user",
                "username": "firstadmin",
                "password": "",
                "max_users": "3",
                "inactive": "1200",
                "role_cms-admin": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"role removal failed ({code}): {result}")
        code, _, login_page = login.request(server.base + "admin/")
        check(
            code == 200 and b"ba_seed" in login_page,
            "removing a role did not terminate the affected administrator session",
        )
        login = Browser(server.origin)
        code, _, dashboard = form_login(
            login, server.base + "admin/", "firstadmin", "first-password"
        )
        check(code == 200 and b"Dashboard" in dashboard,
              "administrator could not log in after role removal")
        code, _, identity_page = login.request(admin_url)
        token = csrf_from(identity_page)
        code, result = identity_api_post(
            login,
            server,
            token,
            {
                "action": "bootstrap-cms-admin",
                "username": "secondadmin",
                "password": "second-password",
            },
        )
        check(
            code == 400 and "only be created when no identity users exist" in result["error"],
            f"second Identity Access bootstrap was not rejected ({code}): {result}",
        )

    check(not (runtime / "data" / "admin-users.encrypted").exists(),
          "first administrator created a second credential database")
    shutil.move(
        runtime / "plugins" / "identity-access",
        runtime / "plugins" / "identity-access.off",
    )
    with MakoProcess(runtime) as server:
        fallback_login = Browser(server.origin)
        code, _, dashboard = form_login(
            fallback_login, "/admin/", "firstadmin", "first-password"
        )
        check(
            code == 200
            and b"Dashboard" in dashboard
            and b">Users<" in dashboard
            and b"Users &amp; Access" not in dashboard,
            "core CMS authentication depended on the Identity Access plugin",
        )
        with contextlib.closing(
            sqlite3.connect(runtime / "data" / "cms.sqlite.db")
        ) as conn:
            selected = conn.execute(
                "SELECT value FROM options WHERE key='admin_identity_provider'"
            ).fetchone()
        check(selected is None,
              "obsolete identity-provider selection was persisted")
        code, _, users_page = admin_post(
            fallback_login,
            server.base,
            "users/",
            {"action": "remove", "username": "firstadmin"},
        )
        check(
            code == 200
            and b"final enabled cms-admin cannot be disabled or demoted" in users_page,
            "core identity allowed accidental removal of its final administrator",
        )
        code, _, reset_page = admin_post(
            fallback_login,
            server.base,
            "users/",
            {"action": "reset"},
        )
        check(code == 200 and b"No admin users configured" in reset_page,
              "explicit authentication reset did not return to bootstrap mode")


def test_command_line_bootstrap() -> None:
    runtime = fresh_runtime("command-line-bootstrap")
    token = "command-line-bootstrap-token-0123456789"
    password = "bootstrap:password"
    args = ("-credentials", f"bootstrap:{password}", "-token", token)

    with MakoProcess(runtime, extra_args=args) as server:
        browser = Browser(server.origin)
        code, _, dashboard = form_login(
            browser, server.base + "admin/", "bootstrap", password
        )
        check(code == 200 and b"Dashboard" in dashboard,
              "command-line administrator could not log in")
        client = McpClient(Browser(server.origin), server.base + "mcp/", token)
        check(client.initialize()["serverInfo"]["name"] == "FuguHub",
              "command-line MCP token did not enable MCP")
        output = "\n".join(server.lines)
        check(password not in output and token not in output,
              "command-line bootstrap secrets were written to the trace")

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        stored = conn.execute(
            "SELECT value FROM options WHERE key='mcp_token_encrypted'"
        ).fetchone()[0]
        check(token not in stored and stored.startswith("v1:"),
              "command-line MCP token was not encrypted at rest")

    replacement_token = "replacement-bootstrap-token-0123456789"
    replacement_args = (
        "-credentials", "replacement:replacement-password",
        "-token", replacement_token,
    )
    with MakoProcess(runtime, extra_args=replacement_args) as server:
        browser = Browser(server.origin)
        code, _, dashboard = form_login(
            browser, server.base + "admin/", "bootstrap", password
        )
        check(code == 200 and b"Dashboard" in dashboard,
              "restart replaced the original command-line administrator")
        client = McpClient(Browser(server.origin), server.base + "mcp/", token)
        client.initialize()
        code, _, _ = Browser(server.origin).request(
            server.base + "mcp/",
            data=b"{}",
            headers={
                "Authorization": f"Bearer {replacement_token}",
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )
        check(code == 403, "restart replaced the original command-line MCP token")
        check(any("bootstrap ignored" in line for line in server.lines),
              "ignored command-line bootstrap was not traced")

    file_runtime = fresh_runtime("command-line-bootstrap-files")
    credentials_file = file_runtime / "bootstrap-credentials.txt"
    token_file = file_runtime / "bootstrap-token.txt"
    credentials_file.write_text("fileadmin:file-password\n", encoding="utf-8")
    file_token = "file-bootstrap-token-0123456789"
    token_file.write_text(file_token + "\n", encoding="utf-8")
    file_args = (
        "-credentials-file", str(credentials_file),
        "-token-file", str(token_file),
    )
    with MakoProcess(file_runtime, extra_args=file_args) as server:
        browser = Browser(server.origin)
        code, _, dashboard = form_login(
            browser, server.base + "admin/", "fileadmin", "file-password"
        )
        check(code == 200 and b"Dashboard" in dashboard,
              "file-based bootstrap administrator could not log in")
        McpClient(Browser(server.origin), server.base + "mcp/", file_token).initialize()

    invalid_runtime = fresh_runtime("command-line-bootstrap-invalid")
    invalid_args = ("-credentials", "invalid:password", "-token", "short")
    with MakoProcess(invalid_runtime, extra_args=invalid_args) as server:
        code, _, body = Browser(server.origin).request("/")
        check(code == 503 and b"MCP token must contain" in body,
              "invalid bootstrap token did not fail startup visibly")
    with contextlib.closing(sqlite3.connect(database_path(invalid_runtime))) as conn:
        check(conn.execute("SELECT count(*) FROM identity_profiles").fetchone()[0] == 0,
              "invalid bootstrap token created a partial administrator")


def run_admin_api_reauthentication_case(mount: str) -> None:
    label = mount or "root"
    runtime = fresh_runtime("admin-api-reauth-" + label)
    install_file_services_plugin(runtime)
    browser: Browser | None = None
    stale_token = ""

    with MakoProcess(runtime, mount=mount) as server:
        browser = Browser(server.origin)
        identity_url = server.base + "admin/plugins/identity-access/"
        code, _, page = browser.request(identity_url)
        token = csrf_from(page)
        code, result = identity_api_post(
            browser,
            server,
            token,
            {
                "action": "bootstrap-cms-admin",
                "username": "reauthadmin",
                "password": "reauth-password",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"{label} API reauthentication bootstrap failed: {result}")
        browser = Browser(server.origin)
        code, _, dashboard = form_login(
            browser, server.base + "admin/", "reauthadmin", "reauth-password"
        )
        check(code == 200 and b"Dashboard" in dashboard,
              f"{label} API reauthentication login failed")
        code, _, files_page = browser.request(
            server.base + "admin/plugins/file-services/"
        )
        check(code == 200, f"{label} File Services page was unavailable")
        stale_token = csrf_from(files_page)

    check(browser is not None, "API reauthentication browser was not created")
    with MakoProcess(runtime, mount=mount) as server:
        browser.origin = server.origin
        code, headers, body = browser.form(
            server.base + "admin/plugins/file-services/api/",
            {
                "action": "save-acl",
                "role": "file-admin",
                "path": "/",
                "permission": "read",
                "enabled": "1",
                "_csrf": stale_token,
            },
        )
        result = json.loads(body)
        expected_login = urllib.parse.urlsplit(server.base).path + "admin/"
        check(
            code == 401
            and "application/json" in headers.get("Content-Type", "").lower()
            and result == {
                "ok": False,
                "error": "CMS admin login required",
                "loginUrl": expected_login,
            }
            and b"ba_seed" not in body,
            f"{label} stale admin API request entered form authentication: "
            f"HTTP {code}, {result}",
        )

        identity_url = server.base + "admin/plugins/identity-access/"
        code, _, login_page = browser.request(identity_url)
        check(code == 200 and b"ba_seed" in login_page,
              f"{label} admin login challenge was unavailable after API 401")
        code, _, identity_page = form_login(
            browser, identity_url, "reauthadmin", "reauth-password"
        )
        check(
            code == 200
            and b"Identity and Access" in identity_page
            and not identity_page.lstrip().startswith(b"{"),
            f"{label} login replayed the stale API request",
        )


def test_admin_api_reauthentication() -> None:
    run_admin_api_reauthentication_case("")
    run_admin_api_reauthentication_case("mybase")




def file_api_post(
    browser: Browser,
    server: MakoProcess,
    token: str,
    fields: dict[str, str],
) -> tuple[int, dict]:
    payload = dict(fields)
    payload["_csrf"] = token
    code, _, body = browser.form(
        server.base + "admin/plugins/file-services/api/",
        payload,
    )
    return code, json.loads(body)


def test_large_file_mailer_foundation() -> None:
    runtime = fresh_runtime("large-file-mailer-foundation")
    install_large_file_mailer_plugin(runtime)
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, _ = browser.request("/")
        check(code == 404, "mailer plugin prevented normal CMS startup")
        admin_url = server.base + "admin/plugins/large-file-mailer/"
        code, _, page = browser.request(admin_url)
        check(code == 200 and b"Large File Mailer" in page
              and b'class="mailer-admin-tabs"' in page
              and b">Settings</a>" in page
              and b"/mailer/contacts/" in page
              and b"/mailer/jobs/" in page,
              "mailer admin page was unavailable")
        code, _, lists_page = browser.request(server.base + "mailer/lists/")
        check(
            code == 200
            and b"data-view='lists'" in lists_page
            and b"ba_username" not in lists_page,
            "zero-user bootstrap unexpectedly protected the mailer",
        )
        code, _, state_body = browser.request(server.base + "mailer/api/")
        bootstrap_state = json.loads(state_body)
        check(
            code == 200
            and bootstrap_state["ok"] is True
            and bootstrap_state["manager"] is True,
            f"zero-user mailer API was unavailable: {bootstrap_state}",
        )
        token = csrf_from(page)
        code, _, script = browser.request(admin_url + "admin.js")
        check(code == 200 and b"Save Settings" in script
              and b"Save and Test" in script
              and b'test_recipient' in script
              and b'form.autocomplete = "off"' in script
              and b'autocomplete: "new-password"' in script,
              "mailer admin JavaScript was unavailable")
        code, headers, stylesheet = browser.request(admin_url + "admin.css")
        check(code == 200
              and "text/css" in headers.get("Content-Type", "").lower()
              and b"container-type: inline-size" in stylesheet
              and b"@container (max-width: 620px)" in stylesheet
              and b"white-space: nowrap" in stylesheet
              and b".mailer-admin-tabs" in stylesheet,
              "mailer responsive stylesheet was unavailable")
        code, headers, public_stylesheet = browser.request(
            server.base + "mailer/public.css"
        )
        check(
            code == 200
            and "text/css" in headers.get("Content-Type", "").lower()
            and b".public-panel" in public_stylesheet
            and b".file-summary" in public_stylesheet,
            "mailer public-page stylesheet was unavailable",
        )
        code, _, body = browser.form(
            admin_url + "api/",
            {
                "_csrf": token,
                "action": "save-settings",
                "enabled": "1",
                "smtp_server": "",
                "smtp_port": "25",
                "smtp_security": "none",
                "smtp_username": "",
                "from_address": "",
                "reply_to": "",
                "public_base_url": "",
                "attachment_limit": "10485760",
                "grant_ttl": "604800",
                "max_attempts": "4",
                "retry_base": "60",
                "send_interval": "1",
                "require_https": "1",
                "password": "",
            },
        )
        result = json.loads(body)
        check(code == 400 and result["ok"] is False,
              "mailer accepted an enabled configuration without SMTP settings")
        code, _, body = browser.form(
            admin_url + "api/",
            {
                "_csrf": token,
                "action": "save-settings",
                "enabled": "1",
                "smtp_server": "smtp.example.test",
                "smtp_port": "2525",
                "smtp_security": "starttls",
                "smtp_username": "mailer-user",
                "from_address": "FuguHub Sender<sender@example.test>",
                "test_recipient": "Real Time Logic<sender@example.test>",
                "reply_to": "FuguHub Reply<reply@example.test>",
                "public_base_url": "https://downloads.example.test",
                "attachment_limit": "2048",
                "grant_ttl": "3600",
                "max_attempts": "3",
                "retry_base": "2",
                "send_interval": "1",
                "require_https": "1",
                "password": "smtp-secret-value",
            },
        )
        result = json.loads(body)
        check(
            code == 200
            and result["ok"] is True
            and result["settings"]["passwordConfigured"] is True
            and "smtp-secret-value" not in body.decode("utf-8"),
            f"mailer settings save failed ({code}): {result}",
        )

    expected_tables = {
        "mailer_settings",
        "mailer_smtp_secret",
        "mailer_contacts",
        "mailer_contact_credentials",
        "mailer_unsubscribe_tokens",
        "mailer_lists",
        "mailer_list_members",
        "mailer_templates",
        "mailer_jobs",
        "mailer_job_recipients",
        "mailer_job_files",
        "mailer_download_grants",
        "mailer_download_events",
    }
    with contextlib.closing(
        sqlite3.connect(runtime / "data" / "cms.sqlite.db")
    ) as conn:
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name LIKE 'mailer_%'"
            )
        }
        roles = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM identity_roles WHERE name LIKE 'mailer-%'"
            )
        }
        settings = conn.execute(
            "SELECT enabled,smtp_security,attachment_limit "
            "FROM mailer_settings WHERE singleton=1"
        ).fetchone()
        encrypted_password = conn.execute(
            "SELECT encrypted_password FROM mailer_smtp_secret WHERE singleton=1"
        ).fetchone()
        contact_columns = {
            row[1] for row in conn.execute("PRAGMA table_info(mailer_contacts)")
        }
        recipient_columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(mailer_job_recipients)")
        }
    check(tables == expected_tables,
          f"mailer schema mismatch: {sorted(tables)}")
    check(roles == {"mailer-user", "mailer-manager"},
          f"mailer roles mismatch: {sorted(roles)}")
    check(settings == (1, "starttls", 2048),
          f"mailer defaults mismatch: {settings}")
    check(
        encrypted_password is not None
        and encrypted_password[0].startswith("v1:")
        and "smtp-secret-value" not in encrypted_password[0],
        "SMTP password was not stored as an encrypted value",
    )
    check(
        "display_name" not in contact_columns
        and "unsubscribed_at" in contact_columns
        and "display_name" not in recipient_columns,
        "fresh mailer contact schema is incorrect",
    )

    with contextlib.closing(
        sqlite3.connect(runtime / "data" / "cms.sqlite.db")
    ) as conn:
        conn.execute(
            "ALTER TABLE mailer_contacts ADD COLUMN display_name "
            "TEXT NOT NULL DEFAULT ''"
        )
        conn.execute(
            "ALTER TABLE mailer_job_recipients ADD COLUMN display_name "
            "TEXT NOT NULL DEFAULT ''"
        )
        conn.execute(
            "INSERT INTO mailer_contacts(email,first_name,last_name,display_name,"
            "created_at,updated_at) VALUES(?,?,?,?,?,?)",
            ("legacy@example.test", "Legacy", "Contact", "Old Display", 1, 1),
        )
        conn.commit()

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        admin_url = server.base + "admin/plugins/large-file-mailer/"
        code, _, page = browser.request(admin_url)
        token = csrf_from(page)
        code, _, body = browser.request(admin_url + "api/")
        result = json.loads(body)
        check(code == 200 and result["settings"]["passwordConfigured"] is True,
              "encrypted SMTP password was not restored after restart")
        fields = {
            "_csrf": token,
            "action": "save-settings",
            "enabled": "0",
            "smtp_server": "smtp.example.test",
            "smtp_port": "2525",
            "smtp_security": "starttls",
            "smtp_username": "mailer-user",
            "from_address": "sender@example.test",
            "reply_to": "reply@example.test",
            "public_base_url": "https://downloads.example.test",
            "attachment_limit": "2048",
            "grant_ttl": "3600",
            "max_attempts": "3",
            "retry_base": "2",
            "send_interval": "1",
            "require_https": "1",
            "password": "",
            "clear_password": "1",
        }
        code, _, body = browser.form(admin_url + "api/", fields)
        result = json.loads(body)
        check(code == 200 and result["settings"]["passwordConfigured"] is False,
              "SMTP password clear failed")

    with contextlib.closing(
        sqlite3.connect(runtime / "data" / "cms.sqlite.db")
    ) as conn:
        secret_count = conn.execute(
            "SELECT COUNT(*) FROM mailer_smtp_secret"
        ).fetchone()[0]
        migrated_contact = conn.execute(
            "SELECT email,first_name,last_name FROM mailer_contacts "
            "WHERE email='legacy@example.test'"
        ).fetchone()
        migrated_contact_columns = {
            row[1] for row in conn.execute("PRAGMA table_info(mailer_contacts)")
        }
        migrated_recipient_columns = {
            row[1]
            for row in conn.execute("PRAGMA table_info(mailer_job_recipients)")
        }
    check(secret_count == 0, "cleared SMTP password remained in SQLite")
    check(
        migrated_contact == ("legacy@example.test", "Legacy", "Contact")
        and "display_name" not in migrated_contact_columns
        and "display_name" not in migrated_recipient_columns,
        "legacy display_name migration lost contacts or retained the columns",
    )

    zip_runtime = fresh_runtime("large-file-mailer-zip")
    install_large_file_mailer_plugin(zip_runtime)
    source = zip_runtime / "plugins" / "large-file-mailer"
    destination = zip_runtime / "plugins" / "large-file-mailer.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in source.rglob("*"):
            if file.is_file():
                archive.write(file, file.relative_to(source).as_posix())
    shutil.rmtree(source)
    with MakoProcess(zip_runtime) as server:
        browser = Browser(server.origin)
        code, _, page = browser.request(
            server.base + "admin/plugins/large-file-mailer/"
        )
        check(code == 200 and b"Large File Mailer" in page,
              "ZIP-packaged mailer admin page failed")
        code, _, parser_body = browser.request(server.base + "mailer-probe/parse")
        parser_result = json.loads(parser_body)
        check(code == 200 and parser_result["ok"] is True,
              f"ZIP-packaged private EML modules failed: {parser_result}")


def test_large_file_mailer_delivery() -> None:
    runtime = fresh_runtime("large-file-mailer-delivery")
    install_large_file_mailer_plugin(runtime)
    (runtime / "mailer-fixture.txt").write_text(
        "FuguHub large file mailer fixture\n", encoding="ascii"
    )

    with smtp_capture_server() as smtp, MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        identity_url = server.base + "admin/plugins/identity-access/"
        code, _, identity_page = browser.request(identity_url)
        check(code == 200, "identity setup page failed for mailer test")
        identity_token = csrf_from(identity_page)
        code, result = identity_api_post(
            browser,
            server,
            identity_token,
            {
                "action": "save-role",
                "name": "mailer-files",
                "description": "File access for mailer tests",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"mailer file role creation failed: {result}")
        code, result = identity_api_post(
            browser,
            server,
            identity_token,
            {
                "action": "save-user",
                "username": "mail-sender",
                "display_name": "Mail Sender",
                "email": "sender@example.test",
                "password": "sender-password",
                "max_users": "3",
                "inactive": "1200",
                "role_mailer-files": "1",
                "role_mailer-user": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"mailer sender creation failed: {result}")
        files_url = server.base + "admin/plugins/file-services/"
        code, _, files_page = browser.request(files_url)
        files_token = csrf_from(files_page)
        code, result = file_api_post(
            browser,
            server,
            files_token,
            {
                "action": "save-acl",
                "id": "",
                "name": "Mailer fixtures",
                "role": "mailer-files",
                "path": "/mailer-fixture.txt",
                "permission": "read",
                "enabled": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"mailer file ACL creation failed: {result}")
        code, result = file_api_post(
            browser,
            server,
            files_token,
            {
                "action": "save-settings",
                "enabled": "1",
                "max_uploads": "20",
                "max_locks": "100",
                "session_timeout": "900",
                "case_sensitive": "1",
            },
        )
        check(code == 200 and result["active"] is True,
              f"File Services activation failed: {result}")

        mailer_url = server.base + "admin/plugins/large-file-mailer/"
        code, _, mailer_page = browser.request(mailer_url)
        mailer_token = csrf_from(mailer_page)
        code, _, body = browser.form(
            mailer_url + "api/",
            {
                "_csrf": mailer_token,
                "action": "save-and-test",
                "enabled": "1",
                "smtp_server": "127.0.0.1",
                "smtp_port": str(smtp.server_address[1]),
                "smtp_security": "none",
                "smtp_username": "",
                "from_address": "FuguHub Sender<sender@example.test>",
                "test_recipient": "Real Time Logic<sender@example.test>",
                "reply_to": "FuguHub Reply<reply@example.test>",
                "public_base_url": server.origin,
                "attachment_limit": "1048576",
                "grant_ttl": "3600",
                "max_attempts": "3",
                "retry_base": "1",
                "send_interval": "1",
                "require_https": "0",
                "password": "",
            },
        )
        result = json.loads(body)
        check(code == 200 and result["settings"]["enabled"] is True,
               f"mailer activation failed: {result}")
        check(
            result.get("testRecipient") == "Real Time Logic <sender@example.test>"
            and len(smtp.messages) == 1
            and b"FuguHub SMTP test" in smtp.messages[0]
            and b"to: Real Time Logic <sender@example.test>" in smtp.messages[0]
            and result["settings"]["fromAddress"] ==
                "FuguHub Sender <sender@example.test>",
            f"Save and Test did not accept and deliver SMTP mailbox syntax: {result}",
        )

        code, result = identity_api_post(
            browser,
            server,
            identity_token,
            {
                "action": "save-user",
                "username": "mail-admin",
                "display_name": "Mail Administrator",
                "email": "mail-admin@example.test",
                "password": "mail-admin-password",
                "max_users": "3",
                "inactive": "1200",
                "role_cms-admin": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"mailer administrator creation failed: {result}")

        chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
        if chrome:
            with HeadlessPage(
                chrome,
                mailer_url,
                RUNTIME_ROOT / "mailer-settings-chrome-profile",
            ) as page:
                page.wait_for(
                    "document.readyState === 'complete' && "
                    "document.getElementById('ba_loginbut') !== null"
                )
                page.evaluate(
                    """(function () {
   document.querySelector('[name=ba_username]').value = 'mail-admin';
   document.querySelector('[name=ba_password]').value = 'mail-admin-password';
   document.getElementById('ba_loginbut').click();
   return true;
}())"""
                )
                page.wait_for(
                    "Array.from(document.querySelectorAll('button')).some("
                    "function (button) { return button.textContent === 'Save and Test'; })"
                )
                page.evaluate(
                    """(function () {
   Array.from(document.querySelectorAll('button')).find(function (button) {
      return button.textContent === 'Save and Test';
   }).click();
   return true;
}())"""
                )
                page.wait_for(
                    "document.getElementById('mailer-message') && "
                    "document.getElementById('mailer-message').textContent.indexOf("
                    "'Test message sent') >= 0"
                )
                feedback = page.evaluate(
                    """(function () {
   const message = document.getElementById('mailer-message');
   const button = Array.from(document.querySelectorAll('button')).find(function (node) {
      return node.textContent === 'Save and Test';
   });
   const messageBox = message.getBoundingClientRect();
   const buttonBox = button.getBoundingClientRect();
   return {
      text: message.textContent,
      success: message.classList.contains('success'),
      distance: Math.abs(messageBox.top - buttonBox.bottom),
      messages: document.querySelectorAll('#mailer-message').length
   };
}())"""
                )
                check(
                    feedback["success"]
                    and feedback["messages"] == 1
                    and feedback["distance"] <= 40
                    and len(smtp.messages) == 2,
                    f"Save and Test UI feedback was not visible near the action: {feedback}",
                )

        code, _, parser_body = browser.request(server.base + "mailer-probe/parse")
        parser_result = json.loads(parser_body)
        check(
            code == 200
            and parser_result["ok"] is True
            and "Parsed body" in parser_result["body"],
            f"vendored EML parser failed: {parser_result}",
        )

        def create_and_wait(kind: str) -> tuple[dict, bytes]:
            before = len(smtp.messages)
            code, _, create_body = browser.request(
                server.base + "mailer-probe/create-" + kind
            )
            created = json.loads(create_body)
            check(code == 200 and created["ok"] is True,
                  f"{kind} job creation failed: {created}")
            job_id = created["job"]["id"]
            deadline = time.time() + 8
            current = created["job"]
            while time.time() < deadline:
                code, _, status_body = browser.request(
                    server.base + f"mailer-probe/job/{job_id}"
                )
                current = json.loads(status_body)["job"]
                if current["status"] in ("completed", "failed"):
                    break
                time.sleep(0.05)
            check(current["status"] == "completed",
                  f"{kind} job did not complete: {current}")
            check(len(smtp.messages) == before + 1,
                  f"{kind} job did not produce exactly one SMTP message")
            return current, smtp.messages[-1]

        attachment_job, attachment_message = create_and_wait("attachment")
        check(
            b"Mailer Test" in attachment_message
            and b"to: Test Recipient <recipient@example.test>" in attachment_message
            and b"mailer-fixture.txt" in attachment_message
            and b"RnVndUh1YiBsYXJnZSBmaWxlIG1haWxlciBmaXh0dXJl" in attachment_message,
            "attachment message omitted expanded content or attachment: "
            + repr(attachment_message[:2000]),
        )

        link_job, link_message = create_and_wait("link")
        decoded_link_message = quopri.decodestring(link_message)
        match = re.search(
            rb"http://(?:localhost|127\.0\.0\.1):\d+/mailer/d/[A-Za-z0-9_-]+",
            decoded_link_message,
        )
        check(match is not None, "link message omitted its secure download URL: "
              + repr(link_message[:2000]))
        check(
            b"Download files:" in decoded_link_message
            and b"Hello Test" in decoded_link_message,
            "link job without DOWNLOAD_LINKS did not append a download section: "
            + repr(decoded_link_message[:2000]),
        )
        link_url = match.group(0).decode("ascii")
        code, headers, download = browser.request(link_url)
        check(
            code == 200
            and headers.get("cache-control") == "no-store"
            and download.replace(b"\r\n", b"\n") ==
                b"FuguHub large file mailer fixture\n",
            f"link download failed: HTTP {code}, headers={headers}, body={download[:200]!r}",
        )

        protected_job, protected_message = create_and_wait("protected-link")
        match = re.search(
            rb"http://(?:localhost|127\.0\.0\.1):\d+/mailer/d/[A-Za-z0-9_-]+",
            quopri.decodestring(protected_message),
        )
        check(match is not None, "protected link message omitted its URL")
        protected_url = match.group(0).decode("ascii")
        protected_browser = Browser(server.origin)
        code, _, password_page = protected_browser.request(protected_url)
        csrf_match = re.search(rb"name='csrf' value='([^']+)'", password_page)
        check(
            code == 200
            and csrf_match is not None
            and b"Protected download" in password_page
            and b"class='public-page'" in password_page
            and b"/mailer/public.css" in password_page
            and b"mailer-fixture.txt" in password_page
            and b"autocomplete='current-password'" in password_page
            and b"Download file" in password_page,
            "protected grant did not return the styled password form",
        )
        code, _, denied = protected_browser.form(
            protected_url,
            {"csrf": csrf_match.group(1).decode("ascii"), "password": "wrong"},
        )
        check(
            code == 200
            and b"Protected download" in denied
            and b"password is incorrect" in denied,
            "wrong grant password did not preserve the form with visible feedback",
        )
        csrf_match = re.search(rb"name='csrf' value='([^']+)'", denied)
        check(csrf_match is not None, "password retry form omitted CSRF")
        code, _, protected_download = protected_browser.form(
            protected_url,
            {
                "csrf": csrf_match.group(1).decode("ascii"),
                "password": "grant-password",
            },
        )
        check(
            code == 200
            and protected_download.replace(b"\r\n", b"\n") ==
                b"FuguHub large file mailer fixture\n",
            "correct grant password did not return the protected file",
        )

        attempts_before = len(smtp.attempts)
        smtp.failures_remaining = 1
        retry_job, _ = create_and_wait("attachment")
        check(
            retry_job["recipients"][0]["attempts"] == 2
            and len(smtp.attempts) == attempts_before + 2,
            f"transient SMTP failure was not retried once: {retry_job}",
        )

        code, _, cancel_body = browser.request(
            server.base + f"mailer-probe/cancel/{link_job['id']}"
        )
        cancelled = json.loads(cancel_body)
        check(code == 200 and cancelled["ok"] is True,
              f"grant revocation request failed: {cancelled}")
        code, _, _ = browser.request(link_url)
        check(code == 404, "cancel operation did not revoke existing grants")

        code, _, draft_body = browser.request(
            server.base + "mailer-probe/create-draft-attachment"
        )
        draft = json.loads(draft_body)["job"]
        (runtime / "mailer-fixture.txt").write_text(
            "Changed after draft creation\n", encoding="ascii"
        )
        messages_before_change = len(smtp.messages)
        code, _, queue_body = browser.request(
            server.base + f"mailer-probe/queue/{draft['id']}"
        )
        check(code == 200 and json.loads(queue_body)["ok"] is True,
              "changed-file job could not be queued")
        deadline = time.time() + 5
        changed_job = draft
        while time.time() < deadline:
            code, _, status_body = browser.request(
                server.base + f"mailer-probe/job/{draft['id']}"
            )
            changed_job = json.loads(status_body)["job"]
            if changed_job["status"] == "failed":
                break
            time.sleep(0.05)
        check(
            changed_job["status"] == "failed"
            and "changed" in changed_job["recipients"][0]["lastError"].lower()
            and len(smtp.messages) == messages_before_change,
            f"changed file was not rejected before SMTP delivery: {changed_job}",
        )
        (runtime / "mailer-fixture.txt").write_text(
            "FuguHub large file mailer fixture\n", encoding="ascii"
        )

        code, _, recovery_body = browser.request(
            server.base + "mailer-probe/create-draft-link"
        )
        recovery_job_id = json.loads(recovery_body)["job"]["id"]

    with contextlib.closing(
        sqlite3.connect(runtime / "data" / "cms.sqlite.db")
    ) as conn:
        grants = conn.execute(
            "SELECT token_hash,password_hash FROM mailer_download_grants"
        ).fetchall()
        events = conn.execute(
            "SELECT event_type FROM mailer_download_events ORDER BY id"
        ).fetchall()
    check(len(grants) == 2 and all(len(row[0]) == 64 for row in grants),
          f"mailer did not retain hash-only grants: {grants}")
    check(all("http" not in row[0] for row in grants),
          "mailer stored a raw download URL or token")
    check(any(row[1] for row in grants),
          "protected grant did not retain a derived password")
    check(("password-failed",) in events and events.count(("downloaded",)) == 2,
          f"download audit events were incomplete: {events}")

    with contextlib.closing(
        sqlite3.connect(runtime / "data" / "cms.sqlite.db")
    ) as conn:
        current_schema = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='mailer_jobs'"
        ).fetchone()[0]
        legacy_schema = current_schema.replace(
            "CREATE TABLE mailer_jobs", "CREATE TABLE mailer_jobs_legacy", 1
        ).replace("'email',", "", 1)
        check("'email'" not in legacy_schema,
              "mailer migration fixture retained email delivery")
        conn.execute("PRAGMA foreign_keys=OFF")
        conn.execute(legacy_schema)
        conn.execute("INSERT INTO mailer_jobs_legacy SELECT * FROM mailer_jobs")
        conn.execute("DROP TABLE mailer_jobs")
        conn.execute("ALTER TABLE mailer_jobs_legacy RENAME TO mailer_jobs")
        conn.execute(
            "UPDATE mailer_jobs SET status='queued',queued_at=? WHERE id=?",
            (int(time.time()), recovery_job_id),
        )
        conn.commit()
    with smtp_capture_server() as recovered_smtp:
        with contextlib.closing(
            sqlite3.connect(runtime / "data" / "cms.sqlite.db")
        ) as conn:
            conn.execute(
                "UPDATE mailer_settings SET smtp_port=?,send_interval=? "
                "WHERE singleton=1",
                (recovered_smtp.server_address[1], 0.001),
            )
            conn.commit()
        with MakoProcess(runtime) as server:
            browser = Browser(server.origin)
            code, _, bulk_body = browser.request(
                server.base + "mailer-probe/create-bulk-1005"
            )
            bulk_created = json.loads(bulk_body)
            check(
                code == 200
                and bulk_created["ok"] is True
                and bulk_created["job"]["recipientCount"] == 1005
                and bulk_created["job"]["active"] == 1005
                and "recipients" not in bulk_created["job"],
                f"bulk job creation response was not bounded: {bulk_created}",
            )
            bulk_job_id = bulk_created["job"]["id"]
            code, _, bulk_queue_body = browser.request(
                server.base + f"mailer-probe/queue/{bulk_job_id}"
            )
            bulk_queued = json.loads(bulk_queue_body)
            check(
                code == 200
                and bulk_queued["ok"] is True
                and bulk_queued["job"]["status"] == "queued"
                and bulk_queued["job"]["recipientCount"] == 1005
                and "recipients" not in bulk_queued["job"],
                f"bulk queue response was not bounded: {bulk_queued}",
            )
            deadline = time.time() + 240
            recovered_job = None
            while time.time() < deadline:
                code, _, status_body = browser.request(
                    server.base + f"mailer-probe/job/{recovery_job_id}"
                )
                recovered_job = json.loads(status_body)["job"]
                if (
                    recovered_job["status"] in ("completed", "failed")
                    and len(recovered_smtp.messages) >= 1006
                ):
                    break
                time.sleep(0.05)
            check(
                recovered_job is not None
                and recovered_job["status"] == "completed"
                and len(recovered_smtp.messages) == 1006,
                "queued jobs were not fully recovered after restart: "
                f"job={recovered_job}, messages={len(recovered_smtp.messages)}",
            )
            bulk_messages = [
                message
                for message in recovered_smtp.messages
                if b"Bulk dry run" in message
            ]
            bulk_recipients = {
                match.group(1).decode("ascii")
                for message in bulk_messages
                if (match := re.search(rb"(?im)^to:\s*([^\r\n]+)", message))
            }
            check(
                len(bulk_messages) == 1005
                and len(bulk_recipients) == 1005
                and b"Hello Bulk 1" in b"\n".join(bulk_messages)
                and b"Hello Bulk 1005" in b"\n".join(bulk_messages),
                "bulk dry delivery lost, duplicated, or failed to personalize messages: "
                f"messages={len(bulk_messages)}, recipients={len(bulk_recipients)}",
            )
            with contextlib.closing(
                sqlite3.connect(runtime / "data" / "cms.sqlite.db")
            ) as conn:
                migrated_schema = conn.execute(
                    "SELECT sql FROM sqlite_master "
                    "WHERE type='table' AND name='mailer_jobs'"
                ).fetchone()[0]
                preserved = conn.execute(
                    "SELECT COUNT(*) FROM mailer_download_events"
                ).fetchone()[0]
                bulk_status = conn.execute(
                    "SELECT j.status,COUNT(r.id),"
                    "SUM(CASE WHEN r.status='sent' THEN 1 ELSE 0 END),"
                    "SUM(r.attempts) FROM mailer_jobs j "
                    "JOIN mailer_job_recipients r ON r.job_id=j.id "
                    "WHERE j.id=? GROUP BY j.id",
                    (bulk_job_id,),
                ).fetchone()
            check(
                "'email'" in migrated_schema and preserved == len(events),
                "email delivery schema migration lost mailer history",
            )
            check(
                bulk_status == ("completed", 1005, 1005, 1005),
                f"bulk delivery database state was incorrect: {bulk_status}",
            )


def test_large_file_mailer_operations() -> None:
    runtime = fresh_runtime("large-file-mailer-operations")
    install_large_file_mailer_plugin(runtime)
    (runtime / "mailer-fixture.txt").write_text(
        "FuguHub operator mailer fixture\n", encoding="ascii"
    )

    with smtp_capture_server() as smtp, MakoProcess(runtime, mount="mybase") as server:
        admin_browser = Browser(server.origin)
        identity_url = server.base + "admin/plugins/identity-access/"
        code, _, identity_page = admin_browser.request(identity_url)
        check(code == 200, "identity setup failed for mailer operations test")
        identity_token = csrf_from(identity_page)

        def save_user(username: str, password: str, roles: tuple[str, ...]) -> None:
            fields = {
                "action": "save-user",
                "username": username,
                "display_name": username.replace("-", " ").title(),
                "email": f"{username}@example.test",
                "password": password,
                "max_users": "3",
                "inactive": "1200",
            }
            for role in roles:
                fields[f"role_{role}"] = "1"
            status, result = identity_api_post(
                admin_browser, server, identity_token, fields
            )
            check(status == 200 and result["ok"] is True,
                  f"creating {username} failed: {result}")

        code, role_result = identity_api_post(
            admin_browser,
            server,
            identity_token,
            {
                "action": "save-role",
                "name": "mailer-files",
                "description": "Read files attached by the mailer",
            },
        )
        check(code == 200 and role_result["ok"] is True,
              f"creating mailer file role failed: {role_result}")
        save_user("mail-user", "mail-user-password", ("mailer-files", "mailer-user"))
        save_user(
            "mail-manager",
            "mail-manager-password",
            ("mailer-files", "mailer-manager"),
        )
        save_user("file-only", "file-only-password", ("mailer-files",))

        files_url = server.base + "admin/plugins/file-services/"
        _, _, files_page = admin_browser.request(files_url)
        files_token = csrf_from(files_page)
        code, result = file_api_post(
            admin_browser,
            server,
            files_token,
            {
                "action": "save-acl",
                "id": "",
                "name": "Mailer operator fixture",
                "role": "mailer-files",
                "path": "/",
                "permission": "read",
                "enabled": "1",
            },
        )
        check(code == 200 and result["ok"] is True,
              f"operator file ACL creation failed: {result}")
        code, result = file_api_post(
            admin_browser,
            server,
            files_token,
            {
                "action": "save-settings",
                "enabled": "1",
                "max_uploads": "20",
                "max_locks": "100",
                "session_timeout": "900",
                "case_sensitive": "1",
            },
        )
        check(code == 200 and result["active"] is True,
              f"operator File Services activation failed: {result}")

        mailer_admin = server.base + "admin/plugins/large-file-mailer/"
        mailer_admin_status, _, mailer_page = admin_browser.request(mailer_admin)
        check(
            mailer_admin_status == 200 and b"name='_csrf'" in mailer_page,
            "large-file-mailer admin route failed "
            f"({mailer_admin_status}): {mailer_page[:1000]!r}\n"
            + "\n".join(server.lines[-80:]),
        )
        mailer_admin_token = csrf_from(mailer_page)
        code, _, body = admin_browser.form(
            mailer_admin + "api/",
            {
                "_csrf": mailer_admin_token,
                "action": "save-settings",
                "enabled": "1",
                "smtp_server": "127.0.0.1",
                "smtp_port": str(smtp.server_address[1]),
                "smtp_security": "none",
                "smtp_username": "",
                "from_address": "sender@example.test",
                "reply_to": "",
                "public_base_url": server.origin,
                "attachment_limit": "1048576",
                "grant_ttl": "3600",
                "max_attempts": "3",
                "retry_base": "1",
                "send_interval": "1",
                "require_https": "0",
                "password": "",
            },
        )
        check(code == 200 and json.loads(body)["settings"]["enabled"] is True,
              f"operator mailer activation failed: {body[:500]!r}")

        save_user(
            "cms-mailer-admin",
            "cms-mailer-admin-password",
            ("cms-admin", "mailer-manager"),
        )

        sender = Browser(server.origin)
        code, _, compose_page = form_login(
            sender,
            server.base + "mailer/compose/",
            "mail-user",
            "mail-user-password",
        )
        check(
            code == 200
            and b"data-view='compose'" in compose_page
            and b"/mybase/mailer/app.js" in compose_page
            and b">Compose</a>" in compose_page
            and b">Contacts</a>" not in compose_page
            and b">Settings</a>" not in compose_page,
            "named-mount compose shell failed",
        )
        for restricted_view in (
            "contacts", "lists", "invitations", "remove", "templates", "jobs", "manage"
        ):
            code, _, _ = sender.request(server.base + f"mailer/{restricted_view}/")
            check(code == 403, f"mailer-user opened the {restricted_view} page")

        manager = Browser(server.origin)
        code, _, manage_page = form_login(
            manager,
            server.base + "mailer/jobs/",
            "mail-manager",
            "mail-manager-password",
        )
        csrf_match = re.search(rb"data-csrf='([^']+)'", manage_page)
        check(
            code == 200
            and csrf_match is not None
            and b"data-view='jobs'" in manage_page
            and b"aria-current='page' href='/mybase/mailer/jobs/'" in manage_page
            and b">Settings</a>" not in manage_page,
            f"mailer-manager shell or CSRF token failed: {code}, {manage_page[:500]!r}",
        )
        for manager_view in (
            "contacts", "lists", "invitations", "remove", "templates", "jobs"
        ):
            code, _, manager_page = manager.request(
                server.base + f"mailer/{manager_view}/"
            )
            check(
                code == 200
                and f"data-view='{manager_view}'".encode() in manager_page
                and (
                    "aria-current='page' href='/mybase/mailer/"
                    f"{manager_view}/'"
                ).encode() in manager_page,
                f"mailer manager route failed for {manager_view}: "
                f"{manager_page[:500]!r}",
            )
        code, _, legacy_manage = manager.request(server.base + "mailer/manage/")
        check(code == 200 and b"data-view='jobs'" in legacy_manage,
              "legacy mailer manage route no longer opens Jobs")
        code, _, compose_state_body = manager.request(
            server.base + "mailer/api/?scope=compose&query=&page=1"
        )
        compose_state = json.loads(compose_state_body)
        check(
            code == 200
            and not compose_state["contacts"]["items"]
            and compose_state["contacts"]["total"] >= 0,
            f"compose API returned an initial contact dump: {compose_state}",
        )

        cms_admin_operator = Browser(server.origin)
        code, _, admin_jobs = form_login(
            cms_admin_operator,
            server.base + "mailer/jobs/",
            "cms-mailer-admin",
            "cms-mailer-admin-password",
        )
        check(
            code == 200
            and b">Settings</a>" in admin_jobs
            and b"data-settings-url='/mybase/admin/plugins/large-file-mailer/'" in
                admin_jobs,
            "CMS administrator did not receive the mailer Settings tab",
        )
        mailer_csrf = csrf_match.group(1).decode("ascii")
        code, headers, script = manager.request(server.base + "mailer/app.js")
        check(code == 200 and b"FormData" in script and
              b"{{UNSUBSCRIBE_LINK}}" in script and
              b"recipient-search" in script and
              b"template_id: template.value" in script and
              b"Stored job content" in script and
              b"loadJob" in script and
              b"Restore email" in script and
              "javascript" in headers.get("Content-Type", "").lower(),
              "mailer client script was unavailable")
        code, headers, stylesheet = manager.request(server.base + "mailer/app.css")
        check(code == 200 and b".workspace" in stylesheet and
              "css" in headers.get("Content-Type", "").lower(),
              "mailer client stylesheet was unavailable")
        code, headers, wfm_script = manager.request(server.base + "mailer/wfm.js")
        check(
            code == 200
            and b'api.add("command"' in wfm_script
            and b'Email selected files' in wfm_script
            and b'entry.s !== -1' in wfm_script
            and "javascript" in headers.get("Content-Type", "").lower(),
            "mailer WFM command module was unavailable",
        )

        wfm_url = server.base + "fs/"
        code, headers, mailer_wfm_page = digest_request(
            wfm_url,
            "mail-user",
            "mail-user-password",
            method="GET",
            headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
        )
        check(
            code == 200
            and b"/rtl/wfm/wfm.js" in mailer_wfm_page
            and b"\\/mybase\\/mailer\\/wfm.js" in mailer_wfm_page
            and dict((key.lower(), value) for key, value in headers.items())
            .get("cache-control", "").lower() == "no-store",
            f"mailer role did not receive the WFM command ({code}): "
            f"{mailer_wfm_page[:1000]!r}",
        )
        code, _, file_only_wfm_page = digest_request(
            wfm_url,
            "file-only",
            "file-only-password",
            method="GET",
            headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
        )
        check(
            code == 200
            and b"/rtl/wfm/wfm.js" in file_only_wfm_page
            and b"\\/mybase\\/mailer\\/wfm.js" not in file_only_wfm_page,
            f"non-mailer user received the WFM mail command ({code}): "
            f"{file_only_wfm_page[:1000]!r}",
        )

        code, _, denied = manager.form(
            server.base + "mailer/api/", {"action": "save-contact"}, multipart=True
        )
        check(code == 403 and json.loads(denied)["ok"] is False,
              f"mailer API accepted a mutation without CSRF ({code}): {denied!r}")

        def mailer_post(
            fields: dict[str, str],
        ) -> dict:
            payload = dict(fields)
            payload["csrf"] = mailer_csrf
            status, _, result_body = manager.form(
                server.base + "mailer/api/",
                payload,
                multipart=True,
            )
            result = json.loads(result_body)
            check(status == 200 and result["ok"] is True,
                  f"mailer operation failed ({status}): {result}")
            return result

        def csv_post(
            action: str,
            source: bytes,
            mapping: dict[str, int] | None = None,
            list_id: int | None = None,
            csrf: bool = True,
            restore_unsubscribed: bool = False,
            has_header: bool | None = None,
        ) -> tuple[int, dict]:
            headers = {"Content-Type": "text/csv"}
            if csrf:
                headers["X-FuguHub-CSRF"] = mailer_csrf
            if mapping is not None:
                headers["X-FuguHub-CSV-Mapping"] = json.dumps(mapping)
            if list_id is not None:
                headers["X-FuguHub-List-ID"] = str(list_id)
            if restore_unsubscribed:
                headers["X-FuguHub-Restore-Unsubscribed"] = "1"
            if has_header is not None:
                headers["X-FuguHub-CSV-Has-Header"] = "1" if has_header else "0"
            status, _, result_body = manager.request(
                server.base + f"mailer/csv/{action}/?query=bulk&page=1",
                data=source,
                headers=headers,
                method="POST",
            )
            return status, json.loads(result_body)

        def removal_post(
            action: str,
            source: bytes,
            csrf: bool = True,
            actor: Browser = manager,
        ) -> tuple[int, dict]:
            headers = {"Content-Type": "text/plain; charset=utf-8"}
            if csrf:
                headers["X-FuguHub-CSRF"] = mailer_csrf
            status, _, result_body = actor.request(
                server.base + f"mailer/remove/{action}/",
                data=source,
                headers=headers,
                method="POST",
            )
            return status, json.loads(result_body)

        state = mailer_post(
            {
                "action": "save-contact",
                "id": "",
                "email": "recipient@example.test",
                "first_name": "Operator",
                "last_name": "Recipient",
                "external_id": "primary",
            }
        )
        primary = next(
            item for item in state["contacts"]["items"]
            if item["email"] == "recipient@example.test"
        )

        url_file_job = mailer_post(
            {
                "action": "create-job",
                "queue": "0",
                "subject": "File Services URL fixture",
                "template_id": "",
                "delivery_mode": "attachment",
                "require_contact_password": "0",
                "text_body": "Absolute File Services URL",
                "html_body": "",
                "files": json.dumps([server.base + "fs/mailer-fixture.txt"]),
                "contact_ids": json.dumps([primary["id"]]),
                "list_ids": "[]",
            }
        )["job"]
        with contextlib.closing(
            sqlite3.connect(runtime / "data" / "cms.sqlite.db")
        ) as conn:
            stored_url_path = conn.execute(
                "SELECT relative_path FROM mailer_job_files WHERE job_id=?",
                (url_file_job["id"],),
            ).fetchone()[0]
        check(
            stored_url_path == "/mailer-fixture.txt",
            f"File Services URL was not normalized server-side: {stored_url_path}",
        )
        mailer_post({"action": "cancel-job", "id": str(url_file_job["id"])})

        unrelated_url_fields = {
            "csrf": mailer_csrf,
            "action": "create-job",
            "queue": "0",
            "subject": "Unrelated URL fixture",
            "template_id": "",
            "delivery_mode": "attachment",
            "require_contact_password": "0",
            "text_body": "Unrelated URL",
            "html_body": "",
            "files": json.dumps([server.origin + "outside/mailer-fixture.txt"]),
            "contact_ids": json.dumps([primary["id"]]),
            "list_ids": "[]",
        }
        code, _, unrelated_url_body = manager.form(
            server.base + "mailer/api/", unrelated_url_fields, multipart=True
        )
        unrelated_url = json.loads(unrelated_url_body)
        check(
            code == 400
            and unrelated_url["ok"] is False
            and "must be below" in unrelated_url["error"],
            f"mailer accepted an unrelated URL as a File Services path: {unrelated_url}",
        )

        protected_fields = {
            "csrf": mailer_csrf,
            "action": "create-job",
            "queue": "1",
            "subject": "Protected fixture",
            "template_id": "",
            "delivery_mode": "link",
            "require_contact_password": "1",
            "text_body": "Hello {{FIRST_NAME}}\n{{DOWNLOAD_LINKS}}",
            "html_body": "",
            "files": json.dumps(["/mailer-fixture.txt"]),
            "contact_ids": json.dumps([primary["id"]]),
            "list_ids": "[]",
        }
        code, _, unconfirmed_body = manager.form(
            server.base + "mailer/api/", protected_fields, multipart=True
        )
        unconfirmed = json.loads(unconfirmed_body)
        check(
            code == 400
            and unconfirmed["ok"] is False
            and "accept a password invitation first" in unconfirmed["error"],
            f"protected delivery accepted an unconfirmed contact: {unconfirmed}",
        )

        code, _, global_invitation_body = manager.form(
            server.base + "mailer/api/",
            {
                "csrf": mailer_csrf,
                "action": "create-invitation-job",
                "subject": "Unsafe global invitation",
                "text_body": "No global recipient selection",
                "html_body": "",
                "contact_ids": "[]",
                "list_ids": "[]",
                "all_unconfirmed": "1",
            },
            multipart=True,
        )
        global_invitation = json.loads(global_invitation_body)
        check(
            code == 400
            and global_invitation["ok"] is False
            and "Select contacts or recipient lists" in global_invitation["error"],
            f"global unconfirmed invitation was not rejected: {global_invitation}",
        )

        before_invitation = len(smtp.messages)
        invitation_state = mailer_post(
            {
                "action": "create-invitation-job",
                "subject": "Confirm your email address",
                "text_body": "Hello {{FIRST_NAME}}",
                "html_body": "",
                "contact_ids": json.dumps([primary["id"]]),
                "list_ids": "[]",
            }
        )
        invitation_job_id = invitation_state["job"]["id"]
        deadline = time.time() + 8
        invitation_job = invitation_state["job"]
        while time.time() < deadline:
            _, _, job_body = manager.request(
                server.base + f"mailer-probe/job/{invitation_job_id}"
            )
            invitation_job = json.loads(job_body)["job"]
            if invitation_job["status"] in ("completed", "failed"):
                break
            time.sleep(0.05)
        check(
            invitation_job["status"] == "completed"
            and invitation_job["jobType"] == "invitation"
            and len(smtp.messages) == before_invitation + 1,
            f"password invitation was not delivered: {invitation_job}",
        )
        invitation_message = quopri.decodestring(smtp.messages[-1])
        invitation_match = re.search(
            rb"http://(?:localhost|127\.0\.0\.1):\d+/mybase/mailer/invite/"
            rb"[A-Za-z0-9_-]+",
            invitation_message,
        )
        check(invitation_match is not None,
              f"invitation message omitted its setup link: {invitation_message[:2000]!r}")
        check(
            b"Hello Operator" in invitation_message
            and b"Set your password:" in invitation_message,
            f"invitation fallback text was not assembled: {invitation_message[:2000]!r}",
        )
        invitation_url = invitation_match.group(0).decode("ascii")
        recipient_browser = Browser(server.origin)
        code, _, invitation_page = recipient_browser.request(invitation_url)
        csrf_match = re.search(rb"name='csrf' value='([^']+)'", invitation_page)
        check(
            code == 200
            and csrf_match is not None
            and b"Set download password" in invitation_page,
            f"invitation setup page failed: {code}, {invitation_page[:1000]!r}",
        )
        code, _, mismatch_page = recipient_browser.form(
            invitation_url,
            {
                "csrf": csrf_match.group(1).decode("ascii"),
                "password": "personal-download-password",
                "confirm": "different-password",
            },
        )
        check(code == 200 and b"passwords do not match" in mismatch_page,
              "invitation accepted mismatched passwords")
        code, _, confirmation_page = recipient_browser.form(
            invitation_url,
            {
                "csrf": csrf_match.group(1).decode("ascii"),
                "password": "personal-download-password",
                "confirm": "personal-download-password",
            },
        )
        check(code == 200 and b"Password saved" in confirmation_page,
              f"contact password setup failed: {confirmation_page[:1000]!r}")
        code, _, _ = recipient_browser.request(invitation_url)
        check(code == 404, "consumed invitation token remained usable")
        code, _, confirmed_body = manager.request(
            server.base + "mailer/api/?scope=contacts&query=recipient%40example.test&page=1"
        )
        confirmed_state = json.loads(confirmed_body)
        check(
            code == 200
            and confirmed_state["contacts"]["items"][0]["confirmed"] is True,
            f"confirmed contact state was not exposed: {confirmed_state}",
        )

        before_protected = len(smtp.messages)
        protected_state = mailer_post({key: str(value) for key, value in protected_fields.items()
                                       if key != "csrf"})
        protected_job_id = protected_state["job"]["id"]
        deadline = time.time() + 8
        protected_job = protected_state["job"]
        while time.time() < deadline:
            _, _, job_body = manager.request(
                server.base + f"mailer-probe/job/{protected_job_id}"
            )
            protected_job = json.loads(job_body)["job"]
            if protected_job["status"] in ("completed", "failed"):
                break
            time.sleep(0.05)
        check(
            protected_job["status"] == "completed"
            and protected_job["requireContactPassword"] is True
            and len(smtp.messages) == before_protected + 1,
            f"recipient-password delivery failed: {protected_job}",
        )
        protected_message = quopri.decodestring(smtp.messages[-1])
        download_match = re.search(
            rb"http://(?:localhost|127\.0\.0\.1):\d+/mybase/mailer/d/"
            rb"[A-Za-z0-9_-]+",
            protected_message,
        )
        check(download_match is not None,
              f"protected delivery omitted its link: {protected_message[:2000]!r}")
        download_url = download_match.group(0).decode("ascii")
        code, _, password_page = recipient_browser.request(download_url)
        download_csrf = re.search(rb"name='csrf' value='([^']+)'", password_page)
        check(code == 200 and download_csrf is not None
              and b"/mybase/mailer/public.css" in password_page,
              f"protected download form failed: {password_page[:1000]!r}")
        code, _, downloaded = recipient_browser.form(
            download_url,
            {
                "csrf": download_csrf.group(1).decode("ascii"),
                "password": "personal-download-password",
            },
        )
        check(code == 200 and downloaded.replace(b"\r\n", b"\n") ==
              b"FuguHub operator mailer fixture\n",
              f"recipient password did not unlock the file: {downloaded[:500]!r}")

        state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "CSV recipients",
                "description": "CSV import destination",
                "contact_ids": "[]",
            }
        )
        csv_list = next(
            item for item in state["lists"] if item["name"] == "CSV recipients"
        )

        csv_rows = [
            "email,first_name,last_name,external_id",
            "recipient@example.test,Duplicate,Contact,duplicate",
            "not-an-email,Invalid,Contact,invalid",
        ]
        for index in range(55):
            csv_rows.append(
                f"bulk{index}@example.test,Bulk,{index},bulk-{index}"
            )
        csv_source = ("\r\n".join(csv_rows) + "\r\n").encode("utf-8")
        status, preview_state = csv_post("preview", csv_source)
        preview = preview_state["csvPreview"]
        check(
            status == 200
            and preview_state["ok"] is True
            and preview["totalRows"] == 57
            and preview["mapping"]["email"] == 1
            and len(preview["rows"]) == 10,
            f"CSV preview failed: {preview}",
        )
        address_book_csv = (
            b"First Name,Last Name,Display Name,Nickname,Primary Email,"
            b"Secondary Email,Notes\r\n"
            b"S\xf8ren,Lee,S\xf8ren Lee,,soren@example.test,,\r\n"
            b"Marcus,Kvist,Marcus Kvist,,marcus@example.test,alternate@example.test,"
            b'"International Banking Centre,\r\nLevel 6 \x80"\r\n'
        )
        status, address_book_state = csv_post("preview", address_book_csv)
        address_book_preview = address_book_state["csvPreview"]
        check(
            status == 200
            and address_book_preview["mapping"]["email"] == 5
            and address_book_preview["mapping"]["firstName"] == 1
            and address_book_preview["mapping"]["lastName"] == 2
            and "displayName" not in address_book_preview["mapping"]
            and address_book_preview["totalRows"] == 2
            and address_book_preview["rows"][0][0] == "S\u00f8ren"
            and address_book_preview["rows"][1][6].endswith("\u20ac"),
            f"personal address book CSV mapping failed: {address_book_state}",
        )
        headerless_csv = (
            b"Headerless,One,Headerless One,,headerless-one@example.test,,\r\n"
            b"Headerless,Two,Headerless Two,,headerless-two@example.test,,\r\n"
            b"Headerless,Three,Headerless Three,,headerless-three@example.test,,\r\n"
        )
        status, headerless_state = csv_post("preview", headerless_csv)
        headerless_preview = headerless_state["csvPreview"]
        check(
            status == 200
            and headerless_preview["hasHeader"] is False
            and headerless_preview["totalRows"] == 3
            and headerless_preview["mapping"]["email"] == 5
            and headerless_preview["headers"][0] == "Column 1"
            and headerless_preview["rows"][0][4]
            == "headerless-one@example.test",
            f"headerless CSV preview dropped or mislabeled a row: {headerless_state}",
        )
        state = mailer_post({
            "action": "save-list",
            "id": "",
            "name": "Headerless CSV recipients",
            "description": "Headerless CSV regression destination",
            "contact_ids": "[]",
        })
        headerless_list = next(
            item for item in state["lists"]
            if item["name"] == "Headerless CSV recipients"
        )
        status, headerless_import_state = csv_post(
            "import",
            headerless_csv,
            {"email": 5, "firstName": 1, "lastName": 2},
            headerless_list["id"],
            has_header=False,
        )
        headerless_import = headerless_import_state["importResult"]
        check(
            status == 200
            and headerless_import["totalRows"] == 3
            and headerless_import["imported"] == 3
            and headerless_import["membersAdded"] == 3,
            f"headerless CSV import did not import every row: {headerless_import_state}",
        )
        status, unknown_email_state = csv_post(
            "preview", b"Name,Preferred Contact\r\nUnknown,unknown@example.test\r\n"
        )
        check(
            status == 200
            and unknown_email_state["csvPreview"]["mapping"].get("email") is None,
            f"CSV preview prevented manual email mapping: {unknown_email_state}",
        )
        status, missing_email_import = csv_post(
            "import",
            b"Name,Preferred Contact\r\nUnknown,unknown@example.test\r\n",
            {"firstName": 1},
            csv_list["id"],
        )
        check(
            status == 400
            and missing_email_import["error"] == "Select an email column",
            f"CSV import accepted no email mapping: {missing_email_import}",
        )
        status, utf16_state = csv_post(
            "preview", b"\xff\xfee\x00m\x00a\x00i\x00l\x00\r\x00\n\x00"
        )
        check(
            status == 400
            and "UTF-16" in utf16_state["error"]
            and ".lua" not in utf16_state["error"],
            f"UTF-16 CSV produced an unclear error: {utf16_state}",
        )
        chunked_csv = (
            b"email,first_name\r\nchunk@example.test,\""
            + b"x" * 12000
            + b"\"\r\n"
        )
        status, chunked = csv_post("preview", chunked_csv)
        check(status == 200 and chunked["csvPreview"]["totalRows"] == 1,
              f"multi-block raw CSV preview failed: {chunked}")
        status, no_csrf = csv_post("preview", csv_source, csrf=False)
        check(status == 403 and no_csrf["ok"] is False,
              f"raw CSV endpoint accepted a request without CSRF: {no_csrf}")
        code, _, method_body = manager.request(
            server.base + "mailer/csv/preview/", method="GET"
        )
        method_error = json.loads(method_body)
        check(code == 405 and method_error["ok"] is False,
              f"raw CSV endpoint accepted GET: {method_error}")
        code, _, sender_csv = sender.request(
            server.base + "mailer/csv/preview/",
            data=csv_source,
            headers={"Content-Type": "text/csv"},
            method="POST",
        )
        check(code == 403 and json.loads(sender_csv)["ok"] is False,
              "mailer-user opened the manager CSV endpoint")
        code, malformed = csv_post(
            "preview", b'email,name\r\n"unterminated,value\r\n'
        )
        check(code == 400 and malformed["ok"] is False and
              "unterminated" in malformed["error"].lower()
              and ".lua" not in malformed["error"],
              f"malformed CSV was accepted: {malformed}")
        code, oversized = csv_post(
            "preview", b"email\r\n" + b"x" * (2 * 1024 * 1024 + 1)
        )
        check(code == 413 and oversized["ok"] is False and
              "2 mib" in oversized["error"].lower(),
              f"oversized CSV was accepted: {oversized}")
        status, imported_state = csv_post(
            "import", csv_source, preview["mapping"]
        )
        check(
            status == 400
            and "destination list" in imported_state["error"].lower(),
            f"CSV import accepted no destination list: {imported_state}",
        )
        status, imported_state = csv_post(
            "import", csv_source, preview["mapping"], csv_list["id"]
        )
        imported = imported_state["importResult"]
        check(
            status == 200
            and imported_state["ok"] is True
            and imported["imported"] == 55
            and imported["membersAdded"] == 56
            and imported["listId"] == csv_list["id"]
            and len(imported["duplicates"]) == 1
            and len(imported["errors"]) == 1,
            f"CSV import accounting failed: {imported}",
        )
        csv_list = next(
            item for item in imported_state["lists"]
            if item["id"] == csv_list["id"]
        )
        check(
            csv_list["members"] == 56 and len(csv_list["memberIds"]) == 56,
            f"CSV contacts were not assigned to the destination list: {csv_list}",
        )

        for email, first_name in (
            ("remove.one@example.test", "RemoveOne"),
            ("remove.two@example.test", "RemoveTwo"),
        ):
            mailer_post(
                {
                    "action": "save-contact",
                    "id": "",
                    "email": email,
                    "first_name": first_name,
                    "last_name": "BulkRemoval",
                    "external_id": "",
                }
            )
        removal_source = (
            b"Unsubscribe REMOVE.ONE@example.test, remove.two@example.test.\r\n"
            b"Duplicate remove.one@example.test and missing@example.test in arbitrary text."
        )
        status, streamed_removal = removal_post(
            "preview", b"x" * 12000 + b" remove.one@example.test"
        )
        check(
            status == 200
            and streamed_removal["removalPreview"]["matchCount"] == 1,
            f"multi-block raw removal preview failed: {streamed_removal}",
        )
        status, removal_preview_state = removal_post("preview", removal_source)
        removal_preview = removal_preview_state["removalPreview"]
        check(
            status == 200
            and removal_preview["extractedCount"] == 3
            and removal_preview["matchCount"] == 2
            and removal_preview["notFoundCount"] == 1
            and {item["email"].lower() for item in removal_preview["matches"]}
            == {"remove.one@example.test", "remove.two@example.test"},
            f"bulk contact removal preview is incorrect: {removal_preview_state}",
        )
        status, no_removal_csrf = removal_post(
            "preview", removal_source, csrf=False
        )
        check(
            status == 403 and no_removal_csrf["ok"] is False,
            f"bulk removal accepted no CSRF token: {no_removal_csrf}",
        )
        status, sender_removal = removal_post(
            "preview", removal_source, csrf=False, actor=sender
        )
        check(
            status == 403 and sender_removal["ok"] is False,
            f"mailer-user opened the manager removal endpoint: {sender_removal}",
        )
        code, _, removal_get_body = manager.request(
            server.base + "mailer/remove/preview/", method="GET"
        )
        check(
            code == 405 and json.loads(removal_get_body)["ok"] is False,
            "bulk removal preview accepted GET",
        )
        status, no_addresses = removal_post("preview", b"No addresses here")
        check(
            status == 400
            and no_addresses["error"] == "No email addresses were found",
            f"bulk removal accepted input without addresses: {no_addresses}",
        )
        status, removal_result_state = removal_post("execute", removal_source)
        removal_result = removal_result_state["removalResult"]
        check(
            status == 200
            and removal_result["removed"] == 2
            and removal_result["extractedCount"] == 3
            and removal_result["notFoundCount"] == 1,
            f"bulk contact removal failed: {removal_result_state}",
        )
        code, _, removed_search_body = manager.request(
            server.base + "mailer/api/?scope=contacts&query=BulkRemoval&page=1"
        )
        removed_search = json.loads(removed_search_body)
        check(
            code == 200 and removed_search["contacts"]["total"] == 0,
            f"bulk-removed contacts remain in the database: {removed_search}",
        )
        code, _, page_two_body = manager.request(
            server.base + "mailer/api/?query=bulk&page=2"
        )
        page_two = json.loads(page_two_body)
        check(
            code == 200
            and page_two["contacts"]["total"] == 55
            and len(page_two["contacts"]["items"]) == 5,
            f"contact search/pagination failed: {page_two}",
        )

        bulk_contact = next(
            item for item in imported_state["contacts"]["items"]
            if item["email"] == "bulk0@example.test"
        )
        state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "Transfer destination",
                "description": "List movement test",
            }
        )
        transfer_list = next(
            item for item in state["lists"] if item["name"] == "Transfer destination"
        )
        state = mailer_post(
            {
                "action": "move-list-members",
                "source_list_id": str(csv_list["id"]),
                "destination_list_id": str(transfer_list["id"]),
                "contact_ids": json.dumps([bulk_contact["id"]]),
            }
        )
        moved_source = next(item for item in state["lists"] if item["id"] == csv_list["id"])
        moved_destination = next(
            item for item in state["lists"] if item["id"] == transfer_list["id"]
        )
        check(
            bulk_contact["id"] not in moved_source["memberIds"]
            and bulk_contact["id"] in moved_destination["memberIds"]
            and state["transfer"]["moved"] == 1,
            f"selected contact was not moved between lists: {state['transfer']}",
        )
        code, _, scoped_body = manager.request(
            server.base
            + "mailer/api/?scope=lists&list_id="
            + str(transfer_list["id"])
            + "&query=bulk0&page=1"
        )
        scoped = json.loads(scoped_body)
        check(
            code == 200
            and scoped["list"]["name"] == "Transfer destination"
            and len(scoped["contacts"]["items"]) == 1
            and scoped["contacts"]["items"][0]["listNames"]
            == ["Transfer destination"],
            f"list-scoped contact API is incorrect: {scoped}",
        )
        state = mailer_post(
            {
                "action": "move-all-list-members",
                "source_list_id": str(transfer_list["id"]),
                "destination_list_id": str(csv_list["id"]),
            }
        )
        moved_destination = next(
            item for item in state["lists"] if item["id"] == transfer_list["id"]
        )
        check(
            moved_destination["members"] == 0
            and state["transfer"]["moved"] == 1,
            f"move-all did not empty the source list: {state['transfer']}",
        )
        state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "Merge source",
                "description": "Temporary merge source",
                "contact_ids": json.dumps([bulk_contact["id"]]),
            }
        )
        merge_source = next(
            item for item in state["lists"] if item["name"] == "Merge source"
        )
        state = mailer_post(
            {
                "action": "merge-list",
                "source_list_id": str(merge_source["id"]),
                "destination_list_id": str(csv_list["id"]),
            }
        )
        check(
            state["transfer"]["sourceDeleted"] is True
            and all(item["id"] != merge_source["id"] for item in state["lists"]),
            f"list merge did not delete its source: {state['transfer']}",
        )

        state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "Primary recipients",
                "description": "Operator test list",
                "contact_ids": json.dumps([primary["id"]]),
            }
        )
        recipient_list = next(
            item for item in state["lists"] if item["name"] == "Primary recipients"
        )
        check(recipient_list["memberIds"] == [primary["id"]],
              f"list membership was not returned: {recipient_list}")

        before_opt_out = len(smtp.messages)
        opt_out_state = mailer_post(
            {
                "action": "create-job",
                "queue": "1",
                "subject": "Opt-out fixture",
                "template_id": "",
                "delivery_mode": "email",
                "require_contact_password": "0",
                "text_body": (
                    "Hello {{FIRST_NAME}}\n\n"
                    "Stop receiving these messages: {{UNSUBSCRIBE_LINK}}"
                ),
                "html_body": "",
                "files": "[]",
                "contact_ids": json.dumps([primary["id"]]),
                "list_ids": "[]",
            }
        )
        opt_out_job_id = opt_out_state["job"]["id"]
        deadline = time.time() + 8
        opt_out_job = opt_out_state["job"]
        while time.time() < deadline:
            _, _, job_body = manager.request(
                server.base + f"mailer-probe/job/{opt_out_job_id}"
            )
            opt_out_job = json.loads(job_body)["job"]
            if opt_out_job["status"] in ("completed", "failed"):
                break
            time.sleep(0.05)
        check(
            opt_out_job["status"] == "completed"
            and len(smtp.messages) == before_opt_out + 1,
            f"opt-out delivery was not sent: {opt_out_job}",
        )
        opt_out_message = quopri.decodestring(smtp.messages[-1])
        opt_out_match = re.search(
            rb"http://(?:localhost|127\.0\.0\.1):\d+/mybase/mailer/unsubscribe/"
            rb"[A-Za-z0-9_-]+",
            opt_out_message,
        )
        check(opt_out_match is not None,
              f"delivery omitted its opt-out link: {opt_out_message[:2000]!r}")
        opt_out_url = opt_out_match.group(0).decode("ascii")
        opt_out_browser = Browser(server.origin)
        code, _, opt_out_page = opt_out_browser.request(opt_out_url)
        opt_out_csrf = re.search(rb"name='csrf' value='([^']+)'", opt_out_page)
        check(
            code == 200
            and opt_out_csrf is not None
            and b"Manage your details" in opt_out_page
            and b"value='recipient@example.test'" in opt_out_page
            and b"value='Operator'" in opt_out_page
            and b"value='Recipient'" in opt_out_page
            and b"action' value='save'" in opt_out_page
            and b"action' value='unsubscribe'" in opt_out_page
            and b"/mybase/mailer/public.css" in opt_out_page,
            f"email preference page failed: {code}, {opt_out_page[:1000]!r}",
        )
        code, _, contact_body = manager.request(
            server.base
            + "mailer/api/?scope=contacts&query=recipient%40example.test&page=1"
        )
        contact_state = json.loads(contact_body)
        original_list_ids = contact_state["contacts"]["items"][0]["listIds"]
        check(
            code == 200
            and contact_state["contacts"]["items"][0]["unsubscribed"] is False,
            "opening an opt-out link unsubscribed the contact",
        )
        code, _, expired_page = opt_out_browser.form(
            opt_out_url, {"csrf": "invalid", "action": "unsubscribe"}
        )
        check(code == 403 and b"form expired" in expired_page.lower(),
              "email preference endpoint accepted invalid CSRF")
        code, _, updated_page = opt_out_browser.form(
            opt_out_url,
            {
                "csrf": opt_out_csrf.group(1).decode("ascii"),
                "action": "save",
                "email": "updated-recipient@example.test",
                "first_name": "Updated",
                "last_name": "Person",
            },
        )
        check(
            code == 200
            and b"contact details were updated" in updated_page
            and b"value='updated-recipient@example.test'" in updated_page
            and b"value='Updated'" in updated_page
            and b"value='Person'" in updated_page,
            f"public contact details could not be updated: {updated_page[:1000]!r}",
        )
        updated_csrf = re.search(rb"name='csrf' value='([^']+)'", updated_page)
        check(updated_csrf is not None,
              "updated email preference page omitted its replacement CSRF token")
        code, _, contact_body = manager.request(
            server.base
            + "mailer/api/?scope=contacts&query=updated-recipient%40example.test&page=1"
        )
        updated_contact = json.loads(contact_body)["contacts"]["items"][0]
        check(
            code == 200
            and updated_contact["id"] == primary["id"]
            and updated_contact["email"] == "updated-recipient@example.test"
            and updated_contact["firstName"] == "Updated"
            and updated_contact["lastName"] == "Person"
            and updated_contact["listIds"] == original_list_ids,
            f"public contact update changed the wrong state: {updated_contact}",
        )
        code, _, restored_page = opt_out_browser.form(
            opt_out_url,
            {
                "csrf": updated_csrf.group(1).decode("ascii"),
                "action": "save",
                "email": "recipient@example.test",
                "first_name": "Operator",
                "last_name": "Recipient",
            },
        )
        opt_out_csrf = re.search(rb"name='csrf' value='([^']+)'", restored_page)
        check(code == 200 and opt_out_csrf is not None,
              f"email preference values could not be restored: {restored_page[:1000]!r}")
        code, _, complete_page = opt_out_browser.form(
            opt_out_url,
            {
                "csrf": opt_out_csrf.group(1).decode("ascii"),
                "action": "unsubscribe",
            },
        )
        check(
            code == 200
            and b"unsubscribed from future mailer deliveries" in complete_page
            and b"Unsubscribe from emails" not in complete_page,
            f"contact could not opt out: {complete_page[:1000]!r}",
        )
        code, _, contact_body = manager.request(
            server.base
            + "mailer/api/?scope=contacts&query=recipient%40example.test&page=1"
        )
        contact_state = json.loads(contact_body)
        opted_out = contact_state["contacts"]["items"][0]
        check(
            code == 200
            and opted_out["unsubscribed"] is True
            and not opted_out["listIds"],
            f"opt-out state or list removal is incorrect: {opted_out}",
        )
        code, _, recipient_search_body = manager.request(
            server.base
            + "mailer/api/?scope=recipient-search&query=recipient%40example.test&page=1"
        )
        recipient_search = json.loads(recipient_search_body)
        check(
            code == 200 and recipient_search["contacts"]["total"] == 0,
            f"opted-out contact remained selectable: {recipient_search}",
        )
        code, _, unsubscribed_body = manager.request(
            server.base
            + "mailer/api/?scope=contacts&contact_filter=unsubscribed"
            + "&query=recipient%40example.test&page=1"
        )
        unsubscribed_state = json.loads(unsubscribed_body)
        check(
            code == 200
            and unsubscribed_state["contacts"]["total"] == 1
            and unsubscribed_state["contacts"]["items"][0]["unsubscribed"] is True,
            f"unsubscribed contact filter failed: {unsubscribed_state}",
        )
        code, _, all_contacts_body = manager.request(
            server.base + "mailer/api/?scope=contacts&page=1"
        )
        all_contact_count = json.loads(all_contacts_body)["contacts"]["total"]
        code, _, invitation_state_body = manager.request(
            server.base + "mailer/api/?scope=invitations&page=1"
        )
        invitation_state = json.loads(invitation_state_body)
        check(
            code == 200
            and invitation_state["confirmation"]["total"] == all_contact_count - 1,
            f"invitation totals included an unsubscribed contact: {invitation_state}",
        )
        rejected_fields = {
            "csrf": mailer_csrf,
            "action": "create-job",
            "queue": "1",
            "subject": "Suppressed fixture",
            "template_id": "",
            "delivery_mode": "email",
            "require_contact_password": "0",
            "text_body": "This must not be sent",
            "html_body": "",
            "files": "[]",
            "contact_ids": json.dumps([primary["id"]]),
            "list_ids": "[]",
        }
        code, _, rejected_body = manager.form(
            server.base + "mailer/api/", rejected_fields, multipart=True
        )
        rejected = json.loads(rejected_body)
        check(
            code == 400
            and rejected["ok"] is False
            and "No contacts matched" in rejected["error"],
            f"opted-out contact was accepted for delivery: {rejected}",
        )
        status, suppressed_import_state = csv_post(
            "import",
            b"email,first_name\r\nrecipient@example.test,Operator\r\n",
            {"email": 1, "firstName": 2},
            csv_list["id"],
        )
        suppressed_import = suppressed_import_state["importResult"]
        check(
            status == 200
            and suppressed_import["membersAdded"] == 0
            and len(suppressed_import["suppressed"]) == 1,
            f"CSV import restored an opted-out contact: {suppressed_import}",
        )
        status, restored_import_state = csv_post(
            "import",
            b"email,first_name\r\nrecipient@example.test,Operator\r\n",
            {"email": 1, "firstName": 2},
            csv_list["id"],
            restore_unsubscribed=True,
        )
        restored_import = restored_import_state["importResult"]
        check(
            status == 200
            and restored_import["restored"] == 1
            and restored_import["membersAdded"] == 1
            and len(restored_import["suppressed"]) == 0,
            f"explicit CSV opt-in restoration failed: {restored_import}",
        )
        code, _, _ = opt_out_browser.request(opt_out_url)
        check(code == 404, "restoring email left an old opt-out link active")
        code, _, contact_body = manager.request(
            server.base
            + "mailer/api/?scope=contacts&query=recipient%40example.test&page=1"
        )
        restored = json.loads(contact_body)["contacts"]["items"][0]
        check(
            restored["unsubscribed"] is False
            and restored["listIds"] == [csv_list["id"]],
            f"CSV restoration did not assign the destination list: {restored}",
        )
        bulk_restore = mailer_post({
            "action": "resubscribe-contacts",
            "contact_ids": json.dumps([primary["id"]]),
        })
        check(
            bulk_restore["restore"]["restored"] == 0,
            f"bulk restoration changed an active contact: {bulk_restore}",
        )
        mailer_post(
            {
                "action": "save-contact",
                "id": str(primary["id"]),
                "email": primary["email"],
                "first_name": primary["firstName"],
                "last_name": primary["lastName"],
                "external_id": primary["externalId"],
                "list_ids": json.dumps([recipient_list["id"]]),
            }
        )

        eml_source = (
            "From: sender@example.test\r\n"
            "To: recipient@example.test\r\n"
            "Subject: Operator template\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n"
            "Content-Transfer-Encoding: 7bit\r\n"
            "\r\n"
            "Hello {{NAME}}\r\n" + ("Template payload.\r\n" * 10000)
        )
        state = mailer_post(
            {
                "action": "save-template",
                "id": "",
                "name": "Operator template",
                "source": eml_source,
            }
        )
        template = next(
            item for item in state["templates"] if item["name"] == "Operator template"
        )
        check(len(template["source"]) > 150000,
              "multipart EML template was truncated")
        parsed_template = mailer_post(
            {
                "action": "parse-eml",
                "template_id": str(template["id"]),
            }
        )["parsedMessage"]
        check(
            parsed_template["subject"] == "Operator template"
            and "Template payload." in parsed_template["textBody"]
            and parsed_template["htmlBody"] == "",
            f"EML template was not split into editable fields: {parsed_template}",
        )

        before_edited_template = len(smtp.messages)
        edited_template_job = mailer_post(
            {
                "action": "create-job",
                "queue": "1",
                "subject": "Edited template subject",
                "template_id": str(template["id"]),
                "delivery_mode": "email",
                "require_contact_password": "0",
                "text_body": "Edited template body for {{FIRST_NAME}}",
                "html_body": "<p>Edited HTML for {{FIRST_NAME}}</p>",
                "files": "[]",
                "contact_ids": json.dumps([primary["id"]]),
                "list_ids": "[]",
            }
        )["job"]
        deadline = time.time() + 8
        while time.time() < deadline:
            _, _, job_body = manager.request(
                server.base + f"mailer-probe/job/{edited_template_job['id']}"
            )
            edited_template_job = json.loads(job_body)["job"]
            if edited_template_job["status"] in ("completed", "failed"):
                break
            time.sleep(0.05)
        edited_message = quopri.decodestring(smtp.messages[-1])
        code, _, edited_detail_body = manager.request(
            server.base + f"mailer/api/?scope=job&id={edited_template_job['id']}"
        )
        edited_detail = json.loads(edited_detail_body)["job"]
        check(
            code == 200
            and edited_template_job["status"] == "completed"
            and len(smtp.messages) == before_edited_template + 1
            and b"subject: Edited template subject" in edited_message
            and b"Edited template body for Operator" in edited_message
            and b"Edited HTML for Operator" in edited_message
            and b"Template payload." not in edited_message
            and edited_detail["textBody"] ==
                "Edited template body for {{FIRST_NAME}}"
            and edited_detail["templateSnapshot"] == eml_source,
            "edited template fields or immutable EML snapshot were not used correctly: "
            f"job={edited_template_job}, detail="
            f"{{'textBody': {edited_detail.get('textBody')!r}, "
            f"'snapshotLength': {len(edited_detail.get('templateSnapshot') or '')}}}, "
            f"message={edited_message[:2000]!r}",
        )

        chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
        if chrome:
            with HeadlessPage(
                chrome,
                server.base + "mailer/jobs/",
                RUNTIME_ROOT / "mailer-operations-chrome-profile",
            ) as page:
                page.wait_for(
                    "document.readyState === 'complete' && "
                    "typeof SHA1 === 'object' && "
                    "document.getElementById('ba_loginbut') !== null"
                )
                page.evaluate(
                    """(function () {
   document.querySelector('[name=ba_username]').value = 'mail-manager';
   document.querySelector('[name=ba_password]').value = 'mail-manager-password';
   document.getElementById('ba_loginbut').click();
   return true;
}())"""
                )
                try:
                    page.wait_for(
                        """document.querySelector('#mailer-client h1') &&
document.querySelector('#mailer-client h1').textContent === 'Jobs'"""
                    )
                except TestFailure as exc:
                    browser_state = page.evaluate(
                        "({url: location.href, text: document.body.textContent.slice(0, 1000)})"
                    )
                    raise TestFailure(
                        f"mailer browser login/render failed: {browser_state}"
                    ) from exc
                rendered = page.evaluate(
                    """({
   text: document.getElementById('mailer-client').textContent,
   width: document.documentElement.scrollWidth,
   clientWidth: document.documentElement.clientWidth
})"""
                )
                check(
                    "Delivery History" in rendered["text"]
                    and rendered["width"] <= rendered["clientWidth"],
                    f"mailer Jobs view did not render cleanly: {rendered}",
                )
                page.evaluate(
                    "document.querySelector('.job-entry button').click(); true"
                )
                page.wait_for("document.querySelector('.job-detail') !== null")
                inspected = page.evaluate(
                    "document.querySelector('.job-detail').textContent"
                )
                check(
                    "Stored job content" in inspected
                    and "not the final personalized email" in inspected,
                    f"mailer job inspector did not render stored data: {inspected}",
                )
                expected_views = {
                    "contacts": ("All Contacts", "CSV recipients"),
                    "lists": ("Lists", "Primary recipients"),
                    "remove": ("Remove Contacts", "Preview matches"),
                    "invitations": ("Password Invitations", "Queue Invitations"),
                    "templates": ("Templates", "Operator template"),
                    "compose": ("Compose Delivery", "Queue Delivery"),
                }
                for route, (heading, expected_text) in expected_views.items():
                    page.evaluate(
                        f"location.href = '/mybase/mailer/{route}/'; true"
                    )
                    page.wait_for(
                        "document.querySelector('#mailer-client h1') && "
                        "document.querySelector('#mailer-client h1').textContent === "
                        + repr(heading)
                    )
                    view_state = page.evaluate(
                        """({
   text: document.getElementById('mailer-client').textContent,
   active: document.querySelector('.mailer-tabs a[aria-current=page]').textContent,
   width: document.documentElement.scrollWidth,
   clientWidth: document.documentElement.clientWidth
})"""
                    )
                    check(
                        expected_text in view_state["text"]
                        and view_state["active"].lower() == route
                        and view_state["width"] <= view_state["clientWidth"],
                        f"mailer {route} view failed: {view_state}",
                    )
                    if route == "compose":
                        page.evaluate(
                            """(function () {
   const select = document.querySelector('.compose-form select');
   const option = Array.from(select.options).find(function (item) {
      return item.textContent === 'Operator template';
   });
   select.value = option.value;
   select.dispatchEvent(new Event('change', { bubbles: true }));
   return true;
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('input[placeholder=Subject]').value === "
                            "'Operator template' && document.querySelector("
                            "'textarea[placeholder=\"Plain-text message\"]'"
                            ").value.indexOf('Template payload.') >= 0"
                        )
                        editable_template = page.evaluate(
                            """({
   subject: document.querySelector('input[placeholder=Subject]').value,
   text: document.querySelector('textarea[placeholder="Plain-text message"]').value,
   html: document.querySelector('textarea[placeholder^="Optional HTML message"]').value,
   notice: document.getElementById('client-message').textContent
})"""
                        )
                        check(
                            editable_template["subject"] == "Operator template"
                            and "Template payload." in editable_template["text"]
                            and editable_template["html"] == ""
                            and "editable fields" in editable_template["notice"],
                            f"template did not populate editable Compose fields: {editable_template}",
                        )
                        page.evaluate(
                            """(function () {
   const html = document.querySelector('textarea[placeholder^="Optional HTML message"]');
   html.value = [
      'Subject: Pasted EML',
      'MIME-Version: 1.0',
      'Content-Type: multipart/alternative; boundary="smart-paste"',
      '',
      '--smart-paste',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: 7bit',
      '',
      'Pasted plain body',
      '--smart-paste',
      'Content-Type: text/html; charset=utf-8',
      'Content-Transfer-Encoding: 7bit',
      '',
      '<p>Pasted HTML body</p>',
      '--smart-paste--',
      ''
   ].join('\\r\\n');
   html.dispatchEvent(new Event('input', { bubbles: true }));
   return true;
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('input[placeholder=Subject]').value === "
                            "'Pasted EML' && document.querySelector("
                            "'textarea[placeholder=\"Plain-text message\"]'"
                            ").value.indexOf('Pasted plain body') >= 0 && document.querySelector("
                            "'textarea[placeholder^=\"Optional HTML message\"]'"
                            ").value.indexOf('Pasted HTML body') >= 0"
                        )
                    if route == "contacts":
                        contacts_state = page.evaluate(
                            """({
   search: document.querySelector(
      'input[placeholder="Search by email, first name, or last name"]') !== null,
   destination: Array.from(document.querySelectorAll('select option')).some(function (option) {
      return option.textContent === 'CSV recipients';
   }),
   memberships: Array.from(document.querySelectorAll('.contact-table th')).some(function (node) {
      return node.textContent === 'Lists';
   }),
   bulkDelete: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Delete all contacts';
   })
})"""
                        )
                        check(
                            contacts_state == {
                                "search": True,
                                "destination": True,
                                "memberships": True,
                                "bulkDelete": True,
                            },
                            f"all-contacts controls were incomplete: {contacts_state}",
                        )
                        page.evaluate(
                            """(function () {
   var input = document.querySelector(
      'input[placeholder="Search by email, first name, or last name"]');
   input.value = 'bulk54';
   input.dispatchEvent(new Event('input', {bubbles: true}));
   return true;
}())"""
                        )
                        page.wait_for(
                            "document.querySelectorAll('.contact-table tbody tr').length === 1 && "
                            "document.querySelector('.contact-table tbody').textContent"
                            ".includes('bulk54@example.test')"
                        )
                    elif route == "lists":
                        list_ui = page.evaluate(
                            """({
    table: document.querySelector('.list-table') !== null,
    detailLinks: Array.from(document.querySelectorAll('.list-table a')).some(function (link) {
       return link.textContent === 'CSV recipients';
    }),
    linkedCount: Array.from(document.querySelectorAll('.list-table a')).some(function (link) {
       return link.closest('td') && link.closest('td').cellIndex === 1 &&
          link.href.includes('?id=');
    }),
    manageContacts: Array.from(document.querySelectorAll('.list-table a')).some(function (link) {
       return link.textContent === 'Manage contacts';
    }),
    bulkDelete: Array.from(document.querySelectorAll('button')).some(function (button) {
       return button.textContent === 'Delete all lists';
    })
 })"""
                        )
                        check(
                            list_ui == {
                                "table": True,
                                "detailLinks": True,
                                "linkedCount": True,
                                "manageContacts": True,
                                "bulkDelete": True,
                            },
                            f"list index UI was incomplete: {list_ui}",
                        )
                        page.evaluate(
                            """(function () {
   Array.from(document.querySelectorAll('.list-table a')).find(function (link) {
      return link.textContent === 'Manage contacts';
   }).click();
   return true;
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('#mailer-client h1') && "
                            "document.querySelector('#mailer-client h1').textContent === "
                            "'CSV recipients'"
                        )
                        detail_ui = page.evaluate(
                            """({
   liveSearch: document.querySelector(
      'input[placeholder="Search by email, first name, or last name"]') !== null,
   moveAll: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Move all contacts';
   }),
   merge: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Merge and delete this list';
   }),
   importer: document.body.textContent.includes('Import CSV into CSV recipients')
})"""
                        )
                        check(
                            detail_ui == {
                                "liveSearch": True,
                                "moveAll": True,
                                "merge": True,
                                "importer": True,
                            },
                            f"list detail UI was incomplete: {detail_ui}",
                        )
                        page.evaluate(
                            """(function () {
   var transfer = new DataTransfer();
   transfer.items.add(new File(
      ['email,first_name\\r\\nbrowser@example.test,Browser\\r\\n'],
      'browser.csv', {type: 'text/csv'}));
   var input = document.querySelector('input[type=file]');
   input.files = transfer.files;
   input.dispatchEvent(new Event('change', {bubbles: true}));
   Array.from(document.querySelectorAll('button')).find(function (button) {
      return button.textContent === 'Preview';
   }).click();
   return true;
}())"""
                        )
                        try:
                            page.wait_for(
                                "document.getElementById('client-message') && "
                                "document.getElementById('client-message').textContent"
                                ".includes('Review the detected columns') && "
                                "document.querySelector('.preview-table') !== null"
                            )
                        except TestFailure as exc:
                            csv_state = page.evaluate(
                                "({url: location.href, text: document.body.textContent, "
                                "html: document.body.innerHTML.slice(0, 2000)})"
                            )
                            raise TestFailure(
                                f"browser CSV preview failed: {csv_state}"
                            ) from exc
                        page.evaluate(
                            "location.href = '/mybase/mailer/lists/?id="
                            + str(transfer_list["id"])
                            + "'; true"
                        )
                        page.wait_for(
                            "document.querySelector('.empty-state') && "
                            "document.querySelector('.empty-state').textContent"
                            ".includes('This list is empty')"
                        )
                        empty_list_ui = page.evaluate(
                            """({
   hasMoveSelected: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Move selected';
   }),
   hasMoveAll: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Move all contacts';
   }),
   hasSearch: document.querySelector(
      'input[placeholder="Search by email, first name, or last name"]') !== null,
   hasContactsLink: Array.from(document.querySelectorAll('a')).some(function (link) {
      return link.textContent === 'Open All Contacts';
   }),
   hasImporter: document.body.textContent.includes('Import CSV into Transfer destination')
})"""
                        )
                        check(
                            empty_list_ui == {
                                "hasMoveSelected": False,
                                "hasMoveAll": False,
                                "hasSearch": False,
                                "hasContactsLink": True,
                                "hasImporter": True,
                            },
                            f"empty list presented nonfunctional controls: {empty_list_ui}",
                        )
                    elif route == "remove":
                        removal_ui = page.evaluate(
                            """({
   textarea: document.querySelector('.bulk-email-input') !== null,
   button: Array.from(document.querySelectorAll('button')).some(function (button) {
      return button.textContent === 'Preview matches';
   })
})"""
                        )
                        check(
                            removal_ui == {"textarea": True, "button": True},
                            f"bulk removal UI is incomplete: {removal_ui}",
                        )
                        page.evaluate(
                            """(function () {
   var input = document.querySelector('.bulk-email-input');
   input.value = 'bulk54@example.test and absent@example.test';
   input.dispatchEvent(new Event('input', {bubbles: true}));
   Array.from(document.querySelectorAll('button')).find(function (button) {
      return button.textContent === 'Preview matches';
   }).click();
   return true;
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('.removal-preview') && "
                            "document.querySelector('.removal-preview').textContent"
                            ".includes('1 contacts match')"
                        )
                    elif route == "invitations":
                        invitation_state = page.evaluate(
                            """(function () {
   const recipients = document.querySelector('.recipient-grid');
   const button = Array.from(document.querySelectorAll('button')).find(function (node) {
      return node.textContent === 'Queue Invitations';
   });
   button.click();
   return {
       recipientsHidden: recipients.hidden,
       hasGlobalInvitation: document.body.textContent.includes(
          'Send to every unconfirmed contact'),
       settingsUrl: document.querySelector('.mailer-app').dataset.settingsUrl,
       buttonDisabled: button.disabled,
       placementHelp: document.querySelector('.link-placement-help').textContent
   };
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('.invitation-message.error') && "
                            "document.querySelector('.invitation-message.error').textContent"
                            ".includes('Select contacts')"
                        )
                        invitation_feedback = page.evaluate(
                            """(function () {
   const message = document.querySelector('.invitation-message');
   const button = Array.from(document.querySelectorAll('button')).find(function (node) {
      return node.textContent === 'Queue Invitations';
   });
   return {
       distance: Math.abs(message.getBoundingClientRect().top -
          button.getBoundingClientRect().bottom)
   };
}())"""
                        )
                        check(
                            invitation_state == {
                                "recipientsHidden": False,
                                "hasGlobalInvitation": False,
                                "settingsUrl": "",
                                "buttonDisabled": False,
                                "placementHelp": (
                                    "The password setup link is appended automatically. "
                                    "Use {{INVITATION_LINK}} only when you want to control "
                                    "its position."
                                ),
                            }
                            and invitation_feedback["distance"] <= 40,
                            f"invitation safeguards or local feedback failed: "
                            f"{invitation_state}, {invitation_feedback}",
                        )
                    elif route == "compose":
                        compose_state = page.evaluate(
                            """(function () {
   const mode = document.querySelector('.delivery-mode');
   const files = document.querySelector('.delivery-files');
   document.querySelector('input[placeholder="Subject"]').value =
      'Feedback placement test';
   Array.from(document.querySelectorAll('button')).find(function (button) {
      return button.textContent === 'Queue Delivery';
   }).click();
   return {
      mode: mode.value,
      filesHidden: files.closest('.field').hidden,
      filesDisplay: getComputedStyle(files.closest('.field')).display,
      filesRequired: files.required,
      pathHelp: files.closest('.field').textContent,
      browseUrl: files.closest('.field').querySelector('a').getAttribute('href'),
      listText: Array.from(document.querySelectorAll('.detailed-choice')).find(
         function (label) {
            return label.querySelector('strong').textContent === 'Primary recipients';
         }).textContent
   };
}())"""
                        )
                        page.wait_for(
                            "document.querySelector('.compose-message.error') && "
                            "document.querySelector('.compose-message.error').textContent"
                            ".includes('recipient')"
                        )
                        feedback = page.evaluate(
                            """(function () {
   const message = document.querySelector('.compose-message');
   const button = Array.from(document.querySelectorAll('button')).find(function (node) {
      return node.textContent === 'Queue Delivery';
   });
   const mode = document.querySelector('.delivery-mode');
   mode.value = 'link';
   mode.dispatchEvent(new Event('change', {bubbles: true}));
   const linkHelp = document.querySelector('.link-placement-help');
   return {
      text: message.textContent,
      distance: Math.abs(message.getBoundingClientRect().top -
         button.getBoundingClientRect().bottom),
      linkHelp: linkHelp.textContent,
      linkHelpDisplay: getComputedStyle(linkHelp).display,
      filesDisplay: getComputedStyle(document.querySelector('.delivery-files')
         .closest('.field')).display
   };
}())"""
                        )
                        check(
                            compose_state["mode"] == "email"
                            and compose_state["filesHidden"] is True
                            and compose_state["filesDisplay"] == "none"
                            and compose_state["filesRequired"] is False
                            and "Mako home IO at /" in compose_state["pathHelp"]
                            and compose_state["browseUrl"] == "/mybase/fs/"
                            and "1 recipient" in compose_state["listText"]
                            and "Operator test list" in compose_state["listText"]
                            and feedback["distance"] <= 40
                            and "appended automatically" in feedback["linkHelp"]
                            and feedback["linkHelpDisplay"] != "none"
                            and feedback["filesDisplay"] != "none",
                            f"email-only Compose or local feedback failed: "
                            f"{compose_state}, {feedback}",
                        )

            with HeadlessPage(
                chrome,
                server.base + "mailer/compose/",
                RUNTIME_ROOT / "mailer-wfm-chrome-profile",
            ) as page:
                page.wait_for(
                    "document.readyState === 'complete' && "
                    "typeof SHA1 === 'object' && "
                    "document.getElementById('ba_loginbut') !== null"
                )
                page.evaluate(
                    """(function () {
   document.querySelector('[name=ba_username]').value = 'mail-user';
   document.querySelector('[name=ba_password]').value = 'mail-user-password';
   document.getElementById('ba_loginbut').click();
   return true;
}())"""
                )
                page.wait_for(
                    "document.querySelector('#mailer-client h1') && "
                    "document.querySelector('#mailer-client h1').textContent === "
                    "'Compose Delivery'"
                )
                command = page.evaluate(
                    """(async function () {
   const module = await import('/mybase/mailer/wfm.js');
   let command;
   const api = {
      add: function (type, spec) { command = spec; return function () {}; },
      ui: {open: function () {}}
   };
   module.default(api);
   const result = {
      id: command.id,
      toolbar: command.toolbar,
      menu: command.menu,
      files: command.when({selection: [
         {n: 'one.txt', s: 3, path: '/one.txt'},
         {n: 'two.txt', s: 4, path: '/folder/two.txt'}
      ]}),
      directory: command.when({selection: [
         {n: 'folder', s: -1, path: '/folder/'}
      ]}),
      empty: command.when({selection: []})
   };
   setTimeout(function () {
      command.run({selection: [
         {n: 'one.txt', s: 3, path: '/one.txt'},
         {n: 'two.txt', s: 4, path: '/folder/two.txt'}
      ]}, api);
   }, 0);
   return result;
}())"""
                )
                check(
                    command == {
                        "id": "email-selected-files",
                        "toolbar": True,
                        "menu": True,
                        "files": True,
                        "directory": False,
                        "empty": False,
                    },
                    f"WFM mail command contract failed: {command}",
                )
                page.wait_for(
                    "document.querySelector('textarea[placeholder*=\"/reports/report.pdf\"]') && "
                    "document.querySelector('textarea[placeholder*=\"/reports/report.pdf\"]').value === "
                    "'/one.txt\\n/folder/two.txt'"
                )
                compose_fields = page.evaluate(
                    """({
   subject: document.querySelector('.compose-form input[required]').value,
   protected: document.querySelector('.compose-form .check-field input').checked,
   passwordField: document.querySelector('.compose-form input[type=password]') !== null,
   autocomplete: document.querySelector('.compose-form').autocomplete
})"""
                )
                check(
                    compose_fields == {
                        "subject": "",
                        "protected": False,
                        "passwordField": False,
                        "autocomplete": "off",
                    },
                    f"compose credential autofill protection failed: {compose_fields}",
                )
                picker_initial = page.evaluate(
                    """({
   search: document.querySelector('[aria-label="Search contacts"]') !== null,
   options: document.querySelectorAll('.recipient-option').length,
   selected: document.querySelector('.selected-recipients').textContent
})"""
                )
                check(
                    picker_initial["search"] is True
                    and picker_initial["options"] == 0
                    and "Selected contacts (0)" in picker_initial["selected"],
                    f"compose contact picker loaded an unbounded list: {picker_initial}",
                )
                page.evaluate(
                    """(function () {
   var input = document.querySelector('[aria-label="Search contacts"]');
   input.value = 'recipient@example.test';
   input.dispatchEvent(new Event('input', {bubbles: true}));
   return true;
}())"""
                )
                page.wait_for(
                    "document.querySelector('.recipient-option') && "
                    "document.querySelector('.recipient-option').textContent"
                    ".includes('recipient@example.test')"
                )
                page.evaluate(
                    """(function () {
   document.querySelector('.recipient-option input[type=checkbox]').click();
   var input = document.querySelector('[aria-label="Search contacts"]');
   input.value = '';
   input.dispatchEvent(new Event('input', {bubbles: true}));
   return true;
}())"""
                )
                page.wait_for(
                    "document.querySelectorAll('.recipient-option').length === 0 && "
                    "document.querySelector('.selected-recipients').textContent"
                    ".includes('recipient@example.test')"
                )
                picker_selected = page.evaluate(
                    """({
   selected: document.querySelector('.selected-recipients').textContent,
   files: document.querySelector('.delivery-files').value,
   mode: document.querySelector('.delivery-mode').value,
   width: document.documentElement.scrollWidth,
   clientWidth: document.documentElement.clientWidth
})"""
                )
                check(
                    "Selected contacts (1)" in picker_selected["selected"]
                    and picker_selected["files"] == "/one.txt\n/folder/two.txt"
                    and picker_selected["mode"] == "attachment"
                    and picker_selected["width"] <= picker_selected["clientWidth"],
                    f"live recipient selection was not preserved: {picker_selected}",
                )

        invalid_fields = {
            "csrf": mailer_csrf,
            "action": "create-job",
            "queue": "0",
            "subject": "Invalid path fixture",
            "template_id": "",
            "delivery_mode": "attachment",
            "require_contact_password": "0",
            "text_body": "Path validation",
            "html_body": "",
            "files": json.dumps([r"C:\\reports\\report.pdf"]),
            "contact_ids": json.dumps([primary["id"]]),
            "list_ids": "[]",
        }
        status, _, invalid_body = manager.form(
            server.base + "mailer/api/", invalid_fields, multipart=True
        )
        invalid_result = json.loads(invalid_body)
        check(
            status == 400
            and "must start with /" in invalid_result["error"]
            and "Mako home IO at /" in invalid_result["error"],
            f"invalid file path error lacked root context: {invalid_result}",
        )

        before_operator_delivery = len(smtp.messages)
        queued = mailer_post(
            {
                "action": "create-job",
                "queue": "1",
                "subject": "Operator delivery",
                "template_id": "",
                "delivery_mode": "email",
                "link_password": "",
                "text_body": "Hello {{NAME}}",
                "html_body": "<p>Hello {{NAME}}</p>",
                "files": "[]",
                "contact_ids": "[]",
                "list_ids": json.dumps([recipient_list["id"]]),
            }
        )["job"]
        deadline = time.time() + 8
        history_state: dict | None = None
        while time.time() < deadline:
            code, _, history_body = manager.request(server.base + "mailer/api/")
            history_state = json.loads(history_body)
            current = next(
                item for item in history_state["history"]["items"]
                if item["id"] == queued["id"]
            )
            if current["status"] in ("completed", "failed"):
                break
            time.sleep(0.05)
        check(
            history_state is not None
            and current["status"] == "completed"
            and len(smtp.messages) == before_operator_delivery + 1
            and b"to: Operator Recipient <recipient@example.test>" in smtp.messages[-1]
            and b"Hello Operator" in smtp.messages[-1],
            f"operator delivery did not complete: {history_state}",
        )
        code, _, detail_body = manager.request(
            server.base + f"mailer/api/?scope=job&id={queued['id']}"
        )
        detail_state = json.loads(detail_body)
        detail = detail_state.get("job", {})
        check(
            code == 200
            and detail_state["ok"] is True
            and detail["subject"] == "Operator delivery"
            and detail["textBody"] == "Hello {{NAME}}"
            and detail["htmlBody"] == "<p>Hello {{NAME}}</p>"
            and detail["recipientCount"] == 1
            and len(detail["recipients"]) == 1
            and detail["recipientsTruncated"] is False
            and detail["recipients"][0]["firstName"] == "Operator"
            and "password_hash" not in json.dumps(detail),
            f"stored mailer job details were incorrect: {detail_state}",
        )
        code, _, denied_body = sender.request(
            server.base + f"mailer/api/?scope=job&id={queued['id']}"
        )
        denied = json.loads(denied_body)
        check(
            code == 403 and denied["ok"] is False,
            f"mailer-user accessed manager job details: {code}, {denied}",
        )
        code, _, invalid_detail_body = manager.request(
            server.base + "mailer/api/?scope=job&id=0"
        )
        invalid_detail = json.loads(invalid_detail_body)
        check(
            code == 400 and invalid_detail["ok"] is False,
            f"invalid job detail ID did not return JSON error: {invalid_detail}",
        )

        mass_state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "Mass recipient fixture",
                "description": "Database-backed recipient selection test",
            }
        )
        mass_list = next(
            item for item in mass_state["lists"]
            if item["name"] == "Mass recipient fixture"
        )
        mass_csv = ["email,first_name,last_name"]
        for index in range(1005):
            mass_csv.append(f"mass{index}@example.test,Mass,{index}")
        status, mass_import = csv_post(
            "import",
            ("\r\n".join(mass_csv) + "\r\n").encode("ascii"),
            mapping={"email": 1, "firstName": 2, "lastName": 3},
            list_id=mass_list["id"],
        )
        check(
            status == 200
            and mass_import["importResult"]["membersAdded"] == 1005,
            f"mass recipient fixture import failed: {mass_import}",
        )
        mass_job = mailer_post(
            {
                "action": "create-job",
                "queue": "0",
                "subject": "Mass recipient selection",
                "template_id": "",
                "delivery_mode": "email",
                "require_contact_password": "0",
                "text_body": "Hello {{FIRST_NAME}}",
                "html_body": "",
                "files": "[]",
                "contact_ids": "[]",
                "list_ids": json.dumps([mass_list["id"]]),
            }
        )["job"]
        check(
            mass_job["status"] == "draft"
            and mass_job["recipientCount"] == 1005
            and mass_job["active"] == 1005
            and "recipients" not in mass_job,
            "a list larger than 1000 contacts was not materialized with a "
            f"bounded response: {mass_job}",
        )
        code, _, mass_detail_body = manager.request(
            server.base + f"mailer/api/?scope=job&id={mass_job['id']}"
        )
        mass_detail = json.loads(mass_detail_body)["job"]
        check(
            code == 200
            and mass_detail["recipientCount"] == 1005
            and len(mass_detail["recipients"]) == 100
            and mass_detail["recipientsTruncated"] is True,
            f"large job inspection was not bounded: {mass_detail}",
        )
        mailer_post({"action": "cancel-job", "id": str(mass_job["id"])})

        purged = mailer_post(
            {
                "action": "purge-history",
                "older_than": str(int(time.time()) + 1),
            }
        )
        check(purged["history"]["total"] == 0,
              f"completed history was not purged: {purged['history']}")
        state = mailer_post({"action": "delete-template", "id": str(template["id"])})
        state = mailer_post({"action": "delete-list", "id": str(recipient_list["id"])})
        state = mailer_post({"action": "delete-contact", "id": str(primary["id"])})
        check(
            all(item["id"] != template["id"] for item in state["templates"])
            and all(item["id"] != recipient_list["id"] for item in state["lists"])
            and all(item["id"] != primary["id"] for item in state["contacts"]["items"]),
            "mailer CRUD deletion did not update operator state",
        )
        state = mailer_post({"action": "delete-all-contacts"})
        check(
            state["contacts"]["total"] == 0
            and all(item["members"] == 0 for item in state["lists"]),
            f"bulk contact deletion left contacts or memberships: {state}",
        )
        state = mailer_post({"action": "delete-all-lists"})
        check(not state["lists"],
              f"bulk list deletion left recipient lists: {state['lists']}")

        state = mailer_post(
            {
                "action": "save-list",
                "id": "",
                "name": "Orphan membership regression",
                "description": "Must count only live contacts",
            }
        )
        orphan_list = next(
            item for item in state["lists"]
            if item["name"] == "Orphan membership regression"
        )

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        conn.execute("PRAGMA foreign_keys=OFF")
        conn.execute(
            "INSERT INTO mailer_list_members(list_id,contact_id) VALUES(?,?)",
            (orphan_list["id"], 999999999),
        )
        conn.commit()
    with MakoProcess(runtime, mount="mybase") as cleanup_server:
        cleanup_manager = Browser(cleanup_server.origin)
        code, _, _ = form_login(
            cleanup_manager,
            cleanup_server.base + "mailer/lists/",
            "mail-manager",
            "mail-manager-password",
        )
        check(code == 200, "mailer manager could not verify orphan cleanup")
        code, _, orphan_body = cleanup_manager.request(
            cleanup_server.base
            + f"mailer/api/?scope=lists&list_id={orphan_list['id']}"
        )
        orphan_state = json.loads(orphan_body)
        current_orphan_list = next(
            item for item in orphan_state["lists"]
            if item["id"] == orphan_list["id"]
        )
        check(
            code == 200
            and current_orphan_list["members"] == 0
            and orphan_state["list"]["members"] == 0
            and orphan_state["contacts"]["total"] == 0,
            f"orphan list membership appeared as a live contact: {orphan_state}",
        )
    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        orphan_count = conn.execute(
            "SELECT COUNT(*) FROM mailer_list_members m "
            "LEFT JOIN mailer_contacts c ON c.id=m.contact_id "
            "LEFT JOIN mailer_lists l ON l.id=m.list_id "
            "WHERE c.id IS NULL OR l.id IS NULL"
        ).fetchone()[0]
    check(orphan_count == 0,
          "mailer schema reconciliation did not remove orphan memberships")


def verify_file_services(
    server: MakoProcess,
    runtime: Path,
    *,
    base_url: str = "/fs/",
    storage_root: Path | None = None,
    lock_dir: str = ".locks",
) -> None:
    browser = Browser(server.origin)
    identity_url = server.base + "admin/plugins/identity-access/"
    code, _, identity_shell = browser.request(identity_url)
    check(code == 200, "identity shell was unavailable to File Services")
    identity_token = csrf_from(identity_shell)
    code, identity_result = identity_api_post(
        browser,
        server,
        identity_token,
        {
            "action": "save-user",
            "username": "filetest",
            "display_name": "File Test",
            "email": "",
            "password": "file-password",
            "max_users": "3",
            "inactive": "1200",
            "role_file-admin": "1",
        },
    )
    check(code == 200 and identity_result["ok"] is True,
          f"file-service identity setup failed: {identity_result}")
    code, identity_result = identity_api_post(
        browser,
        server,
        identity_token,
        {
            "action": "save-user",
            "username": "cmsfileadmin",
            "display_name": "CMS File Administrator",
            "email": "",
            "password": "admin-password",
            "max_users": "3",
            "inactive": "1200",
            "role_cms-admin": "1",
        },
    )
    check(code == 200 and identity_result["ok"] is True,
          f"file-service CMS administrator setup failed: {identity_result}")

    browser = Browser(server.origin)
    code, _, dashboard = form_login(
        browser, server.base + "admin/", "cmsfileadmin", "admin-password"
    )
    check(code == 200 and b"Dashboard" in dashboard,
          "file-service CMS administrator could not log in")
    code, _, identity_shell = browser.request(identity_url)
    check(code == 200, "authenticated identity shell was unavailable")
    identity_token = csrf_from(identity_shell)

    admin_url = server.base + "admin/plugins/file-services/"
    code, headers, body = browser.request(admin_url)
    rendered = text(body, headers)
    check(
        code == 200
        and "File Services" in rendered
        and "Loading file-service data" in rendered,
        f"file-service admin shell failed ({code}): {rendered[:1000]}",
    )
    token = csrf_from(body)
    code, headers, script = browser.request(admin_url + "admin.js")
    check(code == 200 and b'fetch("api/"' in script
          and b'name: "selected_role"' in script
          and b'Add file access' in script
          and b'Access paths' in script
          and b'ACL name' not in script
          and b"FuguHubAdmin.readJson" in script,
          f"file-service JavaScript failed ({code}): {script[:500]!r}")
    code, headers, stylesheet = browser.request(admin_url + "admin.css")
    check(code == 200 and b".file-service-columns" in stylesheet
          and b".file-service-role-toolbar" in stylesheet
          and b"container-type: inline-size" in stylesheet
          and b"@container (max-width: 960px)" in stylesheet,
          f"file-service CSS failed ({code}): {stylesheet[:500]!r}")

    code, _, body = browser.request(admin_url + "api/")
    initial = json.loads(body)
    acls = initial.get("acls", [])
    role_names = {role["name"] for role in initial.get("roles", [])}
    file_admin_role = next(
        (role for role in initial.get("roles", []) if role["name"] == "file-admin"),
        None,
    )
    check(
        code == 200
        and initial["ok"] is True
        and initial["settings"]["enabled"] is False
        and initial["settings"]["lockDir"] == lock_dir
        and initial["active"] is False
        and len(acls) == 1
        and acls[0]["name"] == "File administrators"
        and acls[0]["role"] == "file-admin"
        and acls[0]["path"] == "/*"
        and acls[0]["permission"] == "write"
        and role_names == {"file-admin"}
        and file_admin_role is not None
        and file_admin_role["assignedUsers"] == 1,
        f"file-service initial state failed ({code}): {initial}",
    )
    acl_id = str(acls[0]["id"])
    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "save-acl",
            "id": acl_id,
            "role": "file-admin",
            "path": "/",
            "permission": "write",
            "enabled": "1",
        },
    )
    check(code == 200 and result["ok"] is True,
          f"file-service ACL update failed ({code}): {result}")
    code, _, dashboard = browser.request(server.base + "admin/")
    check(
        code == 200 and b"Dashboard" in dashboard and b"ba_seed" not in dashboard,
        "File Services ACL update terminated the CMS administrator session",
    )
    code, duplicate = file_api_post(
        browser,
        server,
        token,
        {
            "action": "save-acl",
            "id": "",
            "role": "file-admin",
            "path": "/",
            "permission": "read",
            "enabled": "1",
        },
    )
    check(code == 400 and "already has an access rule" in duplicate["error"],
          f"duplicate role/path ACL was accepted ({code}): {duplicate}")

    code, identity_result = identity_api_post(
        browser,
        server,
        identity_token,
        {
            "action": "save-role",
            "name": "limited-files",
            "description": "Access to selected file locations",
        },
    )
    check(code == 200 and identity_result["ok"] is True,
          f"limited file role creation failed ({code}): {identity_result}")
    code, identity_result = identity_api_post(
        browser,
        server,
        identity_token,
        {
            "action": "save-user",
            "username": "limitedfile",
            "display_name": "Limited File User",
            "email": "",
            "password": "limited-password",
            "max_users": "3",
            "inactive": "1200",
            "role_limited-files": "1",
        },
    )
    check(code == 200 and identity_result["ok"] is True,
          f"limited file user creation failed ({code}): {identity_result}")
    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "save-acl",
            "id": "",
            "role": "limited-files",
            "path": "/a/",
            "permission": "read",
            "enabled": "1",
        },
    )
    limited_acl = next(
        (acl for acl in result.get("acls", []) if acl["role"] == "limited-files"),
        None,
    )
    visible_roles = {role["name"] for role in result.get("roles", [])}
    check(code == 200 and result["ok"] is True and limited_acl is not None
          and visible_roles == {"file-admin", "limited-files"},
          f"limited file ACL creation failed ({code}): {result}")
    limited_acl_id = str(limited_acl["id"])
    limited_root = (storage_root or runtime) / "a"
    limited_root.mkdir(exist_ok=True)
    (limited_root / "readme.txt").write_text("LIMITED FILE OK", encoding="utf-8")

    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "save-settings",
            "enabled": "1",
            "max_uploads": "20",
            "max_locks": "100",
            "session_timeout": "900",
            "case_sensitive": "1",
        },
    )
    check(
        code == 200
        and result["active"] is True
        and result["mountUrl"]
        == ((f"/{server.mount}" if server.mount else "") + base_url),
        f"File Services did not activate ({code}): {result}",
    )

    root_url = server.base + base_url.strip("/") + "/"
    code, headers, denied_page = digest_request(
        root_url,
        "cmsfileadmin",
        "admin-password",
        method="GET",
        headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
    )
    expected_admin_path = (
        urllib.parse.urlsplit(server.base).path + "admin/plugins/file-services/"
    )
    check(
        code == 403
        and "text/html" in headers.get("Content-Type", "").lower()
        and b"File access unavailable" in denied_page
        and b"Configure file access" in denied_page
        and f'href="{expected_admin_path}"'.encode() in denied_page
        and b"PROPFIND" not in denied_page,
        f"browser file-access denial was not user-friendly ({code}): {denied_page[:1000]!r}",
    )

    code, headers, limited_denied = digest_request(
        root_url,
        "limitedfile",
        "limited-password",
        method="GET",
        headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
    )
    expected_limited_path = (
        urllib.parse.urlsplit(server.base).path + base_url.strip("/") + "/a/"
    )
    check(
        code == 403
        and b"Available locations" in limited_denied
        and b"/a/" in limited_denied
        and b"Read only" in limited_denied
        and f'href="{expected_limited_path}"'.encode() in limited_denied,
        f"limited access roots were not rendered ({code}): {limited_denied[:1500]!r}",
    )
    limited_url = server.base + base_url.strip("/") + "/a/"
    code, headers, limited_page = digest_request(
        limited_url,
        "limitedfile",
        "limited-password",
        method="GET",
        headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
    )
    check(code == 200 and b"/rtl/wfm/wfm.js" in limited_page,
          f"limited access link was not usable ({code}): {limited_page[:1000]!r}")
    code, _, limited_body = digest_request(
        limited_url + "readme.txt",
        "limitedfile",
        "limited-password",
        method="GET",
    )
    check(code == 200 and limited_body == b"LIMITED FILE OK",
          f"limited file read failed ({code}): {limited_body[:500]!r}")
    code, _, _ = digest_request(
        limited_url + "blocked.txt",
        "limitedfile",
        "limited-password",
        method="PUT",
        data=b"BLOCKED",
        headers={"Content-Type": "text/plain"},
    )
    check(code == 403, f"read-only limited user wrote a file: HTTP {code}")

    code, headers, denied_json = digest_request(
        root_url + "?cmd=lj",
        "cmsfileadmin",
        "admin-password",
        method="GET",
        headers={
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0",
            "X-Requested-With": "XMLHttpRequest",
        },
    )
    check(
        code == 403
        and "application/json" in headers.get("Content-Type", "").lower()
        and json.loads(denied_json)["err"] == "noaccess"
        and b"File access unavailable" not in denied_json,
        f"WFS JSON denial contract changed ({code}): {denied_json[:1000]!r}",
    )

    code, _, denied_dav = digest_request(
        root_url,
        "cmsfileadmin",
        "admin-password",
        method="PROPFIND",
        headers={"Depth": "0"},
    )
    check(
        code == 403 and b"File access unavailable" not in denied_dav,
        f"WebDAV denial was replaced by the browser page ({code}): {denied_dav[:1000]!r}",
    )

    code, headers, allowed_page = digest_request(
        root_url,
        "filetest",
        "file-password",
        method="GET",
        headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0"},
    )
    check(
        code == 200
        and "text/html" in headers.get("Content-Type", "").lower()
        and b"/rtl/wfm/wfm.js" in allowed_page,
        f"authorized WFM page failed ({code}): {allowed_page[:1000]!r}",
    )

    file_url = server.base + base_url.strip("/") + "/integration.txt"
    code, _, _ = digest_request(
        file_url,
        "filetest",
        "file-password",
        method="PUT",
        data=b"FILE SERVICE OK",
        headers={"Content-Type": "text/plain"},
    )
    check(code in (200, 201, 204),
          f"authenticated WebDAV PUT failed: HTTP {code}")
    code, _, file_body = digest_request(
        file_url,
        "filetest",
        "file-password",
        method="GET",
    )
    check(code == 200 and file_body == b"FILE SERVICE OK",
          f"authenticated WebDAV GET failed ({code}): {file_body[:500]!r}")
    code, _, _ = digest_request(
        server.base + base_url.strip("/") + "/",
        "filetest",
        "wrong-password",
        method="PROPFIND",
        headers={"Depth": "0"},
    )
    check(code in (401, 403), f"WebDAV accepted a bad password: {code}")

    code, identity_result = identity_api_post(
        browser,
        server,
        identity_token,
        {
            "action": "save-user",
            "username": "filetest",
            "display_name": "File Test",
            "email": "",
            "password": "",
            "disabled": "1",
            "max_users": "3",
            "inactive": "1200",
            "role_file-admin": "1",
        },
    )
    disabled_file_user = next(
        (user for user in identity_result["users"] if user["username"] == "filetest"),
        None,
    )
    check(code == 200 and disabled_file_user is not None
          and disabled_file_user["disabled"] is True,
          f"file user disable failed: {identity_result}")
    code, _, _ = digest_request(
        file_url,
        "filetest",
        "file-password",
        method="GET",
    )
    check(code in (401, 403), f"disabled file user retained access: {code}")

    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "delete-acl",
            "id": limited_acl_id,
        },
    )
    check(code == 200 and len(result.get("acls", [])) == 1,
          f"limited file ACL deletion failed ({code}): {result}")
    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "save-settings",
            "max_uploads": "20",
            "max_locks": "100",
            "session_timeout": "900",
            "case_sensitive": "1",
        },
    )
    check(code == 200 and result["active"] is False,
          f"File Services did not disable ({code}): {result}")
    code, _, _ = browser.request(
        server.base + base_url.strip("/") + "/integration.txt"
    )
    check(code == 404, "disabled File Services retained its VFS mount")

    code, result = file_api_post(
        browser,
        server,
        token,
        {
            "action": "delete-acl",
            "id": acl_id,
        },
    )
    check(code == 200 and result.get("acls") in ([], {}),
          f"file-service ACL deletion failed ({code}): {result}")

    storage_file = (storage_root or runtime) / "integration.txt"
    check(storage_file.read_bytes() == b"FILE SERVICE OK",
          "file-service storage did not retain the WebDAV test file")
    check(((storage_root or runtime) / lock_dir).is_dir(),
          "configured WebDAV lock directory was not created")


def test_file_services_plugin() -> None:
    runtime = fresh_runtime("file-services-root")
    install_file_services_plugin(runtime)
    with MakoProcess(runtime) as server:
        verify_file_services(server, runtime)

    named_runtime = fresh_runtime("file-services-named")
    install_file_services_plugin(named_runtime)
    with MakoProcess(named_runtime, mount="mybase") as server:
        verify_file_services(server, named_runtime)
        code, _, _ = Browser(server.origin).request("/fs/")
        check(code == 404, "named File Services mount leaked into the server root")

    configured_runtime = fresh_runtime("file-services-configured")
    install_file_services_plugin(configured_runtime)
    storage_root = configured_runtime / "shared-files"
    storage_root.mkdir()
    (configured_runtime / "mako.conf").write_text(
        'wfs = { io = "home", path = "/shared-files/", '
        'baseurl = "/storage/", lockdir = ".webdav-locks" }\n',
        encoding="ascii",
    )
    with MakoProcess(configured_runtime) as server:
        verify_file_services(
            server,
            configured_runtime,
            base_url="/storage/",
            storage_root=storage_root,
            lock_dir=".webdav-locks",
        )
        code, _, _ = Browser(server.origin).request("/fs/")
        check(code == 404, "configured File Services retained the default mount")

    disk_runtime = fresh_runtime("file-services-disk-configured")
    install_file_services_plugin(disk_runtime)
    disk_storage = (disk_runtime / "disk-storage").resolve()
    disk_storage.mkdir()
    disk_posix = disk_storage.as_posix()
    disk_path = "/" + disk_posix[0] + disk_posix[2:] + "/"
    (disk_runtime / "mako.conf").write_text(
        'wfs = { io = "disk", path = "' + disk_path + '", '
        'baseurl = "/disk-files/", lockdir = ".dav-locks" }\n',
        encoding="ascii",
    )
    with MakoProcess(disk_runtime) as server:
        verify_file_services(
            server,
            disk_runtime,
            base_url="/disk-files/",
            storage_root=disk_storage,
            lock_dir=".dav-locks",
        )


def test_multidomain_shared_identity() -> None:
    runtime = fresh_runtime("multidomain-shared-identity")
    shutil.copytree(ROOT / "CmsDomains", runtime / "CmsDomains")
    plugins = runtime / "plugins"
    plugins.mkdir()
    for name in ("identity-access", "file-services", "large-file-mailer"):
        shutil.copytree(plugin_source(name), plugins / name)

    for host in ("a.local", "b.local"):
        assets = runtime / f"assets-{host}"
        assets.mkdir()
        marker = f"unloaded-{host}.txt"
        (assets / ".preload").write_text(
            "function onunload()\n"
            f"   local file=assert(homeIo:open('{marker}','w'))\n"
            "   assert(file:write('unloaded'))\n"
            "   file:close()\n"
            "end\n",
            encoding="ascii",
        )

    (runtime / "mako.conf").write_text(
        """cmsdomains = {
   {
      host = "a.local",
      control = true
   },
   { host = "b.local" }
}
wfs = { io = "home", path = "/", baseurl = "/fs/" }
""",
        encoding="ascii",
    )
    install_reload_controller(runtime, "CmsDomains")

    with MakoProcess(
        runtime,
        application="CmsDomains",
        extra_loads=("-lreload-control::reload-controller",),
    ) as server:
        control = Browser(f"http://a.local:{server.port}")
        consumer = Browser(f"http://b.local:{server.port}")

        code, _, control_page = control.request(
            "/admin/plugins/identity-access/"
        )
        check(code == 200 and b"Identity and Access" in control_page,
              f"control Identity Access page failed: HTTP {code}")
        token = csrf_from(control_page)
        code, _, body = control.form(
            "/admin/plugins/identity-access/api/",
            {
                "_csrf": token,
                "action": "save-user",
                "username": "sharedadmin",
                "display_name": "Shared Administrator",
                "email": "",
                "password": "shared-password",
                "max_users": "3",
                "inactive": "1200",
                "role_cms-admin": "1",
            },
        )
        result = json.loads(body)
        check(code == 200 and result.get("ok") is True,
              f"shared administrator creation failed ({code}): {result}")

        control_admin = Browser(f"http://a.local:{server.port}")
        code, _, control_dashboard = form_login(
            control_admin, "/admin/", "sharedadmin", "shared-password"
        )
        check(code == 200 and b"Dashboard" in control_dashboard,
              "control CMS did not switch to the shared provider")

        code, _, logged_in = form_login(
            consumer, "/admin/", "sharedadmin", "shared-password"
        )
        check(code == 200 and b"Dashboard" in logged_in and b"ba_seed" not in logged_in,
              "consumer did not use the shared provider: "
              f"HTTP {code}, body={logged_in[:1000]!r}")
        check(
            b"Plugin large-file-mailer is unavailable" not in logged_in,
            "consumer reported a failure for the intentionally disabled mailer",
        )
        check(
            b"//a.local/admin/plugins/identity-access/" in logged_in
            and b">Users &amp; Access<" in logged_in,
            "consumer did not link to the control domain's identity management UI",
        )
        check(
            b"/admin/users/" not in logged_in,
            "consumer exposed its standalone Users page while using shared identity",
        )
        code, _, consumer_content = consumer.request("/admin/content/")
        check(
            code == 200
            and b"//a.local/admin/plugins/identity-access/"
            in consumer_content
            and b">Users &amp; Access<" in consumer_content
            and b"/admin/users/" not in consumer_content,
            "consumer LSP admin navigation did not use the control identity UI",
        )
        consumer.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(consumer.jar),
            NoRedirect(),
        )
        code, headers, _ = consumer.request("/admin/users/")
        redirect_location = next(
            (value for key, value in headers.items() if key.lower() == "location"),
            "",
        )
        check(
            code in (301, 302, 303, 307, 308)
            and redirect_location
            == "//a.local/admin/plugins/identity-access/",
            "consumer Users route did not redirect to control identity management: "
            f"HTTP {code}, location={redirect_location!r}",
        )

        code, _, _ = consumer.request(
            "/admin/plugins/identity-access/"
        )
        check(code == 404,
              "consumer CMS loaded the control-owned Identity Access UI")
        code, _, _ = consumer.request(
            "/admin/plugins/file-services/"
        )
        check(code == 404,
              "consumer CMS loaded the control-owned File Services UI")
        code, _, _ = consumer.request(
            "/admin/plugins/large-file-mailer/"
        )
        check(code == 404,
              "consumer CMS loaded the control-owned Large File Mailer UI")
        code, _, control_files = control_admin.request(
            "/admin/plugins/file-services/"
        )
        check(code == 200 and b"File Services" in control_files,
              "control CMS did not own File Services")
        code, _, control_mailer = control_admin.request(
            "/admin/plugins/large-file-mailer/"
        )
        check(code == 200 and b"Large File Mailer" in control_mailer,
              "control CMS did not own Large File Mailer")

        for name in ("cms-a.local.sqlite.db", "cms-b.local.sqlite.db"):
            check((runtime / "data" / name).is_file(),
                  f"domain database was not created: {name}")
        with contextlib.closing(
            sqlite3.connect(runtime / "data" / "cms-a.local.sqlite.db")
        ) as conn:
            check(conn.execute("SELECT count(*) FROM identity_profiles").fetchone()[0] == 1,
                  "control identity profile was not stored in the control database")
        with contextlib.closing(
            sqlite3.connect(runtime / "data" / "cms-b.local.sqlite.db")
        ) as conn:
            check(conn.execute(
                "SELECT count(*) FROM identity_profiles"
            ).fetchone()[0] == 0,
                  "consumer CMS copied shared identity data into its database")

        code, _, identity_page = control_admin.request(
            "/admin/plugins/identity-access/"
        )
        check(code == 200, "authenticated control identity page was unavailable")
        disable_token = csrf_from(identity_page)
        code, _, body = control_admin.form(
            "/admin/plugins/identity-access/api/",
            {
                "_csrf": disable_token,
                "action": "save-user",
                "username": "sharedadmin",
                "display_name": "Shared Administrator",
                "email": "",
                "password": "",
                "disabled": "1",
                "max_users": "3",
                "inactive": "1200",
                "role_cms-admin": "1",
            },
        )
        result = json.loads(body)
        check(
            code == 400
            and "final enabled cms-admin" in result.get("error", ""),
            f"shared final administrator was not protected ({code}): {result}",
        )
        code, _, body = control_admin.form(
            "/admin/plugins/identity-access/api/",
            {"_csrf": disable_token, "action": "reset-identity"},
        )
        result = json.loads(body)
        check(code == 200 and result.get("users") in ([], {}),
              f"shared identity reset failed ({code}): {result}")
        code, _, unprotected = consumer.request("/admin/")
        check(code == 200 and b"Dashboard" in unprotected and b"ba_seed" not in unprotected,
              "consumer did not return to bootstrap mode after shared reset")
        code, _, reload_body = Browser(server.origin).request(
            "/reload-control/reload.lsp"
        )
        reload_result = json.loads(reload_body)
        check(code == 200 and reload_result.get("ok") is True,
              f"CmsDomains in-process reload failed: {reload_result}")
        for host_name in ("a.local", "b.local"):
            marker = runtime / f"unloaded-{host_name}.txt"
            check(marker.read_text(encoding="ascii") == "unloaded",
                  f"domain assets application was not unloaded: {host_name}")
        code, _, public_page = Browser(
            f"http://a.local:{server.port}"
        ).request("/")
        check(code == 404 and b"FuguHub" in public_page,
              "control CMS did not resume after in-process reload")


def verify_plugins(server: MakoProcess) -> None:
    browser = Browser(server.origin)
    code, _, body = browser.request(server.base + "plugin-probe/")
    check(code == 200, f"plugin VFS probe returned {code}: {body[:500]!r}")
    payload = json.loads(body)
    check(
        payload == {
            "id": "base-service",
            "value": "dependency-service",
            "moduleCached": True,
            "dataIo": True,
            "baseUri": "/" if not server.mount else f"/{server.mount}/",
        },
        f"plugin VFS probe returned unexpected data: {payload}",
    )

    code, headers, body = browser.request(server.base + "admin/plugins/consumer/")
    rendered = text(body, headers)
    check(
        code == 200
        and "Plugin Status" in rendered
        and "dependency-service" in rendered
        and "class='active'>Plugin Status</a>" in rendered,
        f"plugin admin page failed ({code}): {rendered[:1000]}",
    )
    token = csrf_from(body)
    code, headers, body = browser.form(
        server.base + "admin/plugins/consumer/",
        {"_csrf": token, "value": "saved-by-plugin"},
    )
    rendered = text(body, headers)
    check(
        code == 200 and "<span id='plugin-saved'>saved-by-plugin</span>" in rendered,
        f"plugin admin POST failed ({code}): {rendered[:1000]}",
    )
    check(
        (server.home / "data" / "plugins" / "base-service").is_dir()
        and (server.home / "data" / "plugins" / "consumer").is_dir(),
        "plugin data directories were not created",
    )
    check(
        any("FuguHub plugin failed:" in line and "broken" in line for line in server.lines),
        "failed plugin was not diagnosed",
    )
    check(
        any(
            "FuguHub plugin failed:" in line
            and "blocked" in line
            and "Dependency did not start: broken" in line
            for line in server.lines
        ),
        "dependant plugin was not blocked after its dependency failed",
    )


def test_plugins() -> None:
    runtime = fresh_runtime("plugins-root")
    install_plugin_fixtures(runtime)
    install_reload_controller(runtime)
    with MakoProcess(runtime, extra_loads=("-lreloadctl::reload-controller",)) as server:
        verify_plugins(server)
        browser = Browser(server.origin)
        code, _, body = browser.request("/reloadctl/reload.lsp")
        check(code == 200, f"plugin hot reload returned {code}: {body[:500]!r}")
        result = json.loads(body)
        check(result.get("ok") is True, f"plugin hot reload failed: {result}")
        deadline = time.time() + 5
        while time.time() < deadline and not any(
            "base-service:" in line and "fixture stopped" in line
            for line in server.lines
        ):
            time.sleep(0.05)
        check(
            any(
                "base-service:" in line and "fixture stopped" in line
                for line in server.lines
            ),
            "plugin stop callback was not called during CMS reload",
        )
        verify_plugins(server)

    named_runtime = fresh_runtime("plugins-named")
    install_plugin_fixtures(named_runtime)
    with MakoProcess(named_runtime, mount="mybase") as server:
        verify_plugins(server)
        code, _, _ = Browser(server.origin).request("/plugin-probe/")
        check(code == 404, "named plugin VFS mount leaked into the server root")


def test_private_module_loading() -> None:
    module_root = ROOT / "cms" / ".lua"
    private_modules = {
        path.relative_to(module_root).with_suffix("").as_posix().replace("/", ".")
        for path in module_root.rglob("*.lua")
    }
    source_files = [ROOT / "cms" / ".preload"]
    source_files.extend(
        path
        for root, pattern in (
            (ROOT / "cms", "*.lua"),
            (ROOT / "cms", "*.lsp"),
            (ROOT / "themes", "*.lsp"),
        )
        for path in root.rglob(pattern)
        if path.is_file()
    )
    require_pattern = re.compile(
        r"""\brequire\s*(?:\(\s*)?["']([^"']+)["']"""
    )
    appreq_pattern = re.compile(
        r"""\b(?:app\.)?appreq\s*(?:\(\s*)?["']([^"']+)["']"""
    )

    global_private_loads: list[str] = []
    missing_private_modules: list[str] = []
    for path in source_files:
        source = path.read_text(encoding="utf-8")
        for module in require_pattern.findall(source):
            if module in private_modules:
                global_private_loads.append(f"{path.relative_to(ROOT)}:{module}")
        for module in appreq_pattern.findall(source):
            if module not in private_modules:
                missing_private_modules.append(f"{path.relative_to(ROOT)}:{module}")

    check(
        not global_private_loads,
        "CMS-private modules use global require: " + ", ".join(global_private_loads),
    )
    check(
        not missing_private_modules,
        "appreq targets missing CMS-private modules: "
        + ", ".join(missing_private_modules),
    )
    preload = (ROOT / "cms" / ".preload").read_text(encoding="utf-8")
    check(
        'local pathio = require "pathio"' in preload
        and 'pathio(io, "lib")' in preload
        and "mako.createloader(libraryIo)" in preload,
        "the CMS does not install the dedicated stable-library loader",
    )
    check(
        "mako.createloader(io)" not in preload,
        "the CMS preload exposes application-private modules globally",
    )
    fastmcp_root = ROOT / "cms" / "lib" / ".lua" / "fastmcp"
    check(fastmcp_root.is_dir(), "FastMCP is not in the process-library tree")
    for path in fastmcp_root.rglob("*.lua"):
        check(
            "appreq" not in path.read_text(encoding="utf-8"),
            f"process-level FastMCP module uses appreq: {path.relative_to(ROOT)}",
        )


def test_deployed_archive() -> None:
    result = subprocess.run(
        ["cmd.exe", "/c", "create-deploy.cmd"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    check(
        result.returncode == 0,
        "deployment archive creation failed:\n" + result.stdout + result.stderr,
    )
    core_result = subprocess.run(
        ["cmd.exe", "/c", "create-core-deploy.cmd"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    check(
        core_result.returncode == 0,
        "core deployment archive creation failed:\n"
        + core_result.stdout
        + core_result.stderr,
    )
    with zipfile.ZipFile(ROOT / "deploy" / "cms.zip") as archive:
        full_names = set(archive.namelist())
    with zipfile.ZipFile(ROOT / "deploy-core" / "cms.zip") as archive:
        core_names = set(archive.namelist())
    check(
        "plugins/identity-access/.preload" in full_names
        and "plugins/file-services/.preload" in full_names
        and "plugins/large-file-mailer/.preload" in full_names,
        "full cms.zip does not contain the built-in plugins",
    )
    check(
        not any(name.startswith("plugins/") for name in core_names),
        "core cms.zip unexpectedly contains plugins",
    )
    check(
        not (ROOT / "deploy-core" / "CmsDomains.zip").exists(),
        "core deployment unexpectedly contains the multi-domain loader",
    )

    runtime = RUNTIME_ROOT / "deployed-archive"
    remove_tree(runtime)
    runtime.mkdir(parents=True)
    shutil.copy2(ROOT / "deploy-core" / "cms.zip", runtime / "cms.zip")
    shutil.copytree(ROOT / "deploy-core" / "themes", runtime / "themes")

    with MakoProcess(
        runtime, mount="zipbase", application="cms.zip"
    ) as server:
        browser = Browser(server.origin)
        code, _, dashboard = browser.request("/zipbase/admin/")
        check(
            code == 200 and b"Dashboard" in dashboard,
            f"deployed CMS admin failed under a base path: HTTP {code}",
        )
        code, _, empty_site = browser.request("/zipbase/")
        check(
            code == 404 and b"FuguHub" in empty_site,
            "deployed CMS did not render its initialized empty-site page",
        )
        code, _, _ = browser.request("/admin/")
        check(code == 404, "deployed named CMS leaked into the server root")

    check(
        (runtime / "data" / "cms.sqlite.db").is_file(),
        "deployed CMS did not initialize its database",
    )

    multidomain_runtime = RUNTIME_ROOT / "deployed-multidomain-archive"
    remove_tree(multidomain_runtime)
    multidomain_runtime.mkdir(parents=True)
    for name in ("cms.zip", "CmsDomains.zip"):
        shutil.copy2(ROOT / "deploy" / name, multidomain_runtime / name)
    shutil.copytree(ROOT / "deploy" / "themes", multidomain_runtime / "themes")
    (multidomain_runtime / "mako.conf").write_text(
        """cmsdomains = {
   { host = "a.local", control = true },
   { host = "b.local" }
}
wfs = { io = "home", path = "/", baseurl = "/fs/", lockdir = ".locks" }
""",
        encoding="ascii",
    )

    with MakoProcess(
        multidomain_runtime, application="CmsDomains.zip"
    ) as server:
        control = Browser(f"http://a.local:{server.port}")
        consumer = Browser(f"http://b.local:{server.port}")
        code, _, control_dashboard = control.request("/admin/")
        check(
            code == 200 and b"Users &amp; Access" in control_dashboard,
            "deployed control CMS did not load its shared plugins",
        )
        code, _, consumer_dashboard = consumer.request("/admin/")
        check(
            code == 200
            and b"//a.local/admin/plugins/identity-access/"
            in consumer_dashboard
            and b"Plugin large-file-mailer is unavailable"
            not in consumer_dashboard,
            "deployed consumer CMS did not use control-domain services",
        )
        code, _, _ = consumer.request("/admin/plugins/large-file-mailer/")
        check(code == 404, "deployed consumer loaded the control-owned mailer")
        code, _, control_mailer = control.request(
            "/admin/plugins/large-file-mailer/"
        )
        check(
            code == 200 and b"Large File Mailer" in control_mailer,
            "deployed control CMS did not load Large File Mailer",
        )

    for name in ("cms-a.local.sqlite.db", "cms-b.local.sqlite.db"):
        check(
            (multidomain_runtime / "data" / name).is_file(),
            f"deployed multidomain database was not created: {name}",
        )


def install_reload_controller(runtime: Path, target_application: str = "cms") -> None:
    controller = runtime / "reload-controller"
    controller.mkdir()
    (controller / ".preload").write_text("app.controller = true\n", encoding="ascii")
    target = target_application.replace("\\", "/")
    (controller / "reload.lsp").write_text(
        f"""<?lsp
local target
for index, path in ipairs(mako.getapps()) do
   local normalized = tostring(path):gsub("\\\\", "/")
   if normalized == "{target}" or normalized:sub(-{len(target) + 1}) == "/{target}" then
      target = index
      break
   end
end
if not target then
   response:setstatus(500)
   response:json {{ ok = false, err = "CMS application not found" }}
else
   local ok, err = mako.reloadapp(target)
   response:json {{ ok = ok == true, err = err }}
end
?>""",
        encoding="ascii",
    )


def test_appreq_hot_reload() -> None:
    runtime = fresh_runtime("appreq-hot-reload")
    (runtime / "assets" / "appreq-probe.lsp").write_text(
        """<?lsp
local module = app.appreq "runtime"
response:json {
   moduleId = tostring(module),
   cached = module == app.appreq "runtime",
   runtimeId = app.runtimeId,
   globallyCached = package.loaded.runtime ~= nil,
   baseUri = app.baseUri
}
?>""",
        encoding="ascii",
    )
    install_reload_controller(runtime)

    with MakoProcess(
        runtime, "mybase", ("-lreload-control::reload-controller",)
    ) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/mybase/appreq-probe.lsp")
        check(
            code == 200,
            f"appreq probe returned {code}: {body[:1000]!r}\n"
            + "\n".join(server.lines),
        )
        before = json.loads(body)
        check(
            before.get("cached") is True
            and before.get("globallyCached") is False
            and before.get("baseUri") == "/mybase/",
            f"application-private module cache is wrong before reload: {before}",
        )
        code, _, body = browser.request("/reload-control/reload.lsp")
        check(code == 200, f"reload controller returned {code}: {body[:1000]!r}")
        reload_result = json.loads(body)
        check(reload_result.get("ok") is True, f"CMS reload failed: {reload_result}")
        code, _, body = browser.request("/mybase/appreq-probe.lsp")
        check(code == 200, f"appreq probe after reload returned {code}: {body[:1000]!r}")
        after = json.loads(body)
        check(
            after.get("cached") is True
            and after.get("globallyCached") is False
            and after.get("baseUri") == "/mybase/"
            and after.get("moduleId") != before.get("moduleId")
            and after.get("runtimeId") != before.get("runtimeId"),
            f"application-private modules did not reload with the CMS: "
            f"before={before}, after={after}",
        )
        code, _, body = browser.request("/mybase/admin/")
        check(
            code == 200 and b"Dashboard" in body,
            "admin UI failed after the in-process CMS reload",
        )
        code, headers, body = browser.request("/mybase/missing-after-reload/")
        rendered = text(body, headers)
        check(
            code == 404 and "/mybase/admin/" in rendered,
            "editable 404 routing failed after the in-process CMS reload",
        )
        check(
            not any("failed" in line.lower() for line in server.lines if "Loading " in line),
            "Mako reported an application load failure during hot reload",
        )


def test_assets_application_reload() -> None:
    runtime = fresh_runtime("assets-application-reload")
    module_path = runtime / "assets" / ".lua" / "lifecycle_state.lua"
    module_path.parent.mkdir(parents=True, exist_ok=True)
    module_path.write_text(
        'return { version = "v1" }\n',
        encoding="ascii",
    )
    (module_path.parent / "nil_module.lua").write_text(
        "nilModuleLoads = (nilModuleLoads or 0) + 1\n",
        encoding="ascii",
    )
    (runtime / "assets" / ".preload").write_text(
        """local first = assetsreq "lifecycle_state"
local second = app.assetsreq "lifecycle_state"
local nilFirst = assetsreq "nil_module"
local nilSecond = assetsreq "nil_module"
assetLifecycle = {
   version = first.version,
   moduleId = tostring(first),
   cached = first == second,
   nilCached = nilFirst == true and nilSecond == true and nilModuleLoads == 1,
   cmsAppreqAvailable = type(app.appreq) == "function",
   assetsreqAvailable = type(app.assetsreq) == "function"
}
trace("ASSET_PRELOAD_" .. first.version)

function onunload()
   trace("ASSET_UNLOAD_" .. first.version)
   local file, err = io:open("unload-" .. first.version .. ".txt", "w")
   if not file then
      error(err)
   end
   file:write(first.version)
   file:close()
end
""",
        encoding="ascii",
    )
    (runtime / "assets" / "lifecycle.lsp").write_text(
        """<?lsp
local state = app.assetLifecycle
response:json {
   version = state.version,
   moduleId = state.moduleId,
   cached = state.cached,
   nilCached = state.nilCached,
   cmsAppreqAvailable = state.cmsAppreqAvailable,
   assetsreqAvailable = state.assetsreqAvailable,
   globallyCached = package.loaded.lifecycle_state ~= nil,
   baseUri = app.baseUri
}
?>""",
        encoding="ascii",
    )
    (runtime / "assets" / "environment.lsp").write_text(
        """<?lsp
response:json {
   assetsreqAvailable = type(app.assetsreq) == "function",
   lifecycleAvailable = type(app.assetLifecycle) == "table"
}
?>""",
        encoding="ascii",
    )

    install_reload_controller(runtime)

    token = "assets-reload-token-0123456789"
    with MakoProcess(
        runtime, "mybase", ("-lreload-control::reload-controller",)
    ) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/mybase/lifecycle.lsp")
        check(code == 200, f"asset lifecycle probe returned {code}: {body[:1000]!r}")
        before = json.loads(body)
        check(
            before["version"] == "v1"
            and before["cached"] is True
            and before["nilCached"] is True
            and before["cmsAppreqAvailable"] is True
            and before["assetsreqAvailable"] is True
            and before["globallyCached"] is False
            and before["baseUri"] == "/mybase/",
            f"initial assets application environment is wrong: {before}",
        )

        configure_mcp(browser, "/mybase/", token)
        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        module_asset = mcp_structured(
            client.call("getAsset", {"path": ".lua/lifecycle_state.lua"})
        )
        written = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": ".lua/lifecycle_state.lua",
                    "content": 'return { version = "v2" }\n',
                    "expectedSha256": module_asset["sha256"],
                    "confirmedExecutable": True,
                },
            )
        )
        check(written["restartRequired"] is True, "Lua asset did not require activation")

        code, _, body = browser.request("/mybase/lifecycle.lsp")
        unchanged = json.loads(body)
        check(
            code == 200 and unchanged["version"] == "v1",
            f"asset module changed before restartAssetsApplication: {unchanged}",
        )

        denied = client.call("restartAssetsApplication", {"confirmed": False})
        check(
            denied.get("isError") is True
            and denied["structuredContent"]["code"] == "confirmationRequired",
            f"unconfirmed assets restart was accepted: {denied}",
        )
        restarted = mcp_structured(
            client.call("restartAssetsApplication", {"confirmed": True})
        )
        check(
            restarted["ok"] is True
            and restarted["unloaded"] is True
            and restarted["loaded"] is True
            and restarted["active"] is True
            and restarted["preloadExists"] is True,
            f"assets application restart failed: {restarted}",
        )
        check(
            (runtime / "assets" / "unload-v1.txt").read_text(encoding="ascii") == "v1",
            "MCP restart did not call the old assets onunload",
        )

        code, _, body = browser.request("/mybase/lifecycle.lsp")
        after = json.loads(body)
        check(
            code == 200
            and after["version"] == "v2"
            and after["cached"] is True
            and after["globallyCached"] is False
            and after["moduleId"] != before["moduleId"],
            f"assets application did not activate the new private module: {after}",
        )

        failing = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": ".lua/lifecycle_state.lua",
                    "content": 'error("EXPECTED_ASSET_RUNTIME_FAILURE")\n',
                    "expectedSha256": written["sha256"],
                    "confirmedExecutable": True,
                },
            )
        )
        failed_restart = client.call(
            "restartAssetsApplication", {"confirmed": True}
        )
        check(
            failed_restart.get("isError") is True
            and failed_restart["structuredContent"]["code"]
            == "assetsPreloadFailed"
            and "EXPECTED_ASSET_RUNTIME_FAILURE"
            in failed_restart["structuredContent"]["loadError"]
            and failed_restart["structuredContent"]["active"] is False,
            f"asset preload runtime failure was not reported: {failed_restart}",
        )
        code, _, body = browser.request("/mybase/environment.lsp")
        failed_environment = json.loads(body)
        check(
            code == 200
            and failed_environment["assetsreqAvailable"] is False
            and failed_environment["lifecycleAvailable"] is False,
            f"failed asset app remained active: {failed_environment}",
        )

        recovered_write = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": ".lua/lifecycle_state.lua",
                    "content": 'return { version = "v3" }\n',
                    "expectedSha256": failing["sha256"],
                    "confirmedExecutable": True,
                },
            )
        )
        recovered = mcp_structured(
            client.call("restartAssetsApplication", {"confirmed": True})
        )
        check(
            recovered["ok"] is True
            and recovered["loaded"] is True
            and recovered["active"] is True,
            f"assets application did not recover after a failed preload: {recovered}",
        )
        code, _, body = browser.request("/mybase/lifecycle.lsp")
        after_recovery = json.loads(body)
        check(
            code == 200
            and after_recovery["version"] == "v3"
            and after_recovery["moduleId"] != after["moduleId"],
            f"recovered assets application did not load v3: {after_recovery}",
        )

        code, _, body = browser.request("/reload-control/reload.lsp")
        reload_result = json.loads(body)
        check(
            code == 200 and reload_result.get("ok") is True,
            f"CMS hot reload failed with an active assets app: {reload_result}",
        )
        check(
            (runtime / "assets" / "unload-v3.txt").read_text(encoding="ascii") == "v3",
            "CMS unload did not call the active assets onunload",
        )
        code, _, body = browser.request("/mybase/lifecycle.lsp")
        reloaded = json.loads(body)
        check(
            code == 200
            and reloaded["version"] == "v3"
            and reloaded["moduleId"] != after_recovery["moduleId"],
            f"CMS hot reload retained the old assets module cache: {reloaded}",
        )

        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        preload = mcp_structured(client.call("getAsset", {"path": ".preload"}))
        deleted = mcp_structured(
            client.call(
                "deleteAsset",
                {
                    "path": ".preload",
                    "expectedSha256": preload["sha256"],
                    "confirmed": True,
                },
            )
        )
        check(deleted["restartRequired"] is True, "deleted preload did not require activation")
        no_preload = mcp_structured(
            client.call("restartAssetsApplication", {"confirmed": True})
        )
        check(
            no_preload["ok"] is True
            and no_preload["preloadExists"] is False
            and no_preload["loaded"] is False
            and no_preload["active"] is False,
            f"no-preload restart result is wrong: {no_preload}",
        )
        code, _, body = browser.request("/mybase/environment.lsp")
        no_preload_environment = json.loads(body)
        check(
            code == 200
            and no_preload_environment["assetsreqAvailable"] is False
            and no_preload_environment["lifecycleAvailable"] is False,
            f"assetsreq was installed without assets/.preload: {no_preload_environment}",
        )


def test_root_runtime() -> None:
    runtime = fresh_runtime("root")
    install_zip_theme(runtime)
    install_assets_zip(runtime)
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        base = "/"

        code, headers, body = browser.request("/missing/")
        rendered = text(body, headers)
        check(
            code == 404,
            f"seeded 404 returned {code}: {rendered[:1000]}\nMako output:\n"
            + "\n".join(server.lines),
        )
        check(
            "/admin/" in rendered and "does not have public content" in rendered,
            "seeded 404 body is wrong: "
            + rendered[:500]
            + "\nMako output:\n"
            + "\n".join(server.lines),
        )
        for method in ("OPTIONS", "PROPFIND"):
            code, headers, body = browser.request("/missing-webdav/", method=method)
            rendered = text(body, headers)
            check(
                code == 404
                and "does not have public content" not in rendered
                and "BarracudaServer.com" in rendered,
                f"editable CMS 404 intercepted {method}: {rendered[:500]}",
            )
        code, _, body = browser.request("/probe.txt")
        check(code == 200 and body == b"zip-assets", "assets.zip did not take precedence")
        check(database_path(runtime).exists(), "fresh startup did not create the SQLite database")

        code, _, _ = browser.form(
            "/admin/settings/",
            {"blog_base_path": "/news/", "not_found_path": "/404/"},
        )
        check(code == 403, "admin POST without CSRF was not rejected")

        create_content(browser, base, path="/", title="Home", body="<p>HOME OK</p>", cache_policy="revalidate")
        create_lsp_test_pages(browser, base)
        create_content(
            browser,
            base,
            path="/fk/",
            title="Foreign keys",
            body='<?lsp local db=app.appreq"db"; local r=db.withRead(app,function(c)return db.one(c,"PRAGMA foreign_keys")end); print(r.foreign_keys) ?>',
            render_mode="lsp",
        )
        create_content(
            browser,
            base,
            path="/bad-lsp/",
            title="Bad LSP",
            body='<?lsp error("expected render failure") ?>',
            render_mode="lsp",
        )
        create_content(browser, base, path="/parent/", title="Parent", body="<p>PARENT</p>")
        create_content(browser, base, path="/parent/child/", title="Child", body="<p>CHILD</p>")
        code, _, _ = admin_post(
            browser,
            base,
            "categories/",
            {
                "action": "add",
                "name": "Engineering",
                "slug": "engineering",
                "description": "Engineering articles",
            },
        )
        check(code == 200, "blog category creation failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            engineering_category_id = conn.execute(
                "SELECT id FROM terms WHERE type='category' AND slug='engineering'"
            ).fetchone()[0]
        create_content(
            browser,
            base,
            path="/first/",
            title="First Post",
            body="<p>POST OK</p>",
            content_type="post",
            category_ids=[engineering_category_id],
        )
        create_content(
            browser,
            base,
            path="/category-api/",
            title="Category API",
            body="""<?lsp
local posts, err = app.cms:postsByCategory("engineering", { limit = 5 })
if not posts then error(err) end
local categories = app.cms:categories()
response:write("<p id='category-api' data-count='", #posts, "' data-categories='",
   #categories, "'>", posts[1].path, "</p>")
?>""",
            render_mode="lsp",
        )
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {
                "action": "add",
                "label": "First Post",
                "url": "/blog/first/",
                "parent_id": "",
                "position": "20",
            },
        )
        check(code == 200, "post menu fixture creation failed")
        code, _, _ = admin_post(
            browser,
            base,
            "redirects/",
            {
                "action": "add",
                "from_path": "/first-post/",
                "to_path": "/blog/first/",
                "status_code": "302",
            },
        )
        check(code == 200, "post redirect fixture creation failed")
        code, _, body = browser.request("/blog/first/")
        check(
            code == 200
            and b"POST OK" in body
            and b"href='/blog/category/engineering/'" in body,
            "post or its category link was not rendered below the default blog base",
        )
        code, _, body = browser.request("/blog/category/engineering/")
        check(
            code == 200
            and b"Engineering articles" in body
            and b"href='/blog/first/'" in body,
            "category archive did not list its assigned post",
        )
        code, _, body = browser.request("/category-api/")
        check(
            code == 200
            and b"id='category-api' data-count='1' data-categories='1'" in body
            and b"/blog/first/" in body,
            "database LSP could not query published posts through "
            f"app.cms:postsByCategory: {body[:1000]!r}",
        )
        code, _, _ = admin_post(
            browser,
            base,
            "settings/",
            {
                "blog_base_path": "/articles/",
                "not_found_path": "/404/",
            },
        )
        check(code == 200, "changing the blog base URL failed")
        code, _, body = browser.request("/articles/first/")
        check(code == 200 and b"POST OK" in body, "post did not move below the configured blog base")
        code, _, archive_body = browser.request("/articles/")
        check(
            code == 200 and b"href='/articles/first/'" in archive_body,
            "blog archive did not use the migrated post URL",
        )
        code, _, category_body = browser.request("/articles/category/engineering/")
        check(
            code == 200 and b"href='/articles/first/'" in category_body,
            "category archive did not follow the configured blog base",
        )
        code, _, _ = browser.request("/blog/first/")
        check(code == 404, "old post URL remained a public content route after the blog base changed")
        code, _, _ = browser.request("/blog/category/engineering/")
        check(code == 404, "old category archive remained after the blog base changed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            post_path = conn.execute(
                "SELECT path FROM content WHERE title='First Post'"
            ).fetchone()[0]
            post_menu_id, post_menu_path = conn.execute(
                "SELECT id,url FROM menu_items WHERE label='First Post'"
            ).fetchone()
            post_redirect_path = conn.execute(
                "SELECT to_path FROM redirects WHERE from_path='/first-post/'"
            ).fetchone()[0]
            category_assignment = conn.execute(
                """SELECT t.slug FROM terms t
                   JOIN content_terms ct ON ct.term_id=t.id
                   JOIN content c ON c.id=ct.content_id
                   WHERE c.title='First Post' AND t.type='category'"""
            ).fetchone()
        check(post_path == "/first/", "blog base leaked into the stored post path")
        check(
            post_menu_path == "/articles/first/"
            and post_redirect_path == "/articles/first/",
            "blog-base update did not update related public menu and redirect targets",
        )
        check(
            category_assignment == ("engineering",),
            "admin content save did not persist the category assignment",
        )
        create_content(
            browser,
            base,
            path="/first/",
            title="First Page",
            body="<p>PAGE WITH SHARED PATH OK</p>",
        )
        code, _, body = browser.request("/first/")
        check(code == 200 and b"PAGE WITH SHARED PATH OK" in body, "page and post could not share a stored path")
        code, _, body = browser.request("/articles/first/")
        check(code == 200 and b"POST OK" in body, "shared page path displaced the blog post")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {"action": "toggle-hidden", "id": str(post_menu_id)},
        )
        check(code == 200, "hiding a menu item failed")
        _, menus_page = admin_get(browser, base, "menus/")
        check(
            'class="item-id-value"' in menus_page
            and '<span class="tag hidden">hidden</span>' in menus_page
            and ">Show</button>" in menus_page,
            "hidden menu item did not show its aligned status and Show action",
        )

        code, headers, body = browser.request("/", headers={"Accept-Encoding": "deflate"})
        rendered = text(body, headers)
        check(code == 200 and "HOME OK" in rendered, "compressed HTML page failed")
        check(headers.get("Content-Encoding") == "deflate", "deflate response was not compressed")
        etag = headers.get("ETag")
        check(bool(etag), "revalidated HTML page did not emit ETag")
        check(
            'href="/theme/style.css"' in rendered and "/theme/style.css?v=" not in rendered,
            "default theme did not use the stable local stylesheet URL",
        )
        code, _, _ = browser.request("/", headers={"If-None-Match": etag or ""})
        check(code == 304, "ETag revalidation did not return 304")
        code, headers, _ = browser.request("/", headers={"Accept-Encoding": "deflate;q=0"})
        check("Content-Encoding" not in headers, "deflate;q=0 incorrectly enabled compression")

        verify_lsp_test_pages(browser, "/")
        code, headers, body = browser.request("/fk/", headers={"Accept-Encoding": "deflate"})
        check(code == 200 and "1" in text(body, headers), "/fk/ LSP rendering failed")

        for accept in ("", "deflate"):
            request_headers = {"Accept-Encoding": accept} if accept else {}
            code, _, body = browser.request("/bad-lsp/", headers=request_headers)
            check(code == 500 and b"expected render failure" in body, f"render error with {accept or 'identity'} failed")

        token, _ = admin_get(browser, base, "redirects/")
        for source, target, status in (
            ("/old-permanent/", "/parent/", "301"),
            ("/old-temporary/", "/lsp-basic/", "302"),
        ):
            code, _, _ = admin_post(
                browser,
                base,
                "redirects/",
                {"action": "add", "from_path": source, "to_path": target, "status_code": status},
                token=token,
            )
            check(code == 200, f"adding {status} redirect failed")
        for path, expected in (("/old-permanent/", 301), ("/old-temporary/", 302)):
            no_redirect = urllib.request.build_opener(NoRedirect())
            request = urllib.request.Request(server.origin + path)
            try:
                no_redirect.open(request)
                raise TestFailure(f"{path} did not redirect")
            except urllib.error.HTTPError as exc:
                check(exc.code == expected, f"{path} returned {exc.code}, expected {expected}")

        code, _, _ = admin_post(
            browser,
            base,
            "redirects/",
            {"action": "add", "from_path": "/bad/", "to_path": "/", "status_code": "307"},
        )
        check(code == 400, "invalid redirect status was accepted")

        code, menu_headers, _ = browser.request("/")
        check(code == 200, "menu cache baseline request failed")
        menu_etag = menu_headers.get("ETag")
        check(bool(menu_etag), "menu cache baseline ETag is missing")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {"action": "add", "label": "Parent", "url": "/parent/", "parent_id": "", "position": "1"},
        )
        check(code == 200, "parent menu item creation failed")
        code, current_headers, current_body = browser.request(
            "/",
            headers={
                "If-None-Match": menu_etag or "",
                "If-Modified-Since": "Wed, 31 Dec 2099 23:59:59 GMT",
            },
        )
        check(
            code == 200
            and current_headers.get("ETag") != menu_etag
            and b">Parent</a>" in current_body,
            "menu mutation did not invalidate cached public HTML",
        )
        code, _, _ = browser.request(
            "/", headers={"If-Modified-Since": "Wed, 31 Dec 2099 23:59:59 GMT"}
        )
        check(code == 200, "CMS incorrectly used If-Modified-Since without an ETag")
        menu_etag = current_headers.get("ETag")
        code, _, _ = browser.request(
            "/",
            headers={
                "If-None-Match": menu_etag or "",
                "If-Modified-Since": "Wed, 31 Dec 2099 23:59:59 GMT",
            },
        )
        check(code == 304, "unchanged menu-aware HTML did not revalidate to 304")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {"action": "add", "label": "Child", "url": "/parent/child/", "parent_id": "", "position": "1"},
        )
        check(code == 200, "child menu item creation failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            parent_id = conn.execute("SELECT id FROM menu_items WHERE label='Parent'").fetchone()[0]
            child_id = conn.execute("SELECT id FROM menu_items WHERE label='Child'").fetchone()[0]
            child_parent = conn.execute("SELECT parent_id FROM menu_items WHERE id=?", (child_id,)).fetchone()[0]
        check(child_parent == parent_id, "menu parent was not inferred from the URL")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {
                "action": "update",
                "id": str(parent_id),
                "label": "Parent",
                "url": "/parent/",
                "parent_id": str(child_id),
                "position": "1",
            },
        )
        check(code == 400, "menu cycle was accepted")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {"action": "add", "label": "Unsafe", "url": "javascript:alert(1)", "parent_id": "", "position": "1"},
        )
        check(code == 400, "unsafe menu URL scheme was accepted")

        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {
                "action": "add",
                "label": "Temporary Menu Parent",
                "url": "/temporary-menu/",
                "parent_id": "",
                "position": "90",
            },
        )
        check(code == 200, "temporary parent menu item creation failed")
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {
                "action": "add",
                "label": "Temporary Menu Child",
                "url": "/temporary-menu/child/",
                "parent_id": "",
                "position": "1",
            },
        )
        check(code == 200, "temporary child menu item creation failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            temporary_parent_id = conn.execute(
                "SELECT id FROM menu_items WHERE label='Temporary Menu Parent'"
            ).fetchone()[0]
            temporary_child_id, temporary_child_parent = conn.execute(
                "SELECT id,parent_id FROM menu_items WHERE label='Temporary Menu Child'"
            ).fetchone()
        check(
            temporary_child_parent == temporary_parent_id,
            "temporary menu child was not attached to its parent",
        )
        _, menu_delete_page = admin_get(
            browser, base, f"menus/delete?id={temporary_parent_id}"
        )
        check(
            "Delete Menu Item" in menu_delete_page
            and "Temporary Menu Parent" in menu_delete_page
            and "Child items will become top-level menu items" in menu_delete_page
            and "Temporary Menu Child" in menu_delete_page,
            "menu deletion confirmation omitted the item or child consequence",
        )
        code, _, body = admin_post(
            browser,
            base,
            f"menus/delete?id={temporary_parent_id}",
            {"id": str(temporary_parent_id), "confirmed": "true"},
        )
        check(code == 200, f"temporary menu deletion failed: {body[:300]!r}")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            deleted_parent = conn.execute(
                "SELECT id FROM menu_items WHERE id=?", (temporary_parent_id,)
            ).fetchone()
            promoted_child = conn.execute(
                "SELECT parent_id FROM menu_items WHERE id=?", (temporary_child_id,)
            ).fetchone()
        check(deleted_parent is None, "deleted menu item remains in the database")
        check(
            promoted_child is not None and promoted_child[0] is None,
            "deleting a parent menu item did not promote its child to top level",
        )

        create_content(
            browser,
            base,
            path="/temporary-delete/",
            title="Temporary Delete",
            body="<p>DELETE THIS CONTENT</p>",
        )
        create_content(
            browser,
            base,
            path="/temporary-delete/child/",
            title="Temporary Delete Child",
            body="<p>PRESERVE THIS CHILD</p>",
        )
        code, _, _ = admin_post(
            browser,
            base,
            "menus/",
            {
                "action": "add",
                "label": "Temporary Delete Link",
                "url": "/temporary-delete/",
                "parent_id": "",
                "position": "91",
            },
        )
        check(code == 200, "temporary content menu dependency creation failed")
        code, _, _ = admin_post(
            browser,
            base,
            "redirects/",
            {
                "action": "add",
                "from_path": "/temporary-delete-alias/",
                "to_path": "/temporary-delete/",
                "status_code": "302",
            },
        )
        check(code == 200, "temporary content redirect dependency creation failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            temporary_content_id = conn.execute(
                "SELECT id FROM content WHERE path='/temporary-delete/'"
            ).fetchone()[0]
        _, content_delete_page = admin_get(
            browser, base, f"content/delete?id={temporary_content_id}"
        )
        check(
            "Delete Permanently" in content_delete_page
            and "Temporary Delete Link" in content_delete_page
            and "/temporary-delete-alias/" in content_delete_page
            and "Child paths will not be deleted" in content_delete_page
            and "Temporary Delete Child" in content_delete_page,
            "content deletion confirmation omitted dependencies or child-content policy",
        )
        code, _, body = admin_post(
            browser,
            base,
            f"content/delete?id={temporary_content_id}",
            {
                "id": str(temporary_content_id),
                "confirmed": "true",
                "menu_items_action": "delete",
                "redirects_action": "delete",
            },
        )
        check(code == 200, f"temporary content deletion failed: {body[:300]!r}")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            deleted_content = conn.execute(
                "SELECT id FROM content WHERE id=?", (temporary_content_id,)
            ).fetchone()
            preserved_child_content = conn.execute(
                "SELECT id FROM content WHERE path='/temporary-delete/child/'"
            ).fetchone()
            deleted_menu_dependency = conn.execute(
                "SELECT id FROM menu_items WHERE label='Temporary Delete Link'"
            ).fetchone()
            deleted_redirect_dependency = conn.execute(
                "SELECT id FROM redirects WHERE from_path='/temporary-delete-alias/'"
            ).fetchone()
        check(deleted_content is None, "deleted content remains in the database")
        check(
            preserved_child_content is not None,
            "content deletion incorrectly deleted child content",
        )
        check(
            deleted_menu_dependency is None and deleted_redirect_dependency is None,
            "selected content dependencies were not deleted",
        )

        code, _, _ = admin_post(browser, base, "themes/", {"theme": "../default"})
        check(code == 400, "unsafe theme name was accepted")
        code, _, _ = admin_post(browser, base, "themes/", {"theme": "zipped"})
        check(code == 200, "ZIP theme activation failed")
        code, theme_headers, theme_body = browser.request(
            "/",
            headers={
                "If-None-Match": menu_etag or "",
                "If-Modified-Since": "Wed, 31 Dec 2099 23:59:59 GMT",
            },
        )
        theme_page = text(theme_body, theme_headers)
        check(
            code == 200
            and theme_headers.get("ETag") != menu_etag
            and 'href="/theme/style.css"' in theme_page
            and "?v=" not in theme_page,
            "theme activation did not invalidate HTML or preserve stable asset URLs",
        )
        code, _, css = browser.request("/theme/style.css")
        check(code == 200 and b"zipped-theme-marker" in css, "ZIP theme was not activated live")
        code, _, _ = admin_post(browser, base, "themes/", {"theme": "broken"})
        check(code == 400, "incomplete theme activation was accepted")
        code, _, css = browser.request("/theme/style.css")
        check(code == 200 and b"zipped-theme-marker" in css, "failed activation replaced the working theme")

        code, _, _ = admin_post(
            browser,
            base,
            "settings/",
            {
                "blog_base_path": "/blog/",
                "not_found_path": "/404/",
                "not_found_enabled": "1",
                "htmx_enabled": "1",
            },
        )
        check(code == 200, "settings update failed")
        code, _, body = browser.request("/blog/first/")
        check(code == 200 and b"POST OK" in body, "post did not follow the blog base when it changed back")
        code, _, page_body = browser.request("/")
        page_html = page_body.decode("utf-8", errors="replace")
        check(
            'src="/assets/htmx/htmx.min.js"' in page_html
            and 'src="/theme/cms.js"' in page_html
            and "cms-nav.js" not in page_html
            and "cms-htmx.js" not in page_html
            and "unpkg.com" not in page_html
            and "?v=" not in page_html,
            "HTMX-enabled default theme did not use stable local assets",
        )
        code, _, htmx_body = browser.request("/assets/htmx/htmx.min.js")
        check(
            code == 200 and b'version:"2.0.10"' in htmx_body,
            "vendored HTMX 2.0.10 asset is unavailable",
        )
        code, headers, body = browser.request("/parent/child/", headers={"HX-Request": "true"})
        fragment = text(body, headers)
        check(code == 200 and "<main" in fragment and "<!doctype" not in fragment.lower(), "HTMX fragment response failed")
        check("HX-Request" in headers.get("Vary", ""), "HTMX response did not vary on HX-Request")

        code, _, _ = admin_post(
            browser,
            base,
            "users/",
            {"action": "save", "username": "testadmin", "password": "testpass"},
        )
        check(code == 200, "creating an admin user failed")
        login = Browser(server.origin)
        code, _, login_body = login.request("/admin/")
        check(code == 200 and b"ba_seed" in login_body, "admin authentication did not present login")
        check(b"src='/rtl/jquery.js'" in login_body and b"src='/rtl/sha1.js'" in login_body, "login scripts are not server-root URLs")
        seed = re.search(rb"name='ba_seed' value='([^']*)'", login_body)
        seedkey = re.search(rb"name='ba_seedkey' value='([^']*)'", login_body)
        check(bool(seed and seedkey), "login challenge fields are missing")
        digest = hashlib.sha1(b"testpass" + seed.group(1)).hexdigest()
        code, _, logged_in = login.form(
            "/admin/",
            {
                "ba_username": "testadmin",
                "ba_password": digest,
                "ba_seed": seed.group(1).decode(),
                "ba_seedkey": seedkey.group(1).decode(),
            },
        )
        check(code == 200 and b"Dashboard" in logged_in and b"ba_seed" not in logged_in, "TPM form login failed")

        code, headers, removed_user_page = admin_post(
            login,
            base,
            "users/",
            {"action": "remove", "username": "testadmin"},
        )
        check(code == 200, "removing the final admin user failed")
        check(
            "final enabled cms-admin cannot be disabled or demoted" in
            text(removed_user_page, headers),
            "the final administrator was not protected from accidental removal",
        )
        code, headers, reset_user_page = admin_post(
            login, base, "users/", {"action": "reset"}
        )
        check(code == 200 and "No admin users configured." in
              text(reset_user_page, headers),
              "explicit authentication reset did not remove the final user")
        check(
            not (runtime / "data" / "admin-users.encrypted").exists()
            and not (runtime / "data" / "plugins" / "identity-access" /
                     "users.encrypted").exists(),
            "authentication reset retained an external credential database",
        )

        second = MakoProcess(runtime).start()
        try:
            second_browser = Browser(second.origin)
            code, _, body = second_browser.request("/")
            check(code == 503 and b"already in use" in body, "second instance did not show fatal ownership UI")
        finally:
            second.stop()

    with MakoProcess(runtime) as restarted:
        browser = Browser(restarted.origin)
        code, headers, body = browser.request("/admin/users/")
        rendered = text(body, headers)
        check(
            code == 200
            and "No admin users configured." in rendered
            and "ba_seed" not in rendered,
            "admin authentication was not cleanly disabled after restart",
        )
        check(
            "Data corrupt" not in "\n".join(restarted.lines),
            "removing the final admin user left a corrupt database startup error",
        )

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        conn.execute(
            "INSERT INTO identity_profiles(username,created_at,updated_at) "
            "VALUES('corrupt-test',0,0)"
        )
        conn.execute(
            "INSERT INTO identity_user_roles(username,role_name) "
            "VALUES('corrupt-test','cms-admin')"
        )
        conn.execute(
            "INSERT OR REPLACE INTO identity_credentials(id,encrypted_base64) "
            "VALUES(1,'not-valid-encrypted-data')"
        )
        conn.commit()
    try:
        with MakoProcess(runtime) as failed_auth:
            browser = Browser(failed_auth.origin)
            code, headers, body = browser.request("/admin/")
            rendered = text(body, headers)
            check(
                code == 503
                and "CMS startup failed" in rendered,
                "corrupt SQLite identity credentials did not fail closed",
            )
            code, _, body = browser.request("/")
            check(
                code == 503 and b"CMS startup failed" in body,
                "identity corruption exposed a partially initialized CMS",
            )
    finally:
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            conn.execute("DELETE FROM identity_profiles WHERE username='corrupt-test'")
            conn.execute("DELETE FROM identity_credentials")
            conn.commit()


def test_named_mount() -> None:
    runtime = fresh_runtime("named")
    shutil.rmtree(runtime / "assets")
    with MakoProcess(runtime, "mybase") as server:
        browser = Browser(server.origin)
        code, headers, body = browser.request("/mybase/missing/")
        rendered = text(body, headers)
        check(code == 404 and "/mybase/admin/" in rendered, "named-mount 404 or admin URL failed")
        code, _, _ = browser.request("/mybase/admin/admin.css")
        check(code == 200, "named-mount admin CSS failed")
        code, _, _ = browser.request("/mybase/theme/style.css")
        check(code == 200, "named-mount theme asset failed")
        code, _, _ = browser.request("/rtl/jquery.js")
        check(code == 200, "server-root login dependency is unavailable")
        create_content(browser, "/mybase/", path="/", title="Named Home", body="<p>NAMED OK</p>")
        create_lsp_test_pages(browser, "/mybase/")
        code, headers, body = browser.request("/mybase/", headers={"Accept-Encoding": "deflate"})
        check(code == 200 and "NAMED OK" in text(body, headers), "named-mount CMS rendering failed")
        code, headers, body = browser.request("/mybase")
        check(code == 200 and "NAMED OK" in text(body, headers), "named mount without trailing slash failed")
        verify_lsp_test_pages(browser, "/mybase/")
        code, _, _ = admin_post(
            browser,
            "/mybase/",
            "categories/",
            {
                "action": "add",
                "name": "Named Category",
                "slug": "named-category",
                "description": "Named mount category",
            },
        )
        check(code == 200, "named-mount category creation failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            named_category_id = conn.execute(
                "SELECT id FROM terms WHERE type='category' AND slug='named-category'"
            ).fetchone()[0]
        create_content(
            browser,
            "/mybase/",
            path="/named-post/",
            title="Named Post",
            body="<p>NAMED POST OK</p>",
            content_type="post",
            category_ids=[named_category_id],
        )
        code, _, _ = admin_post(
            browser,
            "/mybase/",
            "settings/",
            {
                "blog_base_path": "/articles/",
                "not_found_path": "/404/",
                "htmx_enabled": "1",
            },
        )
        check(code == 200, "named-mount blog base update failed")
        code, _, body = browser.request("/mybase/articles/named-post/")
        check(code == 200 and b"NAMED POST OK" in body, "named-mount post did not follow the blog base")
        code, _, body = browser.request("/mybase/articles/category/named-category/")
        check(
            code == 200
            and b"href='/mybase/articles/named-post/'" in body
            and b"Named mount category" in body,
            "named-mount category archive or generated post URL failed",
        )
        code, _, body = browser.request("/mybase/")
        named_html = body.decode("utf-8", errors="replace")
        check(
            'src="/mybase/assets/htmx/htmx.min.js"' in named_html
            and 'href="/mybase/theme/style.css"' in named_html
            and "?v=" not in named_html,
            "named-mount default theme did not use stable local assets",
        )
        code, _, body = browser.request("/mybase/assets/htmx/htmx.min.js")
        check(code == 200 and b'version:"2.0.10"' in body, "named-mount HTMX asset failed")
        code, _, _ = admin_post(
            browser,
            "/mybase/",
            "users/",
            {"action": "save", "username": "namedadmin", "password": "namedpass"},
        )
        check(code == 200, "named-mount admin user creation failed")
        login = Browser(server.origin)
        code, _, login_body = login.request("/mybase/admin/")
        check(code == 200 and b"src='/rtl/jquery.js'" in login_body, "named-mount login page is invalid")
        seed = re.search(rb"name='ba_seed' value='([^']*)'", login_body)
        seedkey = re.search(rb"name='ba_seedkey' value='([^']*)'", login_body)
        check(bool(seed and seedkey), "named-mount login challenge is missing")
        digest = hashlib.sha1(b"namedpass" + seed.group(1)).hexdigest()
        code, _, logged_in = login.form(
            "/mybase/admin/",
            {
                "ba_username": "namedadmin",
                "ba_password": digest,
                "ba_seed": seed.group(1).decode(),
                "ba_seedkey": seedkey.group(1).decode(),
            },
        )
        check(code == 200 and b"Dashboard" in logged_in and b"ba_seed" not in logged_in,
              "named-mount TPM form login failed")


def test_admin_htmx() -> None:
    runtime = fresh_runtime("admin-htmx")
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)

        code, headers, body = browser.request("/admin/content/")
        content_page = text(body, headers)
        check(
            code == 200
            and "<!doctype html>" in content_page.lower()
            and 'src="/assets/htmx/htmx.min.js"' in content_page
            and 'id="content-list"' in content_page,
            f"content LSP page shell is incomplete: {content_page[:1000]}",
        )
        code, _, htmx_script = browser.request("/assets/htmx/htmx.min.js")
        check(
            code == 200 and b'version:"2.0.10"' in htmx_script,
            "admin HTMX was not served locally",
        )

        fragment_paths = (
            "/admin/includes/start.lsp",
            "/admin/includes/end.lsp",
            "/admin/content/list.lsp",
            "/admin/content/row-template.lsp",
            "/admin/content/row.lsp?id=1",
            "/admin/content/save.lsp",
            "/admin/content/delete.lsp?id=1",
            "/admin/categories/list.lsp",
            "/admin/categories/row-template.lsp",
            "/admin/categories/action.lsp",
            "/admin/categories/delete.lsp?id=1",
            "/admin/menus/list.lsp",
            "/admin/menus/item-template.lsp",
            "/admin/menus/item.lsp?id=1",
            "/admin/menus/action.lsp",
            "/admin/menus/delete.lsp?id=1",
        )
        for fragment_path in fragment_paths:
            code, _, _ = browser.request(fragment_path)
            check(
                code == 404,
                f"admin fragment allowed an ordinary direct request: {fragment_path}",
            )
        code, headers, body = browser.request(
            "/admin/content/list.lsp?type=page",
            headers={"HX-Request": "true"},
        )
        content_fragment = text(body, headers)
        check(
            code == 200
            and 'id="content-list"' in content_fragment
            and "<!doctype" not in content_fragment.lower()
            and 'hx-push-url="/admin/content/?type=page"' in content_fragment,
            f"content filter did not return a mount-safe fragment: {content_fragment[:1000]}",
        )

        category_csrf, category_page = admin_get(browser, "/", "categories/")
        check(
            'id="categories-list"' in category_page
            and "Categories" in category_page,
            "category admin page did not render its full shell",
        )
        code, headers, body = browser.form(
            "/admin/categories/action.lsp",
            {
                "_csrf": category_csrf,
                "action": "add",
                "name": "HTMX Category",
                "slug": "",
                "description": "Created through an HTMX fragment",
            },
            headers={"HX-Request": "true"},
        )
        category_fragment = text(body, headers)
        check(
            code == 200
            and "Category added." in category_fragment
            and 'hx-swap-oob="outerHTML"' in category_fragment
            and "htmx-category" in category_fragment,
            f"HTMX category creation returned the wrong fragment: {category_fragment[:1000]}",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            htmx_category_id = conn.execute(
                "SELECT id FROM terms WHERE type='category' AND slug='htmx-category'"
            ).fetchone()[0]

        code, headers, body = browser.form(
            "/admin/categories/action.lsp",
            {
                "_csrf": category_csrf,
                "action": "update",
                "id": str(htmx_category_id),
                "name": "Updated Category",
                "slug": "updated-category",
                "description": "Updated",
            },
            headers={"HX-Request": "true"},
        )
        category_fragment = text(body, headers)
        check(
            code == 200
            and "Saved." in category_fragment
            and "updated-category" in category_fragment
            and "<!doctype" not in category_fragment.lower(),
            f"HTMX category update returned the wrong fragment: {category_fragment[:1000]}",
        )

        create_content(
            browser,
            "/",
            path="/categorized-htmx-post/",
            title="Categorized HTMX Post",
            body="<p>categorized</p>",
            content_type="post",
            category_ids=[htmx_category_id],
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            categorized_post_id = conn.execute(
                "SELECT id FROM content WHERE title='Categorized HTMX Post'"
            ).fetchone()[0]
        _, edit_category_page = admin_get(
            browser, "/", f"content/edit?id={categorized_post_id}"
        )
        check(
            f"name='category_{htmx_category_id}' value='1' checked" in edit_category_page,
            "content editor did not show the assigned category",
        )
        check(
            "<strong>Updated Category</strong></label>" in edit_category_page
            and "<strong>Updated Category</strong><span" not in edit_category_page,
            "content editor duplicated the category label with its slug",
        )
        code, headers, body = browser.request(
            f"/admin/categories/delete.lsp?id={htmx_category_id}",
            headers={"HX-Request": "true"},
        )
        check(
            code == 200
            and "Posts are not deleted." in text(body, headers)
            and b"<!doctype" not in body.lower(),
            "category deletion did not return an inline confirmation",
        )
        code, _, body = browser.form(
            "/admin/categories/delete.lsp",
            {
                "_csrf": category_csrf,
                "id": str(htmx_category_id),
                "confirmed": "true",
            },
            headers={"HX-Request": "true"},
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            deleted_category = conn.execute(
                "SELECT id FROM terms WHERE id=?", (htmx_category_id,)
            ).fetchone()
            preserved_post = conn.execute(
                "SELECT id FROM content WHERE title='Categorized HTMX Post'"
            ).fetchone()
        check(
            code == 200
            and b'id="categories-list"' in body
            and deleted_category is None
            and preserved_post is not None,
            "category deletion did not remove only the category and its assignments",
        )

        create_content(
            browser,
            "/",
            path="/htmx-edit/",
            title="HTMX Edit",
            body="<p>before</p>",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            content_id = conn.execute(
                "SELECT id FROM content WHERE path='/htmx-edit/'"
            ).fetchone()[0]
        code, _, body = browser.request("/htmx-edit/")
        check(
            code == 200 and b"<p>before</p>" in body,
            "content cache warm-up request failed",
        )
        csrf_token, _ = admin_get(browser, "/", f"content/edit?id={content_id}")
        content_fields = {
            "_csrf": csrf_token,
            "id": str(content_id),
            "type": "page",
            "status": "published",
            "title": "HTMX Edited",
            "path": "/htmx-edit/",
            "render_mode": "html",
            "cache_policy": "default",
            "meta_description": "",
            "head_html": "",
            "body_html": "<p>after</p>",
        }
        code, _, _ = browser.form(
            "/admin/content/save.lsp",
            content_fields,
            multipart=True,
        )
        check(code == 404, "content save fragment allowed a non-HTMX POST")
        invalid_fields = dict(content_fields)
        invalid_fields["_csrf"] = "invalid"
        code, _, _ = browser.form(
            "/admin/content/save.lsp",
            invalid_fields,
            multipart=True,
            headers={"HX-Request": "true"},
        )
        check(code == 403, "content save fragment accepted an invalid CSRF token")
        code, headers, body = browser.form(
            "/admin/content/save.lsp",
            content_fields,
            multipart=True,
            headers={"HX-Request": "true"},
        )
        save_fragment = text(body, headers)
        check(
            code == 200
            and "Saved" in save_fragment
            and "<!doctype" not in save_fragment.lower(),
            f"content save did not return a status fragment: {save_fragment}",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            saved = conn.execute(
                "SELECT title,body_html FROM content WHERE id=?", (content_id,)
            ).fetchone()
        check(saved == ("HTMX Edited", "<p>after</p>"), "HTMX content save did not update SQLite")
        code, _, body = browser.request("/htmx-edit/")
        check(
            code == 200
            and b"<p>after</p>" in body
            and b"<p>before</p>" not in body,
            "content save did not invalidate the published-row cache",
        )

        code, headers, body = browser.request(
            f"/admin/content/delete.lsp?id={content_id}",
            headers={"HX-Request": "true"},
        )
        delete_fragment = text(body, headers)
        check(
            code == 200
            and "Delete Permanently" in delete_fragment
            and "<!doctype" not in delete_fragment.lower(),
            "content delete did not return an inline confirmation",
        )
        code, _, body = browser.form(
            "/admin/content/delete.lsp",
            {
                "_csrf": csrf_token,
                "id": str(content_id),
                "confirmed": "true",
            },
            headers={"HX-Request": "true"},
        )
        check(
            code == 200 and b"<!-- content deleted -->" in body,
            "HTMX content deletion did not return an inert row replacement",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            check(
                conn.execute("SELECT id FROM content WHERE id=?", (content_id,)).fetchone()
                is None,
                "HTMX content deletion did not update SQLite",
            )
        code, _, _ = browser.request("/htmx-edit/")
        check(code == 404, "content deletion did not invalidate the published-row cache")

        def add_menu(label: str, url: str, parent_id: int | None, position: int) -> int:
            code, _, _ = admin_post(
                browser,
                "/",
                "menus/",
                {
                    "action": "add",
                    "label": label,
                    "url": url,
                    "parent_id": "" if parent_id is None else str(parent_id),
                    "position": str(position),
                },
            )
            check(code == 200, f"menu fixture creation failed: {label}")
            with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
                return conn.execute(
                    "SELECT id FROM menu_items WHERE label=?", (label,)
                ).fetchone()[0]

        def menu_depth(markup: str, item_id: int) -> int | None:
            match = re.search(
                rf'<form id="menu-item-{item_id}"[^>]*data-menu-depth="(\d+)"',
                markup,
            )
            return int(match.group(1)) if match else None

        parent_id = add_menu("Tree Parent", "/tree-parent/", None, 10)
        child_late_id = add_menu(
            "Tree Child Late", "/tree-parent/late/", parent_id, 20
        )
        child_early_id = add_menu(
            "Tree Child Early", "/tree-parent/early/", parent_id, 10
        )
        grandchild_id = add_menu(
            "Tree Grandchild", "/tree-parent/early/grandchild/", child_early_id, 1
        )
        root_later_id = add_menu("Tree Root Later", "/tree-root-later/", None, 20)
        menu_id = add_menu("HTMX Menu", "/htmx-menu/", None, 80)

        menu_csrf, menu_page = admin_get(browser, "/", "menus/")
        expected_order = (
            parent_id,
            child_early_id,
            grandchild_id,
            child_late_id,
            root_later_id,
            menu_id,
        )
        offsets = [menu_page.index(f'id="menu-item-{item_id}"') for item_id in expected_order]
        check(
            'src="/assets/htmx/htmx.min.js"' in menu_page
            and offsets == sorted(offsets)
            and menu_depth(menu_page, parent_id) == 0
            and menu_depth(menu_page, child_early_id) == 1
            and menu_depth(menu_page, grandchild_id) == 2
            and menu_depth(menu_page, child_late_id) == 1
            and menu_depth(menu_page, root_later_id) == 0
            and "Child of <strong>Tree Parent</strong>" in menu_page,
            "menu LSP page did not render its sorted parent/child tree",
        )
        code, _, _ = browser.request(f"/admin/menus/item.lsp?id={menu_id}")
        check(code == 404, "menu item fragment allowed an ordinary direct request")
        code, _, _ = browser.form(
            "/admin/menus/action.lsp",
            {"_csrf": menu_csrf, "action": "toggle-hidden", "id": str(menu_id)},
        )
        check(code == 404, "menu action fragment allowed a non-HTMX POST")

        code, headers, body = browser.form(
            "/admin/menus/action.lsp",
            {
                "_csrf": menu_csrf,
                "action": "update",
                "id": str(menu_id),
                "label": "HTMX Menu",
                "url": "/htmx-menu/",
                "parent_id": str(parent_id),
                "position": "5",
            },
            headers={"HX-Request": "true"},
        )
        menu_fragment = text(body, headers)
        check(
            code == 200
            and 'id="menu-items"' in menu_fragment
            and menu_depth(menu_fragment, menu_id) == 1
            and menu_fragment.index(f'id="menu-item-{parent_id}"')
            < menu_fragment.index(f'id="menu-item-{menu_id}"')
            < menu_fragment.index(f'id="menu-item-{child_early_id}"')
            and "Saved." in menu_fragment
            and "<!doctype" not in menu_fragment.lower(),
            f"menu update did not re-render and reposition the tree: {menu_fragment[:1200]}",
        )

        code, headers, body = browser.form(
            "/admin/menus/action.lsp",
            {"_csrf": menu_csrf, "action": "toggle-hidden", "id": str(menu_id)},
            headers={"HX-Request": "true"},
        )
        menu_fragment = text(body, headers)
        check(
            code == 200
            and 'id="menu-items"' in menu_fragment
            and f'id="menu-item-{menu_id}"' in menu_fragment
            and ">Show</button>" in menu_fragment
            and menu_depth(menu_fragment, menu_id) == 1
            and "<!doctype" not in menu_fragment.lower(),
            f"menu visibility action did not return the updated tree: {menu_fragment[:1000]}",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            hidden = conn.execute(
                "SELECT hidden FROM menu_items WHERE id=?", (menu_id,)
            ).fetchone()[0]
        check(hidden == 1, "HTMX menu visibility action did not update SQLite")

        code, headers, body = browser.form(
            "/admin/menus/action.lsp",
            {
                "_csrf": menu_csrf,
                "action": "update",
                "id": str(menu_id),
                "label": "HTMX Menu",
                "url": "/htmx-menu/",
                "parent_id": "0",
                "position": "5",
            },
            headers={"HX-Request": "true"},
        )
        menu_fragment = text(body, headers)
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            top_level_parent = conn.execute(
                "SELECT parent_id FROM menu_items WHERE id=?", (menu_id,)
            ).fetchone()[0]
        check(
            code == 200
            and "Saved." in menu_fragment
            and menu_depth(menu_fragment, menu_id) == 0
            and top_level_parent is None,
            f"Parent ID 0 did not move the menu item to top level: {menu_fragment[:1000]}",
        )

        code, headers, body = browser.request(
            f"/admin/menus/delete.lsp?id={menu_id}",
            headers={"HX-Request": "true"},
        )
        check(
            code == 200
            and "Delete Menu Item" in text(body, headers)
            and b"<!doctype" not in body.lower(),
            "menu delete did not return an inline confirmation",
        )
        code, _, body = browser.form(
            "/admin/menus/delete.lsp",
            {
                "_csrf": menu_csrf,
                "id": str(menu_id),
                "confirmed": "true",
            },
            headers={"HX-Request": "true"},
        )
        check(
            code == 200
            and b'id="menu-items"' in body
            and f'id="menu-item-{menu_id}"'.encode() not in body,
            "HTMX menu deletion did not return the updated tree",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            check(
                conn.execute("SELECT id FROM menu_items WHERE id=?", (menu_id,)).fetchone()
                is None,
                "HTMX menu deletion did not update SQLite",
            )

        code, _, body = browser.form(
            "/admin/menus/delete.lsp",
            {
                "_csrf": menu_csrf,
                "id": str(parent_id),
                "confirmed": "true",
            },
            headers={"HX-Request": "true"},
        )
        promoted_fragment = body.decode("utf-8")
        check(
            code == 200
            and f'id="menu-item-{parent_id}"' not in promoted_fragment
            and menu_depth(promoted_fragment, child_early_id) == 0
            and menu_depth(promoted_fragment, child_late_id) == 0
            and menu_depth(promoted_fragment, grandchild_id) == 1,
            "deleting a parent did not re-render its promoted children",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            promoted = conn.execute(
                "SELECT id,parent_id FROM menu_items WHERE id IN (?,?) ORDER BY id",
                (child_early_id, child_late_id),
            ).fetchall()
        check(
            len(promoted) == 2 and all(parent is None for _, parent in promoted),
            "HTMX parent deletion did not promote children in SQLite",
        )

        code, _, _ = admin_post(
            browser,
            "/",
            "users/",
            {"action": "save", "username": "htmxadmin", "password": "htmxpass"},
        )
        check(code == 200, "admin HTMX authentication fixture creation failed")
        unauthorized = Browser(server.origin)
        code, response_headers, body = unauthorized.request(
            "/admin/content/list.lsp",
            headers={"HX-Request": "true"},
        )
        check(
            code == 200
            and response_headers.get("HX-Redirect") == "/admin/"
            and body == b"",
            f"unauthorized HTMX request did not request a full login navigation: "
            f"{code} {response_headers} {body[:300]!r}",
        )

        login = Browser(server.origin)
        code, _, login_body = login.request("/admin/")
        seed = re.search(rb"name='ba_seed' value='([^']*)'", login_body)
        seedkey = re.search(rb"name='ba_seedkey' value='([^']*)'", login_body)
        check(bool(seed and seedkey), "admin HTMX login challenge is missing")
        digest = hashlib.sha1(b"htmxpass" + seed.group(1)).hexdigest()
        code, _, logged_in = login.form(
            "/admin/",
            {
                "ba_username": "htmxadmin",
                "ba_password": digest,
                "ba_seed": seed.group(1).decode(),
                "ba_seedkey": seedkey.group(1).decode(),
            },
        )
        check(code == 200 and b"Dashboard" in logged_in, "admin HTMX login failed")
        code, headers, body = login.request(
            "/admin/content/list.lsp",
            headers={"HX-Request": "true"},
        )
        check(
            code == 200 and 'id="content-list"' in text(body, headers),
            "CMS-admin session could not access a content fragment",
        )
        code, _, _ = login.request("/admin/content/list.lsp")
        check(code == 404, "authenticated direct fragment request was not rejected")

    named_runtime = fresh_runtime("admin-htmx-named")
    with MakoProcess(named_runtime, "mybase") as server:
        browser = Browser(server.origin)
        code, headers, body = browser.request("/mybase/admin/menus/")
        named_page = text(body, headers)
        check(
            code == 200
            and 'src="/mybase/assets/htmx/htmx.min.js"' in named_page
            and 'hx-post="/mybase/admin/menus/action.lsp"' in named_page,
            f"named-mount admin page contains root-relative HTMX URLs: {named_page[:1200]}",
        )
        code, _, _ = browser.request("/mybase/admin/menus/list.lsp")
        check(code == 404, "named-mount menu fragment allowed a direct request")
        code, headers, body = browser.request(
            "/mybase/admin/content/list.lsp?type=page",
            headers={"HX-Request": "true"},
        )
        named_fragment = text(body, headers)
        check(
            code == 200
            and 'hx-push-url="/mybase/admin/content/?type=page"' in named_fragment
            and "<!doctype" not in named_fragment.lower(),
            f"named-mount content fragment is not mount-safe: {named_fragment[:1000]}",
        )


def test_mcp_api() -> None:
    runtime = fresh_runtime("mcp-api")
    shutil.rmtree(runtime / "docs")
    install_zip_theme(runtime)
    (runtime / "assets" / "review-insert-redirect-loop.lsp").write_text(
        """<?lsp
app.db.writeSync(function(conn)
   assert(conn:execute("INSERT OR REPLACE INTO redirects(from_path,to_path,status_code) VALUES('/loop-b/','/loop-a/',302)"))
end)
print("inserted")
?>""",
        encoding="ascii",
    )
    token = "mcp-integration-token-0123456789"
    with MakoProcess(runtime, "mybase") as server:
        browser = Browser(server.origin)
        endpoint = "/mybase/mcp/"

        code, _, body = browser.request(
            endpoint,
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        check(code == 503 and b"disabled" in body.lower(), "MCP was enabled before a token was configured")

        configure_mcp(browser, "/mybase/", token)
        code, headers, body = browser.request("/mybase/admin/mcp/")
        mcp_admin = text(body, headers)
        check(
            code == 200
            and "name='action' value='save'" in mcp_admin
            and "name='action' value='disable' formnovalidate" in mcp_admin
            and mcp_admin.count("<form method='post'>") == 1,
            "MCP admin actions are not grouped in one form",
        )
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            stored = conn.execute(
                "SELECT value FROM options WHERE key='mcp_token_encrypted'"
            ).fetchone()[0]
        check(token not in stored and stored.startswith("v1:"), "MCP token is not encrypted at rest")

        inspector_origin = "http://localhost:6274"
        code, headers, _ = browser.request(
            endpoint,
            headers={
                "Origin": inspector_origin,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization,content-type",
            },
            method="OPTIONS",
        )
        check(code == 204, f"MCP Inspector preflight returned {code}")
        check(
            headers.get("Access-Control-Allow-Origin") == inspector_origin,
            "MCP Inspector origin was not returned by CORS",
        )
        code, _, _ = browser.request(
            endpoint,
            headers={
                "Origin": "https://not-loopback.example",
                "Access-Control-Request-Method": "POST",
            },
            method="OPTIONS",
        )
        check(code == 403, "non-loopback cross-origin MCP preflight was accepted")

        code, _, _ = browser.request(
            endpoint,
            data=b"{}",
            headers={
                "Authorization": "Bearer wrong-token",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        check(code in (401, 403), f"wrong MCP bearer token was not rejected: {code}")

        client = McpClient(browser, endpoint, token, inspector_origin)
        initialized = client.initialize()
        check(initialized["serverInfo"]["name"] == "FuguHub", "unexpected MCP server identity")
        check(
            "getCapabilities" in initialized.get("instructions", "")
            and "realTimeMessaging.smq" in initialized.get("instructions", "")
            and "not a separate MCP mutation tool"
            in initialized.get("instructions", ""),
            "MCP initialization did not include CMS instructions",
        )
        listed = client.rpc("tools/list")
        tool_names = {tool["name"] for tool in listed["tools"]}
        expected = {
            "getCmsInfo",
            "listContent",
            "getContent",
            "getContentBatch",
            "getContentDependencies",
            "validateContent",
            "createContent",
            "copyContent",
            "updateContent",
            "setContentStatus",
            "deleteContent",
            "getCapabilities",
            "listGuides",
            "getGuide",
            "searchHelp",
            "getExample",
            "listMenus",
            "getMenuLocations",
            "createMenu",
            "updateMenu",
            "deleteMenu",
            "createMenuItem",
            "updateMenuItem",
            "deleteMenuItem",
            "listRedirects",
            "setRedirect",
            "deleteRedirect",
            "listTerms",
            "createTerm",
            "updateTerm",
            "deleteTerm",
            "getSettings",
            "updateSettings",
            "listThemes",
            "validateTheme",
            "activateTheme",
            "getHealth",
            "getSchemaInfo",
            "runIntegrityCheck",
            "clearCache",
            "prepareContentExport",
            "prepareContentTransfer",
            "importContentTransfer",
            "readRuntimeTrace",
            "getAssetCapabilities",
            "listAssets",
            "getAsset",
            "getAssetDependencies",
            "testPublicPath",
            "prepareAssetDownload",
            "validateAssetCode",
            "writeTextAsset",
            "restartAssetsApplication",
            "prepareAssetUpload",
            "createAssetDirectory",
            "moveAsset",
            "deleteAsset",
            "prepareAssetsExport",
            "prepareAssetsImport",
            "listThemeFiles",
            "getThemeFile",
            "listThemeDrafts",
            "createThemeDraft",
            "listThemeDraftFiles",
            "getThemeDraftFile",
            "writeThemeDraftText",
            "prepareThemeDraftUpload",
            "prepareThemeDraftDownload",
            "commitThemeDraft",
            "prepareThemeFileDownload",
            "prepareThemeExport",
            "deleteThemeDraftFile",
            "validateThemeDraft",
            "discardThemeDraft",
            "listReferences",
            "getReference",
            "getContentAuthoringContract",
        }
        check(expected <= tool_names, f"MCP tools are missing: {sorted(expected - tool_names)}")

        capabilities = mcp_structured(client.call("getCapabilities"))
        check(
            capabilities["cms"]["mcpApiVersion"] == "0.7.0"
            and capabilities["cms"]["mcpDesignStatus"] == "milestone"
            and capabilities["cms"]["mcpMilestone"] == "mcp-api-0.7.0"
            and capabilities["cms"]["mcpMilestoneDate"] == "2026-07-28"
            and capabilities["runtime"]["baseUri"] == "/mybase/"
            and capabilities["transferCompatibility"]["format"] == "fuguhub-content",
            f"MCP capabilities are incomplete: {capabilities}",
        )
        check(
            capabilities["modules"]["revisions"] is False,
            "MCP capabilities did not report an unavailable module",
        )
        check(
            capabilities["modules"]["assetManagement"] is True
            and capabilities["modules"]["runtimeTrace"] is True
            and capabilities["runtime"]["themeContract"]["rendersContentTitle"] is True,
            f"MCP asset, trace, or theme capabilities are incomplete: {capabilities}",
        )
        check(
            capabilities["modules"]["embeddedGuides"] is True
            and capabilities["modules"]["lspHtmxPattern"] is True
            and capabilities["modules"]["smq"] is True
            and capabilities["modules"]["smqEnabled"] is False
            and capabilities["applicationModel"]["mountSafeUrlHelper"] == "app.url"
            and capabilities["applicationModel"]["databaseLspCompiler"] == "ba.parselsp"
            and capabilities["applicationModel"]["publicApp"] == "app.assetsApp or app"
            and capabilities["applicationModel"]["smqApi"]["registerRpc"]
            == "app.smq:registerRpcMethod"
            and capabilities["applicationModel"]["smqApi"]["brokerStart"]
            == "app.smq:onBrokerStart"
            and capabilities["realTimeMessaging"]["smq"]["available"] is True
            and capabilities["realTimeMessaging"]["smq"]["enabled"] is False
            and capabilities["realTimeMessaging"]["smq"]["requiresHtmx"] is True
            and capabilities["realTimeMessaging"]["smq"]["endpoint"]
            == "/mybase/SMQ/"
            and capabilities["realTimeMessaging"]["smq"]["guideId"] == "smq"
            and capabilities["realTimeMessaging"]["smq"]["referenceId"] == "smq"
            and capabilities["realTimeMessaging"]["smq"]["serverApi"] == "app.smq"
            and capabilities["realTimeMessaging"]["smq"]["browserApi"]
            == "window.cmsSmq.mountPage"
            and capabilities["assetApplication"]["preloadPath"] == "assets/.preload"
            and capabilities["assetApplication"]["moduleRoot"] == "assets/.lua/"
            and capabilities["assetApplication"]["moduleLoader"] == "assetsreq"
            and capabilities["assetApplication"]["moduleCacheRequiresPreload"] is True
            and capabilities["assetApplication"]["reloadTool"] == "restartAssetsApplication"
            and capabilities["assetApplication"]["reloadRequiresConfirmation"] is True
            and capabilities["themeManagement"]["listTool"] == "listThemes"
            and capabilities["themeManagement"]["validateTool"] == "validateTheme"
            and capabilities["themeManagement"]["activateTool"] == "activateTheme"
            and capabilities["themeManagement"]["createDraftTool"]
            == "createThemeDraft"
            and capabilities["themeManagement"]["validateDraftTool"]
            == "validateThemeDraft"
            and capabilities["themeManagement"]["commitDraftTool"]
            == "commitThemeDraft"
            and capabilities["themeManagement"]["exportTool"]
            == "prepareThemeExport"
            and capabilities["themeManagement"]["activationRequiresConfirmation"] is True
            and capabilities["themeManagement"]["commitRequiresConfirmation"] is True
            and capabilities["themeManagement"]["executableConfirmationRequired"]
            is True
            and capabilities["themeManagement"]["commitFormat"] == "zip"
            and capabilities["themeManagement"]["commitActivatesTheme"] is False
            and capabilities["themeManagement"]["draftsPersistent"] is True
            and capabilities["themeManagement"]["activeThemeReplacementAllowed"]
            is True
            and capabilities["themeManagement"][
                "activeThemeReplacementAutomaticForConfirmedCommit"
             ]
             is True
            and capabilities["themeManagement"][
                "activeThemeReplacementRequiresSeparateConfirmation"
            ]
            is False
            and capabilities["themeManagement"][
                "activeThemeReplacementReloadsImmediately"
            ]
            is True
            and capabilities["themeManagement"]["canCreate"] is True
            and capabilities["themeManagement"]["canModify"] is True
            and capabilities["themeManagement"]["canUpload"] is True
            and capabilities["themeManagement"]["canDownload"] is True
            and capabilities["themeManagement"]["canDelete"] is False
            and capabilities["themeManagement"]["canDeleteInstalled"] is False
            and capabilities["themeManagement"]["canDeleteDraft"] is True
            and capabilities["themeManagement"]["canReadSource"] is True
            and capabilities["themeManagement"]["canImportPackage"] is False
            and capabilities["themeManagement"]["canPerformVisualQa"] is False
            and capabilities["limits"]["themeTextFileBytes"] == 4 * 1024 * 1024
            and capabilities["limits"]["themeBinaryFileBytes"] == 32 * 1024 * 1024
            and capabilities["limits"]["themeArchiveBytes"] == 64 * 1024 * 1024
            and capabilities["limits"]["themeEntries"] == 2048
            and capabilities["limits"]["themeTicketSeconds"] == 300
            and capabilities["modules"]["themeDrafts"] is True
            and capabilities["modules"]["themeFileManagement"] is True
            and capabilities["modules"]["themeZipExport"] is True
            and "lsp-htmx" in capabilities["supported"]["applicationPatterns"]
            and "smq-page-scopes"
            in capabilities["supported"]["applicationPatterns"]
            and capabilities["supported"]["smqEndpoint"] == "/mybase/SMQ/"
            and capabilities["applicationModel"]["urlNamespaces"]["siteAsset"][
                "publicUrlExample"
            ]
            == "/mybase/chat/chat.js"
            and "do not prepend /assets"
            in capabilities["applicationModel"]["urlNamespaces"]["siteAsset"][
                "rule"
            ]
            and capabilities["applicationModel"]["urlNamespaces"]["themeAsset"][
                "publicUrlExample"
            ]
            == "/mybase/theme/images/logo.png"
            and capabilities["applicationModel"]["urlNamespaces"]["cmsAsset"][
                "publicUrlExample"
            ]
            == "/mybase/assets/htmx/htmx.min.js"
            and capabilities["applicationModel"]["urlNamespaces"]["makoSystem"][
                "publicUrlExample"
            ]
            == "/rtl/smq.js",
            f"MCP application runtime contracts are incomplete: {capabilities}",
        )
        check(
            all(item["class"] != "unknown" for item in capabilities["operations"]),
            f"MCP capabilities contain unclassified tools: {capabilities['operations']}",
        )
        check(
            any(
                item["feature"] == "mediaLibrary"
                for item in capabilities["unavailable"]
            ),
            "MCP capabilities omitted unavailable structural features",
        )

        guides = mcp_structured(client.call("listGuides"))
        guide_catalog = {guide["id"]: guide for guide in guides["guides"]}
        check(
            {
                "site-builder",
                "assets",
                "database",
                "lsp",
                "lsp-htmx",
                "smq",
                "themes",
                "deployment",
                "mcp",
            }
            <= guide_catalog.keys()
            and all(guide_catalog[guide_id]["available"] for guide_id in guide_catalog)
            and "lsp" in guide_catalog["site-builder"]["relatedGuides"],
            f"MCP guide catalog is incomplete: {guides}",
        )
        for guide_id in guide_catalog:
            packaged_guide = mcp_structured(
                client.call("getGuide", {"id": guide_id})
            )
            packaged_text = packaged_guide["content"]
            check(
                "## Remote MCP Boundary" in packaged_text
                and "HTTP MCP" in packaged_text
                and ".info/guides/" not in packaged_text
                and re.search(r"\]\([^)]*\.md(?:#[^)]*)?\)", packaged_text)
                is None,
                f"MCP guide {guide_id} exposes filesystem-oriented navigation",
            )
        guide = mcp_structured(client.call("getGuide", {"id": "lsp"}))
        check(
            "assets/.preload" in guide["content"]
            and "assetsreq" in guide["content"]
            and "site-builder" in guide["relatedGuides"],
            "MCP LSP guide content is incomplete",
        )
        asset_guide = mcp_structured(client.call("getGuide", {"id": "assets"}))
        check(
            "chat/chat.js" in asset_guide["content"]
            and "/assets/chat/chat.js" in asset_guide["content"]
            and "URL Namespaces" in asset_guide["content"]
            and "Themes Must Stay Generic" in asset_guide["content"]
            and "page-specific" in asset_guide["content"]
            and "page-owned" in asset_guide["content"]
            and "Inline scripts" in asset_guide["content"]
            and "execute" in asset_guide["content"]
            and "testPublicPath" in asset_guide["content"],
            "MCP site asset guide is incomplete",
        )
        htmx_guide = mcp_structured(client.call("getGuide", {"id": "lsp-htmx"}))
        check(
            "HX-Redirect" in htmx_guide["content"]
            and "request:multipart()" in htmx_guide["content"]
            and "session.isCmsAdmin" in htmx_guide["content"],
            "MCP LSP and HTMX guide content is incomplete",
        )
        smq_guide = mcp_structured(client.call("getGuide", {"id": "smq"}))
        check(
            "window.cmsSmq.mountPage" in smq_guide["content"]
            and "app.smq:registerRpcMethod" in smq_guide["content"]
            and "app.smq:onBrokerStart" in smq_guide["content"]
            and "SMQ.Client" in smq_guide["content"],
            "MCP SMQ guide content is incomplete",
        )
        theme_guide = mcp_structured(client.call("getGuide", {"id": "themes"}))
        check(
            "createThemeDraft" in theme_guide["content"]
            and "prepareThemeDraftUpload" in theme_guide["content"]
            and "validateThemeDraft" in theme_guide["content"]
            and "commitThemeDraft" in theme_guide["content"]
            and "same-name active target" in theme_guide["content"]
            and 'app.appreq "cmshttp"' in theme_guide["content"]
            and 'require("cmshttp")' not in theme_guide["content"],
            "MCP theme authoring guide is incomplete",
        )
        help_matches = mcp_structured(
            client.call("searchHelp", {"query": "writer thread", "limit": 5})
        )
        check(help_matches["matches"], "MCP help search returned no matches")
        assetsreq_matches = mcp_structured(
            client.call("searchHelp", {"query": "assetsreq", "limit": 5})
        )
        check(
            any(
                match.get("guideId") in {"site-builder", "lsp"}
                and "assetsreq" in match.get("excerpt", "")
                for match in assetsreq_matches["matches"]
            ),
            f"MCP help search did not discover assetsreq: {assetsreq_matches}",
        )
        smq_matches = mcp_structured(
            client.call("searchHelp", {"query": "SMQ", "limit": 5})
        )
        check(
            any(
                match.get("guideId") in {"site-builder", "smq"}
                and "SMQ" in match.get("excerpt", "")
                for match in smq_matches["matches"]
            ),
            f"MCP help search omitted SMQ guidance: {smq_matches}",
        )
        example = mcp_structured(client.call("getExample", {"id": "mount-safe-link"}))
        check("app.url" in example["content"], "MCP example content is incomplete")
        theme_link_example = mcp_structured(
            client.call("getExample", {"id": "theme-link"})
        )
        site_asset_example = mcp_structured(
            client.call("getExample", {"id": "site-asset-link"})
        )
        check(
            "model.url('/theme/style.css')" in theme_link_example["content"]
            and "model.url('/chat/chat.js')" in site_asset_example["content"]
            and "model.url('/assets/chat/chat.js')" in site_asset_example["content"],
            "MCP URL namespace examples are incomplete",
        )
        assetsreq_example = mcp_structured(
            client.call("getExample", {"id": "assetsreq-module"})
        )
        htmx_example = mcp_structured(
            client.call("getExample", {"id": "lsp-htmx-fragment"})
        )
        check(
            "assetsreq" in assetsreq_example["content"]
            and "HX-Request" in htmx_example["content"]
            and "app.url" in htmx_example["content"],
            "MCP application examples are incomplete",
        )
        references = mcp_structured(client.call("listReferences"))
        reference_ids = {item["id"] for item in references["references"]}
        check(
            {"bas-api", "vfs", "authentication", "owasp", "smq", "sqlite"}
            <= reference_ids,
            f"MCP references are incomplete: {references}",
        )
        bas_reference = mcp_structured(
            client.call("getReference", {"id": "bas-api"})
        )
        smq_reference = mcp_structured(
            client.call("getReference", {"id": "smq"})
        )
        check(
            bas_reference["authoritative"] is True
            and bas_reference["url"].endswith("/basapi.md")
            and smq_reference["authoritative"] is True
            and smq_reference["url"].endswith("/SMQ-Skill.md"),
            "MCP BAS or SMQ reference routing is wrong: "
            f"{bas_reference}, {smq_reference}",
        )
        authoring = mcp_structured(client.call("getContentAuthoringContract"))
        check(
            authoring["contract"]["rendersContentTitle"] is True
            and authoring["contract"]["recommendedBodyHeadingStart"] == 2
            and "Promote" in authoring["markdownRule"],
            f"MCP theme authoring contract is wrong: {authoring}",
        )

        resources = client.rpc("resources/list")["resources"]
        resource_uris = {resource["uri"] for resource in resources}
        check(
            {"fuguhub://instructions", "fuguhub://capabilities"} <= resource_uris,
            f"MCP resources are missing: {resources}",
        )
        instructions_resource = client.rpc(
            "resources/read", {"uri": "fuguhub://instructions"}
        )
        instructions_text = instructions_resource["contents"][0]["text"]
        check(
            "Every interaction with this deployed CMS must use the HTTP MCP API"
            in instructions_text
            and "open its SQLite database directly" in instructions_text
            and "MCP API `0.7.0`" in instructions_text
            and "completed initial design milestone" in instructions_text
            and "Use the theme draft tools" in instructions_text
            and "commitThemeDraft" in instructions_text
            and "realTimeMessaging.smq" in instructions_text
            and "not a separate MCP mutation tool" in instructions_text
            and "`assets` guide" in instructions_text
            and "not `/assets/chat/chat.js`" in instructions_text
            and "path-specific theme" in instructions_text
            and "report it as unsupported" in instructions_text,
            "MCP instructions do not enforce the remote API boundary",
        )
        guide_resource = client.rpc(
            "resources/read", {"uri": "fuguhub://guides/lsp-htmx"}
        )
        check(
            "HTMX" in guide_resource["contents"][0]["text"],
            f"MCP guide resource is incomplete: {guide_resource}",
        )
        prompts = client.rpc("prompts/list")["prompts"]
        prompt_names = {prompt["name"] for prompt in prompts}
        check(
            {
                "createCmsContent",
                "importHtmlContent",
                "buildCmsLspApp",
                "buildCmsHtmxApp",
                "manageCmsTheme",
            }
            <= prompt_names,
            f"MCP prompts are missing: {prompts}",
        )
        check("createCmsTheme" not in prompt_names, f"obsolete MCP prompt remains: {prompts}")
        content_prompt = client.rpc(
            "prompts/get",
            {"name": "createCmsContent", "arguments": {"userRequest": "Create a page"}},
        )
        check(
            "Create a page" in content_prompt["messages"][0]["content"]["text"],
            f"MCP content prompt did not include its argument: {content_prompt}",
        )
        htmx_prompt = client.rpc(
            "prompts/get",
            {
                "name": "buildCmsHtmxApp",
                "arguments": {"userGoal": "Build an editable job queue"},
            },
        )
        htmx_prompt_text = htmx_prompt["messages"][0]["content"]["text"]
        check(
            "Build an editable job queue" in htmx_prompt_text
            and "assetManagement" in htmx_prompt_text
            and "lspHtmxPattern" in htmx_prompt_text
            and "realTimeMessaging.smq" in htmx_prompt_text
            and "window.cmsSmq" in htmx_prompt_text
            and "multipart" in htmx_prompt_text
            and "named mounts" in htmx_prompt_text
            and "`assets` guide" in htmx_prompt_text
            and "`publicUrl`" in htmx_prompt_text
            and "path-specific condition" in htmx_prompt_text,
            f"MCP HTMX prompt is incomplete: {htmx_prompt}",
        )
        theme_prompt = client.rpc(
            "prompts/get",
            {
                "name": "manageCmsTheme",
                "arguments": {"userGoal": "Activate the Default theme"},
            },
        )
        theme_prompt_text = theme_prompt["messages"][0]["content"]["text"]
        check(
            "`assets` guide" in theme_prompt_text
            and "model.url('/chat/chat.js')" in theme_prompt_text
            and "path condition" in theme_prompt_text
            and "`publicUrl`" in theme_prompt_text,
            f"MCP theme prompt omits site asset boundaries: {theme_prompt}",
        )
        normalized_theme_prompt = " ".join(theme_prompt_text.split())
        check(
            "Activate the Default theme" in normalized_theme_prompt
            and "createThemeDraft" in normalized_theme_prompt
            and "validateThemeDraft" in normalized_theme_prompt
            and "commitThemeDraft" in normalized_theme_prompt
            and "same name as the active theme" in normalized_theme_prompt
            and "listThemes" in normalized_theme_prompt
            and "validateTheme" in normalized_theme_prompt
            and "activateTheme" in normalized_theme_prompt,
            f"MCP theme-management prompt is inconsistent: {theme_prompt}",
        )
        import_prompt = client.rpc(
            "prompts/get",
            {
                "name": "importHtmlContent",
                "arguments": {"userRequest": "Import saved article.html"},
            },
        )
        import_text = import_prompt["messages"][0]["content"]["text"]
        check(
            "Import saved article.html" in import_text
            and "source charset" in import_text
            and "desktop and mobile" in import_text
            and "does not prove correct character encoding" in import_text,
            f"MCP legacy HTML import prompt is incomplete: {import_prompt}",
        )

        info = mcp_structured(client.call("getCmsInfo"))
        check(
            info["baseUri"] == "/mybase/"
            and info["mcpPath"] == "/mybase/mcp/"
            and info["settings"]["smqEnabled"] is False,
            f"MCP metadata is not mount-aware: {info}",
        )

        draft = mcp_structured(
            client.call(
                "createContent",
                {
                    "type": "page",
                    "path": "/mcp-draft/",
                    "title": "MCP Draft",
                    "bodyHtml": "<section><p>Created through MCP.</p></section>",
                    "terms": [
                        {
                            "type": "category",
                            "name": "MCP",
                            "slug": "mcp",
                            "description": "MCP content",
                        }
                    ],
                },
            )
        )
        check(draft["status"] == "draft", "MCP content was not draft by default")
        code, _, _ = browser.request("/mybase/mcp-draft/")
        check(code == 404, "draft content was publicly visible")

        unicode_v1 = chr(0x1F44D)
        unicode_v2 = chr(0x1F680) + chr(0x10437) + chr(0x1F44D)
        unicode_created = mcp_structured(
            client.call(
                "createContent",
                {
                    "type": "page",
                    "path": "/mcp-unicode/",
                    "title": "Unicode MCP",
                    "bodyHtml": f"<section><p>Initial {unicode_v1}</p></section>",
                },
            )
        )
        check(
            unicode_v1 in unicode_created["bodyHtml"],
            f"MCP create response corrupted non-BMP Unicode: {unicode_created}",
        )
        unicode_read = mcp_structured(
            client.call("getContent", {"id": unicode_created["id"]})
        )
        check(
            unicode_read["bodyHtml"] == unicode_created["bodyHtml"],
            f"MCP content read corrupted non-BMP Unicode: {unicode_read}",
        )
        unicode_batch = mcp_structured(
            client.call(
                "getContentBatch",
                {"ids": [unicode_created["id"]], "includeBody": True},
            )
        )
        check(
            unicode_batch["items"][0]["bodyHtml"] == unicode_created["bodyHtml"],
            f"MCP batch read corrupted non-BMP Unicode: {unicode_batch}",
        )
        unicode_list = mcp_structured(
            client.call(
                "listContent",
                {"query": "Unicode MCP", "includeBody": True, "limit": 10},
            )
        )
        check(
            len(unicode_list["items"]) == 1
            and unicode_list["items"][0]["bodyHtml"] == unicode_created["bodyHtml"],
            f"MCP list read corrupted non-BMP Unicode: {unicode_list}",
        )
        unicode_updated = mcp_structured(
            client.call(
                "updateContent",
                {
                    "id": unicode_created["id"],
                    "bodyHtml": f"<section><p>Updated {unicode_v2}</p></section>",
                    "expectedUpdatedAt": unicode_created["updatedAt"],
                },
            )
        )
        check(
            unicode_v2 in unicode_updated["bodyHtml"],
            f"MCP update response corrupted non-BMP Unicode: {unicode_updated}",
        )
        unicode_stale = client.call(
            "updateContent",
            {
                "id": unicode_created["id"],
                "title": "Stale Unicode Update",
                "expectedUpdatedAt": unicode_created["updatedAt"],
            },
        )
        check(
            unicode_stale.get("isError") is True
            and unicode_stale["structuredContent"]["code"] == "contentConflict",
            f"MCP stale Unicode retry did not return contentConflict: {unicode_stale}",
        )
        admin_csrf, _ = admin_get(
            browser,
            "/mybase/",
            f"content/edit?id={unicode_created['id']}",
        )
        admin_unicode_fields = {
            "_csrf": admin_csrf,
            "id": str(unicode_created["id"]),
            "type": "page",
            "status": "draft",
            "title": "Unicode Admin Edit",
            "path": "/mcp-unicode/",
            "render_mode": "html",
            "cache_policy": "default",
            "meta_description": "",
            "head_html": "",
            "body_html": f"<section><p>Admin {unicode_v2}</p></section>",
        }
        admin_revisions = []
        for title in ("Unicode Admin Edit One", "Unicode Admin Edit Two"):
            admin_unicode_fields["title"] = title
            code, _, _ = browser.form(
                "/mybase/admin/content/save.lsp",
                admin_unicode_fields,
                multipart=True,
                headers={"HX-Request": "true"},
            )
            check(code == 200, f"back-to-back admin content save failed: {code}")
            with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
                admin_revisions.append(
                    conn.execute(
                        "SELECT updated_at FROM content WHERE id=?",
                        (unicode_created["id"],),
                    ).fetchone()[0]
                )
        check(
            admin_revisions[0] > unicode_updated["updatedAt"]
            and admin_revisions[1] > admin_revisions[0],
            f"admin content revisions were not monotonic: "
            f"{unicode_updated['updatedAt']} -> {admin_revisions}",
        )
        stale_after_admin = client.call(
            "updateContent",
            {
                "id": unicode_created["id"],
                "title": "Overwrite Admin Edit",
                "expectedUpdatedAt": unicode_updated["updatedAt"],
            },
        )
        check(
            stale_after_admin.get("isError") is True
            and stale_after_admin["structuredContent"]["code"] == "contentConflict",
            f"admin saves did not invalidate an MCP revision: {stale_after_admin}",
        )
        unicode_export = mcp_structured(
            client.call("prepareContentExport", {"ids": [unicode_created["id"]]})
        )
        code, _, unicode_archive_body = browser.request(
            unicode_export["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(code == 200, f"MCP Unicode export returned {code}")
        with zipfile.ZipFile(io.BytesIO(unicode_archive_body)) as archive:
            unicode_manifest = json.loads(archive.read(".fuguhub-content.json"))
        check(
            unicode_manifest["items"][0]["bodyHtml"] == admin_unicode_fields["body_html"]
            and unicode_manifest["items"][0]["title"] == admin_unicode_fields["title"],
            f"MCP Unicode export corrupted content: {unicode_manifest}",
        )

        first_page = mcp_structured(
            client.call(
                "listContent",
                {"sort": "id", "direction": "asc", "limit": 1},
            )
        )
        check(
            len(first_page["items"]) == 1
            and first_page["hasMore"] is True
            and "nextCursor" in first_page
            and "bodyHtml" not in first_page["items"][0],
            f"MCP content pagination summary is wrong: {first_page}",
        )
        second_page = mcp_structured(
            client.call(
                "listContent",
                {
                    "sort": "id",
                    "direction": "asc",
                    "limit": 1,
                    "cursor": first_page["nextCursor"],
                    "includeBody": True,
                },
            )
        )
        check(
            second_page["items"][0]["id"] != first_page["items"][0]["id"]
            and "bodyHtml" in second_page["items"][0],
            f"MCP content cursor did not advance: {second_page}",
        )
        searched = mcp_structured(
            client.call(
                "listContent",
                {
                    "query": "MCP Draft",
                    "termType": "category",
                    "termSlug": "mcp",
                    "includeTerms": True,
                    "includeTotal": True,
                },
            )
        )
        check(
            len(searched["items"]) == 1
            and searched["items"][0]["id"] == draft["id"]
            and searched["items"][0]["terms"][0]["slug"] == "mcp"
            and searched["total"] == 1,
            f"MCP content search/filter result is wrong: {searched}",
        )
        validated = mcp_structured(
            client.call(
                "validateContent",
                {
                    "bodyHtml": '<section><a href="/missing/">Missing</a></section>',
                    "renderMode": "html",
                },
            )
        )
        check(
            validated["valid"] is True and validated["warnings"],
            f"MCP content validation omitted warnings: {validated}",
        )
        safe_form = mcp_structured(
            client.call(
                "validateContent",
                {
                    "bodyHtml": (
                        '<form action="/contact/" method="post">'
                        '<button formaction="https://example.com/submit">Send</button>'
                        "</form>"
                    ),
                    "renderMode": "html",
                },
            )
        )
        check(safe_form["valid"] is True, "safe form URL attributes were rejected")
        invalid_validation = client.call(
            "validateContent",
            {"bodyHtml": "<script>alert(1)</script>", "renderMode": "html"},
        )
        check(
            invalid_validation.get("isError") is True,
            "MCP no-save validation accepted unsafe HTML",
        )
        code_listing = mcp_structured(
            client.call(
                "validateContent",
                {
                    "title": "Callbacks",
                    "bodyHtml": (
                        '<pre><code class="language-lua">'
                        "onpublish=function(client,topic)\n"
                        "onerror=function(client,etype)"
                        "</code></pre>"
                    ),
                    "renderMode": "html",
                },
            )
        )
        check(code_listing["valid"] is True, "callback text in a code block was rejected")
        for unsafe in (
            '<img src="x" onerror="alert(1)">',
            '<button onclick="run()">Run</button>',
            '<div ONLOAD="run()"></div>',
            '<a href="jav&#x61;script:alert(1)">Unsafe</a>',
            '<a href="  javascript:alert(1)">Unsafe</a>',
            '<iframe srcdoc="<script>alert(1)</script>"></iframe>',
            '<object data="https://example.com/active"></object>',
            '<form action="javascript:alert(1)"><button>Send</button></form>',
            '<button formaction="data:text/html,unsafe">Send</button>',
            '<svg><a xlink:href="javascript:alert(1)">Unsafe</a></svg>',
            '<img src="vbscript:msgbox(1)">',
            '<!DOCTYPE html><p>Document wrapper</p>',
        ):
            rejected = client.call(
                "validateContent", {"bodyHtml": unsafe, "renderMode": "html"}
            )
            check(
                rejected.get("isError") is True,
                f"MCP structural validator accepted unsafe HTML: {unsafe}",
            )
        duplicate_heading = mcp_structured(
            client.call(
                "validateContent",
                {
                    "title": "Duplicate",
                    "bodyHtml": "<h1>Duplicate</h1><p>Body</p>",
                    "renderMode": "html",
                },
            )
        )
        check(
            any("active theme renders" in warning for warning in duplicate_heading["warnings"]),
            f"theme-aware validation omitted duplicate H1 warning: {duplicate_heading}",
        )
        valid_lsp = mcp_structured(
            client.call(
                "validateContent",
                {
                    "bodyHtml": "<p><?lsp= 6 * 7 ?></p>",
                    "renderMode": "lsp",
                },
            )
        )
        check(valid_lsp["compiled"] is True, "MCP LSP validation did not compile source")
        invalid_lsp = client.call(
            "validateContent",
            {
                "bodyHtml": "<?lsp if then ?>",
                "renderMode": "lsp",
            },
        )
        check(
            invalid_lsp.get("isError") is True,
            "MCP LSP validation accepted invalid Lua",
        )

        asset_caps = mcp_structured(client.call("getAssetCapabilities"))
        check(
            asset_caps["source"] == "directory"
            and asset_caps["writable"] is True
            and "readOnlyReason" not in asset_caps
            and asset_caps["guideId"] == "assets"
            and "not /assets/chat/chat.js" in asset_caps["publicPathRule"]
            and asset_caps["cmsOwnedPublicPrefix"] == "/mybase/assets/"
            and asset_caps["activation"]["preloadRestartRequired"] is True
            and asset_caps["activation"]["restartMethod"]
            == "restartAssetsApplication"
            and asset_caps["activation"]["luaPreloadMakoRestartRequired"] is False
            and asset_caps["executablePolicy"]["assetsApplicationRestartSupported"]
            is True,
            f"MCP asset capabilities are wrong: {asset_caps}",
        )
        missing_asset = client.call("getAsset", {"path": "mcp-assets/missing.txt"})
        check(
            missing_asset.get("isError") is True
            and missing_asset["structuredContent"]["code"] == "assetNotFound"
            and missing_asset["structuredContent"]["path"] == "mcp-assets/missing.txt",
            f"MCP missing asset error is not actionable: {missing_asset}",
        )
        missing_dependencies = client.call(
            "getAssetDependencies", {"path": "mcp-assets/missing.txt"}
        )
        check(
            missing_dependencies.get("isError") is True
            and missing_dependencies["structuredContent"]["code"] == "assetNotFound"
            and missing_dependencies["structuredContent"]["path"]
            == "mcp-assets/missing.txt",
            f"MCP missing dependency error is not actionable: {missing_dependencies}",
        )
        invalid_asset_json = client.call(
            "validateAssetCode",
            {"path": "mcp-assets/bad.json", "content": '{"value": }'},
        )
        invalid_json_details = invalid_asset_json.get("structuredContent", {})
        check(
            invalid_asset_json.get("isError") is True
            and invalid_json_details.get("code") == "assetValidationFailed"
            and invalid_json_details.get("kind") == "json"
            and invalid_json_details.get("path") == "mcp-assets/bad.json"
            and invalid_json_details.get("message"),
            f"MCP JSON validation diagnostics are incomplete: {invalid_asset_json}",
        )
        valid_asset_json = mcp_structured(
            client.call(
                "validateAssetCode",
                {"path": "mcp-assets/good.json", "content": '{"value": true}'},
            )
        )
        check(
            valid_asset_json["warnings"] == [],
            f"MCP empty validation warnings are not an array: {valid_asset_json}",
        )
        created_css = mcp_structured(
            client.call(
                "writeTextAsset",
                {"path": "mcp-assets/site.css", "content": "body { color: #123456; }\n"},
            )
        )
        check(
            created_css["restartRequired"] is False
            and created_css["publicUrl"] == "/mybase/mcp-assets/site.css",
            f"MCP text asset creation is wrong: {created_css}",
        )
        check(
            created_css["validationWarnings"] == [],
            f"MCP empty write warnings are not an array: {created_css}",
        )
        code, _, body = browser.request("/mybase/mcp-assets/site.css")
        check(code == 200 and b"#123456" in body, "new CSS asset was not immediately public")
        public_css = mcp_structured(
            client.call(
                "testPublicPath",
                {"path": "/mybase/mcp-assets/site.css", "maxBytes": 4096},
            )
        )
        check(
            public_css["status"] == 200
            and public_css["path"] == "/mybase/mcp-assets/site.css"
            and "#123456" in public_css["bodyExcerpt"]
            and public_css["truncated"] is False,
            f"MCP public-path CSS test failed: {public_css}",
        )
        truncated_css = mcp_structured(
            client.call(
                "testPublicPath",
                {"path": "/mybase/mcp-assets/site.css", "maxBytes": 4},
            )
        )
        check(
            truncated_css["truncated"] is True
            and truncated_css["bytesRead"] == 4
            and "excerptSha256" in truncated_css
            and "sha256" not in truncated_css,
            f"MCP bounded public-path response is wrong: {truncated_css}",
        )
        public_head = mcp_structured(
            client.call(
                "testPublicPath",
                {"path": "/mybase/mcp-assets/site.css", "method": "HEAD"},
            )
        )
        check(
            public_head["status"] == 200
            and public_head["method"] == "HEAD"
            and "bodyExcerpt" not in public_head,
            f"MCP public-path HEAD test failed: {public_head}",
        )
        external_public_path = client.call(
            "testPublicPath", {"path": "/outside-this-mount/"}
        )
        check(
            external_public_path.get("isError") is True
            and external_public_path["structuredContent"]["code"]
            == "invalidPublicPath",
            f"MCP public-path test escaped the CMS mount: {external_public_path}",
        )
        unsafe_public_path = client.call(
            "testPublicPath", {"path": "/mybase/assets/.."}
        )
        check(
            unsafe_public_path.get("isError") is True
            and unsafe_public_path["structuredContent"]["code"]
            == "invalidPublicPath",
            f"MCP public-path test accepted traversal: {unsafe_public_path}",
        )
        read_css = mcp_structured(
            client.call("getAsset", {"path": "mcp-assets/site.css"})
        )
        check(
            read_css["content"].startswith("body")
            and read_css["sha256"] == created_css["sha256"],
            f"MCP text asset read is wrong: {read_css}",
        )
        stale_write = client.call(
            "writeTextAsset",
            {"path": "mcp-assets/site.css", "content": "body { color: red; }\n"},
        )
        check(
            stale_write.get("isError") is True
            and stale_write["structuredContent"]["code"] == "assetConflict",
            f"MCP asset replacement did not require optimistic concurrency: {stale_write}",
        )
        replaced_css = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": "mcp-assets/site.css",
                    "content": "body { color: #abcdef; }\n",
                    "expectedSha256": read_css["sha256"],
                },
            )
        )
        check(
            replaced_css["previousSha256"] == read_css["sha256"],
            f"MCP asset replacement lost previous digest: {replaced_css}",
        )
        invalid_asset_lsp = client.call(
            "validateAssetCode",
            {"path": "mcp-assets/bad.lsp", "content": "<?lsp if then ?>"},
        )
        invalid_lsp_details = invalid_asset_lsp.get("structuredContent", {})
        check(
            invalid_asset_lsp.get("isError") is True
            and invalid_lsp_details.get("code") == "assetValidationFailed"
            and invalid_lsp_details.get("kind") == "lsp"
            and invalid_lsp_details.get("path") == "mcp-assets/bad.lsp"
            and invalid_lsp_details.get("line") == 1
            and invalid_lsp_details.get("message"),
            f"invalid asset LSP diagnostics are incomplete: {invalid_asset_lsp}",
        )
        unconfirmed_lsp = client.call(
            "writeTextAsset",
            {
                "path": "mcp-assets/trace.lsp",
                "content": '<?lsp trace("MCP_ASSET_TRACE_MARKER"); print("asset-lsp-ok") ?>',
            },
        )
        check(
            unconfirmed_lsp.get("isError") is True,
            "server-executable asset did not require explicit confirmation",
        )
        lsp_asset = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": "mcp-assets/trace.lsp",
                    "content": '<?lsp trace("MCP_ASSET_TRACE_MARKER"); print("asset-lsp-ok") ?>',
                    "confirmedExecutable": True,
                },
            )
        )
        check(
            lsp_asset["restartRequired"] is False,
            f"LSP asset incorrectly requires restart: {lsp_asset}",
        )
        code, headers, body = browser.request("/mybase/mcp-assets/trace.lsp")
        check(
            code == 200 and "asset-lsp-ok" in text(body, headers),
            "new LSP asset did not execute immediately",
        )
        public_lsp = mcp_structured(
            client.call(
                "testPublicPath",
                {"path": "/mybase/mcp-assets/trace.lsp", "maxBytes": 4096},
            )
        )
        check(
            public_lsp["status"] == 200
            and "asset-lsp-ok" in public_lsp["bodyExcerpt"],
            f"MCP public-path LSP test failed: {public_lsp}",
        )
        trace_result = mcp_structured(client.call("readRuntimeTrace"))
        check(
            trace_result["scope"] == "server-global"
            and trace_result["cmsAttributionReliable"] is False
            and "MCP_ASSET_TRACE_MARKER" in trace_result["trace"],
            f"MCP runtime trace did not capture asset execution: {trace_result}",
        )
        cleared_trace = mcp_structured(client.call("readRuntimeTrace"))
        check(
            cleared_trace["trace"] == "" and cleared_trace["cleared"] is True,
            f"MCP runtime trace was not cleared on read: {cleared_trace}",
        )
        bad_module_path = client.call(
            "writeTextAsset",
            {
                "path": "mcp-assets/helper.lua",
                "content": "return { ok = true }\n",
                "confirmedExecutable": True,
            },
        )
        check(
            bad_module_path.get("isError") is True,
            "Lua module outside .lua/ was accepted",
        )
        module_asset = mcp_structured(
            client.call(
                "writeTextAsset",
                {
                    "path": ".lua/mcp_test_helper.lua",
                    "content": "return { ok = true }\n",
                    "confirmedExecutable": True,
                },
            )
        )
        preload_call = client.call(
            "writeTextAsset",
            {
                "path": ".preload",
                "content": 'trace("MCP_PRELOAD_RESTART_TEST")\n',
                "confirmedExecutable": True,
            },
        )
        preload_asset = mcp_structured(preload_call)
        check(
            module_asset.get("restartRequired") is True
            and preload_asset.get("restartRequired") is True,
            f"Lua module or .preload did not report restartRequired: "
            f"{module_asset} {preload_call}",
        )
        binary = b"\x89PNG\r\n\x1a\nFuguHub-test-image"
        prepared_upload = mcp_structured(
            client.call(
                "prepareAssetUpload",
                {
                    "path": "mcp-assets/test.png",
                    "expectedBytes": len(binary),
                    "sha256": hashlib.sha256(binary).hexdigest(),
                    "contentType": "image/png",
                },
            )
        )
        check(
            prepared_upload["oneUse"] is True
            and prepared_upload["redirectPolicy"] == "do-not-follow"
            and any(
                header.startswith("Authorization: Bearer")
                for header in prepared_upload["requiredHeaders"]
            ),
            f"MCP binary upload contract is incomplete: {prepared_upload}",
        )
        code, _, upload_body = browser.request(
            prepared_upload["uploadUrl"],
            data=binary,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "image/png",
            },
            method="POST",
        )
        upload_result = json.loads(upload_body)
        check(
            code == 200
            and upload_result["result"]["sha256"] == hashlib.sha256(binary).hexdigest(),
            f"MCP binary upload failed: {code} {upload_result}",
        )
        prepared_download = mcp_structured(
            client.call("prepareAssetDownload", {"path": "mcp-assets/test.png"})
        )
        code, headers, downloaded = browser.request(
            prepared_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200
            and downloaded == binary
            and headers["X-FuguHub-SHA256"] == hashlib.sha256(binary).hexdigest(),
            "MCP binary download did not preserve bytes and digest",
        )
        code, _, _ = browser.request(
            prepared_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(code == 404, "MCP asset download ticket was reusable")
        original_digest = hashlib.sha256(binary).hexdigest()
        stale_binary = b"\x89PNG\r\n\x1a\nFuguHub-stale-upload"
        winning_binary = b"\x89PNG\r\n\x1a\nFuguHub-winning-upload"

        def prepare_replacement(payload: bytes) -> dict:
            return mcp_structured(
                client.call(
                    "prepareAssetUpload",
                    {
                        "path": "mcp-assets/test.png",
                        "expectedBytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "contentType": "image/png",
                        "expectedCurrentSha256": original_digest,
                    },
                )
            )

        stale_upload = prepare_replacement(stale_binary)
        winning_upload = prepare_replacement(winning_binary)
        code, _, winning_body = browser.request(
            winning_upload["uploadUrl"],
            data=winning_binary,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "image/png",
            },
            method="POST",
        )
        check(code == 200, f"winning prepared asset upload failed: {winning_body!r}")
        code, _, stale_body = browser.request(
            stale_upload["uploadUrl"],
            data=stale_binary,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "image/png",
            },
            method="POST",
        )
        stale_result = json.loads(stale_body)
        check(
            code == 400
            and stale_result["ok"] is False
            and "changed after the upload was prepared" in stale_result["error"],
            f"stale prepared asset upload overwrote a concurrent edit: {stale_result}",
        )
        current_download = mcp_structured(
            client.call("prepareAssetDownload", {"path": "mcp-assets/test.png"})
        )
        code, _, current_binary = browser.request(
            current_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200 and current_binary == winning_binary,
            "rejected stale asset upload changed the installed bytes",
        )
        dependencies = mcp_structured(
            client.call("getAssetDependencies", {"path": "mcp-assets/site.css"})
        )
        check(
            dependencies["complete"] is False,
            f"MCP asset dependency result overclaimed completeness: {dependencies}",
        )
        created_dir = mcp_structured(
            client.call("createAssetDirectory", {"path": "mcp-assets/empty"})
        )
        check(created_dir["created"] is True, "MCP asset directory creation failed")
        existing_dir = mcp_structured(
            client.call("createAssetDirectory", {"path": "mcp-assets/empty"})
        )
        check(
            existing_dir
            == {
                "created": False,
                "exists": True,
                "directory": True,
                "path": "mcp-assets/empty",
            },
            f"MCP existing-directory creation is not idempotent: {existing_dir}",
        )
        moved_css = mcp_structured(
            client.call(
                "moveAsset",
                {
                    "path": "mcp-assets/site.css",
                    "newPath": "mcp-assets/site-renamed.css",
                    "expectedSha256": replaced_css["sha256"],
                    "confirmed": True,
                },
            )
        )
        check(
            moved_css["restartRequired"] is False,
            f"static asset move incorrectly requires restart: {moved_css}",
        )
        deleted_css = mcp_structured(
            client.call(
                "deleteAsset",
                {
                    "path": "mcp-assets/site-renamed.css",
                    "expectedSha256": replaced_css["sha256"],
                    "confirmed": True,
                },
            )
        )
        check(deleted_css["deleted"] is True, "MCP asset deletion failed")
        deleted_dir = mcp_structured(
            client.call(
                "deleteAsset",
                {"path": "mcp-assets/empty", "confirmed": True},
            )
        )
        check(deleted_dir["deleted"] is True, "MCP empty asset directory deletion failed")
        listed_assets = mcp_structured(
            client.call("listAssets", {"recursive": True, "limit": 500})
        )
        listed_paths = {item["path"] for item in listed_assets["items"]}
        check(
            {"mcp-assets/test.png", "mcp-assets/trace.lsp", ".preload"}
            <= listed_paths,
            f"MCP asset listing is incomplete: {listed_paths}",
        )
        check(
            all("sha256" not in item for item in listed_assets["items"]),
            "asset listing eagerly hashed files without includeSha256",
        )
        hashed_assets = mcp_structured(
            client.call(
                "listAssets",
                {
                    "path": "mcp-assets",
                    "recursive": True,
                    "limit": 500,
                    "includeSha256": True,
                },
            )
        )
        check(
            all(
                item.get("sha256")
                for item in hashed_assets["items"]
                if not item["directory"]
            ),
            "asset listing omitted requested SHA-256 values",
        )
        assets_export = mcp_structured(client.call("prepareAssetsExport"))
        code, _, assets_zip = browser.request(
            assets_export["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200
            and hashlib.sha256(assets_zip).hexdigest()
            == assets_export["digest"].removeprefix("sha256:"),
            "MCP assets ZIP export failed digest verification",
        )
        with zipfile.ZipFile(io.BytesIO(assets_zip)) as archive:
            check(
                "mcp-assets/test.png" in archive.namelist()
                and ".preload" in archive.namelist(),
                f"MCP assets export has incorrect roots: {archive.namelist()}",
            )
            check(
                any(
                    info.compress_type == zipfile.ZIP_DEFLATED
                    for info in archive.infolist()
                    if not info.is_dir()
                ),
                "MCP assets ZIP export contains no DEFLATE-compressed entries",
            )

        unsafe_buffer = io.BytesIO()
        with zipfile.ZipFile(unsafe_buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("../escape.txt", "unsafe")
        unsafe_bytes = unsafe_buffer.getvalue()
        unsafe_import = mcp_structured(
            client.call(
                "prepareAssetsImport",
                {
                    "expectedBytes": len(unsafe_bytes),
                    "sha256": hashlib.sha256(unsafe_bytes).hexdigest(),
                    "confirmed": True,
                },
            )
        )
        code, _, unsafe_body = browser.request(
            unsafe_import["uploadUrl"],
            data=unsafe_bytes,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/zip",
            },
            method="POST",
        )
        check(
            code == 400 and json.loads(unsafe_body)["ok"] is False,
            "MCP assets ZIP import accepted a traversal entry",
        )
        check(not (runtime / "assets.zip").exists(), "unsafe assets ZIP was installed")

        duplicate_buffer = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(
                duplicate_buffer, "w", zipfile.ZIP_DEFLATED
            ) as archive:
                archive.writestr("duplicate.txt", "first")
                archive.writestr("DUPLICATE.txt", "second")
        duplicate_bytes = duplicate_buffer.getvalue()
        duplicate_import = mcp_structured(
            client.call(
                "prepareAssetsImport",
                {
                    "expectedBytes": len(duplicate_bytes),
                    "sha256": hashlib.sha256(duplicate_bytes).hexdigest(),
                    "confirmed": True,
                },
            )
        )
        code, _, duplicate_body = browser.request(
            duplicate_import["uploadUrl"],
            data=duplicate_bytes,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/zip",
            },
            method="POST",
        )
        check(
            code == 400 and json.loads(duplicate_body)["ok"] is False,
            "MCP assets ZIP import accepted duplicate paths",
        )
        check(not (runtime / "assets.zip").exists(), "duplicate-path assets ZIP was installed")

        package_buffer = io.BytesIO()
        with zipfile.ZipFile(package_buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("package-marker.txt", "package-active")
            archive.writestr(
                "package-test.lsp",
                '<?lsp print("package-lsp-ok") ?>',
            )
        package_bytes = package_buffer.getvalue()
        prepared_import = mcp_structured(
            client.call(
                "prepareAssetsImport",
                {
                    "expectedBytes": len(package_bytes),
                    "sha256": hashlib.sha256(package_bytes).hexdigest(),
                    "confirmed": True,
                },
            )
        )
        code, _, import_body = browser.request(
            prepared_import["uploadUrl"],
            data=package_bytes,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/zip",
            },
            method="POST",
        )
        import_result = json.loads(import_body)
        check(
            code == 200
            and import_result["result"]["restartRequired"] is True
            and import_result["result"]["activeSource"] == "directory",
            f"MCP assets ZIP import failed: {code} {import_result}",
        )
        code, _, _ = browser.request("/mybase/package-marker.txt")
        check(code == 404, "assets.zip became active without the required restart")

        edited = mcp_structured(
            client.call(
                "updateContent",
                {
                    "id": draft["id"],
                    "bodyHtml": "<section><p>Published through MCP.</p></section>",
                    "expectedUpdatedAt": draft["updatedAt"],
                },
            )
        )
        check(edited["status"] == "draft", "ordinary MCP update changed publication status")
        published_change = mcp_structured(
            client.call(
                "setContentStatus",
                {
                    "id": draft["id"],
                    "status": "published",
                    "expectedUpdatedAt": edited["updatedAt"],
                },
            )
        )
        published = published_change["content"]
        check(
            published_change["previousStatus"] == "draft"
            and published_change["newStatus"] == "published",
            f"explicit MCP status transition is wrong: {published_change}",
        )
        stale = client.call(
            "updateContent",
            {
                "id": draft["id"],
                "title": "Stale update",
                "expectedUpdatedAt": edited["updatedAt"],
            },
        )
        check(
            stale.get("isError") is True
            and stale["structuredContent"]["code"] == "contentConflict",
            f"stale MCP content update was accepted: {stale}",
        )
        code, headers, body = browser.request("/mybase/mcp-draft/")
        check(code == 200 and "Published through MCP" in text(body, headers), "published MCP page did not render")

        created_term = mcp_structured(
            client.call(
                "createTerm",
                {
                    "type": "topic",
                    "name": "Edge",
                    "slug": "edge",
                    "description": "Edge topic",
                },
            )
        )
        terms = mcp_structured(client.call("listTerms", {"type": "topic"}))
        check(
            len(terms["terms"]) == 1
            and terms["terms"][0]["id"] == created_term["id"]
            and terms["terms"][0]["assignmentCount"] == 0,
            f"MCP taxonomy listing is wrong: {terms}",
        )
        updated_term = mcp_structured(
            client.call(
                "updateTerm",
                {"id": created_term["id"], "name": "Edge Computing"},
            )
        )
        check(updated_term["name"] == "Edge Computing", "MCP taxonomy update failed")
        unconfirmed_term_delete = client.call(
            "deleteTerm", {"id": created_term["id"], "confirmed": False}
        )
        check(
            unconfirmed_term_delete.get("isError") is True
            and unconfirmed_term_delete["structuredContent"]["code"]
            == "confirmationRequired",
            "MCP taxonomy deletion did not require confirmation",
        )
        deleted_term = mcp_structured(
            client.call("deleteTerm", {"id": created_term["id"], "confirmed": True})
        )
        check(deleted_term["deleted"] is True, "MCP taxonomy deletion failed")

        locations = mcp_structured(client.call("getMenuLocations"))
        check(
            locations["locations"][0]["id"] == "primary",
            f"MCP menu locations are wrong: {locations}",
        )
        home_item = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "label": "Home",
                    "url": "/",
                    "position": 1,
                    "topLevel": True,
                },
            )
        )
        ajax_item = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "label": "AJAX",
                    "url": "/AJAX/",
                    "position": 2,
                    "topLevel": True,
                },
            )
        )
        check(
            home_item["parentId"] is None
            and home_item["topLevel"] is True
            and ajax_item["parentId"] is None
            and ajax_item["topLevel"] is True,
            f"MCP topLevel create did not produce root items: {home_item} {ajax_item}",
        )
        inferred_item = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "label": "Documentation",
                    "url": "/Documentation/",
                    "position": 3,
                },
            )
        )
        check(
            inferred_item["parentId"] == home_item["id"]
            and inferred_item["topLevel"] is False,
            f"MCP menu parent inference did not use Home: {inferred_item}",
        )
        promoted_item = mcp_structured(
            client.call(
                "updateMenuItem",
                {"id": inferred_item["id"], "topLevel": True},
            )
        )
        check(
            promoted_item["parentId"] is None
            and promoted_item["topLevel"] is True,
            f"MCP topLevel update did not clear the parent: {promoted_item}",
        )
        demoted_item = mcp_structured(
            client.call(
                "updateMenuItem",
                {"id": inferred_item["id"], "parentId": ajax_item["id"]},
            )
        )
        check(
            demoted_item["parentId"] == ajax_item["id"]
            and demoted_item["topLevel"] is False,
            f"MCP explicit parent update did not demote the item: {demoted_item}",
        )
        hierarchy = mcp_structured(client.call("listMenus"))
        primary_items = next(
            menu["items"]
            for menu in hierarchy["menus"]
            if menu["slug"] == "primary"
        )
        by_item_id = {item["id"]: item for item in primary_items}
        check(
            by_item_id[home_item["id"]]["parentId"] is None
            and by_item_id[ajax_item["id"]]["parentId"] is None
            and by_item_id[inferred_item["id"]]["parentId"] == ajax_item["id"],
            f"MCP menu listing did not preserve the requested hierarchy: {primary_items}",
        )
        code, headers, menu_page_body = browser.request("/mybase/mcp-draft/")
        menu_page = text(menu_page_body, headers)
        ajax_at = menu_page.find(">AJAX</a>")
        docs_at = menu_page.find(">Documentation</a>", ajax_at + 1)
        check(
            code == 200
            and ajax_at >= 0
            and docs_at > ajax_at
            and "<ul>" in menu_page[ajax_at:docs_at]
            and "cms.js" in menu_page
            and "cms-nav.js" not in menu_page
            and "cms-htmx.js" not in menu_page,
            "default theme did not render the MCP menu hierarchy with submenu controls",
        )
        secondary = mcp_structured(
            client.call("createMenu", {"name": "Footer", "slug": "footer"})
        )
        secondary = mcp_structured(
            client.call(
                "updateMenu",
                {"id": secondary["id"], "name": "Footer Navigation"},
            )
        )
        secondary_item = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "menuSlug": secondary["slug"],
                    "label": "Home",
                    "url": "/",
                },
            )
        )
        check(secondary_item["menuId"] == secondary["id"], "MCP menu item used wrong menu")
        unconfirmed_menu_delete = client.call(
            "deleteMenu", {"id": secondary["id"], "confirmed": False}
        )
        check(
            unconfirmed_menu_delete.get("isError") is True,
            "MCP menu deletion did not require confirmation",
        )
        deleted_menu = mcp_structured(
            client.call("deleteMenu", {"id": secondary["id"], "confirmed": True})
        )
        check(
            deleted_menu["removedItems"] == 1,
            f"MCP menu deletion dependency count is wrong: {deleted_menu}",
        )

        disposable = mcp_structured(
            client.call(
                "createContent",
                {
                    "type": "page",
                    "path": "/disposable/",
                    "title": "Disposable",
                    "bodyHtml": "<p>Delete this page.</p>",
                },
            )
        )
        disposable_menu = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "label": "Disposable",
                    "url": "/disposable/",
                    "contentId": disposable["id"],
                    "hidden": True,
                },
            )
        )
        client.call(
            "setRedirect",
            {
                "fromPath": "/old-disposable/",
                "toPath": "/disposable/",
                "statusCode": 302,
            },
        )
        dependencies = mcp_structured(
            client.call("getContentDependencies", {"id": disposable["id"]})
        )
        check(
            len(dependencies["menuItems"]) == 1
            and len(dependencies["redirects"]) == 1,
            f"MCP content dependency inspection is wrong: {dependencies}",
        )
        missing_decision = client.call(
            "deleteContent",
            {
                "id": disposable["id"],
                "expectedUpdatedAt": disposable["updatedAt"],
                "confirmed": True,
            },
        )
        check(
            missing_decision.get("isError") is True
            and missing_decision["structuredContent"]["code"]
            == "contentDependenciesRequireDecision",
            f"MCP content deletion chose a dependency action: {missing_decision}",
        )
        delete_result = client.call(
            "deleteContent",
            {
                "id": disposable["id"],
                "expectedUpdatedAt": disposable["updatedAt"],
                "confirmed": True,
                "menuItemsAction": "preserve",
                "redirectsAction": "delete",
            },
        )
        check(
            delete_result.get("isError") is not True,
            f"MCP confirmed content deletion failed: {delete_result}",
        )
        deleted_content = mcp_structured(delete_result)
        check(
            deleted_content["preservedMenuItems"] == 1
            and deleted_content["removedRedirects"] == 1,
            f"MCP content deletion result is wrong: {deleted_content}",
        )
        menus_after_delete = mcp_structured(client.call("listMenus"))
        preserved_item = next(
            item
            for menu_value in menus_after_delete["menus"]
            for item in menu_value["items"]
            if item["id"] == int(disposable_menu["id"])
        )
        check(
            preserved_item.get("contentId") is None,
            "MCP content deletion did not preserve the selected menu URL",
        )
        required_delete = client.call(
            "deleteContent",
            {"path": "/404/", "confirmed": True},
        )
        check(
            required_delete.get("isError") is True
            and required_delete["structuredContent"]["code"] == "requiredContent",
            "MCP allowed deletion of the active editable 404 page",
        )

        current_settings = mcp_structured(client.call("getSettings"))
        check(
            current_settings["blogBasePath"] == "/blog/"
            and current_settings["htmxEnabled"] is False
            and current_settings["smqEnabled"] is False,
            f"MCP settings read is wrong: {current_settings}",
        )
        dry_run = mcp_structured(
            client.call(
                "updateSettings",
                {
                    "blogBasePath": "/news/",
                    "htmxEnabled": False,
                    "smqEnabled": True,
                    "notFoundEnabled": False,
                    "dryRun": True,
                },
            )
        )
        check(
            dry_run["dryRun"] is True
            and dry_run["settings"]["blogBasePath"] == "/news/"
            and dry_run["settings"]["smqEnabled"] is False,
            f"MCP settings dry-run is wrong: {dry_run}",
        )
        check(
            mcp_structured(client.call("getSettings"))["blogBasePath"] == "/blog/",
            "MCP settings dry-run changed persistent state",
        )
        updated_settings = mcp_structured(
            client.call(
                "updateSettings",
                {
                    "blogBasePath": "/news/",
                    "htmxEnabled": True,
                    "smqEnabled": True,
                    "notFoundEnabled": True,
                    "notFoundPath": "/404/",
                },
            )
        )
        check(
            updated_settings["settings"]["blogBasePath"] == "/news/"
            and updated_settings["settings"]["htmxEnabled"] is True
            and updated_settings["settings"]["smqEnabled"] is True,
            f"MCP settings update is wrong: {updated_settings}",
        )

        themes = mcp_structured(client.call("listThemes"))
        theme_names = {item["name"]: item for item in themes["themes"]}
        check(
            theme_names["default"]["active"] is True
            and theme_names["zipped"]["source"] == "zip",
            f"MCP theme listing is wrong: {themes}",
        )
        installed_style = mcp_structured(
            client.call("getThemeFile", {"name": "default", "path": "style.css"})
        )
        check(
            installed_style["text"] is True
            and ":root" in installed_style["content"]
            and len(installed_style["sha256"]) == 64,
            f"MCP installed theme file read is wrong: {installed_style}",
        )
        unsafe_theme_path = client.call(
            "getThemeFile",
            {"name": "default", "path": "../style.css"},
        )
        check(
            unsafe_theme_path.get("isError") is True,
            "MCP installed theme read accepted path traversal",
        )
        incomplete_draft = mcp_structured(
            client.call("createThemeDraft", {"name": "incomplete-theme"})
        )
        incomplete_validation = client.call(
            "validateThemeDraft",
            {"draftId": incomplete_draft["id"]},
        )
        check(
            incomplete_validation.get("isError") is True,
            "MCP accepted an incomplete empty theme draft",
        )
        mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": incomplete_draft["id"], "confirmed": True},
            )
        )
        theme_draft = mcp_structured(
            client.call(
                "createThemeDraft",
                {"name": "mcp-theme-draft", "fromTheme": "default"},
            )
        )
        theme_draft_id = theme_draft["id"]
        check(
            theme_draft["name"] == "mcp-theme-draft"
            and theme_draft["fromTheme"] == "default"
            and theme_draft["targetExisted"] is False,
            f"MCP theme draft creation is wrong: {theme_draft}",
        )
        draft_catalog = mcp_structured(client.call("listThemeDrafts"))
        check(
            any(item["id"] == theme_draft_id for item in draft_catalog["drafts"]),
            f"MCP theme draft listing omitted the draft: {draft_catalog}",
        )
        draft_files = mcp_structured(
            client.call(
                "listThemeDraftFiles",
                {"draftId": theme_draft_id, "recursive": True},
            )
        )
        draft_paths = {item["path"] for item in draft_files["items"]}
        check(
            {
                "style.css",
                "theme.json",
                "templates/layout.lsp",
                "templates/page.lsp",
            }
            <= draft_paths
            and ".draft.json" not in draft_paths,
            f"MCP theme draft file listing is wrong: {draft_files}",
        )
        check(
            all("sha256" not in item for item in draft_files["items"]),
            "theme draft listing eagerly hashed files without includeSha256",
        )
        hashed_draft_files = mcp_structured(
            client.call(
                "listThemeDraftFiles",
                {
                    "draftId": theme_draft_id,
                    "recursive": True,
                    "includeSha256": True,
                },
            )
        )
        check(
            all(
                item.get("sha256")
                for item in hashed_draft_files["items"]
                if not item["directory"]
            ),
            "theme draft listing omitted requested SHA-256 values",
        )
        draft_layout = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {"draftId": theme_draft_id, "path": "templates/layout.lsp"},
            )
        )
        unconfirmed_lsp = client.call(
            "writeThemeDraftText",
            {
                "draftId": theme_draft_id,
                "path": "templates/layout.lsp",
                "content": draft_layout["content"],
                "expectedSha256": draft_layout["sha256"],
            },
        )
        check(
            unconfirmed_lsp.get("isError") is True,
            "MCP theme draft accepted executable LSP without confirmation",
        )
        invalid_lsp = client.call(
            "writeThemeDraftText",
            {
                "draftId": theme_draft_id,
                "path": "templates/layout.lsp",
                "content": "<?lsp this is not valid Lua ?>",
                "expectedSha256": draft_layout["sha256"],
                "confirmedExecutable": True,
            },
        )
        check(
            invalid_lsp.get("isError") is True,
            "MCP theme draft accepted invalid LSP",
        )
        draft_style = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {"draftId": theme_draft_id, "path": "style.css"},
            )
        )
        changed_style = draft_style["content"] + "\n/* MCP theme draft marker */\n"
        written_style = mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": theme_draft_id,
                    "path": "style.css",
                    "content": changed_style,
                    "expectedSha256": draft_style["sha256"],
                },
            )
        )
        check(
            written_style["previousSha256"] == draft_style["sha256"]
            and written_style["sha256"] != draft_style["sha256"],
            f"MCP theme draft text replacement is wrong: {written_style}",
        )
        stale_style = client.call(
            "writeThemeDraftText",
            {
                "draftId": theme_draft_id,
                "path": "style.css",
                "content": changed_style + "/* stale */",
                "expectedSha256": draft_style["sha256"],
            },
        )
        check(
            stale_style.get("isError") is True,
            "MCP theme draft ignored a stale SHA-256 precondition",
        )
        draft_note = mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": theme_draft_id,
                    "path": "notes.txt",
                    "content": "temporary",
                },
            )
        )
        unconfirmed_delete = client.call(
            "deleteThemeDraftFile",
            {
                "draftId": theme_draft_id,
                "path": "notes.txt",
                "expectedSha256": draft_note["sha256"],
                "confirmed": False,
            },
        )
        check(
            unconfirmed_delete.get("isError") is True,
            "MCP theme draft deletion did not require confirmation",
        )
        deleted_note = mcp_structured(
            client.call(
                "deleteThemeDraftFile",
                {
                    "draftId": theme_draft_id,
                    "path": "notes.txt",
                    "expectedSha256": draft_note["sha256"],
                    "confirmed": True,
                },
            )
        )
        check(deleted_note["deleted"] is True, "MCP theme draft file was not deleted")
        theme_binary = b"\x89PNG\r\n\x1a\nFuguHub-theme-draft-image"
        prepared_theme_upload = mcp_structured(
            client.call(
                "prepareThemeDraftUpload",
                {
                    "draftId": theme_draft_id,
                    "path": "images/test.png",
                    "expectedBytes": len(theme_binary),
                    "sha256": hashlib.sha256(theme_binary).hexdigest(),
                    "contentType": "image/png",
                },
            )
        )
        check(
            prepared_theme_upload["oneUse"] is True
            and prepared_theme_upload["uploadUrl"].endswith(
                prepared_theme_upload["uploadUrl"].split("?ticket=", 1)[1]
            )
            and "/mybase/mcp/themes?ticket=" in prepared_theme_upload["uploadUrl"],
            f"MCP theme binary upload contract is incomplete: {prepared_theme_upload}",
        )
        code, _, theme_upload_body = browser.request(
            prepared_theme_upload["uploadUrl"],
            data=theme_binary,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "image/png",
            },
            method="POST",
        )
        theme_upload_result = json.loads(theme_upload_body)
        check(
            code == 200
            and theme_upload_result["result"]["sha256"]
            == hashlib.sha256(theme_binary).hexdigest(),
            f"MCP theme binary upload failed: {code} {theme_upload_result}",
        )
        prepared_theme_download = mcp_structured(
            client.call(
                "prepareThemeDraftDownload",
                {"draftId": theme_draft_id, "path": "images/test.png"},
            )
        )
        code, theme_download_headers, downloaded_theme_binary = browser.request(
            prepared_theme_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200
            and downloaded_theme_binary == theme_binary
            and theme_download_headers["X-FuguHub-SHA256"]
            == hashlib.sha256(theme_binary).hexdigest(),
            "MCP theme binary download did not preserve bytes and digest",
        )
        code, _, _ = browser.request(
            prepared_theme_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(code == 404, "MCP theme download ticket was reusable")
        validated_draft = mcp_structured(
            client.call("validateThemeDraft", {"draftId": theme_draft_id})
        )
        check(
            validated_draft["valid"] is True
            and len(validated_draft["templates"]) == 6
            and len(validated_draft["fingerprint"]) == 64,
            f"MCP theme draft validation is wrong: {validated_draft}",
        )
        unconfirmed_commit = client.call(
            "commitThemeDraft",
            {
                "draftId": theme_draft_id,
                "expectedFingerprint": validated_draft["fingerprint"],
                "confirmed": False,
                "confirmedExecutable": True,
            },
        )
        check(
            unconfirmed_commit.get("isError") is True,
            "MCP theme commit did not require confirmation",
        )
        unconfirmed_executable_commit = client.call(
            "commitThemeDraft",
            {
                "draftId": theme_draft_id,
                "expectedFingerprint": validated_draft["fingerprint"],
                "confirmed": True,
                "confirmedExecutable": False,
            },
        )
        check(
            unconfirmed_executable_commit.get("isError") is True,
            "MCP theme commit did not require executable confirmation",
        )
        stale_commit = client.call(
            "commitThemeDraft",
            {
                "draftId": theme_draft_id,
                "expectedFingerprint": "0" * 64,
                "confirmed": True,
                "confirmedExecutable": True,
            },
        )
        check(
            stale_commit.get("isError") is True,
            "MCP theme commit ignored a stale validation fingerprint",
        )
        committed_theme = mcp_structured(
            client.call(
                "commitThemeDraft",
                {
                    "draftId": theme_draft_id,
                    "expectedFingerprint": validated_draft["fingerprint"],
                    "confirmed": True,
                    "confirmedExecutable": True,
                },
            )
        )
        check(
            committed_theme["committed"] is True
            and committed_theme["name"] == "mcp-theme-draft"
            and committed_theme["source"] == "zip"
            and committed_theme["active"] is False
            and committed_theme["activationRequired"] is True,
            f"MCP theme commit is wrong: {committed_theme}",
        )
        installed_draft_theme = mcp_structured(
            client.call("validateTheme", {"name": "mcp-theme-draft"})
        )
        check(
            installed_draft_theme["valid"] is True,
            f"committed MCP theme is invalid: {installed_draft_theme}",
        )
        installed_binary_download_result = client.call(
            "prepareThemeFileDownload",
            {"name": "mcp-theme-draft", "path": "images/test.png"},
        )
        installed_binary_download = mcp_structured(installed_binary_download_result)
        check(
            "downloadUrl" in installed_binary_download,
            "installed MCP theme binary download was not prepared: "
            f"{installed_binary_download_result}",
        )
        code, _, installed_theme_binary = browser.request(
            installed_binary_download["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200 and installed_theme_binary == theme_binary,
            "installed MCP theme binary download failed",
        )
        theme_export = mcp_structured(
            client.call("prepareThemeExport", {"name": "mcp-theme-draft"})
        )
        code, _, exported_theme_zip = browser.request(
            theme_export["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(
            code == 200
            and hashlib.sha256(exported_theme_zip).hexdigest()
            == theme_export["digest"].removeprefix("sha256:"),
            "MCP theme export failed digest verification",
        )
        with zipfile.ZipFile(io.BytesIO(exported_theme_zip)) as archive:
            exported_theme_names = set(archive.namelist())
            check(
                {
                    "style.css",
                    "theme.json",
                    "templates/layout.lsp",
                    "images/test.png",
                }
                <= exported_theme_names
                and ".draft.json" not in exported_theme_names
                and not any(name.startswith("mcp-theme-draft/") for name in exported_theme_names),
                f"MCP theme export has incorrect roots: {sorted(exported_theme_names)}",
            )
            check(
                any(
                    info.compress_type == zipfile.ZIP_DEFLATED
                    for info in archive.infolist()
                    if not info.is_dir()
                ),
                "MCP theme export contains no DEFLATE-compressed entries",
            )
        modification_draft = mcp_structured(
            client.call(
                "createThemeDraft",
                {
                    "name": "mcp-theme-draft",
                    "fromTheme": "mcp-theme-draft",
                },
            )
        )
        modification_style = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {
                    "draftId": modification_draft["id"],
                    "path": "style.css",
                },
            )
        )
        mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": modification_draft["id"],
                    "path": "style.css",
                    "content": modification_style["content"]
                    + "\n/* MCP inactive modification marker */\n",
                    "expectedSha256": modification_style["sha256"],
                },
            )
        )
        modification_validation = mcp_structured(
            client.call(
                "validateThemeDraft",
                {"draftId": modification_draft["id"]},
            )
        )
        modified_theme_result = client.call(
            "commitThemeDraft",
            {
                "draftId": modification_draft["id"],
                "expectedFingerprint": modification_validation["fingerprint"],
                "confirmed": True,
                "confirmedExecutable": True,
            },
        )
        modified_theme = mcp_structured(modified_theme_result)
        check(
            modified_theme.get("committed") is True
            and modified_theme["name"] == "mcp-theme-draft",
            f"MCP inactive theme modification failed: {modified_theme_result}",
        )
        installed_modified_style = mcp_structured(
            client.call(
                "getThemeFile",
                {"name": "mcp-theme-draft", "path": "style.css"},
            )
        )
        check(
            "MCP inactive modification marker"
            in installed_modified_style["content"],
            "MCP inactive theme modification was not installed",
        )
        mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": modification_draft["id"], "confirmed": True},
            )
        )
        activated_draft_theme = mcp_structured(
            client.call(
                "activateTheme",
                {"name": "mcp-theme-draft", "confirmed": True},
            )
        )
        check(
            activated_draft_theme["activeTheme"] == "mcp-theme-draft",
            f"committed MCP theme did not activate: {activated_draft_theme}",
        )
        code, _, committed_css = browser.request("/mybase/theme/style.css")
        check(
            code == 200
            and b"MCP theme draft marker" in committed_css
            and b"MCP inactive modification marker" in committed_css,
            "committed MCP theme CSS was not served after activation",
        )
        active_modification = mcp_structured(
            client.call(
                "createThemeDraft",
                {"name": "mcp-theme-draft", "fromTheme": "mcp-theme-draft"},
            )
        )
        active_style = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {
                    "draftId": active_modification["id"],
                    "path": "style.css",
                },
            )
        )
        mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": active_modification["id"],
                    "path": "style.css",
                    "content": active_style["content"]
                    + "\n/* MCP active replacement marker */\n",
                    "expectedSha256": active_style["sha256"],
                },
            )
        )
        active_modification_validation = mcp_structured(
            client.call(
                "validateThemeDraft",
                {"draftId": active_modification["id"]},
            )
        )
        replaced_active_theme = mcp_structured(
            client.call(
                "commitThemeDraft",
                {
                    "draftId": active_modification["id"],
                    "expectedFingerprint": active_modification_validation["fingerprint"],
                    "confirmed": True,
                    "confirmedExecutable": True,
                },
            )
        )
        check(
            replaced_active_theme["committed"] is True
            and replaced_active_theme["active"] is True
            and replaced_active_theme["activationRequired"] is False
            and replaced_active_theme["reloaded"] is True
            and replaced_active_theme["reloadRequired"] is False,
            f"MCP active theme replacement result is wrong: {replaced_active_theme}",
        )
        code, _, active_replacement_css = browser.request("/mybase/theme/style.css")
        check(
            code == 200
            and b"MCP active replacement marker" in active_replacement_css,
            "MCP active ZIP theme replacement did not reload its assets",
        )
        mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": active_modification["id"], "confirmed": True},
            )
        )
        unconfirmed_discard = client.call(
            "discardThemeDraft",
            {"draftId": theme_draft_id, "confirmed": False},
        )
        check(
            unconfirmed_discard.get("isError") is True,
            "MCP theme draft discard did not require confirmation",
        )
        discarded_draft = mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": theme_draft_id, "confirmed": True},
            )
        )
        check(
            discarded_draft["discarded"] is True,
            f"MCP theme draft discard failed: {discarded_draft}",
        )
        missing_draft = client.call(
            "getThemeDraftFile",
            {"draftId": theme_draft_id, "path": "style.css"},
        )
        check(
            missing_draft.get("isError") is True,
            "discarded MCP theme draft remained accessible",
        )
        valid_theme = mcp_structured(client.call("validateTheme", {"name": "zipped"}))
        check(
            valid_theme["valid"] is True and len(valid_theme["templates"]) == 6,
            f"MCP ZIP theme validation is wrong: {valid_theme}",
        )
        broken_theme = client.call("validateTheme", {"name": "broken"})
        check(
            broken_theme.get("isError") is True,
            "MCP accepted an incomplete theme",
        )
        unconfirmed_theme = client.call(
            "activateTheme", {"name": "zipped", "confirmed": False}
        )
        check(
            unconfirmed_theme.get("isError") is True,
            "MCP theme activation did not require confirmation",
        )
        activated_theme = mcp_structured(
            client.call("activateTheme", {"name": "zipped", "confirmed": True})
        )
        check(
            activated_theme["activeTheme"] == "zipped"
            and activated_theme["reloadRequired"] is False,
            f"MCP ZIP theme activation is wrong: {activated_theme}",
        )
        code, _, css = browser.request("/mybase/theme/style.css")
        check(
            code == 200 and b"zipped-theme-marker" in css,
            "MCP ZIP theme activation did not take effect immediately",
        )
        switched_theme_draft = mcp_structured(
            client.call(
                "createThemeDraft",
                {
                    "name": "mcp-theme-draft",
                    "fromTheme": "mcp-theme-draft",
                },
            )
        )
        switched_theme_validation = mcp_structured(
            client.call(
                "validateThemeDraft",
                {"draftId": switched_theme_draft["id"]},
            )
        )
        switched_theme_commit = mcp_structured(
            client.call(
                "commitThemeDraft",
                {
                    "draftId": switched_theme_draft["id"],
                    "expectedFingerprint": switched_theme_validation["fingerprint"],
                    "confirmed": True,
                    "confirmedExecutable": True,
                },
            )
        )
        check(
            switched_theme_commit.get("committed") is True,
            "the previous active theme ZIP remained locked after switching themes",
        )
        mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": switched_theme_draft["id"], "confirmed": True},
            )
        )

        health = mcp_structured(client.call("getHealth"))
        check(
            health["healthy"] is True
            and health["baseUri"] == "/mybase/"
            and health["database"]["foreignKeys"] is True
            and health["theme"]["name"] == "zipped",
            f"MCP health report is wrong: {health}",
        )
        schema_info = mcp_structured(client.call("getSchemaInfo"))
        schema_tables = {table["name"] for table in schema_info["tables"]}
        check(
            schema_info["schemaVersion"] == 2
            and {"content", "menus", "options", "terms"} <= schema_tables,
            f"MCP schema information is incomplete: {schema_info}",
        )
        clean_integrity = mcp_structured(client.call("runIntegrityCheck"))
        check(
            clean_integrity["ok"] is True,
            f"MCP integrity check found unexpected errors: {clean_integrity}",
        )
        client.call(
            "setRedirect",
            {"fromPath": "/loop-a/", "toPath": "/loop-b/", "statusCode": 302},
        )
        rejected_loop = client.call(
            "setRedirect",
            {"fromPath": "/loop-b/", "toPath": "/loop-a/", "statusCode": 302},
        )
        check(rejected_loop.get("isError") is True, "MCP accepted a redirect loop")
        code, _, _ = admin_post(
            browser,
            "/mybase/",
            "redirects/",
            {
                "action": "add",
                "from_path": "/loop-b/",
                "to_path": "/loop-a/",
                "status_code": "302",
            },
        )
        check(code == 400, "admin accepted a redirect loop")
        code, _, fixture_body = browser.request(
            "/mybase/review-insert-redirect-loop.lsp"
        )
        check(
            code == 200 and b"inserted" in fixture_body,
            "legacy redirect-loop fixture insertion failed",
        )
        loop_integrity = mcp_structured(client.call("runIntegrityCheck"))
        check(
            loop_integrity["ok"] is False
            and any(
                issue["code"] == "redirectLoop"
                for issue in loop_integrity["issues"]
            ),
            f"MCP integrity check missed a redirect loop: {loop_integrity}",
        )
        unconfirmed_redirect_delete = client.call(
            "deleteRedirect", {"fromPath": "/loop-a/", "confirmed": False}
        )
        check(
            unconfirmed_redirect_delete.get("isError") is True,
            "MCP redirect deletion did not require confirmation",
        )
        client.call("deleteRedirect", {"fromPath": "/loop-a/", "confirmed": True})
        client.call("deleteRedirect", {"fromPath": "/loop-b/", "confirmed": True})
        cleared = mcp_structured(client.call("clearCache", {"scope": "all"}))
        check(
            cleared["cleared"] is True and cleared["scope"] == "all",
            f"MCP cache clear result is wrong: {cleared}",
        )

        unsafe = client.call(
            "createContent",
            {
                "type": "page",
                "path": "/unsafe/",
                "title": "Unsafe",
                "bodyHtml": "<script>alert(1)</script>",
            },
        )
        check(unsafe.get("isError") is True, "MCP accepted a script element")

        implicit_lsp = client.call(
            "createContent",
            {
                "type": "page",
                "path": "/implicit-lsp/",
                "title": "Implicit LSP",
                "bodyHtml": "<?lsp print('bad') ?>",
            },
        )
        check(implicit_lsp.get("isError") is True, "MCP accepted LSP without explicit render mode")

        explicit_lsp = mcp_structured(
            client.call(
                "createContent",
                {
                    "type": "page",
                    "path": "/explicit-lsp/",
                    "title": "Explicit LSP",
                    "bodyHtml": "<p>MCP LSP <?lsp= 6 * 7 ?></p>",
                    "renderMode": "lsp",
                    "publish": True,
                },
            )
        )
        check(explicit_lsp["renderMode"] == "lsp", "explicit MCP LSP content was not stored as LSP")
        code, headers, body = browser.request("/mybase/explicit-lsp/")
        check(code == 200 and "MCP LSP 42" in text(body, headers), "MCP-created LSP page did not execute")
        unapproved_lsp_copy = client.call(
            "copyContent",
            {"id": explicit_lsp["id"], "newPath": "/explicit-lsp-copy/"},
        )
        check(
            unapproved_lsp_copy.get("isError") is True
            and unapproved_lsp_copy["structuredContent"]["code"]
            == "lspConfirmationRequired",
            "MCP copied executable LSP without explicit approval",
        )

        copied_content = mcp_structured(
            client.call(
                "copyContent",
                {
                    "id": published["id"],
                    "newPath": "/mcp-copy/",
                    "title": "MCP Copy",
                },
            )
        )
        check(
            copied_content["status"] == "draft"
            and copied_content["copiedFrom"]["id"] == published["id"],
            f"MCP content copy did not default to draft: {copied_content}",
        )
        batch = mcp_structured(
            client.call(
                "getContentBatch",
                {
                    "ids": [published["id"], copied_content["id"]],
                    "paths": ["/does-not-exist/"],
                    "includeTerms": True,
                },
            )
        )
        check(
            batch["requested"] == 3
            and batch["found"] == 2
            and batch["missing"] == 1,
            f"MCP batch content read is wrong: {batch}",
        )
        copied_deleted = mcp_structured(
            client.call(
                "deleteContent",
                {
                    "id": copied_content["id"],
                    "expectedUpdatedAt": copied_content["updatedAt"],
                    "confirmed": True,
                },
            )
        )
        check(copied_deleted["deleted"] is True, "MCP copied content cleanup failed")

        menu = mcp_structured(
            client.call(
                "createMenuItem",
                {
                    "label": "MCP Draft",
                    "url": "/mcp-draft/",
                    "contentId": draft["id"],
                    "hidden": True,
                },
            )
        )
        check(int(menu["hidden"]) == 1, "MCP menu hidden state was not saved")
        menus = mcp_structured(client.call("listMenus"))
        check(
            any(
                item["id"] == int(menu["id"]) and item["hidden"] is True
                for value in menus["menus"]
                for item in value["items"]
            ),
            "MCP menu listing omitted the hidden item",
        )

        redirect = mcp_structured(
            client.call(
                "setRedirect",
                {"fromPath": "/mcp-old/", "toPath": "/mcp-draft/", "statusCode": 301},
            )
        )
        check(redirect["statusCode"] == 301, "MCP redirect was not saved")
        redirects = mcp_structured(client.call("listRedirects"))
        check(
            any(row["from_path"] == "/mcp-old/" for row in redirects["redirects"]),
            "MCP redirect listing omitted the saved redirect",
        )

        exported = mcp_structured(
            client.call("prepareContentExport", {"ids": [draft["id"]]})
        )
        check(
            exported["downloadUrl"].startswith(server.origin + "/mybase/mcp/archive?ticket="),
            f"MCP export URL is not mount-aware: {exported}",
        )
        code, headers, archive_body = browser.request(
            exported["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(code == 200, f"MCP ZIP export returned {code}")
        check(
            hashlib.sha256(archive_body).hexdigest()
            == exported["digest"].removeprefix("sha256:"),
            "MCP ZIP export digest does not match its descriptor",
        )
        with zipfile.ZipFile(io.BytesIO(archive_body)) as archive:
            check(
                archive.namelist() == [".fuguhub-content.json"],
                f"MCP ZIP contains unexpected entries: {archive.namelist()}",
            )
            check(
                archive.getinfo(".fuguhub-content.json").compress_type
                == zipfile.ZIP_DEFLATED,
                "MCP content ZIP manifest is not DEFLATE-compressed",
            )
            manifest = json.loads(archive.read(".fuguhub-content.json"))
        check(isinstance(manifest.get("items"), list), f"MCP manifest items is not an array: {manifest}")
        check(
            isinstance(manifest["items"][0].get("terms"), list),
            f"MCP manifest terms is not an array: {manifest}",
        )
        check(
            manifest["format"] == "fuguhub-content"
            and manifest["items"][0]["path"] == "/mcp-draft/"
            and manifest["items"][0]["terms"][0]["slug"] == "mcp",
            "MCP ZIP manifest is incomplete",
        )
        code, _, _ = browser.request(
            exported["downloadUrl"],
            headers={"Authorization": f"Bearer {token}"},
        )
        check(code == 404, "MCP ZIP export ticket was reusable")

    with MakoProcess(runtime, "mybase") as restarted:
        browser = Browser(restarted.origin)
        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        info = mcp_structured(client.call("getCmsInfo"))
        check(info["baseUri"] == "/mybase/", "encrypted MCP token did not survive restart")
        zip_caps = mcp_structured(client.call("getAssetCapabilities"))
        check(
            zip_caps["source"] == "zip"
            and zip_caps["writable"] is False
            and "immutable" in zip_caps["readOnlyReason"],
            f"imported assets.zip was not selected after restart: {zip_caps}",
        )
        code, _, body = browser.request("/mybase/package-marker.txt")
        check(code == 200 and body == b"package-active", "imported assets ZIP static file failed")
        code, headers, body = browser.request("/mybase/package-test.lsp")
        check(
            code == 200 and "package-lsp-ok" in text(body, headers),
            "imported assets ZIP LSP file failed",
        )
        zip_write = client.call(
            "writeTextAsset",
            {"path": "should-fail.txt", "content": "read only"},
        )
        check(
            zip_write.get("isError") is True
            and zip_write["structuredContent"]["code"] == "assetsReadOnly",
            f"ZIP-backed assets accepted a write: {zip_write}",
        )
        code, _, _ = admin_post(
            browser,
            "/mybase/",
            "mcp/",
            {"action": "disable", "token": ""},
        )
        check(code == 200, "disabling MCP from admin failed")
        code, _, body = browser.request(
            "/mybase/mcp/",
            data=b"{}",
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        check(code == 503 and b"disabled" in body.lower(), "MCP stayed enabled after admin disable")


def test_theme_draft_persistence() -> None:
    runtime = fresh_runtime("theme-draft-persistence")
    token = "theme-draft-persistence-token-0123456789"
    draft_id = ""
    marker = "persistent theme draft marker"

    with MakoProcess(runtime, "mybase") as server:
        browser = Browser(server.origin)
        configure_mcp(browser, "/mybase/", token)
        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        draft = mcp_structured(
            client.call(
                "createThemeDraft",
                {"name": "persistent-theme", "fromTheme": "default"},
            )
        )
        draft_id = draft["id"]
        mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": draft_id,
                    "path": "persistence.txt",
                    "content": marker,
                },
            )
        )

    with MakoProcess(runtime, "mybase") as server:
        browser = Browser(server.origin)
        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        drafts = mcp_structured(client.call("listThemeDrafts"))
        check(
            any(item["id"] == draft_id for item in drafts["drafts"]),
            f"theme draft did not persist across restart: {drafts}",
        )
        persisted = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {"draftId": draft_id, "path": "persistence.txt"},
            )
        )
        check(
            persisted["content"] == marker,
            f"theme draft content did not persist across restart: {persisted}",
        )
        discarded = mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": draft_id, "confirmed": True},
            )
        )
        check(discarded["discarded"] is True, "persistent theme draft was not discarded")


def test_active_directory_theme_replacement() -> None:
    runtime = fresh_runtime("active-directory-theme-replacement")
    token = "active-directory-theme-replacement-token-0123456789"
    marker = "MCP active directory replacement marker"

    with MakoProcess(runtime, "mybase") as server:
        browser = Browser(server.origin)
        configure_mcp(browser, "/mybase/", token)
        client = McpClient(browser, "/mybase/mcp/", token)
        client.initialize()
        draft = mcp_structured(
            client.call(
                "createThemeDraft",
                {"name": "default", "fromTheme": "default"},
            )
        )
        style = mcp_structured(
            client.call(
                "getThemeDraftFile",
                {"draftId": draft["id"], "path": "style.css"},
            )
        )
        mcp_structured(
            client.call(
                "writeThemeDraftText",
                {
                    "draftId": draft["id"],
                    "path": "style.css",
                    "content": style["content"] + f"\n/* {marker} */\n",
                    "expectedSha256": style["sha256"],
                },
            )
        )
        validated = mcp_structured(
            client.call("validateThemeDraft", {"draftId": draft["id"]})
        )
        committed = mcp_structured(
            client.call(
                "commitThemeDraft",
                {
                    "draftId": draft["id"],
                    "expectedFingerprint": validated["fingerprint"],
                    "confirmed": True,
                    "confirmedExecutable": True,
                },
            )
        )
        check(
            committed["active"] is True
            and committed["activationRequired"] is False
            and committed["source"] == "zip"
            and (runtime / "themes" / "default.zip").is_file(),
            f"active directory theme was not replaced by a ZIP: {committed}",
        )
        code, _, css = browser.request("/mybase/theme/style.css")
        check(
            code == 200 and marker.encode() in css,
            "active directory theme replacement did not reload its assets",
        )
        info = mcp_structured(client.call("getCmsInfo"))
        check(
            info["activeTheme"] == "default",
            f"active directory replacement did not update runtime metadata: {info}",
        )
        mcp_structured(
            client.call(
                "discardThemeDraft",
                {"draftId": draft["id"], "confirmed": True},
            )
        )


def test_theme_startup_recovery() -> None:
    runtime = fresh_runtime("theme-startup-recovery")
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/")
        check(
            code == 404 and b"This FuguHub installation is empty" in body,
            f"initial theme recovery runtime failed: {body[:500]!r}",
        )

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        conn.execute(
            "INSERT OR REPLACE INTO options(key,value) VALUES('active_theme',?)",
            ("removed-theme",),
        )
        conn.commit()

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/theme/style.css")
        check(code == 200 and b"--" in body,
              "missing active theme did not fall back to default")
        check(
            any(
                "FuguHub selected fallback theme:" in line
                and "default" in line
                for line in server.lines
            ),
            "default theme fallback was not diagnosed",
        )

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        selected = conn.execute(
            "SELECT value FROM options WHERE key='active_theme'"
        ).fetchone()[0]
    check(selected == "default", "default fallback was not persisted")

    shutil.rmtree(runtime / "themes" / "default")
    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        conn.execute(
            "UPDATE options SET value='removed-theme' WHERE key='active_theme'"
        )
        conn.commit()

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/theme/style.css")
        check(code == 200 and len(body) > 0,
              "missing default theme did not fall back to another installed theme")
        check(
            any(
                "FuguHub selected fallback theme:" in line
                and "embedded-dashboard" in line
                for line in server.lines
            ),
            "non-default theme fallback was not diagnosed",
        )

    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        selected = conn.execute(
            "SELECT value FROM options WHERE key='active_theme'"
        ).fetchone()[0]
    check(
        selected == "embedded-dashboard",
        f"non-default fallback was not persisted: {selected}",
    )

    shutil.rmtree(runtime / "themes" / "embedded-dashboard")
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/")
        check(
            code == 503 and b"No usable CMS theme found" in body,
            "startup did not stop the CMS when no usable theme was installed",
        )


def test_mcp_transfer() -> None:
    source_runtime = fresh_runtime("mcp-transfer-source")
    destination_runtime = fresh_runtime("mcp-transfer-destination")
    (destination_runtime / "assets" / "review-stale-transfer.lsp").write_text(
        """<?lsp
local db = app.appreq "db"
local content = app.appreq "mcpcontent"
local contentpath = app.appreq "contentpath"
local before = db.readOne(app,
   "SELECT id,updated_at FROM content WHERE type='post' AND path='/transfer-test/'")
app.db.writeSync(function(conn)
   local ok, err = conn:execute("UPDATE content SET title='Concurrent destination edit',updated_at=" ..
      db.nextRevision(before.updated_at) .. " WHERE id=" .. tonumber(before.id))
   if not ok then error(err) end
end)
local plan = {}
plan[contentpath.key("post", "/transfer-test/")] = {
   action = "replace",
   existingId = tonumber(before.id),
   expectedUpdatedAt = tonumber(before.updated_at)
}
local result, err, code, details = content.importBatch(app, {{
   type = "post",
   path = "/transfer-test/",
   title = "Stale transfer replacement",
   bodyHtml = "<p>must not replace</p>",
   renderMode = "html",
   status = "published",
   createdAt = os.time(),
   updatedAt = os.time(),
   metaDescription = "",
   headHtml = "",
   cachePolicy = "default",
   terms = {}
}}, plan, false)
response:json {
   ok = result ~= nil,
   error = err,
   code = code,
   details = details
}
?>""",
        encoding="ascii",
    )
    source_token = "source-mcp-token-0123456789"
    destination_token = "destination-mcp-token-012345"

    with MakoProcess(source_runtime, "source") as source, MakoProcess(
        destination_runtime, "destination"
    ) as destination:
        source_browser = Browser(source.origin)
        destination_browser = Browser(destination.origin)
        configure_mcp(source_browser, "/source/", source_token)
        configure_mcp(destination_browser, "/destination/", destination_token)
        source_client = McpClient(source_browser, "/source/mcp/", source_token)
        destination_client = McpClient(
            destination_browser, "/destination/mcp/", destination_token
        )
        source_client.initialize()
        destination_client.initialize()

        transfer_unicode = chr(0x1F680) + chr(0x10437)
        transfer_body = (
            f"<article><p>Transferred body with Unicode {transfer_unicode}.</p></article>"
        )
        created = mcp_structured(
            source_client.call(
                "createContent",
                {
                    "type": "post",
                    "path": "/transfer-test/",
                    "title": "Transfer Test",
                    "bodyHtml": transfer_body,
                    "publish": True,
                    "metaDescription": "Transfer metadata",
                    "headHtml": "<meta name='transfer-test' content='yes'>",
                    "cachePolicy": "revalidate",
                    "terms": [
                        {
                            "type": "category",
                            "name": "Transfer",
                            "slug": "transfer",
                            "description": "Transferred category",
                        },
                        {
                            "type": "tag",
                            "name": "ZIP",
                            "slug": "zip",
                            "description": "ZIP transfer",
                        },
                    ],
                },
            )
        )
        descriptor = mcp_structured(
            source_client.call("prepareContentTransfer", {"ids": [created["id"]]})
        )
        unconfirmed = destination_client.call("importContentTransfer", descriptor)
        check(
            unconfirmed.get("isError") is True
            and unconfirmed["structuredContent"]["code"]
            == "transferSourceRequiresConfirmation",
            f"transfer did not require source-origin confirmation: {unconfirmed}",
        )
        confirmed_args = dict(descriptor)
        confirmed_args["confirmedSourceOrigin"] = source.origin
        imported = mcp_structured(
            destination_client.call("importContentTransfer", confirmed_args)
        )
        check(
            imported["created"] == ["/transfer-test/"]
            and imported["publishedSourceContent"] is False,
            f"initial transfer result is wrong: {imported}",
        )
        with contextlib.closing(sqlite3.connect(database_path(destination_runtime))) as conn:
            row = conn.execute(
                "SELECT status,meta_description,head_html,cache_policy,body_html FROM content WHERE path=?",
                ("/transfer-test/",),
            ).fetchone()
            terms = conn.execute(
                """SELECT t.type,t.slug,t.description
                   FROM terms t JOIN content_terms ct ON ct.term_id=t.id
                   JOIN content c ON c.id=ct.content_id
                   WHERE c.path=? ORDER BY t.type,t.slug""",
                ("/transfer-test/",),
            ).fetchall()
        check(row[0] == "draft", "transferred content was published without explicit import permission")
        check(
            row[1:] == (
                "Transfer metadata",
                "<meta name='transfer-test' content='yes'>",
                "revalidate",
                transfer_body,
            ),
            "transfer lost content metadata or non-BMP Unicode",
        )
        imported_content = mcp_structured(
            destination_client.call("getContent", {"path": "/blog/transfer-test/"})
        )
        check(
            imported_content["bodyHtml"] == transfer_body,
            f"MCP transfer response corrupted non-BMP Unicode: {imported_content}",
        )
        check(
            terms
            == [
                ("category", "transfer", "Transferred category"),
                ("tag", "zip", "ZIP transfer"),
            ],
            f"transfer lost taxonomy assignments: {terms}",
        )
        code, _, stale_transfer_body = destination_browser.request(
            "/destination/review-stale-transfer.lsp"
        )
        stale_transfer = json.loads(stale_transfer_body)
        current_after_stale = mcp_structured(
            destination_client.call("getContent", {"path": "/blog/transfer-test/"})
        )
        check(
            code == 200
            and stale_transfer["ok"] is False
            and stale_transfer["code"] == "contentConflict"
            and stale_transfer["details"]["expectedUpdatedAt"]
            < stale_transfer["details"]["currentUpdatedAt"]
            and current_after_stale["title"] == "Concurrent destination edit",
            f"stale transfer decision overwrote a destination edit: "
            f"{stale_transfer} {current_after_stale}",
        )

        descriptor = mcp_structured(
            source_client.call("prepareContentTransfer", {"paths": ["/blog/transfer-test/"]})
        )
        conflict_args = dict(descriptor)
        conflict_args["confirmedSourceOrigin"] = source.origin
        conflict = destination_client.call("importContentTransfer", conflict_args)
        check(
            conflict.get("isError") is True
            and conflict["structuredContent"]["code"]
            == "contentConflictsRequireDecision",
            f"transfer conflict was not presented as a question: {conflict}",
        )
        question = conflict["structuredContent"].get("question", "")
        check(
            "skipped" in question and "replaced" in question and "new path" in question,
            f"transfer conflict question is incomplete: {question}",
        )
        conflict_args["decisions"] = [
            {
                "path": "/transfer-test/",
                "type": "post",
                "action": "importDraft",
                "newPath": "/transfer-test-copy/",
            }
        ]
        copied = mcp_structured(
            destination_client.call("importContentTransfer", conflict_args)
        )
        check(
            copied["created"] == ["/transfer-test-copy/"],
            f"conflicting transfer was not imported at the selected path: {copied}",
        )


def create_known_repair_database(path: Path) -> None:
    with contextlib.closing(sqlite3.connect(path)) as conn:
        conn.execute(
            """CREATE TABLE content(
               id INTEGER PRIMARY KEY, type TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
               title TEXT NOT NULL, body_html TEXT NOT NULL DEFAULT ''
            )"""
        )
        conn.commit()


def create_unsupported_database(path: Path) -> None:
    with contextlib.closing(sqlite3.connect(path)) as conn:
        conn.execute("CREATE TABLE terms(id INTEGER PRIMARY KEY, type TEXT, name TEXT)")
        conn.commit()


def create_legacy_post_database(path: Path) -> None:
    now = int(time.time())
    with contextlib.closing(sqlite3.connect(path)) as conn:
        conn.execute(
            """CREATE TABLE content(
               id INTEGER PRIMARY KEY,
               type TEXT NOT NULL,
               path TEXT NOT NULL UNIQUE,
               title TEXT NOT NULL,
               body_html TEXT NOT NULL DEFAULT '',
               render_mode TEXT NOT NULL DEFAULT 'html',
               status TEXT NOT NULL DEFAULT 'published',
               created_at INTEGER,
               updated_at INTEGER,
               meta_description TEXT NOT NULL DEFAULT '',
               head_html TEXT NOT NULL DEFAULT '',
               cache_policy TEXT NOT NULL DEFAULT 'default'
            )"""
        )
        conn.execute("CREATE TABLE options(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        conn.execute(
            """INSERT INTO content(
               type,path,title,body_html,render_mode,status,created_at,updated_at,
               meta_description,head_html,cache_policy
               ) VALUES('post','/blog/legacy-post/','Legacy Post','<p>LEGACY POST OK</p>',
               'html','published',?,?, '', '', 'default')""",
            (now, now),
        )
        conn.execute(
            "INSERT INTO options(key,value) VALUES('blog_base_path','/articles/')"
        )
        conn.commit()


def run_headless_dom(
    chrome: Path,
    url: str,
    profile: Path,
    viewport: tuple[int, int] = (1440, 900),
    virtual_time_ms: int = 2000,
) -> str:
    remove_tree(profile)
    result = subprocess.run(
        [
            str(chrome),
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            f"--user-data-dir={profile}",
            f"--window-size={viewport[0]},{viewport[1]}",
            f"--virtual-time-budget={virtual_time_ms}",
            "--dump-dom",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    check(result.returncode == 0, "headless browser failed: " + result.stderr[-500:])
    return result.stdout


def seed_large_menu(runtime: Path) -> None:
    roots = (
        ("Home", "/"),
        ("Web & UI", "/web-ui/"),
        ("Security", "/security/"),
        ("Data", "/data/"),
        ("Messaging & IoT", "/messaging-iot/"),
        ("Platforms", "/platforms/"),
        ("Developer Tools", "/developer-tools/"),
    )
    probe = """<script>
window.addEventListener("load", function () {
   var nav = document.querySelector(".site-nav");
   var roots = Array.from(nav.querySelectorAll(":scope > ul > li"));
   var visibleLinks = function () {
      return Array.from(nav.querySelectorAll("a")).filter(function (link) {
         return link.getClientRects().length > 0;
      }).length;
   };
   document.body.dataset.navRootCount = String(roots.length);
   document.body.dataset.navTotalLinks = String(nav.querySelectorAll("a").length);
   document.body.dataset.navRootLabels = roots.map(function (item) {
      return item.querySelector(":scope > .nav-entry > a").textContent.trim();
   }).join("|");
   document.body.dataset.navVisibleInitial = String(visibleLinks());
   document.body.dataset.navHeaderInitial = String(
      Math.round(document.querySelector(".site-header").getBoundingClientRect().height)
   );
   document.body.dataset.navNestedInitial = String(
      Array.from(nav.querySelectorAll("li > ul")).every(function (list) {
         return getComputedStyle(list).display === "none";
      })
   );
   var content = document.getElementById("large-menu-content");
   var image = document.getElementById("large-menu-image");
   var pre = document.getElementById("large-menu-pre");
   document.body.dataset.contentDocumentWidth = String(document.documentElement.scrollWidth);
   document.body.dataset.contentClientWidth = String(document.documentElement.clientWidth);
   document.body.dataset.contentWidth = String(Math.round(content.getBoundingClientRect().width));
   document.body.dataset.contentImageWidth = String(Math.round(image.getBoundingClientRect().width));
   document.body.dataset.contentPreClientWidth = String(pre.clientWidth);
   document.body.dataset.contentPreScrollWidth = String(pre.scrollWidth);
   var rootButton = roots[1].querySelector(":scope > .nav-entry > .submenu-toggle");
   rootButton.click();
   document.body.dataset.navVisibleLevelOne = String(visibleLinks());
   var nestedButton = roots[1].querySelector(
      ":scope > ul > li > .nav-entry > .submenu-toggle"
   );
    nestedButton.click();
    document.body.dataset.navVisibleLevelTwo = String(visibleLinks());
    var nestedEntry = nestedButton.closest(".nav-entry").getBoundingClientRect();
    var nestedMenu = nestedButton.closest("li").querySelector(":scope > ul").getBoundingClientRect();
    document.body.dataset.navNestedOpensLeft = String(
       nestedButton.closest("li").classList.contains("submenu-opens-left")
    );
    document.body.dataset.navNestedGap = String(Math.round(nestedMenu.left - nestedEntry.right));
    document.body.dataset.navNestedWithinViewport = String(
       nestedMenu.left >= 0 && nestedMenu.right <= document.documentElement.clientWidth
    );
 });
</script>"""
    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        menu_id = conn.execute("SELECT id FROM menus WHERE slug='primary'").fetchone()[0]
        conn.execute("DELETE FROM menu_items WHERE menu_id=?", (menu_id,))
        conn.execute("UPDATE content SET head_html=? WHERE path='/'", (probe,))
        root_ids: list[int] = []
        for position, (label, url) in enumerate(roots, 1):
            cursor = conn.execute(
                """INSERT INTO menu_items(
                   menu_id,parent_id,content_id,label,url,position,hidden
                   ) VALUES(?,NULL,NULL,?,?,?,0)""",
                (menu_id, label, url, position),
            )
            root_ids.append(cursor.lastrowid)

        child_ids: list[int] = []
        for root_index, root_id in enumerate(root_ids[1:], 1):
            root_url = roots[root_index][1]
            for child_index in range(1, 7):
                cursor = conn.execute(
                    """INSERT INTO menu_items(
                       menu_id,parent_id,content_id,label,url,position,hidden
                       ) VALUES(?,?,NULL,?,?,?,0)""",
                    (
                        menu_id,
                        root_id,
                        f"Category {root_index}.{child_index}",
                        f"{root_url}category-{child_index}/",
                        child_index,
                    ),
                )
                child_ids.append(cursor.lastrowid)

        for index, parent_id in enumerate(child_ids[:10], 1):
            conn.execute(
                """INSERT INTO menu_items(
                   menu_id,parent_id,content_id,label,url,position,hidden
                   ) VALUES(?,?,NULL,?,?,1,0)""",
                (
                    menu_id,
                    parent_id,
                    f"Detail {index}",
                    f"/detail-{index}/",
                ),
            )
        conn.commit()


def test_large_menu_render() -> None:
    chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
    if not chrome:
        print("SKIP live large-menu browser test: Chrome/Edge not found")
        return

    runtime = fresh_runtime("large-menu")
    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        create_content(
            browser,
            "/",
            path="/",
            title="Large Menu Test",
            body="""<div id="large-menu-content">
<p>Navigation and responsive-content regression fixture.</p>
<img id="large-menu-image" width="538" height="100" alt=""
 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='538' height='100'%3E%3C/svg%3E">
<pre id="large-menu-pre">This preformatted test line is deliberately much wider than the mobile content container and must scroll inside itself.</pre>
</div>""",
        )
    seed_large_menu(runtime)

    expected_labels = (
        "Home|Web &amp; UI|Security|Data|Messaging &amp; IoT|Platforms|Developer Tools"
    )
    with MakoProcess(runtime) as server:
        for name, viewport, max_header in (
            ("desktop", (1440, 900), 200),
            ("mobile", (390, 844), 700),
        ):
            dom = run_headless_dom(
                chrome,
                server.origin + "/",
                RUNTIME_ROOT / f"chrome-large-menu-{name}",
                viewport,
            )
            check(
                'data-nav-root-count="7"' in dom
                and 'data-nav-total-links="53"' in dom
                and f'data-nav-root-labels="{expected_labels}"' in dom,
                f"{name} public menu did not preserve the seven-root/53-item tree",
            )
            check(
                'data-nav-visible-initial="7"' in dom
                and 'data-nav-nested-initial="true"' in dom,
                f"{name} public menu exposed nested links before interaction",
            )
            level_one = re.search(r'data-nav-visible-level-one="(\d+)"', dom)
            level_two = re.search(r'data-nav-visible-level-two="(\d+)"', dom)
            check(
                bool(level_one and level_two)
                and 7 < int(level_one.group(1)) < 53
                and int(level_two.group(1)) > int(level_one.group(1)),
                f"{name} submenu disclosure did not reveal each hierarchy level",
            )
            header = re.search(r'data-nav-header-initial="(\d+)"', dom)
            check(
                bool(header) and int(header.group(1)) < max_header,
                f"{name} initial navigation is not compact: {header.group(1) if header else 'missing'}px",
            )
            if name == "desktop":
                nested_gap = re.search(r'data-nav-nested-gap="(-?\d+)"', dom)
                check(
                    bool(nested_gap)
                    and int(nested_gap.group(1)) <= 0
                    and 'data-nav-nested-opens-left="false"' in dom
                    and 'data-nav-nested-within-viewport="true"' in dom,
                    "live default theme did not open its left-side nested menu to the right",
                )
            if name == "mobile":
                dimensions = {
                    key: int(match.group(1))
                    for key in (
                        "document-width",
                        "client-width",
                        "width",
                        "image-width",
                        "pre-client-width",
                        "pre-scroll-width",
                    )
                    if (
                        match := re.search(
                            rf'data-content-{key}="(\d+)"', dom
                        )
                    )
                }
                check(
                    len(dimensions) == 6
                    and dimensions["document-width"] <= dimensions["client-width"]
                    and dimensions["image-width"] <= dimensions["width"]
                    and dimensions["pre-scroll-width"]
                    > dimensions["pre-client-width"],
                    f"live default theme did not contain wide mobile content: {dimensions}",
                )


def test_schema_paths() -> None:
    repair = fresh_runtime("schema-repair")
    create_known_repair_database(database_path(repair))
    with MakoProcess(repair) as server:
        browser = Browser(server.origin)
        code, _, _ = browser.request("/admin/")
        check(code == 200, "known additive schema repair did not start")
    with contextlib.closing(sqlite3.connect(database_path(repair))) as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(content)")}
        indexes = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            )
        }
    check("cache_policy" in columns and "render_mode" in columns, "known columns were not repaired")
    check(
        "idx_content_path_status_type" in indexes,
        "published content path index was not repaired",
    )

    unsupported = fresh_runtime("schema-unsupported")
    create_unsupported_database(database_path(unsupported))
    with MakoProcess(unsupported) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/")
        check(code == 503 and b"Unsupported CMS database schema" in body, "unsupported schema was not reported as fatal")


def test_blog_startup_reconciliation() -> None:
    runtime = fresh_runtime("blog-reconciliation")
    create_legacy_post_database(database_path(runtime))

    with MakoProcess(runtime) as server:
        browser = Browser(server.origin)
        code, _, body = browser.request("/articles/legacy-post/")
        check(
            code == 200 and b"LEGACY POST OK" in body,
            "startup did not migrate and route a legacy full post path",
        )
        code, _, _ = browser.request("/blog/legacy-post/")
        check(code == 404, "legacy post route remained active after migration")
    with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
        path = conn.execute(
            "SELECT path FROM content WHERE title='Legacy Post'"
        ).fetchone()[0]
        schema_sql = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='content'"
        ).fetchone()[0]
    check(path == "/legacy-post/", "startup migration did not store a relative post path")
    check(
        "UNIQUE(type, path)" in schema_sql or "UNIQUE(type,path)" in schema_sql,
        "startup migration did not install type-scoped path uniqueness",
    )


def install_smq_test_app(runtime: Path, version: str = "v1") -> None:
    assets = runtime / "assets"
    (assets / "smq-version.txt").write_text(version, encoding="ascii")
    (assets / ".preload").write_text(
        """local versionFile = assert(io:open("smq-version.txt"))
local version = assert(versionFile:read("*a")):gsub("%s+$", "")
versionFile:close()

local removeRpc, rpcErr = app.smq:registerRpcMethod("cmsSmqTestEcho", function(value)
   local ok, publishErr = app.smq:publish({
      value = "event-" .. tostring(value),
      version = version
   }, "CmsSmqTestEvent")
   if ok == nil and publishErr then return nil, publishErr end
   return {
      value = "rpc-" .. tostring(value),
      version = version,
      baseUri = app.baseUri
   }
end)
if not removeRpc then error(rpcErr) end

local removeBrokerStart, startErr = app.smq:onBrokerStart(function(broker)
   broker:subscribe("self", {
      subtopic = "CmsSmqDirectReq",
      json = true,
      onmsg = function(data, ptid)
         broker:publish({
            value = "direct-" .. tostring(data and data.value),
            version = version
         }, ptid, "CmsSmqDirectResp")
      end
   })
end)
if not removeBrokerStart then error(startErr) end
""",
        encoding="ascii",
    )


def smq_first_page(next_path: str) -> str:
    return f"""<section id="smq-first">
<h2>SMQ first page</h2>
<a id="smq-next" href="{next_path}">Next SMQ page</a>
</section>
<script>
(function () {{
   var keepAlive = window.setInterval(function () {{}}, 100);
   window.setTimeout(function () {{
      window.clearInterval(keepAlive);
   }}, 12000);
   var state = {{
      rpc: false,
      event: false,
      direct: false,
      htmx: false,
      navigating: false
   }};
   function fail(error) {{
      document.body.setAttribute("data-smq-error", String(error && error.message || error));
   }}
   function navigateWhenReady() {{
      if (!state.navigating && state.rpc && state.event && state.direct &&
          state.htmx) {{
         state.navigating = true;
         var next = document.getElementById("smq-next");
         document.body.setAttribute("data-smq-navigation-started", "true");
         window.htmx.ajax("GET", next.href, {{
            target: "#cms-main",
            swap: "outerHTML"
         }});
      }}
   }}
   function markHtmxReady() {{
      if (!window.htmx || typeof window.htmx.ajax !== "function") {{
         fail("htmx unavailable");
         return;
      }}
      state.htmx = true;
      document.body.setAttribute("data-smq-htmx-ready", "true");
      navigateWhenReady();
   }}
   document.addEventListener("htmx:load", markHtmxReady, {{ once: true }});
   window.addEventListener("load", function () {{
      setTimeout(markHtmxReady, 100);
   }}, {{ once: true }});
   if (!window.cmsSmq) {{
      fail("cmsSmq unavailable");
      return;
   }}
   window.cmsSmq.mountPage("SMQ integration first", function (scope) {{
      scope.subscribeToEvent("CmsSmqTestEvent", function (message) {{
         document.body.setAttribute("data-smq-event", message.value);
         state.event = true;
         navigateWhenReady();
      }});
      scope.subscribeToDirectMessage("CmsSmqDirectResp", function (message) {{
         document.body.setAttribute("data-smq-direct", message.value);
         state.direct = true;
         navigateWhenReady();
      }});
      scope.onCleanup(function () {{
         document.body.setAttribute("data-smq-cleanup", "true");
         document.body.setAttribute("data-smq-connected-during-cleanup",
            String(window.cmsSmq.isConnected()));
      }});
      scope.onReady(async function () {{
         try {{
            scope.sendToBroker("CmsSmqDirectReq", {{ value: "alpha" }});
            var response = await scope.rpc.cmsSmqTestEcho("alpha");
            document.body.setAttribute("data-smq-rpc", response.value);
            document.body.setAttribute("data-smq-version", response.version);
            document.body.setAttribute("data-smq-base", response.baseUri);
            state.rpc = true;
            navigateWhenReady();
         }} catch (error) {{
            fail(error);
         }}
      }});
   }});
}}());
</script>"""


def smq_second_page() -> str:
    return """<section id="smq-second"><h2>SMQ second page</h2></section>
<script>
(function () {
   function fail(error) {
      document.body.setAttribute("data-smq-error", String(error && error.message || error));
   }
   if (!window.cmsSmq) {
      fail("cmsSmq unavailable on second page");
      return;
   }
   window.cmsSmq.mountPage("SMQ integration second", function (scope) {
      scope.onReady(async function () {
         try {
            var response = await scope.rpc.cmsSmqTestEcho("beta");
            document.body.setAttribute("data-smq-second-rpc", response.value);
            document.body.setAttribute("data-smq-second-version", response.version);
            document.body.setAttribute("data-smq-connected-after-swap",
               String(window.cmsSmq.isConnected()));
         } catch (error) {
            fail(error);
         }
      });
   });
}());
</script>"""


def smq_reconnect_page() -> str:
    return """<section id="smq-reconnect"><h2>SMQ reconnect page</h2></section>
<script>
(function () {
   function count(name) {
      var value = Number(document.body.getAttribute(name) || "0") + 1;
      document.body.setAttribute(name, String(value));
      return value;
   }
   function fail(error) {
      document.body.setAttribute("data-smq-reconnect-error",
         String(error && error.message || error));
   }
   document.addEventListener("cms:smq-connect", function (event) {
      count("data-smq-connect-count");
      document.body.setAttribute("data-smq-connect-generation",
         String(event.detail.generation));
   });
   document.addEventListener("cms:smq-close", function (event) {
      count("data-smq-close-count");
      document.body.setAttribute("data-smq-close-message", event.detail.message);
      document.body.setAttribute("data-smq-close-can-reconnect",
         String(event.detail.canReconnect));
   });
   if (!window.cmsSmq) {
      fail("cmsSmq unavailable");
      return;
   }
   window.cmsSmq.mountPage("SMQ reconnect", function (scope) {
      scope.subscribeToEvent("CmsSmqReconnectEvent", function (message) {
         count("data-smq-event-count");
         document.body.setAttribute("data-smq-event-value", message.value);
      });
      scope.onReady(async function () {
         var sequence = count("data-smq-ready-count");
         try {
            scope.publishEvent("CmsSmqReconnectEvent", {
               value: "event-" + sequence
            });
            var response = await scope.rpc.cmsSmqTestEcho("reconnect-" + sequence);
            document.body.setAttribute("data-smq-rpc-count", String(sequence));
            document.body.setAttribute("data-smq-rpc-value", response.value);
         } catch (error) {
            fail(error);
         }
      });
   });
}());
</script>"""


def run_smq_reconnect_case(runtime: Path, mount: str, chrome: Path) -> None:
    extra_loads = ("-lreload-control::reload-controller",)
    server = MakoProcess(runtime, mount, extra_loads).start()
    replacement: MakoProcess | None = None
    page: HeadlessPage | None = None
    try:
        browser = Browser(server.origin)
        base = f"/{mount}/" if mount else "/"
        create_content(
            browser,
            base,
            path="/smq-reconnect/",
            title="SMQ Reconnect",
            body=smq_reconnect_page(),
        )
        page = HeadlessPage(
            chrome,
            server.origin + base + "smq-reconnect/",
            RUNTIME_ROOT / ("chrome-smq-reconnect-" + (mount or "root")),
        ).start()
        page.wait_for(
            """document.body &&
document.body.getAttribute("data-smq-rpc-count") === "1" &&
document.body.getAttribute("data-smq-event-value") === "event-1" """
        )

        code, _, body = browser.request("/reload-control/reload.lsp")
        check(code == 200, f"SMQ reload controller returned {code}: {body[:1000]!r}")
        reload_result = json.loads(body)
        check(reload_result.get("ok") is True, f"CMS reload failed: {reload_result}")
        reload_close_state = page.wait_for(
            """document.body &&
document.body.getAttribute("data-smq-close-count") && ({
  message: document.body.getAttribute("data-smq-close-message"),
  canReconnect: document.body.getAttribute("data-smq-close-can-reconnect")
})"""
        )
        check(
            reload_close_state.get("canReconnect") == "true",
            "CMS hot reload sent a terminal SMQ disconnect: "
            f"{reload_close_state}",
        )
        try:
            page.wait_for(
                """document.body &&
document.body.getAttribute("data-smq-rpc-count") === "2" &&
document.body.getAttribute("data-smq-event-value") === "event-2" """,
                timeout=20,
            )
        except TestFailure as exc:
            raise TestFailure(
                "SMQ did not reconnect after in-process CMS reload; "
                f"close={reload_close_state}: {exc}"
            ) from exc

        original_port = server.port
        server.stop()
        close_state = page.wait_for(
            """document.body &&
Number(document.body.getAttribute("data-smq-close-count")) >= 2 && ({
  message: document.body.getAttribute("data-smq-close-message"),
  canReconnect: document.body.getAttribute("data-smq-close-can-reconnect")
})"""
        )
        check(
            close_state.get("canReconnect") == "true",
            f"Mako process stop sent a terminal SMQ disconnect: {close_state}",
        )

        replacement = MakoProcess(runtime, mount, extra_loads).start()
        check(
            replacement.port == original_port,
            f"Mako did not restart on the same origin: {original_port} -> {replacement.port}",
        )
        try:
            page.wait_for(
                """document.body &&
document.body.getAttribute("data-smq-rpc-count") === "3" &&
document.body.getAttribute("data-smq-event-value") === "event-3" """,
                timeout=20,
            )
        except TestFailure as exc:
            raise TestFailure(
                f"SMQ did not reconnect after Mako restart; close={close_state}: {exc}"
            ) from exc
    finally:
        if page:
            page.stop()
        if replacement:
            replacement.stop()
        server.stop()


def run_smq_runtime_case(mount: str) -> None:
    runtime = fresh_runtime("smq-" + (mount or "root"))
    install_smq_test_app(runtime)
    chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
    check(bool(chrome), "Chrome or Edge is required for the SMQ browser test")

    with MakoProcess(runtime, mount) as server:
        browser = Browser(server.origin)
        base = f"/{mount}/" if mount else "/"
        endpoint = base + "SMQ/"

        code, _, _ = browser.request(endpoint)
        check(code == 404, f"disabled SMQ endpoint returned {code} at {endpoint}")
        code, headers, body = browser.request(base + "admin/settings/")
        settings_html = text(body, headers)
        disabled_input = re.search(
            r"<input[^>]+id='setting-smq'[^>]*>", settings_html
        )
        check(
            code == 200
            and disabled_input is not None
            and "disabled" in disabled_input.group(0)
            and f"src='{base}admin/settings.js'" in settings_html,
            "admin did not disable SMQ while HTMX was off or load mount-safe settings JS",
        )
        code, _, _ = browser.request(base + "admin/settings.js")
        check(code == 200, "admin SMQ dependency script is not publicly available")

        create_content(
            browser,
            base,
            path="/",
            title="SMQ Home",
            body="<p>SMQ HOME</p>",
        )
        create_content(
            browser,
            base,
            path="/smq-first/",
            title="SMQ First",
            body=smq_first_page(base + "smq-second/"),
        )
        create_content(
            browser,
            base,
            path="/smq-second/",
            title="SMQ Second",
            body=smq_second_page(),
        )

        code, _, _ = admin_post(
            browser,
            base,
            "settings/",
            {
                "blog_base_path": "/blog/",
                "not_found_path": "/404/",
                "smq_enabled": "1",
            },
        )
        check(code == 200, "settings update with SMQ but without HTMX failed")
        with contextlib.closing(sqlite3.connect(database_path(runtime))) as conn:
            forced_off = conn.execute(
                "SELECT value FROM options WHERE key='smq_enabled'"
            ).fetchone()[0]
        check(forced_off == "0", "SMQ was not forced off while HTMX was disabled")

        code, _, _ = admin_post(
            browser,
            base,
            "settings/",
            {
                "blog_base_path": "/blog/",
                "not_found_path": "/404/",
                "htmx_enabled": "1",
                "smq_enabled": "1",
            },
        )
        check(code == 200, "enabling HTMX and SMQ failed")
        code, headers, body = browser.request(base + "admin/settings/")
        settings_html = text(body, headers)
        enabled_input = re.search(
            r"<input[^>]+id='setting-smq'[^>]*>", settings_html
        )
        check(
            code == 200
            and enabled_input is not None
            and "checked" in enabled_input.group(0)
            and "disabled" not in enabled_input.group(0),
            "admin did not show the enabled SMQ setting after HTMX activation",
        )

        code, _, _ = browser.request(endpoint)
        check(code == 400, f"enabled SMQ endpoint did not reject ordinary HTTP: {code}")
        code, _, _ = browser.request(base + "assets/smq/cms-smq.js")
        check(code == 200, "CMS SMQ page-scope client is not publicly available")
        code, _, _ = browser.request("/rtl/smq.js")
        check(code == 200, "Mako SMQ browser client is not publicly available")

        code, headers, body = browser.request(base + "smq-first/")
        rendered = text(body, headers)
        check(
            code == 200
            and f'name="fuguhub-smq-endpoint" content="{endpoint}"' in rendered
            and f'src="{base}assets/smq/cms-smq.js"' in rendered
            and 'src="/rtl/smq.js"' in rendered,
            "SMQ-enabled full shell omitted mount-aware client configuration",
        )

        dom = run_headless_dom(
            chrome,
            server.origin + base + "smq-first/",
            RUNTIME_ROOT / ("chrome-smq-" + (mount or "root")),
            virtual_time_ms=15000,
        )
        expected_base = base
        check('data-smq-error=' not in dom, "SMQ browser workflow failed: " + dom[-1000:])
        check(
            'data-smq-rpc="rpc-alpha"' in dom
            and 'data-smq-event="event-alpha"' in dom
            and 'data-smq-direct="direct-alpha"' in dom,
            "SMQ RPC, event, or direct-message round trip failed: "
            + (re.search(r"<body[^>]*>", dom).group(0)
               if re.search(r"<body[^>]*>", dom) else dom[-1000:]),
        )
        check(
            'data-smq-cleanup="true"' in dom
            and 'data-smq-connected-during-cleanup="true"' in dom
            and 'data-smq-connected-after-swap="true"' in dom
            and 'data-smq-second-rpc="rpc-beta"' in dom
            and f'data-smq-base="{expected_base}"' in dom,
            "SMQ page scope did not survive and clean up across an HTMX swap: "
            + ", ".join(re.findall(r'data-smq-[\w-]+="[^"]*"', dom)),
        )
        check('id="smq-second"' in dom, "HTMX did not navigate to the second SMQ page")
        check(
            'data-smq-version="v1"' in dom
            and 'data-smq-second-version="v1"' in dom,
            "initial asset-owned SMQ RPC registration returned the wrong version",
        )

        if not mount:
            token = "smq-assets-restart-token-0123456789"
            configure_mcp(browser, base, token)
            client = McpClient(browser, base + "mcp/", token)
            client.initialize()
            (runtime / "assets" / "smq-version.txt").write_text("v2", encoding="ascii")
            restarted = mcp_structured(
                client.call("restartAssetsApplication", {"confirmed": True})
            )
            check(
                restarted["ok"] is True
                and restarted["unloaded"] is True
                and restarted["loaded"] is True,
                f"SMQ asset registration restart failed: {restarted}",
            )
            dom = run_headless_dom(
                chrome,
                server.origin + base + "smq-first/",
                RUNTIME_ROOT / "chrome-smq-restarted",
                virtual_time_ms=15000,
            )
            check(
                'data-smq-error=' not in dom
                and 'data-smq-version="v2"' in dom
                and 'data-smq-second-version="v2"' in dom,
                "assets restart retained stale SMQ RPC or broker callbacks: "
                + ", ".join(re.findall(r'data-smq-[\w-]+="[^"]*"', dom)),
            )

        code, _, _ = admin_post(
            browser,
            base,
            "settings/",
            {
                "blog_base_path": "/blog/",
                "not_found_path": "/404/",
                "smq_enabled": "1",
            },
        )
        check(code == 200, "disabling HTMX after SMQ enablement failed")
        code, _, _ = browser.request(endpoint)
        check(code == 404, "SMQ endpoint remained active after HTMX was disabled")
        code, headers, body = browser.request(base + "smq-first/")
        rendered = text(body, headers)
        check(
            "fuguhub-smq-endpoint" not in rendered
            and "/assets/smq/cms-smq.js" not in rendered,
            "SMQ scripts remained in the shell after disablement",
        )


def test_smq_runtime() -> None:
    run_smq_runtime_case("")
    run_smq_runtime_case("mybase")
    runtime = fresh_runtime("smq-reconnect")
    install_smq_test_app(runtime)
    install_reload_controller(runtime)
    chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
    check(bool(chrome), "Chrome or Edge is required for the SMQ reconnect test")
    with MakoProcess(
        runtime, extra_loads=("-lreload-control::reload-controller",)
    ) as setup_server:
        browser = Browser(setup_server.origin)
        code, _, _ = admin_post(
            browser,
            "/",
            "settings/",
            {
                "blog_base_path": "/blog/",
                "not_found_path": "/404/",
                "htmx_enabled": "1",
                "smq_enabled": "1",
            },
        )
        check(code == 200, "enabling HTMX and SMQ for reconnect test failed")
    run_smq_reconnect_case(runtime, "", chrome)


def test_client_script() -> None:
    node = shutil.which("node")
    check(bool(node), "node is required for JavaScript syntax validation")
    scripts = (
        ROOT / "themes" / "default" / "cms.js",
        ROOT / "cms" / "assets" / "smq" / "cms-smq.js",
        ROOT / "cms" / "admin" / "admin.js",
        ROOT / "cms" / "admin" / "settings.js",
        ROOT / "plugins" / "identity-access" / "public" / "admin.js",
        ROOT / "plugins" / "file-services" / "public" / "admin.js",
        ROOT / "plugins" / "large-file-mailer" / "public" / "admin.js",
    )
    for script in scripts:
        subprocess.run(
            [node, "--check", str(script)],
            check=True,
            capture_output=True,
            text=True,
        )

    admin_script = json.dumps(str(ROOT / "cms" / "admin" / "admin.js"))
    admin_response_test = f"""
global.window = {{
  location: {{
    pathname: "/mybase/admin/plugins/file-services/",
    assigned: "",
    assign: function (value) {{ this.assigned = value; }}
  }}
}};
require({admin_script});
var headers = function (value) {{
  return {{ get: function () {{ return value; }} }};
}};
window.FuguHubAdmin.readJson({{
  headers: headers("application/json"),
  json: function () {{
    return Promise.resolve({{
      ok: false,
      error: "CMS admin login required",
      loginUrl: "/mybase/admin/"
    }});
  }},
  status: 401,
  ok: false
}}, "File-service request failed");
setTimeout(async function () {{
  if (window.location.assigned !== "/mybase/admin/") process.exit(2);
  var payload = await window.FuguHubAdmin.readJson({{
    headers: headers("application/json"),
    json: function () {{ return Promise.resolve({{ ok: true, value: 7 }}); }},
    status: 200,
    ok: true
  }}, "File-service request failed");
  if (payload.value !== 7) process.exit(3);
  try {{
    await window.FuguHubAdmin.readJson({{
      headers: headers("text/html"),
      text: function () {{ return Promise.resolve("<!doctype html><p>failure</p>"); }},
      status: 500,
      ok: false
    }}, "File-service request failed");
    process.exit(4);
  }} catch (error) {{
    if (error.message !== "File-service request failed (HTTP 500)") process.exit(5);
  }}
}}, 0);
"""
    subprocess.run(
        [node, "-e", admin_response_test],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )

    chrome = next((path for path in CHROME_CANDIDATES if path.exists()), None)
    if not chrome:
        print("SKIP browser event test: Chrome/Edge not found")
        return
    fixture = RUNTIME_ROOT / "browser.html"
    script_uri = (ROOT / "themes" / "default" / "cms.js").as_uri()
    style_uri = (ROOT / "themes" / "default" / "style.css").as_uri()
    fixture.write_text(
        f"""<!doctype html><html><head>
<link rel="stylesheet" href="{style_uri}">
<meta name="description" content="Initial description">
<meta data-cms-page-head-start>
<style id="initial-page-style">.initial-page-marker {{ color: red; }}</style>
<script id="initial-page-script">window.__pageHeadRuns = 1;</script>
<meta data-cms-page-head-end>
<script>
window.__cmsListenerCounts = {{}};
var nativeDocumentAddEventListener = document.addEventListener.bind(document);
document.addEventListener = function (name, handler, options) {{
   window.__cmsListenerCounts[name] = (window.__cmsListenerCounts[name] || 0) + 1;
   return nativeDocumentAddEventListener(name, handler, options);
}};
</script>
</head><body>
<nav class="site-nav"><ul><li id="parent"><div class="nav-entry"><a href="/parent/">Parent</a>
<button type="button" class="submenu-toggle" aria-expanded="false">Open</button></div>
<ul id="submenu"><li id="nested-parent"><div class="nav-entry"><a href="/parent/child/">Child</a>
<button type="button" class="submenu-toggle" aria-expanded="false">Open child</button></div>
<ul id="nested-submenu"><li><div class="nav-entry"><a href="/parent/child/grandchild/">Grandchild</a></div></li></ul>
</li></ul>
</li></ul></nav>
<nav id="right-nav" class="site-nav" style="position:absolute;right:8px;top:180px"><ul>
<li id="right-parent"><div class="nav-entry"><a href="/right/">Right</a>
<button type="button" class="submenu-toggle" aria-expanded="false">Open right</button></div>
<ul id="right-submenu"><li id="right-nested-parent"><div class="nav-entry"><a href="/right/child/">Right child</a>
<button type="button" class="submenu-toggle" aria-expanded="false">Open right child</button></div>
<ul id="right-nested-submenu"><li><div class="nav-entry"><a href="/right/child/grandchild/">Right grandchild</a></div></li></ul>
</li></ul></li></ul></nav>
<main class="site-main" data-cms-title="Child" data-cms-path="/parent/child/">
<article class="content-card"><div class="cms-body" id="responsive-content">
<img id="wide-image" width="538" height="100" alt="" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='538' height='100'%3E%3C/svg%3E">
<pre id="wide-pre">This preformatted test line is deliberately much wider than the mobile content container and must scroll inside itself.</pre>
</div></article>
<div id="initial-head-marker" class="cms-page-head" data-cms-meta-description="Initial description" hidden></div>
</main>
<script>
document.getElementById("initial-head-marker").setAttribute(
   "data-cms-head-html",
   '<style id="initial-page-style">.initial-page-marker {{ color: red; }}</style>' +
   '<script id="initial-page-script">window.__pageHeadRuns = 1;<\\/script>'
);
</script>
<script src="{script_uri}"></script>
<script>
document.body.setAttribute("data-initial-managed-head",
   String(document.head.querySelectorAll("[data-cms-page-head]").length));
document.body.setAttribute("data-submenu-initial", getComputedStyle(document.getElementById("submenu")).display);
var rootButton = document.querySelector(".submenu-toggle");
rootButton.click();
document.body.setAttribute("data-submenu-open", getComputedStyle(document.getElementById("submenu")).display);
var rootEntry = document.querySelector("#parent > .nav-entry").getBoundingClientRect();
var rootMenu = document.getElementById("submenu").getBoundingClientRect();
document.body.setAttribute("data-submenu-gap", String(Math.round(rootMenu.top - rootEntry.bottom)));
var nestedButton = document.querySelector("#nested-parent > .nav-entry > .submenu-toggle");
nestedButton.click();
var nestedEntry = document.querySelector("#nested-parent > .nav-entry").getBoundingClientRect();
var nestedMenu = document.getElementById("nested-submenu").getBoundingClientRect();
document.body.setAttribute("data-nested-submenu-gap", String(Math.round(nestedMenu.left - nestedEntry.right)));
document.body.setAttribute("data-nested-submenu-opens-left",
   String(document.getElementById("nested-parent").classList.contains("submenu-opens-left")));
document.body.setAttribute("data-nested-submenu-within-viewport",
   String(nestedMenu.left >= 0 && nestedMenu.right <= document.documentElement.clientWidth));
document.body.setAttribute("data-submenu-nested-expanded",
   String(rootButton.getAttribute("aria-expanded") === "true" &&
      nestedButton.getAttribute("aria-expanded") === "true"));
var rightRootButton = document.querySelector("#right-parent > .nav-entry > .submenu-toggle");
rightRootButton.click();
var rightNestedButton = document.querySelector("#right-nested-parent > .nav-entry > .submenu-toggle");
rightNestedButton.click();
var rightNestedEntry = document.querySelector("#right-nested-parent > .nav-entry").getBoundingClientRect();
var rightNestedMenu = document.getElementById("right-nested-submenu").getBoundingClientRect();
document.body.setAttribute("data-right-submenu-gap",
   String(Math.round(rightNestedEntry.left - rightNestedMenu.right)));
document.body.setAttribute("data-right-submenu-opens-left",
   String(document.getElementById("right-nested-parent").classList.contains("submenu-opens-left")));
document.body.setAttribute("data-right-submenu-within-viewport",
   String(rightNestedMenu.left >= 0 && rightNestedMenu.right <= document.documentElement.clientWidth));
rightNestedButton.click();
rightRootButton.click();
var childLink = document.querySelector("#nested-parent > .nav-entry > a");
childLink.addEventListener("click", function (event) {{ event.preventDefault(); }});
childLink.focus();
childLink.click();
document.body.setAttribute("data-submenu-after-link-click",
   getComputedStyle(document.getElementById("submenu")).display);
document.body.setAttribute("data-nested-submenu-after-link-click",
   getComputedStyle(document.getElementById("nested-submenu")).display);
document.body.setAttribute("data-nav-dismissed-after-link-click",
   String(document.querySelector(".site-nav").classList.contains("submenus-dismissed")));
document.body.setAttribute("data-submenu-buttons-closed",
   String(rootButton.getAttribute("aria-expanded") === "false" &&
      nestedButton.getAttribute("aria-expanded") === "false"));
rootButton.click();
document.body.setAttribute("data-submenu-reopened",
   getComputedStyle(document.getElementById("submenu")).display);
document.body.setAttribute("data-nav-dismissed-after-reopen",
   String(document.querySelector(".site-nav").classList.contains("submenus-dismissed")));
rootButton.click();
var content = document.getElementById("responsive-content");
var image = document.getElementById("wide-image");
var pre = document.getElementById("wide-pre");
document.body.setAttribute("data-document-width", String(document.documentElement.scrollWidth));
document.body.setAttribute("data-client-width", String(document.documentElement.clientWidth));
document.body.setAttribute("data-content-width", String(Math.round(content.getBoundingClientRect().width)));
document.body.setAttribute("data-image-width", String(Math.round(image.getBoundingClientRect().width)));
document.body.setAttribute("data-pre-client-width", String(pre.clientWidth));
document.body.setAttribute("data-pre-scroll-width", String(pre.scrollWidth));
document.body.setAttribute("data-overflow-elements", Array.from(document.querySelectorAll("*")).filter(function (element) {{
   var rect = element.getBoundingClientRect();
   return rect.right > document.documentElement.clientWidth + 0.5 || rect.left < -0.5;
}}).map(function (element) {{
   var rect = element.getBoundingClientRect();
   return element.tagName + "." + element.className + ":" + Math.round(rect.left) + "," + Math.round(rect.right);
}}).join("|"));
var nextHead = document.createElement("div");
nextHead.innerHTML = '<div class="cms-page-head" data-cms-meta-description="Replacement description" hidden></div>';
nextHead.querySelector(".cms-page-head").setAttribute(
   "data-cms-head-html",
   '<style id="replacement-page-style">.replacement-page-marker {{ color: green; }}</style>' +
   '<script id="replacement-page-script">window.__pageHeadRuns += 1;<\\/script>'
);
document.body.appendChild(nextHead);
nextHead.dispatchEvent(new CustomEvent("htmx:afterSwap", {{
   bubbles: true,
   detail: {{target: nextHead}}
}}));
document.body.setAttribute("data-page-head-runs", String(window.__pageHeadRuns));
document.body.setAttribute("data-old-head-removed",
   String(!document.getElementById("initial-page-style") && !document.getElementById("initial-page-script")));
document.body.setAttribute("data-new-head-count",
   String(document.head.querySelectorAll("[data-cms-page-head]").length));
document.body.setAttribute("data-head-description",
   document.head.querySelector("meta[name='description']").getAttribute("content"));
document.body.setAttribute("data-after-swap-listeners",
   String(window.__cmsListenerCounts["htmx:afterSwap"] || 0));
document.dispatchEvent(new CustomEvent("htmx:afterSettle", {{detail: {{}}}}));
document.dispatchEvent(new CustomEvent("htmx:sendError", {{detail: {{pathInfo: {{requestPath: "/parent/child/"}}}}}}));
</script></body></html>""",
        encoding="utf-8",
    )
    dom = run_headless_dom(chrome, fixture.as_uri(), RUNTIME_ROOT / "chrome-profile")
    check(
        bool(
            re.search(
                r'<li(?=[^>]*\bid="parent")(?=[^>]*\bclass="[^"]*\bselected\b)[^>]*>',
                dom,
            )
        ),
        "HTMX client did not select the parent menu",
    )
    check('data-submenu-initial="none"' in dom,
          "default theme submenu was visible before interaction")
    check('data-submenu-open="block"' in dom,
          "default theme submenu did not open through its disclosure button")
    check('data-submenu-nested-expanded="true"' in dom,
          "nested submenu controls did not expose their open state")
    check(
        'data-submenu-after-link-click="none"' in dom
        and 'data-nested-submenu-after-link-click="none"' in dom
        and 'data-nav-dismissed-after-link-click="true"' in dom
        and 'data-submenu-buttons-closed="true"' in dom,
        "menu link navigation did not dismiss the persistent HTMX menu",
    )
    check(
        'data-submenu-reopened="block"' in dom
        and 'data-nav-dismissed-after-reopen="false"' in dom,
        "dismissed menu could not be reopened with its disclosure button",
    )
    root_gap = re.search(r'data-submenu-gap="(-?\d+)"', dom)
    nested_gap = re.search(r'data-nested-submenu-gap="(-?\d+)"', dom)
    right_gap = re.search(r'data-right-submenu-gap="(-?\d+)"', dom)
    check(
        bool(root_gap and nested_gap and right_gap)
        and int(root_gap.group(1)) <= 0
        and int(nested_gap.group(1)) <= 0,
        "right-opening desktop submenu positioning contains a pointer dead zone",
    )
    check(
        int(right_gap.group(1)) <= 0
        and 'data-nested-submenu-opens-left="false"' in dom
        and 'data-nested-submenu-within-viewport="true"' in dom
        and 'data-right-submenu-opens-left="true"' in dom
        and 'data-right-submenu-within-viewport="true"' in dom,
        "nested submenus did not open right by default and flip at the viewport edge",
    )
    check('id="cms-htmx-error-overlay"' in dom, "HTMX connection overlay did not appear")
    check(
        'data-initial-managed-head="2"' in dom
        and 'data-page-head-runs="2"' in dom
        and 'data-old-head-removed="true"' in dom
        and 'data-new-head-count="2"' in dom
        and 'data-head-description="Replacement description"' in dom
        and 'data-after-swap-listeners="1"' in dom,
        "HTMX page-head lifecycle retained stale nodes or handled a swap more than once",
    )

    mobile_dom = run_headless_dom(
        chrome,
        fixture.as_uri(),
        RUNTIME_ROOT / "chrome-profile-mobile",
        (390, 844),
    )
    dimensions = {
        name: int(match.group(1))
        for name in (
            "document-width",
            "client-width",
            "content-width",
            "image-width",
            "pre-client-width",
            "pre-scroll-width",
        )
        if (match := re.search(rf'data-{name}="(\d+)"', mobile_dom))
    }
    overflow = re.search(r'data-overflow-elements="([^"]*)"', mobile_dom)
    check(
        len(dimensions) == 6
        and dimensions["image-width"] <= dimensions["content-width"]
        and dimensions["pre-scroll-width"] > dimensions["pre-client-width"],
        "default theme did not contain wide mobile content: "
        f"{dimensions}, overflow={overflow.group(1) if overflow else 'unknown'}",
    )


def main() -> int:
    remove_tree(RUNTIME_ROOT)
    RUNTIME_ROOT.mkdir()
    tests = (
        ("client script", test_client_script),
        ("private module loading", test_private_module_loading),
        ("deployed archive", test_deployed_archive),
        ("plugins", test_plugins),
        ("identity plugin", test_identity_plugin),
        ("identity database reset", test_identity_database_reset),
        ("identity legacy migration", test_identity_legacy_migration),
        ("identity first admin", test_identity_first_admin_bootstrap),
        ("command-line bootstrap", test_command_line_bootstrap),
        ("admin API reauthentication", test_admin_api_reauthentication),
        ("file services plugin", test_file_services_plugin),
        ("large file mailer foundation", test_large_file_mailer_foundation),
        ("large file mailer delivery", test_large_file_mailer_delivery),
        ("large file mailer operations", test_large_file_mailer_operations),
        ("multidomain shared identity", test_multidomain_shared_identity),
        ("appreq hot reload", test_appreq_hot_reload),
        ("assets application reload", test_assets_application_reload),
        ("root runtime", test_root_runtime),
        ("named mount", test_named_mount),
        ("admin HTMX", test_admin_htmx),
        ("MCP API", test_mcp_api),
        ("theme draft persistence", test_theme_draft_persistence),
        ("active directory theme replacement", test_active_directory_theme_replacement),
        ("theme startup recovery", test_theme_startup_recovery),
        ("MCP transfer", test_mcp_transfer),
        ("large menu render", test_large_menu_render),
        ("schema paths", test_schema_paths),
        ("blog startup reconciliation", test_blog_startup_reconciliation),
        ("SMQ runtime", test_smq_runtime),
    )
    try:
        for name, function in tests:
            started = time.time()
            print(f"RUN  {name}", flush=True)
            function()
            print(f"PASS {name} ({time.time() - started:.1f}s)", flush=True)
        print(f"PASS all {len(tests)} test groups", flush=True)
        return 0
    except Exception as exc:
        print(f"FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        traceback.print_exc()
        return 1
    finally:
        remove_tree(RUNTIME_ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
