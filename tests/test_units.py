from mgm.units import (
    ms_to_samples,
    samples_to_ms,
    rescale_samples,
    rescale_array,
)


def test_ms_to_samples_spec_example():
    # 30 ms at 48000 Hz == 1440 samples (from the spec).
    assert ms_to_samples(30, 48000) == 1440


def test_round_trip_ms_samples():
    assert samples_to_ms(ms_to_samples(12.5, 44100), 44100) == 12.5


def test_rescale_samples_doubling_rate():
    # 1440 samples at 48k -> 2880 at 96k (same wall-clock time).
    assert rescale_samples(1440, 48000, 96000) == 2880


def test_rescale_array():
    assert rescale_array([100, 200], 48000, 96000) == [200, 400]
