"""Unit handling for groove offsets.

A groove offset is "how far a note is nudged from a perfectly even grid".
It can be expressed in two units:

    * ``"ms"``      -- milliseconds (sample-rate independent)
    * ``"samples"`` -- integer audio samples (only meaningful next to a rate)

These helpers convert between the two and rescale a sample-based array from
one sample rate to another.  Keep them tiny and pure -- everything else in
the package leans on them.
"""
from __future__ import annotations

from typing import Iterable, List

# The sample rates you are most likely to meet in the wild.  Not enforced --
# any positive rate works -- but handy for validation / UI dropdowns.
COMMON_SAMPLE_RATES = (44100, 48000, 96000, 192000)

UNIT_MS = "ms"
UNIT_SAMPLES = "samples"
VALID_UNITS = (UNIT_MS, UNIT_SAMPLES)


def ms_to_samples(ms: float, sample_rate: int) -> float:
    """Convert milliseconds to samples: ``samples = seconds * rate``.

    e.g. 30 ms at 48000 Hz -> 0.030 * 48000 = 1440 samples.
    Returns a float so callers can decide whether/when to round.
    """
    return (ms / 1000.0) * sample_rate


def samples_to_ms(samples: float, sample_rate: int) -> float:
    """Convert samples back to milliseconds (inverse of :func:`ms_to_samples`)."""
    return (samples / sample_rate) * 1000.0


def rescale_samples(value: float, old_rate: int, new_rate: int) -> float:
    """Rescale one sample value from ``old_rate`` to ``new_rate``.

    new = old * new_rate / old_rate.  A 1440-sample offset at 48 kHz becomes
    2880 samples at 96 kHz (same wall-clock time, twice the samples).
    """
    return value * new_rate / old_rate


def convert_array_ms_to_samples(arr: Iterable[float], sample_rate: int) -> List[float]:
    """Vectorised :func:`ms_to_samples` over a whole offset array."""
    return [ms_to_samples(v, sample_rate) for v in arr]


def convert_array_samples_to_ms(arr: Iterable[float], sample_rate: int) -> List[float]:
    """Vectorised :func:`samples_to_ms` over a whole offset array."""
    return [samples_to_ms(v, sample_rate) for v in arr]


def rescale_array(arr: Iterable[float], old_rate: int, new_rate: int) -> List[float]:
    """Rescale a whole sample-based array from ``old_rate`` to ``new_rate``."""
    return [rescale_samples(v, old_rate, new_rate) for v in arr]


def validate_unit(unit: str) -> str:
    """Raise if ``unit`` is not one we understand; return it otherwise."""
    if unit not in VALID_UNITS:
        raise ValueError(f"unit must be one of {VALID_UNITS}, got {unit!r}")
    return unit
