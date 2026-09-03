from __future__ import annotations

import argparse
import http.client
import http.cookiejar
import re
import shutil
import sqlite3
import statistics
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


MODES = ("DELETE", "WAL", "WAL_NORMAL")


class TestError(RuntimeError):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise TestError(message)


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
                raise TestError("Mako exited during startup:\n" + "\n".join(self.lines))
            if self.port and self.loaded:
                return
            time.sleep(0.05)
        raise TestError("Timed out waiting for FuguHub:\n" + "\n".join(self.lines))

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
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
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

    def multipart(
        self, path: str, fields: dict[str, str], headers: dict[str, str]
    ) -> tuple[int, bytes]:
        boundary = "----FuguHubWal" + uuid.uuid4().hex
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
        request_headers = dict(headers)
        request_headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        return self.request(path, body=b"".join(chunks), headers=request_headers, method="POST")


@dataclass(frozen=True)
class Page:
    content_id: int
    path: str
    title: str
    body: str
    render_mode: str
    cache_policy: str
    meta_description: str
    head_html: str


@dataclass(frozen=True)
class RoundResult:
    mode: str
    reads: int
    read_seconds: float
    read_latencies: tuple[float, ...]
    writes: int
    write_latencies: tuple[float, ...]
    errors: tuple[str, ...]

    @property
    def throughput(self) -> float:
        return self.reads / self.read_seconds


