"""Build a groove library (JSON) from the Google Groove MIDI Dataset.

The MIDI carries each hit's exact microtiming, so there is no onset-detection
error here -- we reduce the drummer's real timing into a 16-slot-per-bar offset
array (ms) by AVERAGING across all bars (no clamp; the offsets are the true,
recovered microtiming). This shares the library's onsets_to_offsets fold so the
MIDI path and the audio path agree.
"""
import csv
import json
import os
from collections import defaultdict

import mido

from mgm import onsets_to_offsets
from mgm.grid import TimeSignature

ROOT = os.path.dirname(__file__)
GMD = os.path.join(ROOT, "data", "groove")
OUT = os.path.join(ROOT, "examples", "groove_library.json")
SUBDIV = 16
N = SUBDIV  # slots per 4/4 bar


def note_onset_times(midi_path):
    """Return drum-hit onset times in seconds (note_on, velocity > 0)."""
    mid = mido.MidiFile(midi_path)
    t = 0.0
    times = []
    for msg in mid:                      # iterating yields real-time delta secs
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            times.append(t)
    return times


def offsets_from_times(times, bpm):
    """True per-16th microtiming (ms): averaged across bars, outliers rejected."""
    offs = onsets_to_offsets(
        times, tempo_bpm=bpm, time_signature=TimeSignature(4, 4),
        subdivision=N, unit="ms",
    )
    return [round(v, 2) for v in offs]


def main(per_style=2):
    rows = list(csv.DictReader(open(os.path.join(GMD, "info.csv"))))
    # Keep clean 4/4 "beat" performances (not fills), group by style.
    rows = [r for r in rows if r["time_signature"] == "4-4"
            and r["beat_type"] == "beat"]
    by_style = defaultdict(list)
    for r in rows:
        by_style[r["style"].split("/")[0]].append(r)

    library = []
    for style in sorted(by_style):
        picked = 0
        for r in by_style[style]:
            if picked >= per_style:
                break
            path = os.path.join(GMD, r["midi_filename"])
            try:
                times = note_onset_times(path)
            except Exception:
                continue
            if len(times) < N:           # too sparse to be meaningful
                continue
            bpm = float(r["bpm"])
            offs = offsets_from_times(times, bpm)
            parts = r["style"].split("/")
            variant = parts[1] if len(parts) > 1 else parts[0]
            library.append({
                "name": f"{style} {variant} ({int(bpm)} bpm)",
                "style": style,
                "bpm": int(bpm),
                "subdivision": SUBDIV,
                "time_signature": "4/4",
                "unit": "ms",
                "timing": offs,
            })
            picked += 1

    # Always include a dead-straight reference at the top.
    library.insert(0, {
        "name": "Straight (no swing)", "style": "none", "bpm": 0,
        "subdivision": SUBDIV, "time_signature": "4/4", "unit": "ms",
        "timing": [0.0] * N,
    })

    json.dump(library, open(OUT, "w"), indent=2)
    print(f"wrote {len(library)} grooves -> {OUT}")
    for g in library[:6]:
        print(f"  {g['name']:32s} {g['timing']}")


if __name__ == "__main__":
    main()
