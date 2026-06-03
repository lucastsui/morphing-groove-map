"""Real-world run: extract the Amen break's swing with the MGM tool, then
stamp it onto a straight target loop. Produces a no-swing and a swung WAV."""
import os
import numpy as np
import soundfile as sf

from mgm import (
    extract_groove_from_audio, groove_from_offsets, GrooveMap,
    save_mgm, render_grooved_audio,
)

HERE = os.path.join(os.path.dirname(__file__), "examples")
SR = 48000
TEMPO = 137.2          # detected from the Amen break
SUBDIV = 16            # the Amen is a 16th-note funk groove
AMEN = os.path.join(HERE, "amen.wav")

# 1. EXTRACT the groove from the real Amen break with our tool.
print("[1] Extracting Amen swing (16th notes, 137 bpm) ...")
amen_groove = extract_groove_from_audio(
    AMEN, time_signature="4/4", subdivision=SUBDIV, unit="ms", tempo_bpm=TEMPO
)
print("    timing offsets (ms):", [round(v, 1) for v in amen_groove.timing])

# Morph map: dead-straight at dial 0, the stolen Amen feel at dial 127.
straight = groove_from_offsets([0] * amen_groove.slots, "4/4", SUBDIV, unit="ms")
gmap = GrooveMap({0: straight, 127: amen_groove})
save_mgm(os.path.join(HERE, "amen_swing.mgm"), gmap)
print("[2] Saved amen_swing.mgm")


# 2. Synthesize a perfectly straight target: a hi-hat-ish hit on every 16th
#    for two bars at 137 bpm. This is the 'before' material.
def synth_straight_target(path, bars=2):
    sec_per_16th = (60.0 / TEMPO) / 4.0
    n_slots = SUBDIV * bars
    total = int(sec_per_16th * n_slots * SR) + SR // 2
    y = np.zeros(total, dtype=np.float32)
    rng = np.random.default_rng(7)
    burst = int(SR * 0.02)
    for i in range(n_slots):
        start = int(i * sec_per_16th * SR)
        env = np.linspace(1.0, 0.0, burst, dtype=np.float32) ** 2
        # accent the downbeats so the groove is easy to hear
        gain = 0.7 if i % 4 == 0 else 0.35
        y[start:start + burst] += rng.standard_normal(burst).astype(np.float32) * env * gain
    sf.write(path, y, SR)


target = os.path.join(HERE, "straight_target.wav")
synth_straight_target(target)
print("[3] Synthesized straight target loop")

# 3. RENDER: no-swing (dial 0) vs full Amen swing (dial 127).
no_swing = os.path.join(HERE, "OUT_no_swing.wav")
with_swing = os.path.join(HERE, "OUT_amen_swing.wav")
render_grooved_audio(target, gmap.resolve(0), no_swing)
render_grooved_audio(target, gmap.resolve(127), with_swing)
print(f"[4] Wrote:\n    {no_swing}\n    {with_swing}")
