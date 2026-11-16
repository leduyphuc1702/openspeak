import numpy as np

from app import prosody
from app.prosody import ProsodyTrack

from .conftest import make_track


def test_final_slope_direction():
    assert prosody.final_slope(make_track(1.5, 150, 250), 1.5) > 2
    assert prosody.final_slope(make_track(1.5, 250, 150), 1.5) < -2


def test_contour_and_range_scores():
    assert prosody.contour_score("rising", 5.0) == 100
    assert prosody.contour_score("rising", -2.0) == 30
    assert prosody.contour_score("falling", -4.0) == 100
    assert prosody.range_score(1.0) == 20


def test_dtw_identical_is_zero_and_tolerates_time_shift():
    a = np.sin(np.linspace(0, 3, 100)) * 4
    shifted = np.sin(np.linspace(0, 3, 100) - 0.2) * 4
    assert prosody.dtw_distance(a, a) == 0
    assert prosody.dtw_distance(a, shifted) < np.mean(np.abs(a - shifted))


def test_stress_detection_picks_the_prominent_syllable():
    times = np.arange(0, 0.6, 0.01)
    f0 = np.where(times >= 0.3, 220.0, 160.0)
    db = np.where(times >= 0.3, 75.0, 65.0)
    track = ProsodyTrack(times, f0, db)
    assert prosody.detect_stress(track, [(0.05, 0.2), (0.3, 0.55)]) == 1


def test_parselmouth_tracks_a_real_rising_tone():
    sr = 16000
    t = np.arange(0, 1.2, 1 / sr)
    freq = np.linspace(140, 260, t.size)
    wav = 0.5 * np.sin(2 * np.pi * np.cumsum(freq) / sr)
    track = prosody.extract_prosody(wav, sr)
    voiced = track.f0[~np.isnan(track.f0)]
    assert 130 < voiced.min() < 160 and 240 < voiced.max() < 270
    assert prosody.final_slope(track, 1.2) > 2