def percentile(values: tuple[float, ...], percent: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * percent
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def set_normal_synchronous(archive: Path) -> None:
    replacement = archive.with_suffix(".patched.zip")
    marker = b'''         configureConnection(writeConn)\n'''
    addition = marker + b'''         local syncOk, syncErr = writeConn:execute("PRAGMA synchronous=NORMAL")\n         if not syncOk then\n            closeWriteConn()\n            error("Configuring SQLite synchronous mode failed: " .. tostring(syncErr), 2)\n         end\n'''
    found = False
    with zipfile.ZipFile(archive, "r") as source, zipfile.ZipFile(replacement, "w") as output:
        for info in source.infolist():
            content = source.read(info.filename)
            if info.filename == ".lua/db.lua":
                check(marker in content, "Could not patch the test database module")
                content = content.replace(marker, addition, 1)
                found = True
            output.writestr(info, content)
    check(found, "The test archive has no .lua/db.lua")
    replacement.replace(archive)


def prepare_runtime(seed: Path, target: Path, mode: str) -> tuple[Page, list[str]]:
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(seed, target)
    database = target / "data" / "cms.sqlite.db"
    check(database.is_file(), f"Seed database was not found: {database}")
    for suffix in ("-shm", "-wal"):
        sidecar = Path(str(database) + suffix)
        if sidecar.exists():
            sidecar.unlink()
    with sqlite3.connect(database, timeout=10) as conn:
        journal_mode = "WAL" if mode.startswith("WAL") else "DELETE"
        selected = conn.execute(f"PRAGMA journal_mode={journal_mode}").fetchone()[0].upper()
        check(
            selected == journal_mode,
            f"SQLite selected journal mode {selected}, expected {journal_mode}",
        )
        row = conn.execute(
            """
            SELECT id,path,title,body_html,render_mode,cache_policy,
                   meta_description,head_html
            FROM content
            WHERE type='page' AND path LIKE '/stress/%'
            ORDER BY length(body_html),id
            LIMIT 1
            """
        ).fetchone()
        check(row is not None, "Seed database has no stress page")
    if mode == "WAL_NORMAL":
        set_normal_synchronous(target / "cms.zip")
    urls_path = target / "stress-urls.txt"
    urls = [
        line.strip()
        for line in urls_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    check(bool(urls), "Stress URL manifest is empty")
    values = [str(value or "") for value in row[1:]]
    return Page(int(row[0]), *values), urls


def csrf(browser: Browser, content_id: int) -> str:
    status, body = browser.request(f"/admin/content/edit?id={content_id}")
    check(status == 200, f"Admin edit page returned HTTP {status}")
    match = re.search(rb"name=['\"]_csrf['\"] value=['\"]([^'\"]+)", body)
    check(bool(match), "Admin edit page did not contain a CSRF token")
    return match.group(1).decode()


def run_round(
    mode: str,
    server: MakoProcess,
    page: Page,
    urls: list[str],
    reads: int,
    concurrency: int,
    write_interval: float,
) -> RoundResult:
    browser = Browser(server.origin)
    token = csrf(browser, page.content_id)
    stop = threading.Event()
    gate = threading.Barrier(concurrency + 2)
    errors: list[str] = []
    result_lock = threading.Lock()
    read_latencies: list[float] = []
    write_latencies: list[float] = []
    jobs = list(range(reads))
    job_lock = threading.Lock()

    def fail(message: str) -> None:
        with result_lock:
            errors.append(message)

    def reader() -> None:
        connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=15)
        local: list[float] = []
        gate.wait()
        try:
            while True:
                with job_lock:
                    if not jobs:
                        break
                    index = jobs.pop()
                started = time.perf_counter()
                try:
                    connection.request(
                        "GET",
                        urls[index % len(urls)],
                        headers={
                            "Accept": "text/html",
                            "Accept-Encoding": "identity",
                            "Cache-Control": "no-cache",
                            "Connection": "keep-alive",
                        },
                    )
                    response = connection.getresponse()
                    response.read()
                    elapsed = (time.perf_counter() - started) * 1000
                    if response.status != 200:
                        fail(f"GET returned HTTP {response.status}")
                    else:
                        local.append(elapsed)
                except Exception as error:
                    fail(f"GET failed: {type(error).__name__}: {error}")
                    connection.close()
                    connection = http.client.HTTPConnection(
                        "127.0.0.1", server.port, timeout=15
                    )
        finally:
            connection.close()
            with result_lock:
                read_latencies.extend(local)

    def writer() -> None:
        sequence = 0
        gate.wait()
        while not stop.is_set():
            sequence += 1
            fields = {
                "_csrf": token,
                "id": str(page.content_id),
                "type": "page",
                "status": "published",
                "title": page.title,
                "path": page.path,
                "render_mode": page.render_mode,
                "cache_policy": page.cache_policy,
                "meta_description": page.meta_description,
                "head_html": page.head_html,
                "body_html": page.body + f"<!-- WAL benchmark {sequence % 2} -->",
            }
            started = time.perf_counter()
            try:
                status, body = browser.multipart(
                    "/admin/content/save.lsp", fields, {"HX-Request": "true"}
                )
                elapsed = (time.perf_counter() - started) * 1000
                if status != 200:
                    fail(f"write returned HTTP {status}: {body[:160]!r}")
                else:
                    write_latencies.append(elapsed)
            except Exception as error:
                fail(f"write failed: {type(error).__name__}: {error}")
            stop.wait(write_interval)

    with ThreadPoolExecutor(max_workers=concurrency + 1) as pool:
        reader_futures = [pool.submit(reader) for _ in range(concurrency)]
        writer_future = pool.submit(writer)
        started = time.perf_counter()
        gate.wait()
        for future in reader_futures:
            future.result()
        elapsed = time.perf_counter() - started
        stop.set()
        writer_future.result()

    return RoundResult(
        mode,
        len(read_latencies),
        elapsed,
        tuple(read_latencies),
        len(write_latencies),
        tuple(write_latencies),
        tuple(errors),
    )


def print_round(index: int, result: RoundResult) -> None:
    print(
        f"{result.mode:<6} round {index}: "
        f"GET {result.throughput:8.2f}/s, "
        f"avg {statistics.fmean(result.read_latencies):7.2f} ms, "
        f"p95 {percentile(result.read_latencies, 0.95):7.2f} ms; "
        f"writes {result.writes:4d}, "
        f"avg {statistics.fmean(result.write_latencies):7.2f} ms, "
        f"errors {len(result.errors)}"
    )


def summarize(results: dict[str, list[RoundResult]]) -> None:
    print("\nMedian of rounds")
    for mode in MODES:
        selected = results[mode]
        throughput = statistics.median(item.throughput for item in selected)
        read_avg = statistics.median(
            statistics.fmean(item.read_latencies) for item in selected
        )
        read_p95 = statistics.median(
            percentile(item.read_latencies, 0.95) for item in selected
        )
        write_avg = statistics.median(
            statistics.fmean(item.write_latencies) for item in selected
        )
        print(
            f"{mode:<6}: GET {throughput:8.2f}/s, avg {read_avg:7.2f} ms, "
            f"p95 {read_p95:7.2f} ms; write avg {write_avg:7.2f} ms"
        )
    delete_rate = statistics.median(item.throughput for item in results["DELETE"])
    for mode in MODES[1:]:
        mode_rate = statistics.median(item.throughput for item in results[mode])
        print(f"{mode} throughput change: {(mode_rate / delete_rate - 1) * 100:+.2f}%")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compare FuguHub mixed read/write performance in DELETE and WAL modes."
    )
    parser.add_argument("--runtime", type=Path, default=Path("deploy-stress"))
    parser.add_argument("--work", type=Path, default=Path(".test-runtime/sqlite-wal"))
    parser.add_argument("--reads", type=int, default=3000)
    parser.add_argument("--concurrency", type=int, default=24)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--write-interval", type=float, default=0.02)
    args = parser.parse_args()
    check(args.runtime.is_dir(), f"Stress deployment was not found: {args.runtime}")
    check(
        args.reads > 0 and args.concurrency > 0 and args.rounds > 0,
        "reads, concurrency, and rounds must be positive",
    )

    results: dict[str, list[RoundResult]] = {mode: [] for mode in MODES}
    args.work.mkdir(parents=True, exist_ok=True)
    try:
        for round_index in range(1, args.rounds + 1):
            offset = (round_index - 1) % len(MODES)
            modes = MODES[offset:] + MODES[:offset]
            for mode in modes:
                target = args.work / f"{mode.lower()}-{round_index}"
                page, urls = prepare_runtime(args.runtime, target, mode)
                server = MakoProcess(target)
                try:
                    server.start()
                    result = run_round(
                        mode,
                        server,
                        page,
                        urls,
                        args.reads,
                        args.concurrency,
                        args.write_interval,
                    )
                finally:
                    server.stop()
                check(result.reads == args.reads, f"{mode} did not complete every GET")
                check(result.writes > 0, f"{mode} completed no writes")
                if result.errors:
                    raise TestError(f"{mode} errors:\n" + "\n".join(result.errors[:20]))
                results[mode].append(result)
                print_round(round_index, result)
        summarize(results)
        return 0
    except TestError as error:
        print(f"ERROR: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
