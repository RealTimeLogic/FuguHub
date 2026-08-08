from __future__ import annotations

import argparse
import csv
import http.client
import math
import queue
import random
import ssl
import statistics
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Result:
    path: str
    status: int | None
    elapsed_ms: float
    size: int
    encoding: str
    error: str | None


def read_urls(path: Path) -> list[str]:
    urls = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not urls:
        raise ValueError(f"No URLs found in {path}")
    if any(not path.startswith("/") for path in urls):
        raise ValueError("Every URL path must begin with /")
    return urls


def normalize_base(value: str) -> str:
    value = "/" + value.strip("/")
    return "/" if value == "/" else value + "/"


def mounted_path(base: str, path: str) -> str:
    return path if base == "/" else base.rstrip("/") + "/" + path.lstrip("/")


def percentile(values: list[float], percent: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * percent
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


class Fetcher:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.context: ssl.SSLContext | None = None
        if args.scheme == "https":
            self.context = ssl.create_default_context()
            if args.insecure:
                self.context.check_hostname = False
                self.context.verify_mode = ssl.CERT_NONE

    def connection(self) -> http.client.HTTPConnection:
        if self.args.scheme == "https":
            return http.client.HTTPSConnection(
                self.args.host,
                self.args.port,
                timeout=self.args.timeout,
                context=self.context,
            )
        return http.client.HTTPConnection(
            self.args.host,
            self.args.port,
            timeout=self.args.timeout,
        )

    def one(self, connection: http.client.HTTPConnection, path: str) -> Result:
        headers = {
            "Accept": "text/html",
            "Accept-Encoding": self.args.encoding,
            "User-Agent": "FuguHub-Stress/1.0",
            "Connection": "close" if self.args.no_keepalive else "keep-alive",
        }
        started = time.perf_counter()
        try:
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            body = response.read()
            elapsed = (time.perf_counter() - started) * 1000
            return Result(
                path,
                response.status,
                elapsed,
                len(body),
                response.getheader("Content-Encoding", "identity"),
                None,
            )
        except Exception as error:
            elapsed = (time.perf_counter() - started) * 1000
            return Result(path, None, elapsed, 0, "", f"{type(error).__name__}: {error}")


def warm_up(fetcher: Fetcher, paths: list[str], rounds: int) -> None:
    if rounds <= 0:
        return
    connection = fetcher.connection()
    try:
        for _ in range(rounds):
            for path in paths:
                result = fetcher.one(connection, path)
                if result.error or result.status != 200:
                    raise RuntimeError(
                        f"Warm-up GET {path} failed: "
                        f"{result.error or f'HTTP {result.status}'}"
                    )
                if fetcher.args.no_keepalive:
                    connection.close()
                    connection = fetcher.connection()
    finally:
        connection.close()


def run_load(
    fetcher: Fetcher,
    paths: list[str],
    request_count: int,
    concurrency: int,
) -> tuple[list[Result], float]:
    jobs: queue.Queue[str] = queue.Queue()
    scheduled = [paths[index % len(paths)] for index in range(request_count)]
    random.Random(42).shuffle(scheduled)
    for path in scheduled:
        jobs.put(path)

    workers = min(concurrency, request_count)
    gate = threading.Barrier(workers + 1)
    results: list[Result] = []
    result_lock = threading.Lock()

    def worker() -> None:
        connection = fetcher.connection()
        local: list[Result] = []
        gate.wait()
        try:
            while True:
                try:
                    path = jobs.get_nowait()
                except queue.Empty:
                    break
                result = fetcher.one(connection, path)
                local.append(result)
                if result.error or fetcher.args.no_keepalive:
                    connection.close()
                    connection = fetcher.connection()
        finally:
            connection.close()
            with result_lock:
                results.extend(local)

    with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="fuguhub-stress") as pool:
        futures = [pool.submit(worker) for _ in range(workers)]
        started = time.perf_counter()
        gate.wait()
        for future in futures:
            future.result()
        wall_time = time.perf_counter() - started
    return results, wall_time


def latency_line(results: list[Result]) -> str:
    values = [result.elapsed_ms for result in results]
    return (
        f"avg={statistics.fmean(values):.2f} ms  "
        f"median={statistics.median(values):.2f} ms  "
        f"p95={percentile(values, 0.95):.2f} ms  "
        f"p99={percentile(values, 0.99):.2f} ms  "
        f"min={min(values):.2f} ms  max={max(values):.2f} ms"
    )


