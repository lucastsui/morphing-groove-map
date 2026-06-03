"""MGM file format: a human-readable JSON groove map.

Layout (pretty-printed, version-tagged for forward compatibility)::

    {
      "format": "MGM",
      "version": 1,
      "time_signature": "4/4",
      "subdivision": 16,
      "unit": "ms",
      "sample_rate": 48000,
      "anchors": [
        {"position": 0,   "timing": [...], "velocity": [...], "gate": [...]},
        {"position": 127, "timing": [...]}
      ]
    }

``velocity`` / ``gate`` are written only when present.  The grid metadata
lives once at the top level since all anchors share it.
"""
from __future__ import annotations

import json
from typing import Any, Dict

from .grid import TimeSignature
from .groove import Anchor, Groove, GrooveMap

FORMAT_TAG = "MGM"
FORMAT_VERSION = 1


def _anchor_to_dict(anchor: Anchor) -> Dict[str, Any]:
    g = anchor.groove
    out: Dict[str, Any] = {"position": anchor.position, "timing": list(g.timing)}
    if g.velocity is not None:
        out["velocity"] = list(g.velocity)
    if g.gate is not None:
        out["gate"] = list(g.gate)
    return out


def groove_map_to_dict(gmap: GrooveMap) -> Dict[str, Any]:
    """Serialise a :class:`GrooveMap` to a plain JSON-ready dict."""
    ref = gmap.anchors[0].groove
    return {
        "format": FORMAT_TAG,
        "version": FORMAT_VERSION,
        "time_signature": str(ref.time_signature),
        "subdivision": ref.subdivision,
        "unit": ref.unit,
        "sample_rate": ref.sample_rate,
        "anchors": [_anchor_to_dict(a) for a in gmap.anchors],
    }


def groove_map_from_dict(data: Dict[str, Any]) -> GrooveMap:
    """Rebuild a :class:`GrooveMap` from a parsed MGM dict."""
    if data.get("format") != FORMAT_TAG:
        raise ValueError("not an MGM document (missing format tag)")
    ts = TimeSignature.parse(data["time_signature"])
    subdivision = data["subdivision"]
    unit = data["unit"]
    sample_rate = data.get("sample_rate")

    anchors: Dict[int, Groove] = {}
    for a in data["anchors"]:
        anchors[a["position"]] = Groove(
            time_signature=ts,
            subdivision=subdivision,
            unit=unit,
            sample_rate=sample_rate,
            timing=list(a["timing"]),
            velocity=list(a["velocity"]) if "velocity" in a else None,
            gate=list(a["gate"]) if "gate" in a else None,
        )
    return GrooveMap(anchors)


def save_mgm(path: str, gmap: GrooveMap) -> None:
    """Write a groove map to ``path`` as pretty-printed JSON."""
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(groove_map_to_dict(gmap), fh, indent=2)
        fh.write("\n")


def load_mgm(path: str) -> GrooveMap:
    """Read a groove map back from an MGM JSON file."""
    with open(path, "r", encoding="utf-8") as fh:
        return groove_map_from_dict(json.load(fh))
