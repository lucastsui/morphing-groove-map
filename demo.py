"""End-to-end demo of the Morphing Groove Map pipeline.

    amen.wav  --extract-->  amen.mgm  --apply+render-->  grooved_loop.wav

Usage
-----
With your own files::

    uv run python demo.py path/to/amen_break.wav path/to/stiff_loop.wav

With no arguments it SYNTHESIZES a swung "source" loop and a stiff "target"
loop into ./examples so you can hear the whole thing work without supplying
any audio::

    uv run python demo.py

Outputs (in ./examples):
    source.wav / target.wav   -- inputs (synthesized if none supplied)
    amen.mgm                  -- the extracted swing, as readable JSON
    grooved_000.wav           -- target at dial 0   (no swing applied)
    grooved_063.wav           -- target at dial 63  (half the stolen swing)
    grooved_127.wav           -- target at dial 127 (full stolen swing)
"""
from __future__ import annotations

import os
import sys

import numpy as np
import soundfile as sf

from mgm import (
    Groove,
    GrooveMap,
    TimeSignature,
    extract_groove_from_audio,
    groove_from_offsets,
    render_grooved_audio,
    save_mgm,
)

EXAMPLES = os.path.join(os.path.dirname(__file__), "examples")
SR = 48000


def _click(n_clicks, gap_s, swing_ms, sr=SR, seed=0):
    """Synthesize a drum-ish click track; odd slots pushed `swing_ms` late."""
    rng = np.random.default_rng(seed)
    total = int(sr * gap_s * n_clicks) + sr // 4
    y = np.zeros(total, dtype=np.float32)
    burst = int(sr * 0.012)
    for i in range(n_clicks):
        nudge = (swing_ms / 1000.0) if (i % 2 == 1) else 0.0
        start = int((i * gap_s + nudge) * sr)
        env = np.linspace(1.0, 0.0, burst, dtype=np.float32) ** 2
        y[start:start + burst] += rng.standard_normal(burst).astype(np.float32) * env * 0.6
    return y, sr


def _ensure_inputs(argv):
    """Return (source_path, target_path), synthesizing defaults if needed."""
    os.makedirs(EXAMPLES, exist_ok=True)
    if len(argv) >= 3:
        return argv[1], argv[2]
    print("No audio supplied -> synthesizing a swung source and a stiff target.")
    src = os.path.join(EXAMPLES, "source.wav")
    tgt = os.path.join(EXAMPLES, "target.wav")
    y_src, sr = _click(8, 0.25, swing_ms=55, seed=1)   # heavily swung
    y_tgt, _ = _click(8, 0.25, swing_ms=0, seed=2)     # dead straight
    sf.write(src, y_src, sr)
    sf.write(tgt, y_tgt, sr)
    return src, tgt


def main(argv):
    source_path, target_path = _ensure_inputs(argv)

    # 1. EXTRACT the groove from the source (the hard, stub stage).
    print(f"\n[1/3] Extracting groove from {source_path} ...")
    stolen = extract_groove_from_audio(
        source_path, time_signature="4/4", subdivision=8, unit="ms"
    )
    print("      timing offsets (ms):",
          [round(v, 1) for v in stolen.timing])

    # Build a morph map: straight (all zeros) at dial 0, stolen feel at 127.
    straight = groove_from_offsets([0] * stolen.slots, "4/4", 8, unit="ms")
    gmap = GrooveMap({0: straight, 127: stolen})

    # 2. SAVE the swing file.
    mgm_path = os.path.join(EXAMPLES, "amen.mgm")
    save_mgm(mgm_path, gmap)
    print(f"\n[2/3] Saved swing file -> {mgm_path}")

    # 3. RENDER the target at three dial positions.
    print(f"\n[3/3] Stamping groove onto {target_path} at dials 0 / 63 / 127 ...")
    for dial in (0, 63, 127):
        resolved = gmap.resolve(dial)
        out_path = os.path.join(EXAMPLES, f"grooved_{dial:03d}.wav")
        report = render_grooved_audio(target_path, resolved, out_path)
        print(f"      dial {dial:3d} -> {out_path} "
              f"({report['onsets_detected']} onsets)")

    print("\nDone. Listen to examples/grooved_000 vs _063 vs _127 to hear the morph.")


if __name__ == "__main__":
    main(sys.argv)
