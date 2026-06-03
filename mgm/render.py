"""Render new audio by stamping a groove onto a target file.

Strategy (the "new part" beyond the pure-data spec):

  1. Detect onsets in the target audio.
  2. Slice the audio into one chunk per onset (chunk = onset_i .. onset_i+1).
  3. Shift each chunk later/earlier by its slot's groove offset.
  4. Overlap-add the shifted chunks into a fresh buffer, with short
     crossfades at the seams to hide clicks.

This works best on PERCUSSIVE / drum material with clean transients (exactly
the Amen-break use case).  Shifting a chunk late opens a small gap; shifting
early can overlap the previous chunk's tail -- the crossfade masks most, not
all, of it.  It re-times existing hits only: it never adds or removes notes,
never pitch-shifts, and is not mastering-grade.
"""
from __future__ import annotations

from typing import List, Optional

import numpy as np

from .groove import Groove
from .units import ms_to_samples

# Short equal-power-ish crossfade length (in samples) applied at chunk seams.
_DEFAULT_XFADE = 64


def _offset_to_samples(value: float, groove: Groove, sr: int) -> float:
    """Convert a single groove timing value to samples at render rate ``sr``."""
    if groove.unit == "ms":
        return ms_to_samples(value, sr)
    # samples unit: rescale if the file's rate differs from the stored rate.
    if groove.sample_rate and groove.sample_rate != sr:
        return value * sr / groove.sample_rate
    return value


def _apply_fades(chunk: np.ndarray, xfade: int) -> np.ndarray:
    """Apply a linear fade-in/out to a chunk so overlap-add seams don't click."""
    out = chunk.copy()
    n = len(out)
    f = min(xfade, n // 2)
    if f > 0:
        ramp = np.linspace(0.0, 1.0, f, dtype=out.dtype)
        out[:f] *= ramp
        out[-f:] *= ramp[::-1]
    return out


def render_grooved_audio(
    target_path: str,
    groove: Groove,
    out_path: str,
    sample_rate: Optional[int] = None,
    xfade: int = _DEFAULT_XFADE,
) -> dict:
    """Apply ``groove`` to the audio in ``target_path``, write ``out_path``.

    Returns a small report dict (onsets found, output length) so callers /
    the demo can print what happened.  Onsets are detected from the audio
    (the chosen onset source).
    """
    import librosa
    import soundfile as sf

    y, sr = librosa.load(target_path, sr=sample_rate, mono=True)

    # 1. Detect onsets (sample indices), always including the very start.
    onset_frames = librosa.onset.onset_detect(y=y, sr=sr, units="frames", backtrack=True)
    onsets = librosa.frames_to_samples(onset_frames).tolist()
    if not onsets or onsets[0] != 0:
        onsets = [0] + onsets
    onsets.append(len(y))  # sentinel end so the last chunk has a boundary

    offsets = groove.timing
    n_off = len(offsets)

    # 2/3/4. Slice, shift, overlap-add. Pad the output to absorb late shifts.
    max_shift = int(
        max((abs(_offset_to_samples(o, groove, sr)) for o in offsets), default=0)
    )
    out = np.zeros(len(y) + max_shift + xfade + 1, dtype=np.float32)

    for i in range(len(onsets) - 1):
        start, end = onsets[i], onsets[i + 1]
        chunk = _apply_fades(y[start:end].astype(np.float32), xfade)
        shift = int(round(_offset_to_samples(offsets[i % n_off], groove, sr)))
        dst = max(0, start + shift)  # never write before t=0
        out[dst:dst + len(chunk)] += chunk

    # Guard against clipping introduced by overlapping chunks.
    peak = float(np.max(np.abs(out))) if out.size else 0.0
    if peak > 1.0:
        out = out / peak

    sf.write(out_path, out, sr)
    return {
        "onsets_detected": len(onsets) - 1,  # minus the sentinel
        "sample_rate": sr,
        "out_samples": len(out),
        "out_path": out_path,
    }
