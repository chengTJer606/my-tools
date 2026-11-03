# -*- coding: utf-8 -*-
"""
dedup_scan.py — Recursively walk one or more Baidu Netdisk folders and dump
the full file inventory (path / name / size / md5 / fsid / category) as JSON.

This is a READ-ONLY tool. It uses the personal-experience access_token against
the public xpan REST endpoints. Write operations go through the MCP SSE entry
in Claude Code; this script never writes to the disk side.

Usage
-----
    python dedup_scan.py <root_path> [<root_path> ...] [-o OUT.json] [--token TOKEN]

Each root is walked recursively. Every emitted record carries a `tree` field
set to the originating root path, so downstream analyses can tell which top
-level folder a file came from.

Token resolution order: --token flag > $BAIDU_TOKEN > .claude.json
mcpServers.baidu-netdisk.url#access_token.

Output
------
JSON list of dicts. Schema:
    {
      "path":         "/abs/path/in/netdisk",
      "name":         "filename.ext",
      "parent_dir":   "/abs/parent",
      "size":         int (bytes),
      "md5":          str (may be "" for folders / large oddities),
      "fsid":         int,
      "category":     int (1=video, 2=audio, 3=image, 4=doc, 5=app, 6=other, 7=torrent),
      "isdir":        0,
      "tree":         "<root_path argument this file came from>",
      "server_mtime": int (unix seconds)
    }
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import deque
from typing import Iterable, Iterator

import requests
import urllib3

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

# Suppress InsecureRequestWarning from proxy-intercepting SSL
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

BASE = "https://pan.baidu.com/rest/2.0/xpan/file"
PAGE_LIMIT = 100  # xpan list hard ceiling per request

# --------------------------------------------------------------------------- #
# Token resolution
# --------------------------------------------------------------------------- #
def load_token_from_claude_json() -> str | None:
    candidates = [
        os.path.expanduser("~/.claude.json"),
        os.path.join(os.path.expanduser("~"), ".claude.json"),
    ]
    for path in candidates:
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                url = (
                    data.get("mcpServers", {})
                    .get("baidu-netdisk", {})
                    .get("url", "")
                )
                m = re.search(r"access_token=([^&\s]+)", url)
                if m:
                    return m.group(1)
            except Exception:
                continue
    return None


def resolve_token(cli_token: str | None) -> str:
    if cli_token:
        return cli_token
    env = os.environ.get("BAIDU_TOKEN")
    if env:
        return env
    from_json = load_token_from_claude_json()
    if from_json:
        return from_json
    sys.exit(
        "[FATAL] no access_token. Pass --token, set $BAIDU_TOKEN, "
        "or configure mcpServers.baidu-netdisk.url in ~/.claude.json"
    )


# --------------------------------------------------------------------------- #
# Shared requests session (connection pooling + SSL tolerance)
# --------------------------------------------------------------------------- #
_SESSION: requests.Session | None = None


def _get_session() -> requests.Session:
    global _SESSION
    if _SESSION is None:
        _SESSION = requests.Session()
        _SESSION.verify = False
        _SESSION.headers.update({"User-Agent": "curl/8"})
        _SESSION.proxies.update(urllib.request.getproxies())
        # Mount a retry adapter to survive intermittent proxy SSL failures
        from requests.adapters import HTTPAdapter
        from urllib3.util.retry import Retry
        retry = Retry(
            total=5,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["GET"],
        )
        adapter = HTTPAdapter(max_retries=retry)
        _SESSION.mount("https://", adapter)
    return _SESSION


# --------------------------------------------------------------------------- #
# xpan list API
# --------------------------------------------------------------------------- #
def api_list(path: str, token: str, start: int = 0,
             limit: int = PAGE_LIMIT) -> dict:
    """Single xpan list call. Returns the raw decoded JSON dict."""
    params = {
        "method": "list",
        "dir": path,
        "order": "time",
        "desc": 1,
        "start": start,
        "limit": limit,
        "web": 1,
        "access_token": token,
    }
    _RETRIES = 3
    last_err = None
    for attempt in range(_RETRIES):
        try:
            r = _get_session().get(BASE, params=params, timeout=60)
            r.raise_for_status()
            return r.json()
        except (requests.exceptions.SSLError, requests.exceptions.ConnectionError) as e:
            last_err = e
            if attempt < _RETRIES - 1:
                time.sleep(1.0 * (attempt + 1))
                continue
            raise
    raise last_err  # type: ignore[misc]


def walk(root: str, token: str, label: str = "",
         skip_dirs: Iterable[str] = ()) -> Iterator[dict]:
    """BFS walk; yields flat file records (folders are traversed, not yielded).

    `skip_dirs` is a tuple of absolute paths to skip entirely (e.g. known
    junk folders you do not want to pay API calls for).
    """
    skip_set = {p.rstrip("/") for p in skip_dirs}
    queue: deque[tuple[str, int]] = deque([(root, 0)])
    seen = 0
    t0 = time.time()
    while queue:
        cur, depth = queue.popleft()
        # Skip enqueued dirs that match skip_dirs
        if cur.rstrip("/") in skip_set:
            continue
        start = 0
        while True:
            try:
                resp = api_list(cur, token, start=start)
            except Exception as e:
                print(f"  [ERR] {cur}: {e}", flush=True)
                break
            if resp.get("errno"):
                print(
                    f"  [ERRNO {resp['errno']}] {cur}: "
                    f"{resp.get('errmsg', '')}",
                    flush=True,
                )
                break
            items = resp.get("list", [])
            if not items:
                break
            for it in items:
                if it.get("isdir"):
                    queue.append((it["path"], depth + 1))
                else:
                    parent = it.get("path", "").rsplit("/", 1)[0]
                    yield {
                        "path": it.get("path"),
                        "name": it.get("server_filename")
                        or it.get("filename", ""),
                        "parent_dir": parent,
                        "size": it.get("size", 0),
                        "md5": it.get("md5", "") or "",
                        "fsid": it.get("fs_id"),
                        "category": it.get("category", 6),
                        "isdir": 0,
                        "tree": root,
                        "server_mtime": it.get("server_mtime", 0),
                    }
                    seen += 1
                    if seen % 100 == 0:
                        rate = seen / max(time.time() - t0, 1e-9)
                        print(
                            f"  [{label}] {seen} files "
                            f"({rate:.1f} files/s, depth={depth})",
                            flush=True,
                        )
            if len(items) < PAGE_LIMIT:
                break
            start += PAGE_LIMIT


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main() -> None:
    ap = argparse.ArgumentParser(
        description="Walk Baidu Netdisk folders and dump a JSON inventory.",
    )
    ap.add_argument("roots", nargs="+",
                    help="one or more absolute netdisk paths to scan")
    ap.add_argument("-o", "--output", default="dedup_result.json",
                    help="output JSON file (default: dedup_result.json)")
    ap.add_argument("--token", default=None,
                    help="access_token (default: read from .claude.json)")
    ap.add_argument("--skip", action="append", default=[],
                    help="absolute path to skip (can repeat)")
    args = ap.parse_args()

    token = resolve_token(args.token)

    all_records: list[dict] = []
    t0 = time.time()
    for root in args.roots:
        print(f"[SCAN] {root}", flush=True)
        n_before = len(all_records)
        for rec in walk(root, token, label=root, skip_dirs=args.skip):
            all_records.append(rec)
        print(
            f"[SCAN] {root} -> {len(all_records) - n_before} files "
            f"(total {len(all_records)}, elapsed {time.time() - t0:.1f}s)",
            flush=True,
        )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(all_records, f, ensure_ascii=False, indent=2)

    total_bytes = sum(r["size"] for r in all_records)
    print("", flush=True)
    print(f"[DONE] {len(all_records)} files, "
          f"{total_bytes / 1e9:.2f} GB total, "
          f"{time.time() - t0:.1f}s elapsed", flush=True)
    print(f"[SAVED] {args.output}", flush=True)


if __name__ == "__main__":
    main()
