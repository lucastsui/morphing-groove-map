"""Ground-truth validation harness for the swing-extraction algorithm.

There is no public "audio -> correct swing array" table, so we MAKE one:

  known offset array  --synthesize-->  audio  --extract-->  recovered array

Because we authored the offsets, we know the exact right answer and can report
per-slot error and mean-absolute-error (MAE). This is the honest way to tell
whether extraction is working -- and to see its known failure modes (e.g. the
quarter-slot clamp caps how big an offset can be recovered).
"""
import numpy as np
import soundfile as sf
import librosa

SR = 48000
BPM = 120.0
SUBDIV = 16
BARS = 4                      # more bars -> averaging beats down onset jitter
N = SUBDIV
SLOT_S = (60.0 / BPM) / 4.0   # seconds per 16th
SLOT_MS = SLOT_S * 1000.0
QUARTER_MS = SLOT_MS / 4.0
LEAD_S = 0.25                 # pad so a negative first-slot offset stays >= 0


def synthesize(offsets_ms, path, seed=0):
    """Render a drum-ish hit on every 16th, each nudged by its known offset."""
    rng = np.random.default_rng(seed)
    total = int((LEAD_S + SLOT_S * N * BARS) * SR) + SR // 2
    y = np.zeros(total, dtype=np.float32)
    burst = int(SR * 0.018)
    for bar in range(BARS):
        for i in range(N):
            ideal = LEAD_S + (bar * N + i) * SLOT_S
            t = ideal + offsets_ms[i] / 1000.0
            start = int(t * SR)
            env = np.linspace(1.0, 0.0, burst, dtype=np.float32) ** 2
            y[start:start + burst] += rng.standard_normal(burst).astype(np.float32) * env * 0.6
    sf.write(path, y, SR)


def extract(path):
    """The algorithm under test -- the library's accurate extractor.

    Uses accurate_onset_times (fine-hop peak + waveform refinement) and the
    averaging fold. The LEAD_S phase is removed before folding so the recovered
    slots line up with the authored array (real extraction would detect phase).
    """
    from mgm import accurate_onset_times
    y, sr = librosa.load(path, sr=SR, mono=True)
    times = [t - LEAD_S for t in accurate_onset_times(y, sr)]
    bar_s = SLOT_S * N
    sums, counts = [0.0] * N, [0] * N
    for t in times:
        tb = t % bar_s
        slot = int(round(tb / SLOT_S)) % N
        d = (tb - slot * SLOT_S) * 1000.0
        if abs(d) <= SLOT_MS * 0.5:
            sums[slot] += d
            counts[slot] += 1
    return [sums[i] / counts[i] if counts[i] else 0.0 for i in range(N)]


# A few test grooves spanning easy -> hard cases.
CASES = {
    "straight":      [0.0] * N,
    "light 8th swing": [0, 12] * 8,                       # tiny, well inside clamp
    "heavy 8th swing": [0, 22] * 8,                       # near the clamp edge
    "random small":  list(np.round(np.linspace(-18, 18, N), 1)),
    "large swing":   [0, 40] * 8,           # 40ms: used to be clamped, now recovered
    "near reject":   [0, 55] * 8,           # 55ms ~ close to half-slot reject edge
}


def main():
    print(f"grid: {BPM:.0f} bpm, 16ths -> slot={SLOT_MS:.1f} ms, "
          f"clamp=+/-{QUARTER_MS:.1f} ms, {BARS} bars\n")
    print(f"{'case':18s} {'MAE(ms)':>8s}  {'max|err|':>8s}   note")
    print("-" * 64)
    for name, true in CASES.items():
        path = f"examples/_val_{name.replace(' ', '_')}.wav"
        synthesize(true, path)
        got = extract(path)
        err = [g - t for g, t in zip(got, true)]
        mae = float(np.mean(np.abs(err)))
        mx = float(np.max(np.abs(err)))
        note = ""
        if max(abs(v) for v in true) > SLOT_MS * 0.5:
            note = "(true exceeds half-slot reject threshold)"
        print(f"{name:18s} {mae:8.2f}  {mx:8.2f}   {note}")

    # Detailed per-slot dump for one representative case.
    print("\nper-slot detail -- 'heavy 8th swing':")
    true = CASES["heavy 8th swing"]
    got = extract("examples/_val_heavy_8th_swing.wav")
    print("  slot :", " ".join(f"{i:5d}" for i in range(N)))
    print("  true :", " ".join(f"{v:5.1f}" for v in true))
    print("  got  :", " ".join(f"{v:5.1f}" for v in got))
    print("  err  :", " ".join(f"{g - t:5.1f}" for g, t in zip(got, true)))


if __name__ == "__main__":
    main()
