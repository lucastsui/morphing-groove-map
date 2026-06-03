# Morphing Groove Map (MGM)

Capture the **swing/groove** of a drum beat as an array of numbers, **morph**
between grooves with a 0–127 dial, **stamp** a groove onto a different beat, and
**render new audio** from it.

```
amen_break.wav ──extract──▶ amen.mgm ──apply + render──▶ grooved_loop.wav
```

## Quick start

```bash
uv sync                       # install deps (numpy, librosa, soundfile)
uv run pytest -q              # run the test suite
uv run python demo.py         # synthesize inputs + run the whole pipeline
uv run python demo.py source.wav target.wav   # use your own audio
```

`demo.py` writes `examples/grooved_000.wav`, `_063.wav`, `_127.wav` — the same
loop at three dial positions. Listen across them to hear the morph.

## Core concepts

- **Groove** — parallel arrays over equal subdivision slots of one measure:
  - `timing` — offset from a perfect grid (`+` late, `−` early, `0` dead-on)
  - `velocity` — hit strength 0–127 (optional lane)
  - `gate` — note length (optional lane)
- **Units** — offsets in `ms` or `samples`. `samples = seconds × sample_rate`
  (30 ms @ 48 kHz = 1440 samples). Convert both ways; rescale across rates with
  `new = old × new_rate / old_rate`. Sample-based grooves store their rate.
- **Grid** — array length = `beats × slices_per_beat`, derived from time
  signature + subdivision (4/4 eighths → 8, 4/4 sixteenths → 16, 3/4 → 6/12).
  Arbitrary signatures and 8th→128th subdivisions.
- **Morph** — a `GrooveMap` holds anchors at integer dial positions (0–127).
  Any dial value linearly interpolates, slot by slot, between its two
  bracketing anchors: `out = v_low + (v_high − v_low)·(pos − p_low)/(p_high − p_low)`.

## Module map

| Module | Responsibility |
|---|---|
| `mgm/units.py` | ms ↔ samples, sample-rate rescaling |
| `mgm/grid.py` | time signature + subdivision → slot count |
| `mgm/groove.py` | `Groove`, `Anchor`, `GrooveMap` (the morph math) |
| `mgm/mgmio.py` | `save_mgm` / `load_mgm` — human-readable JSON format |
| `mgm/apply.py` | `apply_to_beat` — add offsets to onset positions |
| `mgm/extract.py` | `groove_from_offsets` (reliable) + `extract_groove_from_audio` (**stub**) |
| `mgm/render.py` | `render_grooved_audio` — slice/shift/overlap-add to new WAV |

## Reliability notes

- **Trustworthy / deterministic:** units, grid, morph dial, save/load, apply.
  Covered by tests.
- **Render:** good on percussive/drum material; soft artifacts on big shifts or
  dense/sustained audio. Re-times existing hits only — no add/remove/pitch.
- **`extract_groove_from_audio` is a FIRST-PASS STUB.** Onset detection on real
  recordings is the hard, unverified part (ghost notes, flams, tempo drift).
  Treat its numbers as a starting point. The reliable path is to import offsets
  from Ableton via `groove_from_offsets(...)`, which skips detection entirely.

## Example

```python
from mgm import groove_from_offsets, GrooveMap, save_mgm, render_grooved_audio

straight = groove_from_offsets([0]*8, "4/4", 8, unit="ms")
swung    = groove_from_offsets([0,40,0,40,0,40,0,40], "4/4", 8, unit="ms")
gmap = GrooveMap({0: straight, 127: swung})

gmap.resolve(63).timing          # -> [0, 19.8, 0, 19.8, ...] (half swing)
save_mgm("swing.mgm", gmap)
render_grooved_audio("loop.wav", gmap.resolve(127), "swung_loop.wav")
```
