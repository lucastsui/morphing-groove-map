"""Real-world accuracy report: extract swing from the Groove MIDI Dataset's
AUDIO and compare against the paired MIDI (the ground-truth microtiming).

For each performance:
    MIDI note times  --fold-->  ground-truth offset array
    paired audio     --accurate_onset_times--fold-->  extracted offset array
Both use the same bpm/grid and start at t=0, so phase aligns naturally.
We report per-style and overall mean-absolute-error (ms).
"""
import csv
import os
import sys
from collections import defaultdict

import librosa
import mido
import numpy as np

from mgm import accurate_onset_times, onsets_to_offsets
from mgm.grid import TimeSignature

ROOT = os.path.dirname(__file__)
GMD = os.path.join(ROOT, "data", "groove_full")  # full set with audio
N = 16
TS = TimeSignature(4, 4)


def midi_times(path):
    mid = mido.MidiFile(path)
    t, out = 0.0, []
    for msg in mid:
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            out.append(t)
    return out


def offsets(times, bpm):
    return onsets_to_offsets(times, tempo_bpm=bpm, time_signature=TS,
                             subdivision=N, unit="ms")


def mae_for(midi_path, audio_path, bpm):
    truth = offsets(midi_times(midi_path), bpm)
    y, sr = librosa.load(audio_path, sr=48000, mono=True)
    got = offsets(accurate_onset_times(y, sr), bpm)
    # compare only slots the ground truth actually uses (a real hit present)
    errs = [abs(g - t) for g, t in zip(got, truth) if t != 0.0]
    return (float(np.mean(errs)) if errs else None), len(errs)


def main(per_style=3, limit=None):
    rows = [r for r in csv.DictReader(open(os.path.join(GMD, "info.csv")))
            if r["time_signature"] == "4-4" and r["beat_type"] == "beat"]
    by_style = defaultdict(list)
    for r in rows:
        by_style[r["style"].split("/")[0]].append(r)

    per_style_err = defaultdict(list)
    all_err = []
    n_done = 0
    for style in sorted(by_style):
        for r in by_style[style][:per_style]:
            mp = os.path.join(GMD, r["midi_filename"])
            ap = os.path.join(GMD, r["audio_filename"])
            if not (os.path.exists(mp) and os.path.exists(ap)):
                continue
            try:
                mae, nslots = mae_for(mp, ap, float(r["bpm"]))
            except Exception as e:
                print(f"  skip {r['id']}: {e}")
                continue
            if mae is None:
                continue
            per_style_err[style].append(mae)
            all_err.append(mae)
            n_done += 1
            if limit and n_done >= limit:
                break
        if limit and n_done >= limit:
            break

    print(f"\n{'style':14s} {'files':>5s} {'MAE(ms)':>9s}")
    print("-" * 32)
    for style in sorted(per_style_err):
        e = per_style_err[style]
        print(f"{style:14s} {len(e):5d} {np.mean(e):9.2f}")
    print("-" * 32)
    print(f"{'OVERALL':14s} {n_done:5d} {np.mean(all_err):9.2f}")
    print(f"\nmedian per-file MAE: {np.median(all_err):.2f} ms")


if __name__ == "__main__":
    lim = int(sys.argv[1]) if len(sys.argv) > 1 else None
    main(limit=lim)
