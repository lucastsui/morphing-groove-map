"""Grid geometry: how many slots a measure has.

The whole point of the spec is that array length is *derived*, never
hardcoded.  Length is::

    slots = beats_per_measure * slices_per_beat

where ``slices_per_beat`` comes from the chosen subdivision relative to the
time signature's beat unit.

Worked example (4/4):
    The beat unit is a quarter note.  Eighth notes are 2 per beat, so
    "1 and 2 and 3 and 4 and" = 4 beats * 2 = 8 slots.  Sixteenths -> 16.

We describe subdivision by its note value (8 = eighth, 16 = sixteenth, ...,
up to 128th).  ``slices_per_beat = subdivision / beat_unit`` where the beat
unit is the denominator of the time signature.
"""
from __future__ import annotations

from dataclasses import dataclass

# Note values we accept as a subdivision depth, eighth down to 128th.
VALID_SUBDIVISIONS = (8, 16, 32, 64, 128)


@dataclass(frozen=True)
class TimeSignature:
    """A time signature like 4/4 or 3/4.

    ``numerator`` = beats per measure, ``denominator`` = the note value that
    gets one beat (4 = quarter, 8 = eighth, ...).
    """

    numerator: int
    denominator: int

    def __post_init__(self) -> None:
        if self.numerator <= 0 or self.denominator <= 0:
            raise ValueError("time signature parts must be positive")

    @classmethod
    def parse(cls, text: str) -> "TimeSignature":
        """Parse ``"4/4"`` -> ``TimeSignature(4, 4)``."""
        try:
            num, den = text.split("/")
            return cls(int(num), int(den))
        except (ValueError, AttributeError) as exc:
            raise ValueError(f"could not parse time signature {text!r}") from exc

    def __str__(self) -> str:  # pragma: no cover - trivial
        return f"{self.numerator}/{self.denominator}"


def slices_per_beat(time_signature: TimeSignature, subdivision: int) -> int:
    """How many subdivision slots fall inside one beat.

    e.g. 4/4 + sixteenths -> 16/4 = 4 slices per quarter-note beat.
    Must divide evenly, otherwise the subdivision doesn't line up with the
    beat unit and we refuse to guess.
    """
    if subdivision not in VALID_SUBDIVISIONS:
        raise ValueError(
            f"subdivision must be one of {VALID_SUBDIVISIONS}, got {subdivision}"
        )
    if subdivision % time_signature.denominator != 0:
        raise ValueError(
            f"subdivision {subdivision} is not a whole multiple of beat unit "
            f"{time_signature.denominator}"
        )
    return subdivision // time_signature.denominator


def slot_count(time_signature: TimeSignature, subdivision: int) -> int:
    """Total slots in one measure = beats * slices_per_beat."""
    return time_signature.numerator * slices_per_beat(time_signature, subdivision)
