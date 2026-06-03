"""Cleaner re-render.

Two fixes over run_amen.py:
  (A) Better Amen extraction -- fold every bar onto one, AVERAGE the offsets
      per slot (instead of first-hit-wins), and CLAMP to +/- a quarter slot so
      no note can cross its neighbour and collide.
  (B) A clean hand-made 16th swing (the reliable, detection-free path) for
      comparison -- this is what a musical groove file is supposed to feel like.
"""
import os
import numpy as np
import soundfile as sf
import librosa

from mgm import groove_from_offsets, GrooveMap, save_mgm, render_grooved_audio

HERE = os.path.join(os.path.dirname(__file__), "examples")
SR = 48000
TEMPO = 137.2
SUBDIV = 16
N = SUBDIV  # one bar = 16 slots
SLOT_MS = (60.0 / TEMPO) / 4.0 * 1000.0          # 109 ms
QUARTER = SLOT_MS / 4.0                           # ~27 ms clamp


def clean_extract_amen():
    """Averaged, clamped per-slot offsets from the real Amen break."""
    y, sr = librosa.load(os.path.join(HERE, "amen.wav"), sr=SR, mono=True)
    times = librosa.frames_to_time(
        librosa.onset.onset_detect(y=y, sr=sr, units="frames", backtrack=True), sr=sr
    )
    bar_s = SLOT_MS * N / 1000.0
    sums = [0.0] * N
    counts = [0] * N
    for t in times:
        t_in_bar = t % bar_s
        slot = int(round(t_in_bar / (SLOT_MS / 1000.0))) % N
        delta_ms = (t_in_bar - slot * SLOT_MS / 1000.0) * 1000.0
        # ignore hits that are basically a whole slot away (wrong-slot noise)
        if abs(delta_ms) <= SLOT_MS * 0.5:
            sums[slot] += delta_ms
            counts[slot] += 1
    offsets = []
    for s, c in zip(sums, counts):
        v = (s / c) if c else 0.0
        offsets.append(float(np.clip(v, -QUARTER, QUARTER)))   # clamp
    return offsets


def synth_straight_target(path, bars=2):
    sec16 = (60.0 / TEMPO) / 4.0
    n = SUBDIV * bars
    y = np.zeros(int(sec16 * n * SR) + SR // 2, dtype=np.float32)
    rng = np.random.default_rng(7)
    burst = int(SR * 0.02)
    for i in range(n):
        start = int(i * sec16 * SR)
        env = np.linspace(1.0, 0.0, burst, dtype=np.float32) ** 2
        gain = 0.7 if i % 4 == 0 else 0.35
        y[start:start + burst] += rng.standard_normal(burst).astype(np.float32) * env * gain
    sf.write(path, y, SR)


target = os.path.join(HERE, "straight_target.wav")
synth_straight_target(target)

# (A) Cleaned Amen swing -----------------------------------------------------
amen_off = clean_extract_amen()
print("Amen (averaged + clamped +/-27ms):", [round(v, 1) for v in amen_off])
amen = groove_from_offsets(amen_off, "4/4", SUBDIV, unit="ms")
straight = groove_from_offsets([0] * N, "4/4", SUBDIV, unit="ms")
gmap_amen = GrooveMap({0: straight, 127: amen})
save_mgm(os.path.join(HERE, "amen_swing.mgm"), gmap_amen)
render_grooved_audio(target, gmap_amen.resolve(0), os.path.join(HERE, "OUT_no_swing.wav"))
render_grooved_audio(target, gmap_amen.resolve(127), os.path.join(HERE, "OUT_amen_clean.wav"))

# (B) Clean hand-made 16th swing (reliable path) -----------------------------
# Classic swing: push every OFF-8th (odd 8th == slots 2,6,10,14) late, and the
# in-between 16ths slightly late too. Gentle, musical, no detection involved.
swing_off = [0, 18, 35, 18] * 4          # repeating 4-slot shape per beat
swing_off = swing_off[:N]
hand = groove_from_offsets(swing_off, "4/4", SUBDIV, unit="ms")
gmap_hand = GrooveMap({0: straight, 127: hand})
save_mgm(os.path.join(HERE, "hand_swing.mgm"), gmap_hand)
render_grooved_audio(target, gmap_hand.resolve(127), os.path.join(HERE, "OUT_hand_swing.wav"))
print("Hand swing:", swing_off)
print("\nWrote OUT_no_swing.wav, OUT_amen_clean.wav, OUT_hand_swing.wav")
