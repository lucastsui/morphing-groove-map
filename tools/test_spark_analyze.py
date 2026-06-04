#!/usr/bin/env python3
"""
Spark /analyze contract + smoke test.

Sends real songs to the Spark's groove-analysis service and checks that every
response is a `.stt` the iPad app can load WITHOUT crashing, plus a sane report.

The `.stt` validation here mirrors the Swift load path EXACTLY:
  - STTFile.groove()  (MGMKit/Sources/MGMKit/MGMIO.swift)
  - Groove.validate()  (MGMKit/Sources/MGMKit/Model.swift)
so a PASS means MGMIO.decodeSTT(...) on the iPad would succeed. The single most
important check is the CRASH-RISK one: `subdivision % denominator == 0`. On the
iPad that is a `precondition` (slicesPerBeat), NOT a catchable error — a bad
value hard-crashes the app, so it is treated as a hard failure here.

No third-party deps (urllib only). Run AFTER the Spark service is up on :8001.

Usage:
  python3 tools/test_spark_analyze.py                 # bundled WAVs + ~/Downloads/music mp3s
  python3 tools/test_spark_analyze.py --no-music      # bundled Resources WAVs only
  python3 tools/test_spark_analyze.py path/to/song.mp3 ...   # explicit files
  SPARK_URL=http://100.73.106.98:8001 python3 tools/test_spark_analyze.py
  python3 tools/test_spark_analyze.py --save /tmp/spark_out   # dump each response

Exit code 0 = all files returned a loadable .stt; 1 = at least one hard failure.
"""
from __future__ import annotations

import argparse
import json
import math
import mimetypes
import os
import sys
import time
import uuid
import urllib.error
import urllib.request
from pathlib import Path

# ---- contract constants (must match MGMKit/Sources/MGMKit/Model.swift) -------
BF_PER_BEAT = 196608          # one beat = 2^16 * 3
BF_MAX = 196608               # spec range is +/- one beat
MIN_RESOLUTION = 16           # minimumResolution
VALID_UNITS = {"ms", "samples", "bf"}
AUDIO_EXTS = {".wav", ".mp3", ".m4a", ".aif", ".aiff", ".flac"}

REPO = Path(__file__).resolve().parents[1]
RESOURCES = REPO / "GroovePlayer" / "Resources"
MUSIC_DIR = Path.home() / "Downloads" / "music"

DEFAULT_URL = os.environ.get("SPARK_URL", "http://100.73.106.98:8001")
DEFAULT_TIMEOUT = 180


