#!/usr/bin/env python3
"""CodexRunLog hook collector.

Codex passes one JSON object on stdin for each lifecycle hook. This script
appends that object (plus a UTC timestamp) to a JSONL file under
``$CODEX_HOME/runlog/events.jsonl`` so CodexRunLog can read structured events
instead of reconstructing them from rollout JSONL.

The hook must never break a Codex turn, so every failure exits 0.
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import sys

VERSION = 1
MAX_LINE_BYTES = 2_000_000
ROTATE_BYTES = 20_000_000


def codex_home() -> pathlib.Path:
    """Return the active Codex home directory."""
    env = os.environ.get("CODEX_HOME")
    if env:
        return pathlib.Path(env)
    return pathlib.Path.home() / ".codex"


def utc_now() -> str:
    """Return an ISO-8601 UTC timestamp with millisecond precision."""
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def trim_line(payload: dict) -> str:
    """Serialize payload compactly, shrinking oversized tool responses."""
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if len(line.encode("utf-8")) > MAX_LINE_BYTES:
        response = payload.get("tool_response")
        payload["tool_response"] = json.dumps(response, ensure_ascii=False)[:200_000]
        payload["runlog_truncated"] = True
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return line


def rotate(path: pathlib.Path) -> None:
    """Keep the event log bounded by moving an oversized file aside."""
    try:
        if path.exists() and path.stat().st_size >= ROTATE_BYTES:
            os.replace(path, path.with_suffix(path.suffix + ".1"))
    except OSError:
        pass


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        payload = {"raw": raw[:4000], "runlog_parse_error": True}

    if not isinstance(payload, dict):
        payload = {"value": payload}

    payload["logged_at"] = utc_now()
    payload["runlog_hook_version"] = VERSION

    out = codex_home() / "runlog" / "events.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    rotate(out)

    line = trim_line(payload)
    with open(out, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(line + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - hooks must never block Codex
        print(f"codex-runlog-hook: {exc}", file=sys.stderr)
        sys.exit(0)
