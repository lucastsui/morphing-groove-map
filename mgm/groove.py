"""Groove data structures and the morphing dial.

Three concepts live here:

    * ``Groove``    -- one resolved feel: parallel timing / velocity / gate
                       arrays, all the same length, plus its grid metadata.
    * ``Anchor``    -- a ``Groove`` pinned to an integer dial position 0-127.
    * ``GrooveMap`` -- a collection of anchors you can morph between by turning
                       a 0-127 dial.  This is the "main math" of the spec.

Lanes
-----
Every groove carries up to three parallel "lanes", all the same length:

    timing   -- offset from the grid (ms or samples); negative = early.
    velocity -- how hard the note is hit, 0-127 (optional).
    gate     -- note length in the same unit as timing (optional).

Velocity and gate are optional; if absent they simply aren't interpolated.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence

from .grid import TimeSignature, slot_count
from .units import UNIT_MS, validate_unit

DIAL_MIN = 0
DIAL_MAX = 127


def _lerp(v_low: float, v_high: float, pos: float, p_low: int, p_high: int) -> float:
    """Linear interpolation between two anchor values, per the spec formula::

        out = v_low + (v_high - v_low) * (pos - p_low) / (p_high - p_low)

    ``p_low == p_high`` would be a divide-by-zero; callers guarantee it can't
    happen (an exact-hit anchor is returned directly, never interpolated).
    """
    return v_low + (v_high - v_low) * (pos - p_low) / (p_high - p_low)


@dataclass
class Groove:
    """One concrete, resolved groove (no dial position attached).

    The arrays are stored as plain lists of floats so a ``Groove`` is trivially
    JSON-serialisable.  ``timing`` is required; ``velocity`` and ``gate`` are
    optional lanes that, when present, must match ``timing`` in length.
    """

    time_signature: TimeSignature
    subdivision: int
    unit: str = UNIT_MS
    sample_rate: Optional[int] = None  # required when unit == "samples"
    timing: List[float] = field(default_factory=list)
    velocity: Optional[List[float]] = None
    gate: Optional[List[float]] = None

    def __post_init__(self) -> None:
        validate_unit(self.unit)
        expected = slot_count(self.time_signature, self.subdivision)
        if len(self.timing) != expected:
            raise ValueError(
                f"timing has {len(self.timing)} slots but {self.time_signature} "
                f"at subdivision {self.subdivision} needs {expected}"
            )
        for name in ("velocity", "gate"):
            lane = getattr(self, name)
            if lane is not None and len(lane) != expected:
                raise ValueError(
                    f"{name} lane has {len(lane)} slots, expected {expected}"
                )
        if self.unit == "samples" and self.sample_rate is None:
            raise ValueError("sample_rate is required when unit == 'samples'")

    @property
    def slots(self) -> int:
        return len(self.timing)


@dataclass
class Anchor:
    """A groove pinned to a dial position in [0, 127]."""

    position: int
    groove: Groove

    def __post_init__(self) -> None:
        if not (DIAL_MIN <= self.position <= DIAL_MAX):
            raise ValueError(
                f"anchor position must be in [{DIAL_MIN}, {DIAL_MAX}], "
                f"got {self.position}"
            )


class GrooveMap:
    """A morphable collection of anchors along a 0-127 dial.

    Turning the dial to any position resolves to a single :class:`Groove` by
    linearly interpolating, slot by slot, between the two bracketing anchors.
    With anchors at e.g. 0, 47 and 127, dialing 30 blends the 0 and 47 anchors;
    dialing 80 blends the 47 and 127 anchors.
    """

    def __init__(self, anchors: Dict[int, Groove]):
        if not anchors:
            raise ValueError("a GrooveMap needs at least one anchor")
        # Sort anchors by dial position and sanity-check they're compatible.
        self.anchors: List[Anchor] = [
            Anchor(pos, gr) for pos, gr in sorted(anchors.items())
        ]
        self._check_compatible()

    def _check_compatible(self) -> None:
        """All anchors must share grid geometry, unit and lane presence."""
        first = self.anchors[0].groove
        for anchor in self.anchors[1:]:
            g = anchor.groove
            if (
                g.time_signature != first.time_signature
                or g.subdivision != first.subdivision
                or g.unit != first.unit
                or g.slots != first.slots
            ):
                raise ValueError("all anchors must share grid, unit and length")
            if (g.velocity is None) != (first.velocity is None):
                raise ValueError("all anchors must agree on whether velocity exists")
            if (g.gate is None) != (first.gate is None):
                raise ValueError("all anchors must agree on whether gate exists")

    @property
    def positions(self) -> List[int]:
        return [a.position for a in self.anchors]

    def _bracket(self, pos: float) -> tuple[Anchor, Anchor]:
        """Find the two anchors that bracket ``pos``.

        Positions outside the anchor range clamp to the nearest end anchor
        (returned as a degenerate pair so resolution yields that anchor).
        """
        anchors = self.anchors
        if pos <= anchors[0].position:
            return anchors[0], anchors[0]
        if pos >= anchors[-1].position:
            return anchors[-1], anchors[-1]
        for low, high in zip(anchors, anchors[1:]):
            if low.position <= pos <= high.position:
                return low, high
        raise RuntimeError("bracket search failed")  # pragma: no cover

    def resolve(self, position: float) -> Groove:
        """Resolve the dial to a concrete :class:`Groove`.

        Interpolates every lane slot-by-slot between the bracketing anchors.
        """
        if not (DIAL_MIN <= position <= DIAL_MAX):
            raise ValueError(f"dial position must be in [{DIAL_MIN}, {DIAL_MAX}]")

        low, high = self._bracket(position)
        ref = low.groove

        # Exact hit or clamped to an end -> return that anchor's data verbatim.
        if low.position == high.position:
            return Groove(
                time_signature=ref.time_signature,
                subdivision=ref.subdivision,
                unit=ref.unit,
                sample_rate=ref.sample_rate,
                timing=list(ref.timing),
                velocity=None if ref.velocity is None else list(ref.velocity),
                gate=None if ref.gate is None else list(ref.gate),
            )

        def blend(low_lane: Sequence[float], high_lane: Sequence[float]) -> List[float]:
            return [
                _lerp(lv, hv, position, low.position, high.position)
                for lv, hv in zip(low_lane, high_lane)
            ]

        gl, gh = low.groove, high.groove
        velocity = (
            None if gl.velocity is None else blend(gl.velocity, gh.velocity)
        )
        gate = None if gl.gate is None else blend(gl.gate, gh.gate)

        return Groove(
            time_signature=ref.time_signature,
            subdivision=ref.subdivision,
            unit=ref.unit,
            sample_rate=ref.sample_rate,
            timing=blend(gl.timing, gh.timing),
            velocity=velocity,
            gate=gate,
        )