def _finite(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


# ---- HTTP --------------------------------------------------------------------

def _multipart(fields: dict, file_field: str, filename: str,
               filedata: bytes, content_type: str):
    boundary = "----sparktest" + uuid.uuid4().hex
    crlf = b"\r\n"
    b = bytearray()
    for k, v in fields.items():
        b += b"--" + boundary.encode() + crlf
        b += f'Content-Disposition: form-data; name="{k}"'.encode() + crlf + crlf
        b += str(v).encode() + crlf
    b += b"--" + boundary.encode() + crlf
    b += (f'Content-Disposition: form-data; name="{file_field}"; '
          f'filename="{filename}"').encode() + crlf
    b += f"Content-Type: {content_type}".encode() + crlf + crlf
    b += filedata + crlf
    b += b"--" + boundary.encode() + b"--" + crlf
    return bytes(b), boundary


def http_get(url: str, token: str | None, timeout: float):
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def post_analyze(base_url: str, filepath: Path, fields: dict,
                 token: str | None, timeout: float):
    data = filepath.read_bytes()
    ctype = mimetypes.guess_type(str(filepath))[0] or "application/octet-stream"
    body, boundary = _multipart(fields, "file", filepath.name, data, ctype)
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(body)),
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(base_url.rstrip("/") + "/analyze",
                                 data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


# ---- validation (mirrors STTFile.groove() + Groove.validate()) ---------------

def validate_stt(stt) -> tuple[list[str], list[str]]:
    """Return (hard_errors, warnings)."""
    errs: list[str] = []
    warns: list[str] = []
    if not isinstance(stt, dict):
        return (["'stt' is not a JSON object"], warns)

    if stt.get("format") != "STT":
        errs.append(f'format must be "STT" (got {stt.get("format")!r}); decodeSTT rejects otherwise')
    if stt.get("version") != 1:
        warns.append(f'version is {stt.get("version")!r}, expected 1 (not fatal)')

    # time signature "n/d"
    ts = stt.get("timeSignature")
    num = den = None
    if not isinstance(ts, str) or ts.count("/") != 1:
        errs.append(f'timeSignature must be "n/d" (got {ts!r})')
    else:
        a, d = ts.split("/")
        try:
            num, den = int(a), int(d)
        except ValueError:
            errs.append(f'timeSignature not parseable: {ts!r}')

    sub = stt.get("subdivision")
    timing = stt.get("timing")
    if not isinstance(sub, int) or isinstance(sub, bool):
        errs.append(f'subdivision must be an int (got {sub!r})')

    # *** the crash check ***
    if isinstance(sub, int) and not isinstance(sub, bool) and den:
        if sub % den != 0:
            errs.append(f'CRASH RISK: subdivision {sub} is not a multiple of denominator {den} '
                        f'- slicesPerBeat() preconditions and HARD-CRASHES the iPad app')
        else:
            spb = sub // den
            expected = num * spb
            if not isinstance(timing, list):
                errs.append("timing must be an array")
            else:
                if len(timing) != expected:
                    errs.append(f'timing has {len(timing)} slots, grid needs {expected} '
                                f'(= {num} beats x {spb}/beat) - wrongSlotCount')
                if len(timing) < MIN_RESOLUTION:
                    errs.append(f'timing has {len(timing)} slots, below minimum {MIN_RESOLUTION} '
                                f'- belowMinimumResolution')

    if num is not None and stt.get("beats") != num:
        warns.append(f'beats={stt.get("beats")!r} != numerator {num} (informational)')

    unit = stt.get("unit")
    if unit not in VALID_UNITS:
        errs.append(f'unit must be one of {sorted(VALID_UNITS)} (got {unit!r}); JSON decode fails otherwise')

    if isinstance(timing, list):
        nonfinite = [x for x in timing if not _finite(x)]
        if nonfinite:
            errs.append(f'{len(nonfinite)} timing value(s) are NaN/Inf/non-numeric')
        if unit == "bf":
            oor = [x for x in timing if _finite(x) and abs(x) > BF_MAX]
            if oor:
                warns.append(f'{len(oor)} bf timing value(s) exceed +/-{BF_MAX} (will be clamped on render)')
        finite_vals = [x for x in timing if _finite(x)]
        if finite_vals and all(x == 0 for x in finite_vals):
            warns.append("timing is all zeros - no microtiming extracted "
                         "(fold may have failed, or the input is dead-straight)")

    vel = stt.get("velocity")
    if vel is not None:
        if not isinstance(vel, list):
            errs.append("velocity must be an array or omitted")
        else:
            if isinstance(timing, list) and len(vel) != len(timing):
                errs.append(f'velocity has {len(vel)} slots, expected {len(timing)} - laneLengthMismatch')
            bad = [x for x in vel if not _finite(x) or x < 0 or x > 127]
            if bad:
                errs.append(f'{len(bad)} velocity value(s) outside 0..127 - velocityOutOfRange (e.g. {bad[0]})')

    gate = stt.get("gate")
    if gate is not None:
        if not isinstance(gate, list):
            errs.append("gate must be an array or omitted")
        elif isinstance(timing, list) and len(gate) != len(timing):
            errs.append(f'gate has {len(gate)} slots, expected {len(timing)} - laneLengthMismatch')

    return errs, warns


def validate_report(rep) -> list[str]:
    warns: list[str] = []
    if not isinstance(rep, dict):
        return ["'report' missing or not an object - UI tempo/confidence unavailable"]
    bpm = rep.get("tempoBpm")
    if not _finite(bpm) or bpm <= 0:
        warns.append(f'tempoBpm invalid: {bpm!r}')
    elif not (40 <= bpm <= 250):
        warns.append(f'tempoBpm {bpm} outside typical 40-250 (possible octave error)')
    conf = rep.get("confidence")
    if conf is not None and _finite(conf) and not (0 <= conf <= 1):
        warns.append(f'confidence {conf} outside 0..1')
    sr = rep.get("swingRatio")
    if sr is not None and _finite(sr) and not (0 <= sr <= 1):
        warns.append(f'swingRatio {sr} outside 0..1')
    return warns


def looks_like_llm(obj) -> bool:
    return isinstance(obj, dict) and ("choices" in obj or obj.get("object") == "chat.completion")


# ---- driver ------------------------------------------------------------------

def discover_files(args) -> list[Path]:
    if args.files:
        return [Path(f).expanduser() for f in args.files]
    files = sorted(p for p in RESOURCES.glob("*") if p.suffix.lower() in AUDIO_EXTS)
    if not args.no_music and MUSIC_DIR.is_dir():
        files += sorted(p for p in MUSIC_DIR.glob("*") if p.suffix.lower() in AUDIO_EXTS)
    return files


def fmt_range(vals):
    f = [x for x in vals if _finite(x)]
    return f"{min(f):+.0f}/{max(f):+.0f}" if f else "n/a"


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate the Spark /analyze service against the .stt contract.")
    ap.add_argument("files", nargs="*", help="explicit audio files (overrides discovery)")
    ap.add_argument("--url", default=DEFAULT_URL, help=f"service base URL (default {DEFAULT_URL})")
    ap.add_argument("--token", default=os.environ.get("SPARK_TOKEN"), help="bearer token (optional)")
    ap.add_argument("--no-music", action="store_true", help="skip ~/Downloads/music; bundled Resources WAVs only")
    ap.add_argument("--save", metavar="DIR", help="save each response JSON to DIR")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help=f"per-request seconds (default {DEFAULT_TIMEOUT})")
    args = ap.parse_args()

    files = discover_files(args)
    if not files:
        print("No audio files found. Pass files explicitly or use --with-music.", file=sys.stderr)
        return 2
    missing = [f for f in files if not f.is_file()]
    if missing:
        print("Missing files:\n  " + "\n  ".join(str(m) for m in missing), file=sys.stderr)
        return 2

    save_dir = Path(args.save).expanduser() if args.save else None
    if save_dir:
        save_dir.mkdir(parents=True, exist_ok=True)

    print(f"Service : {args.url}")
    print(f"Auth    : {'bearer token' if args.token else 'none'}")
    print(f"Files   : {len(files)}")
    print("-" * 72)

    # health probe (non-fatal)
    try:
        st, body = http_get(args.url.rstrip('/') + "/healthz", args.token, 10)
        print(f"/healthz: HTTP {st}  {body[:80].decode('utf-8', 'replace').strip()}")
    except Exception as e:  # noqa: BLE001
        print(f"/healthz: unreachable ({e}). The Demucs service may not be built/running on :8001 yet.")
    print("-" * 72)

    hard_failures = 0
    for f in files:
        t0 = time.time()
        try:
            status, raw = post_analyze(args.url, f, {}, args.token, args.timeout)
        except urllib.error.HTTPError as e:
            hard_failures += 1
            print(f"[FAIL] {f.name}  HTTP {e.code}\n       {e.read()[:300].decode('utf-8', 'replace')}")
            continue
        except Exception as e:  # noqa: BLE001
            hard_failures += 1
            print(f"[FAIL] {f.name}  request error: {e}")
            continue
        dt = time.time() - t0

        if save_dir:
            (save_dir / (f.stem + ".json")).write_bytes(raw)

        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            hard_failures += 1
            print(f"[FAIL] {f.name}  ({dt:.1f}s) non-JSON response: {raw[:200]!r}")
            continue

        if looks_like_llm(obj) and "stt" not in obj:
            hard_failures += 1
            print(f"[FAIL] {f.name}  ({dt:.1f}s) response looks like the gpt-oss/vLLM OpenAI API, "
                  f"not the groove service.\n       Point --url at the Demucs service "
                  f"(default :8001), not vLLM (:8000).")
            continue

        # accept either the envelope {stt, report} or a bare .stt
        if "stt" in obj:
            stt, report = obj.get("stt"), obj.get("report")
        elif obj.get("format") == "STT":
            stt, report = obj, None
            print(f"  note: {f.name} returned a bare .stt (no {{stt, report}} envelope)")
        else:
            hard_failures += 1
            print(f"[FAIL] {f.name}  ({dt:.1f}s) missing 'stt' key. Top-level keys: {list(obj)[:8]}")
            continue

        errs, warns = validate_stt(stt)
        if report is not None or "report" in obj:
            warns += validate_report(report)

        if errs:
            hard_failures += 1
            print(f"[FAIL] {f.name}  ({dt:.1f}s)")
            for e in errs:
                print(f"       ERROR: {e}")
            for w in warns:
                print(f"       warn:  {w}")
            continue

        timing = stt.get("timing") or []
        vel = stt.get("velocity") or []
        rep = report or {}
        bpm = rep.get("tempoBpm")
        swing = rep.get("swingRatio")
        conf = rep.get("confidence")
        bpm_s = f"{bpm:.1f}bpm" if _finite(bpm) else "bpm?"
        swing_s = f"swing{swing:.2f}" if _finite(swing) else ""
        conf_s = f"conf{conf:.2f}" if _finite(conf) else ""
        velmax = f"velmax{max((x for x in vel if _finite(x)), default=0):.0f}" if vel else ""
        print(f"[PASS] {f.name}  ({dt:.1f}s)  {bpm_s} {swing_s} {conf_s}  "
              f"{len(timing)} slots  timing[{stt.get('unit')}] {fmt_range(timing)}  {velmax}".rstrip())
        for w in warns:
            print(f"       warn:  {w}")

    print("-" * 72)
    total = len(files)
    print(f"{total - hard_failures}/{total} passed"
          + (f"  ({hard_failures} hard failure(s))" if hard_failures else "  - all responses are loadable .stt"))
    return 1 if hard_failures else 0


if __name__ == "__main__":
    sys.exit(main())
