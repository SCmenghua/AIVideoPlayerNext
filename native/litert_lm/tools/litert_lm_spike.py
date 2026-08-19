"""Inspect the official LiteRT-LM Gemma package without downloading it.

The runtime itself is intentionally kept outside this helper. This script
only provides repeatable metadata and local-package checks for the Windows
and iOS spikes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_PROXY = "http://127.0.0.1:10808"
MODEL_ID = "litert-community/gemma-4-E2B-it-litert-lm"
MODEL_API = f"https://huggingface.co/api/models/{MODEL_ID}"


def open_url(url: str, proxy: str) -> bytes:
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    opener = urllib.request.build_opener(*handlers)
    request = urllib.request.Request(url, headers={"User-Agent": "AIVideoPlayerNext-LiteRT-LM-Spike/1"})
    with opener.open(request, timeout=30) as response:
        return response.read()


def list_remote(proxy: str) -> int:
    payload = json.loads(open_url(MODEL_API, proxy))
    print(f"repository: {MODEL_ID}")
    print(f"sha: {payload.get('sha', 'unknown')}")
    for item in payload.get("siblings", []):
        name = item.get("rfilename", "")
        size = item.get("size")
        suffix = f" ({size} bytes)" if size is not None else ""
        print(f"{name}{suffix}")
    return 0


def inspect_package(path: str) -> int:
    package = Path(path).expanduser().resolve()
    if not package.is_file():
        print(f"missing: {package}")
        return 2
    if package.suffix.lower() != ".litertlm":
        print(f"unexpected extension: {package.suffix}; expected .litertlm")
        return 2
    print(f"package: {package}")
    print(f"bytes: {package.stat().st_size}")
    print("format: litertlm")
    print("runtime smoke: pending official LiteRT-LM CLI/C++ invocation")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy", default=DEFAULT_PROXY)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list-remote", help="list the official HF deployment package")
    inspect = subparsers.add_parser("inspect", help="inspect a local .litertlm package")
    inspect.add_argument("path")
    args = parser.parse_args()
    if args.command == "list-remote":
        return list_remote(args.proxy)
    return inspect_package(args.path)


if __name__ == "__main__":
    sys.exit(main())
