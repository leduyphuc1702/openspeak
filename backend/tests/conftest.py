import sys
from pathlib import Path
from typing import Dict, List, Sequence

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.phonetics import Lexicon  # noqa: E402
from app.prosody import ProsodyTrack  # noqa: E402
from app.recognizer import Posteriors  # noqa: E402

VOCAB: Dict[str, int] = {
    t: i for i, t in enumerate(
        ["<pad>", "θ", "ɪ", "ŋ", "k", "s", "h", "ə", "l", "oʊ", "ɑː", "ɹ", "j", "uː", "iː", "p", "ʃ", "w", "æ", "t", "ʌ", "ʔ"]
    )
}

LEXICON = Lexicon({
    "think": [["TH", "IH1", "NG", "K"]],
    "hello": [["HH", "AH0", "L", "OW1"]],
    "are": [["AA1", "R"]],
    "you": [["Y", "UW1"]],
    "sheep": [["SH", "IY1", "P"]],
    "what": [["W", "AH1", "T"]],
})


class ScriptedRecognizer:
    """Emits each scripted token confidently for a few frames, separated by blanks."""

    vocab = VOCAB
    blank_id = 0

    def __init__(self, spoken: Sequence[str], frames_per_token: int = 3, blanks: int = 2):
        self.spoken = list(spoken)
        self.fpt = frames_per_token
        self.blanks = blanks

    def posteriors(self, wav: np.ndarray) -> Posteriors:
        rows: List[np.ndarray] = []

        def frame(token_id: int) -> np.ndarray:
            p = np.full(len(VOCAB), 0.01)
            p[token_id] = 1.0
            return np.log(p / p.sum())

        for _ in range(self.blanks):
            rows.append(frame(0))
        for tok in self.spoken:
            rows += [frame(VOCAB[tok])] * self.fpt
            rows += [frame(0)] * self.blanks
        return Posteriors(np.stack(rows), 0.02)


def make_track(duration: float, f0_start: float, f0_end: float, hop: float = 0.01) -> ProsodyTrack:
    times = np.arange(0.0, duration, hop)
    f0 = np.linspace(f0_start, f0_end, len(times))
    return ProsodyTrack(times, f0, np.full(len(times), 70.0))


@pytest.fixture
def lexicon() -> Lexicon:
    return LEXICON
