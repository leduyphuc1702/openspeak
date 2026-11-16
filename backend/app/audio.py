from __future__ import annotations

import io
from math import gcd

import numpy as np

from .recognizer import SAMPLE_RATE


def load_audio(data: bytes, target_sr: int = SAMPLE_RATE) -> np.ndarray:
    """Decode WAV/FLAC/OGG bytes to mono float32 at target_sr.

    Level is left untouched so the silence check in Assessor stays meaningful;
    the wav2vec2 feature extractor normalizes its own input.
    """
    import soundfile as sf
    from scipy.signal import resample_poly

    wav, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
    wav = wav.mean(axis=1)
    if sr != target_sr:
        g = gcd(sr, target_sr)
        wav = resample_poly(wav, target_sr // g, sr // g).astype(np.float32)
    return wav
