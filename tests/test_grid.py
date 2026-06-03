import pytest

from mgm.grid import TimeSignature, slices_per_beat, slot_count


def test_parse():
    ts = TimeSignature.parse("3/4")
    assert (ts.numerator, ts.denominator) == (3, 4)


def test_4_4_eighths_and_sixteenths():
    ts = TimeSignature(4, 4)
    assert slot_count(ts, 8) == 8
    assert slot_count(ts, 16) == 16


def test_3_4_eighths_and_sixteenths():
    ts = TimeSignature(3, 4)
    assert slot_count(ts, 8) == 6
    assert slot_count(ts, 12 if False else 16) == 12  # 16ths in 3/4 -> 12


def test_deep_subdivision():
    ts = TimeSignature(4, 4)
    assert slot_count(ts, 64) == 64
    assert slot_count(ts, 128) == 128


def test_slices_per_beat():
    assert slices_per_beat(TimeSignature(4, 4), 16) == 4


def test_bad_subdivision_rejected():
    with pytest.raises(ValueError):
        slot_count(TimeSignature(4, 4), 7)
