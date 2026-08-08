from __future__ import annotations

import argparse
import http.cookiejar
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Entry:
    kind: str
    name: str
    size: int
    render_mode: str

    @property
    def storage_path(self) -> str:
        if self.kind == "post":
            return f"/stress-post-{self.name}/"
        return f"/stress/page-{self.name}/"

    @property
    def public_path(self) -> str:
        if self.kind == "post":
            return f"/blog/stress-post-{self.name}/"
        return self.storage_path

    @property
    def title(self) -> str:
        return f"Stress {self.kind.title()} {self.name.replace('-', ' ').title()}"


SIZES = (
    ("small", 2 * 1024),
    ("medium", 8 * 1024),
    ("large", 32 * 1024),
    ("very-large", 128 * 1024),
    ("fairly-large", 512 * 1024),
)

CORPUS = tuple(
    Entry("page", name, size, "lsp" if index in (1, 3) else "html")
    for index, (name, size) in enumerate(SIZES)
) + tuple(
    Entry("post", name, size, "lsp" if index in (0, 2, 4) else "html")
    for index, (name, size) in enumerate(SIZES)
)


class BuildError(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise BuildError(message)


class MakoProcess:
    def __init__(self, runtime: Path) -> None:
        self.runtime = runtime
        self.process: subprocess.Popen[str] | None = None
        self.lines: list[str] = []
        self.port: int | None = None
        self.loaded = False

    def start(self) -> None:
        executable = shutil.which("mako")
        check(bool(executable), "mako was not found in PATH")
        self.process = subprocess.Popen(
            [str(executable), "-l::cms.zip"],
            cwd=self.runtime,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

        def read_output() -> None:
            assert self.process and self.process.stdout
            for line in self.process.stdout:
                line = line.rstrip()
                self.lines.append(line)
                port = re.search(r"Server listening on IPv4 port (\d+)", line)
                if port and self.port is None:
                    self.port = int(port.group(1))
                if re.match(r'^Loading cms\.zip as "root application" : ok$', line):
                    self.loaded = True

        threading.Thread(target=read_output, daemon=True).start()
        deadline = time.time() + 20
        while time.time() < deadline:
            if self.process.poll() is not None:
                raise BuildError("Mako exited during startup:\n" + "\n".join(self.lines))
            failed = next(
                (line for line in self.lines if 'Loading cms.zip as "root application" : failed:' in line),
                None,
            )
            if failed:
                raise BuildError("FuguHub failed to load:\n" + "\n".join(self.lines))
            if self.port and self.loaded:
                return
            time.sleep(0.05)
        raise BuildError("Timed out waiting for FuguHub:\n" + "\n".join(self.lines))

    def stop(self) -> None:
        if not self.process or self.process.poll() is not None:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

    @property
    def origin(self) -> str:
        check(self.port is not None, "Mako has not started")
        return f"http://127.0.0.1:{self.port}"


class Browser:
    def __init__(self, origin: str) -> None:
        self.origin = origin
        jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(jar),
            urllib.request.HTTPRedirectHandler(),
        )

    def request(
        self,
        path: str,
        *,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        method: str | None = None,
    ) -> tuple[int, bytes]:
        request = urllib.request.Request(
            self.origin + path,
            data=body,
            headers=headers or {},
            method=method,
        )
        try:
            with self.opener.open(request, timeout=15) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def form(self, path: str, fields: dict[str, str], *, multipart: bool = False) -> tuple[int, bytes]:
        if multipart:
            boundary = "----FuguHubStress" + uuid.uuid4().hex
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
            chunks.append(f"--{boundary}--\r\n".encode())
            body = b"".join(chunks)
            content_type = f"multipart/form-data; boundary={boundary}"
        else:
            body = urllib.parse.urlencode(fields).encode()
            content_type = "application/x-www-form-urlencoded"
        return self.request(
            path,
            body=body,
            headers={"Content-Type": content_type},
            method="POST",
        )


def csrf(browser: Browser, path: str) -> str:
    status, body = browser.request(path)
    check(status == 200, f"GET {path} returned HTTP {status}")
    match = re.search(rb"name=['\"]_csrf['\"] value=['\"]([^'\"]+)", body)
    check(bool(match), f"GET {path} did not contain a CSRF token")
    return match.group(1).decode()


def content_body(entry: Entry) -> str:
    identifier = f"stress-{entry.kind}-{entry.name}"
    opening = (
        f'<section class="stress-content" id="{identifier}" '
        f'data-target-bytes="{entry.size}" data-render-mode="{entry.render_mode}">\n'
    )
    lsp = ""
    if entry.render_mode == "lsp":
        lsp = """<?lsp
local checksum = 0
for i = 1, 300 do
   checksum = (checksum + i * 17) % 1000003
end
response:write("<p class='stress-lsp-marker' data-checksum='", checksum,
               "'>LSP executed for ", request:method(), "</p>")
?>
"""
    chunks = [lsp, opening]
    current_size = len(lsp.encode()) + len(opening.encode())
    paragraph = (
        "This deterministic benchmark paragraph exercises database retrieval, "
        "theme rendering, optional LSP execution, response compression, and "
        "network transfer without loading external resources."
    )
    index = 1
    while current_size < entry.size - 32:
        chunk = f"<p data-sequence=\"{index}\">{paragraph}</p>\n"
        chunks.append(chunk)
        current_size += len(chunk.encode())
        index += 1
    chunks.append("</section>")
    return "".join(chunks)


def create_content(browser: Browser, entry: Entry) -> None:
    token = csrf(browser, "/admin/content/new")
    status, body = browser.form(
        "/admin/content/new",
        {
            "_csrf": token,
            "type": entry.kind,
            "status": "published",
            "title": entry.title,
            "path": entry.storage_path,
            "render_mode": entry.render_mode,
            "cache_policy": "no-store" if entry.render_mode == "lsp" else "revalidate",
            "meta_description": f"Deterministic {entry.kind} stress fixture.",
            "head_html": "",
            "body_html": content_body(entry),
        },
        multipart=True,
    )
    check(
        status == 200,
        f"Creating {entry.storage_path} returned HTTP {status}: {body[:300]!r}",
    )


def add_menu_item(browser: Browser, entry: Entry, position: int) -> None:
    token = csrf(browser, "/admin/menus/")
    status, body = browser.form(
        "/admin/menus/",
        {
            "_csrf": token,
            "action": "add",
            "label": entry.title,
            "url": entry.public_path,
            "parent_id": "0",
            "position": str(position),
        },
    )
    check(
        status == 200,
        f"Adding menu item {entry.public_path} returned HTTP {status}: {body[:300]!r}",
    )


def verify_http(browser: Browser) -> None:
    for entry in CORPUS:
        status, body = browser.request(entry.public_path)
        check(status == 200, f"GET {entry.public_path} returned HTTP {status}")
        check(entry.title.encode() in body, f"GET {entry.public_path} omitted the title")
        marker = b"class='stress-lsp-marker'"
        if entry.render_mode == "lsp":
            check(marker in body, f"GET {entry.public_path} did not execute LSP")
        else:
            check(marker not in body, f"GET {entry.public_path} unexpectedly contained an LSP marker")


def verify_database(database: Path) -> None:
    check(database.is_file(), f"Seed database was not created: {database}")
    with sqlite3.connect(database) as connection:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        check(integrity == ("ok",), f"SQLite integrity check failed: {integrity}")
        rows = connection.execute(
            """
            SELECT type,path,render_mode,status,body_html
              FROM content
             WHERE path LIKE '/stress/%' OR path LIKE '/stress-post-%'
             ORDER BY type,path
            """
        ).fetchall()
        check(len(rows) == 10, f"Expected 10 stress entries, found {len(rows)}")
        check(sum(row[0] == "page" for row in rows) == 5, "Expected five stress pages")
        check(sum(row[0] == "post" for row in rows) == 5, "Expected five stress posts")
        check(sum(row[2] == "lsp" for row in rows) == 5, "Expected five LSP stress entries")
        check(all(row[3] == "published" for row in rows), "All stress entries must be published")
        check(max(len(row[4].encode()) for row in rows) >= 512 * 1024, "Largest fixture is too small")
        menu_count = connection.execute(
            "SELECT COUNT(*) FROM menu_items WHERE url LIKE '/stress/%' OR url LIKE '/blog/stress-post-%'"
        ).fetchone()[0]
        check(menu_count == 10, f"Expected 10 stress menu items, found {menu_count}")


def read_urls(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def build(runtime: Path, manifest: Path) -> None:
    runtime = runtime.resolve()
    manifest = manifest.resolve()
    check((runtime / "cms.zip").is_file(), f"Missing {runtime / 'cms.zip'}")
    check((runtime / "themes" / "default.zip").is_file(), "Missing default theme package")
    check(read_urls(manifest) == [entry.public_path for entry in CORPUS], "URL manifest does not match corpus")

    data = runtime / "data"
    if data.exists():
        shutil.rmtree(data)
    data.mkdir()

    server = MakoProcess(runtime)
    try:
        server.start()
        browser = Browser(server.origin)
        for entry in CORPUS:
            print(
                f"Creating {entry.kind:4} {entry.render_mode:4} "
                f"{entry.size // 1024:>3} KiB {entry.public_path}",
                flush=True,
            )
            create_content(browser, entry)
        for position, entry in enumerate(CORPUS, start=1):
            add_menu_item(browser, entry, position * 10)
        verify_http(browser)
    finally:
        server.stop()

    database = data / "cms.sqlite.db"
    verify_database(database)
    for suffix in ("-journal", "-shm", "-wal"):
        check(not Path(str(database) + suffix).exists(), f"Unexpected SQLite sidecar: {database}{suffix}")

    assets = runtime / "assets"
    if assets.exists() and not any(assets.iterdir()):
        assets.rmdir()

    shutil.copy2(manifest, runtime / "stress-urls.txt")
    print(f"Seed database ready: {database}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the deterministic FuguHub stress database.")
    parser.add_argument("--runtime", type=Path, required=True, help="Stress deployment runtime directory.")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("urls.txt"),
        help="Expected public URL manifest.",
    )
    args = parser.parse_args()
    try:
        build(args.runtime, args.manifest)
    except Exception as error:
        print(f"ERROR: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
