"""Morphing Groove Map (MGM) -- capture, morph and stamp the swing of a beat.

Public API:

    Grid / units
        TimeSignature, slot_count, slices_per_beat
        ms_to_samples, samples_to_ms, rescale_samples, rescale_array

    Grooves & morphing
        Groove, Anchor, GrooveMap

    File format
        save_mgm, load_mgm

    Apply / extract / render
        apply_to_beat, apply_offsets_to_onsets
        groove_from_offsets, onsets_to_offsets, extract_groove_from_audio
        render_grooved_audio
"""
from __future__ import annotations

from .apply import apply_offsets_to_onsets, apply_to_beat
from .extract import (
    accurate_onset_times,
    extract_groove_from_audio,
    groove_from_offsets,
    onsets_to_offsets,
)
from .grid import TimeSignature, slices_per_beat, slot_count
from .groove import Anchor, Groove, GrooveMap
from .mgmio import load_mgm, save_mgm
from .render import render_grooved_audio
from .units import (
    COMMON_SAMPLE_RATES,
    ms_to_samples,
    rescale_array,
    rescale_samples,
    samples_to_ms,
)

__all__ = [
    "TimeSignature",
    "slices_per_beat",
    "slot_count",
    "Groove",
    "Anchor",
    "GrooveMap",
    "save_mgm",
    "load_mgm",
    "apply_to_beat",
    "apply_offsets_to_onsets",
    "groove_from_offsets",
    "onsets_to_offsets",
    "accurate_onset_times",
    "extract_groove_from_audio",
    "render_grooved_audio",
    "ms_to_samples",
    "samples_to_ms",
    "rescale_samples",
    "rescale_array",
    "COMMON_SAMPLE_RATES",
]
