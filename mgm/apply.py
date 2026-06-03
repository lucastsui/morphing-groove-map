"""Apply a resolved groove to a quantized beat.

This is the deterministic, exact half of the round trip (the *reverse* of
extraction): given note onset positions and a groove, nudge each note by its
slot's timing offset.

The onsets and offsets must be in the *same unit*.  If your onsets are in
samples, hand in a samples-based groove (or convert first with
:mod:`mgm.units`).
"""
from __future__ import annotations

from typing import List, Sequence

from .groove import Groove


def apply_offsets_to_onsets(
    onsets: Sequence[float], offsets: Sequence[float]
) -> List[float]:
    """Add each offset to its corresponding onset.

    Onsets are matched to slots positionally (onset *i* gets offset *i*).
    If there are more onsets than slots the groove wraps around -- a 1-bar
    groove tiles across a multi-bar beat, which is the usual musical intent.
    """
    if not offsets:
        raise ValueError("offsets must be non-empty")
    n = len(offsets)
    return [onset + offsets[i % n] for i, onset in enumerate(onsets)]


def apply_to_beat(onsets: Sequence[float], groove: Groove) -> List[float]:
    """Convenience wrapper: apply a :class:`Groove`'s timing lane to onsets."""
    return apply_offsets_to_onsets(onsets, groove.timing)
