"""Pitch, intensity, intonation and stress analysis from the raw waveform."""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np


@dataclass
class ProsodyTrack:
    times: np.ndarray       # seconds, uniform hop
    f0: np.ndarray          # Hz, NaN where unvoiced
    intensity: np.ndarray   # dB, same length as times

    @property
    def semitones(self) -> np.ndarray:
        """F0 in semitones relative to the speaker's median, so voices are comparable."""
        voiced = self.f0[~np.isnan(self.f0)]
        if voiced.size == 0:
            return np.full_like(self.f0, np.nan)
        return 12.0 * np.log2(self.f0 / np.median(voiced))


def extract_prosody(wav: np.ndarray, sr: int, hop: float = 0.01) -> ProsodyTrack:
    import parselmouth

    snd = parselmouth.Sound(wav.astype(np.float64), sampling_frequency=sr)
    pitch = snd.to_pitch(time_step=hop, pitch_floor=75.0, pitch_ceiling=500.0)
    times = pitch.xs()
    f0 = pitch.selected_array["frequency"].astype(float)
    f0[f0 <= 0] = np.nan
    intensity = snd.to_intensity(minimum_pitch=75.0, time_step=hop)
    db = np.interp(times, intensity.xs(), intensity.values[0], left=np.nan, right=np.nan)
    return ProsodyTrack(np.asarray(times), f0, db)


def _segment(track: ProsodyTrack, start: float, end: float) -> np.ndarray:
    return (track.times >= start) & (track.times < end)


# --- Intonation ---

def final_slope(track: ProsodyTrack, speech_end: float, window: float = 0.6) -> Optional[float]:
    """Pitch slope (semitones/second) over the last voiced stretch of the utterance."""
    st = track.semitones
    voiced = ~np.isnan(st) & (track.times <= speech_end + 0.05)
    if voiced.sum() < 5:
        return None
    last_t = track.times[voiced][-1]
    sel = voiced & (track.times >= last_t - window)
    if sel.sum() < 5:
        return None
    slope, _ = np.polyfit(track.times[sel], st[sel], 1)
    return float(slope)


def pitch_range(track: ProsodyTrack) -> Optional[float]:
    st = track.semitones
    st = st[~np.isnan(st)]
    if st.size < 5:
        return None
    p10, p90 = np.percentile(st, [10, 90])
    return float(p90 - p10)


def contour_score(expected: str, slope: Optional[float]) -> Optional[float]:
    if slope is None:
        return None
    if expected == "rising":
        return float(np.interp(slope, [0.0, 4.0], [30.0, 100.0]))
    return float(np.interp(slope, [-3.0, 2.0], [100.0, 30.0]))


def range_score(semitone_range: Optional[float]) -> Optional[float]:
    """Penalize monotone delivery; native read speech typically spans 4+ semitones."""
    if semitone_range is None:
        return None
    return float(np.interp(semitone_range, [1.5, 4.0], [20.0, 100.0]))


def resample_contour(track: ProsodyTrack, n: int = 100) -> Optional[np.ndarray]:
    st = track.semitones
    voiced = ~np.isnan(st)
    if voiced.sum() < 5:
        return None
    t = track.times[voiced]
    grid = np.linspace(t[0], t[-1], n)
    return np.interp(grid, t, st[voiced])


def dtw_distance(a: np.ndarray, b: np.ndarray, band: float = 0.2) -> float:
    """Mean absolute semitone difference along the best warping path."""
    n, m = len(a), len(b)
    w = max(int(band * max(n, m)), abs(n - m))
    cost = np.full((n + 1, m + 1), np.inf)
    steps = np.zeros((n + 1, m + 1))
    cost[0, 0] = 0.0
    for i in range(1, n + 1):
        lo, hi = max(1, i - w), min(m, i + w)
        for j in range(lo, hi + 1):
            d = abs(a[i - 1] - b[j - 1])
            prev = [(cost[i - 1, j - 1], steps[i - 1, j - 1]),
                    (cost[i - 1, j], steps[i - 1, j]),
                    (cost[i, j - 1], steps[i, j - 1])]
            c, s = min(prev, key=lambda x: x[0])
            cost[i, j] = c + d
            steps[i, j] = s + 1
    return float(cost[n, m] / max(steps[n, m], 1))


def similarity_from_distance(d: float, scale: float = 3.0) -> float:
    return float(100.0 * np.exp(-d / scale))


# --- Lexical stress ---

@dataclass
class StressResult:
    expected: int
    detected: int

    @property
    def correct(self) -> bool:
        return self.expected == self.detected


def detect_stress(track: ProsodyTrack, nuclei: Sequence[Tuple[float, float]]) -> Optional[int]:
    """Index of the most prominent vowel nucleus (pitch + loudness + length)."""
    if len(nuclei) < 2:
        return None
    st = track.semitones
    feats = []
    for start, end in nuclei:
        sel = _segment(track, start, end)
        pitch_vals = st[sel]
        pitch_vals = pitch_vals[~np.isnan(pitch_vals)]
        loud = track.intensity[sel]
        loud = loud[~np.isnan(loud)]
        feats.append((
            float(pitch_vals.mean()) if pitch_vals.size else np.nan,
            float(loud.mean()) if loud.size else np.nan,
            end - start,
        ))
    arr = np.array(feats)
    if np.isnan(arr[:, 0]).sum() > len(nuclei) - 2:
        return None  # need pitch on at least two syllables to compare them
    weights = np.array([0.4, 0.3, 0.3])
    z = np.zeros_like(arr)
    for k in range(3):
        col = arr[:, k]
        ok = ~np.isnan(col)
        if ok.sum() >= 2 and np.std(col[ok]) > 1e-9:
            z[ok, k] = (col[ok] - col[ok].mean()) / col[ok].std()
    return int(np.argmax(z @ weights))


# --- Fluency ---

def find_pauses(track: ProsodyTrack, gaps: Sequence[Tuple[float, float]], min_pause: float = 0.4) -> List[Tuple[float, float]]:
    """Inter-word gaps that are long and actually quiet."""
    speech = track.intensity[~np.isnan(track.intensity)]
    if speech.size == 0:
        return []
    quiet_level = np.percentile(speech, 90) - 20.0
    pauses = []
    for start, end in gaps:
        if end - start < min_pause:
            continue
        seg = track.intensity[_segment(track, start, end)]
        seg = seg[~np.isnan(seg)]
        if seg.size and np.median(seg) < quiet_level:
            pauses.append((start, end))
    return pauses


def rate_score(syllables_per_second: float) -> float:
    return float(np.interp(syllables_per_second, [1.0, 2.5, 5.5, 7.5], [30.0, 100.0, 100.0, 50.0]))
