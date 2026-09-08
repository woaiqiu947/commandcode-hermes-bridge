#!/usr/bin/env python3
"""Sequential single-flight model probe for OpenAI-compatible subscription bridges.

Safe for single-credential bridges: parallel bursts trip per-credential concurrency
and cooldown, turning supported models into 502/503 noise (see hermes-external-provider-bridge
SKILL.md probing rules). Serial with one retry per 5xx is the reliable classifier:

  200                          -> supported
  400/401/402/403/404          -> unsupported (plan/model level, reliable)
  persistent 429/5xx/timeout   -> flaky (do NOT remove; re-check later)

Usage:
  python3 probe_bridge_models.py [base_url]        # base_url default http://127.0.0.1:9992
Reads BRIDGE_API_KEY from BRIDGE_KEY env var, else from ~/commandcode-bridge/.env.
Model list source: GET {base}/v1/models (canonical list the bridge exposes).
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9992").rstrip("/")
KEY = os.environ.get("BRIDGE_KEY", "")
if not KEY:
    try:
        content = open(os.path.expanduser("~/commandcode-bridge/.env"), encoding="utf-8").read()
        m = re.search(r"^BRIDGE_API_KEY=(\S+)", content, flags=re.M)
        KEY = m.group(1) if m else ""
    except OSError:
        pass
if not KEY:
    sys.exit("BRIDGE_KEY not found: set env BRIDGE_KEY or fill ~/commandcode-bridge/.env")

HDRS = {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"}
GAP_S = 6  # seconds between probes (respect cooldown)
RETRY_AFTER_S = 15


def get_models():
    req = urllib.request.Request(BASE + "/v1/models", headers=HDRS)
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    return [m["id"] for m in data.get("data", data if isinstance(data, list) else [])]


def probe(model_id, timeout=150):
    body = json.dumps({
        "model": model_id,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
        "temperature": 0,
        "stream": False,
    }).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=body, method="POST", headers=HDRS)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:  # noqa: BLE001 - network/timeout bucket
        return type(e).__name__


def main():
    ids = get_models()
    print(f"{len(ids)} models; probing sequentially with {GAP_S}s gaps", flush=True)
    ok, bad, flaky = [], [], []
    for i, mid in enumerate(ids, 1):
        c1 = probe(mid)
        c2 = None
        if not isinstance(c1, int) or c1 in (429, 500, 502, 503, 504):
            time.sleep(RETRY_AFTER_S)
            c2 = probe(mid)
        final = c2 if c2 is not None else c1
        verdict = "ok" if final == 200 else "bad" if isinstance(final, int) and final in (400, 401, 402, 403, 404) else "flaky"
        (ok if verdict == "ok" else bad if verdict == "bad" else flaky).append(mid)
        print(f"[{i}/{len(ids)}] {mid} -> {c1}" + (f" then {c2}" if c2 is not None else "") + f"  => {verdict}", flush=True)
        time.sleep(GAP_S)
    print(f"\n=== SUPPORTED ({len(ok)}) ===")
    print("\n".join(ok))
    print(f"\n=== UNSUPPORTED ({len(bad)}) ===")
    print("\n".join(bad))
    print(f"\n=== FLAKY ({len(flaky)}) — re-check later, do not remove ===")
    print("\n".join(flaky))


if __name__ == "__main__":
    main()
