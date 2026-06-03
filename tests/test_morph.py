import pytest

from mgm import Groove, GrooveMap, TimeSignature


def _g(timing, velocity=None, gate=None):
    return Groove(
        time_signature=TimeSignature(4, 4),
        subdivision=8,
        unit="ms",
        timing=timing,
        velocity=velocity,
        gate=gate,
    )


def test_spec_midpoint_example():
    # dial 63 of [0,0,...] -> [0,30,...] should give [0,15,...].
    straight = _g([0, 0, 0, 0, 0, 0, 0, 0])
    swung = _g([0, 30, 0, 30, 0, 30, 0, 30])
    gmap = GrooveMap({0: straight, 127: swung})
    out = gmap.resolve(63)
    assert out.timing[0] == 0
    assert out.timing[1] == pytest.approx(30 * 63 / 127)
    # And ~15 at the midpoint magnitude.
    assert out.timing[1] == pytest.approx(14.88, abs=0.05)


def test_endpoints_return_anchor():
    straight = _g([0] * 8)
    swung = _g([0, 40, 0, 40, 0, 40, 0, 40])
    gmap = GrooveMap({0: straight, 127: swung})
    assert gmap.resolve(0).timing == [0] * 8
    assert gmap.resolve(127).timing == swung.timing


def test_multiple_anchors_pick_correct_pair():
    a0 = _g([0] * 8)
    a47 = _g([10] * 8)
    a127 = _g([100] * 8)
    gmap = GrooveMap({0: a0, 47: a47, 127: a127})
    # Between 0 and 47: dial 23.5 -> halfway -> 5.
    assert gmap.resolve(23.5).timing[0] == pytest.approx(5)
    # Between 47 and 127: dial 87 -> v_low + (v_high-v_low)*(87-47)/(127-47).
    expected = 10 + (100 - 10) * (87 - 47) / (127 - 47)
    assert gmap.resolve(87).timing[0] == pytest.approx(expected)


def test_velocity_and_gate_lanes_interpolate():
    a = _g([0] * 8, velocity=[0] * 8, gate=[0] * 8)
    b = _g([0] * 8, velocity=[100] * 8, gate=[80] * 8)
    gmap = GrooveMap({0: a, 127: b})
    mid = gmap.resolve(63)
    assert mid.velocity[0] == pytest.approx(100 * 63 / 127)
    assert mid.gate[0] == pytest.approx(80 * 63 / 127)


def test_incompatible_anchors_rejected():
    a = _g([0] * 8)
    b = Groove(time_signature=TimeSignature(4, 4), subdivision=16,
               unit="ms", timing=[0] * 16)
    with pytest.raises(ValueError):
        GrooveMap({0: a, 127: b})


def test_lane_presence_must_agree():
    a = _g([0] * 8, velocity=[0] * 8)
    b = _g([0] * 8)  # no velocity
    with pytest.raises(ValueError):
        GrooveMap({0: a, 127: b})
