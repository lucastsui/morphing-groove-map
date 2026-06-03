"""Render test using a synthesized click track -- no external audio needed."""
import numpy as np
import soundfile as sf

from mgm import groove_from_offsets, render_grooved_audio


def _make_click_track(path, sr=48000, n_clicks=8, gap_s=0.25):
    """Write a simple drum-ish click track: short noise bursts on a grid."""
    total = int(sr * gap_s * n_clicks)
    y = np.zeros(total, dtype=np.float32)
    burst = int(sr * 0.01)
    rng = np.random.default_rng(0)
    for i in range(n_clicks):
        start = int(i * gap_s * sr)
        env = np.linspace(1.0, 0.0, burst, dtype=np.float32)
        y[start:start + burst] += (rng.standard_normal(burst).astype(np.float32)
                                   * env * 0.5)
    sf.write(path, y, sr)
    return sr


def test_render_produces_output(tmp_path):
    src = tmp_path / "click.wav"
    out = tmp_path / "grooved.wav"
    sr = _make_click_track(str(src))

    groove = groove_from_offsets(
        [0, 30, 0, 30, 0, 30, 0, 30], "4/4", 8, unit="ms"
    )
    report = render_grooved_audio(str(src), groove, str(out))

    assert report["onsets_detected"] >= 4  # detector should find the clicks
    y, out_sr = sf.read(str(out))
    assert out_sr == sr
    assert len(y) > 0
    assert np.max(np.abs(y)) <= 1.0 + 1e-6  # no clipping
