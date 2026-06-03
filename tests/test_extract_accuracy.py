"""Regression guard: extraction must recover a KNOWN swing from synthesized
audio to within a tight error bound. If this fails, onset localization or the
fold has regressed."""
import numpy as np
import soundfile as sf

from mgm import accurate_onset_times

SR = 48000
BPM = 120.0
N = 16
SLOT_S = (60.0 / BPM) / 4.0
LEAD_S = 0.25


def _synth(offsets_ms, path, seed=0):
    rng = np.random.default_rng(seed)
    y = np.zeros(int((LEAD_S + SLOT_S * N * 4) * SR) + SR // 2, dtype=np.float32)
    burst = int(SR * 0.018)
    for bar in range(4):
        for i in range(N):
            t = LEAD_S + (bar * N + i) * SLOT_S + offsets_ms[i] / 1000.0
            s = int(t * SR)
            env = np.linspace(1.0, 0.0, burst, dtype=np.float32) ** 2
            y[s:s + burst] += rng.standard_normal(burst).astype(np.float32) * env * 0.6
    sf.write(path, y, SR)


def _extract(path):
    y, sr = sf.read(path)
    times = [t - LEAD_S for t in accurate_onset_times(y.astype(np.float32), sr)]
    sums, counts = [0.0] * N, [0] * N
    for t in times:
        tb = t % (SLOT_S * N)
        slot = int(round(tb / SLOT_S)) % N
        d = (tb - slot * SLOT_S) * 1000.0
        if abs(d) <= SLOT_S * 1000.0 * 0.5:
            sums[slot] += d
            counts[slot] += 1
    return [sums[i] / counts[i] if counts[i] else 0.0 for i in range(N)]


def test_recovers_known_swing_within_2ms(tmp_path):
    for name, true in {
        "straight": [0.0] * N,
        "swing": [0, 22] * 8,
        "large": [0, 40] * 8,   # would have been clipped by the old quarter-slot clamp
    }.items():
        p = str(tmp_path / f"{name}.wav")
        _synth(true, p)
        got = _extract(p)
        mae = float(np.mean([abs(g - t) for g, t in zip(got, true)]))
        assert mae < 2.0, f"{name}: MAE {mae:.2f} ms exceeds 2 ms"