def report(args: argparse.Namespace, results: list[Result], wall_time: float) -> int:
    successes = [result for result in results if result.error is None and result.status == 200]
    failures = [result for result in results if result.error is not None or result.status != 200]
    target = f"{args.scheme}://{args.host}:{args.port}{normalize_base(args.base)}"
    print()
    print("FuguHub stress test")
    print(f"Target:       {target}")
    print(f"Requests:     {len(results)}")
    print(f"Concurrency:  {min(args.concurrency, args.requests)}")
    print(f"Connections:  {'new per request' if args.no_keepalive else 'persistent per worker'}")
    print(f"Compression:  Accept-Encoding: {args.encoding}")
    print(f"Wall time:    {wall_time:.3f} s")
    print(f"Throughput:   {len(results) / wall_time:.2f} requests/s")
    print(f"Successful:   {len(successes)}")
    print(f"Failed:       {len(failures)}")
    print(f"Body bytes:   {sum(result.size for result in successes):,}")
    if successes:
        print(f"Latency:      {latency_line(successes)}")

    print()
    print("Per URL")
    for path in sorted({result.path for result in results}):
        selected = [
            result
            for result in successes
            if result.path == path
        ]
        failed = sum(1 for result in failures if result.path == path)
        if selected:
            print(f"{path:<46} {latency_line(selected)}  failed={failed}")
        else:
            print(f"{path:<46} no successful requests  failed={failed}")

    if failures:
        print()
        print("Failures")
        summaries: dict[str, int] = {}
        for result in failures:
            message = result.error or f"HTTP {result.status}"
            summaries[message] = summaries.get(message, 0) + 1
        for message, count in sorted(summaries.items()):
            print(f"{count:>6}  {message}")
    return 0 if not failures else 1


def write_csv(path: Path, results: list[Result]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow(("path", "status", "elapsed_ms", "body_bytes", "content_encoding", "error"))
        for result in results:
            writer.writerow(
                (
                    result.path,
                    result.status or "",
                    f"{result.elapsed_ms:.6f}",
                    result.size,
                    result.encoding,
                    result.error or "",
                )
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Issue concurrent GET requests against the FuguHub stress corpus."
    )
    parser.add_argument("--host", default="localhost", help="Domain name or IP address.")
    parser.add_argument("--port", type=int, help="HTTP port; defaults to 80 or 443.")
    parser.add_argument("--scheme", choices=("http", "https"), default="http")
    parser.add_argument("--base", default="/", help="CMS base path, for example /mybase/.")
    parser.add_argument("--requests", type=int, default=1000, help="Total measured requests.")
    parser.add_argument("--concurrency", type=int, default=16, help="Simultaneous worker count.")
    parser.add_argument("--warmup", type=int, default=1, help="Warm-up rounds per URL.")
    parser.add_argument("--timeout", type=float, default=10.0, help="Per-request timeout in seconds.")
    parser.add_argument(
        "--encoding",
        choices=("deflate", "identity"),
        default="deflate",
        help="Requested response content encoding.",
    )
    parser.add_argument("--no-keepalive", action="store_true", help="Open a new connection per GET.")
    parser.add_argument("--insecure", action="store_true", help="Disable HTTPS certificate validation.")
    parser.add_argument(
        "--urls",
        type=Path,
        default=Path(__file__).with_name("urls.txt"),
        help="Text file containing public URL paths.",
    )
    parser.add_argument("--csv", type=Path, help="Optional per-request CSV output.")
    args = parser.parse_args()
    if args.requests < 1:
        parser.error("--requests must be at least 1")
    if args.concurrency < 1:
        parser.error("--concurrency must be at least 1")
    if args.warmup < 0:
        parser.error("--warmup cannot be negative")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if not (1 <= (args.port or (443 if args.scheme == "https" else 80)) <= 65535):
        parser.error("--port must be between 1 and 65535")
    args.port = args.port or (443 if args.scheme == "https" else 80)
    args.base = normalize_base(args.base)
    return args


def main() -> int:
    args = parse_args()
    try:
        source_paths = read_urls(args.urls)
        paths = [mounted_path(args.base, path) for path in source_paths]
        fetcher = Fetcher(args)
        print(
            f"Warming {len(paths)} URLs with {args.warmup} round(s); "
            f"then issuing {args.requests} GETs at concurrency {args.concurrency}...",
            flush=True,
        )
        warm_up(fetcher, paths, args.warmup)
        results, wall_time = run_load(fetcher, paths, args.requests, args.concurrency)
        if args.csv:
            write_csv(args.csv, results)
            print(f"CSV: {args.csv.resolve()}")
        return report(args, results, wall_time)
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130
    except Exception as error:
        print(f"ERROR: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
