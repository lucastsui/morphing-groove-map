import pytest

from mgm import (
    Groove,
    GrooveMap,
    TimeSignature,
    apply_to_beat,
    groove_from_offsets,
    load_mgm,
    onsets_to_offsets,
    save_mgm,
)


def test_mgm_round_trip(tmp_path):
    a = Groove(TimeSignature(4, 4), 8, "samples", 48000, timing=[0] * 8,
               velocity=[63] * 8)
    b = Groove(TimeSignature(4, 4), 8, "samples", 48000,
               timing=[0, 40, -10, 40, 0, 40, -20, 20], velocity=[100] * 8)
    gmap = GrooveMap({0: a, 127: b})
    path = tmp_path / "groove.mgm"
    save_mgm(str(path), gmap)
    loaded = load_mgm(str(path))
    assert loaded.positions == [0, 127]
    assert loaded.resolve(127).timing == b.timing
    assert loaded.anchors[0].groove.velocity == [63] * 8
    assert loaded.anchors[0].groove.sample_rate == 48000


def test_apply_to_beat_adds_offsets():
    g = groove_from_offsets([0, 40, -10, 40, 0, 40, -20, 20], "4/4", 8, unit="ms")
    onsets = [0, 100, 200, 300, 400, 500, 600, 700]
    out = apply_to_beat(onsets, g)
    assert out == [0, 140, 190, 340, 400, 540, 580, 720]


def test_apply_wraps_groove_across_multibar():
    g = groove_from_offsets([5, -5, 5, -5, 5, -5, 5, -5], "4/4", 8, unit="ms")
    onsets = list(range(16))  # two bars' worth
    out = apply_to_beat(onsets, g)
    assert out[8] == 8 + 5  # slot 0 again
    assert out[9] == 9 - 5


def test_onsets_to_offsets_basic():
    # 4/4 eighths at 120 bpm: beat = 0.5s, eighth = 0.25s, 8 slots.
    # Put a hit 10 ms late on slot 1 (ideal 0.25s -> 0.26s).
    offs = onsets_to_offsets(
        [0.0, 0.26], tempo_bpm=120, time_signature=TimeSignature(4, 4),
        subdivision=8, unit="ms",
    )
    assert offs[0] == pytest.approx(0, abs=1e-6)
    assert offs[1] == pytest.approx(10, abs=0.5)


def test_groove_from_offsets_validates_length():
    with pytest.raises(ValueError):
        groove_from_offsets([0, 1, 2], "4/4", 8)  # needs 8 slots
