"""CTC forced alignment, Goodness-of-Pronunciation, and phone-sequence alignment."""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np

from .phonetics import VOWELS

NEG_INF = -1e30


@dataclass(frozen=True)
class TokenSpan:
    token_index: int
    first_frame: int  # first frame emitting the token
    last_frame: int   # last frame emitting the token (inclusive)


def ctc_forced_align(log_probs: np.ndarray, tokens: Sequence[int], blank: int) -> List[TokenSpan]:
    """Viterbi path of `tokens` through CTC log-posteriors (frames x vocab)."""
    T = log_probs.shape[0]
    L = len(tokens)
    if L == 0:
        return []
    ext = np.full(2 * L + 1, blank, dtype=np.int64)
    ext[1::2] = tokens
    S = len(ext)
    repeats = sum(1 for a, b in zip(tokens, tokens[1:]) if a == b)
    if T < L + repeats:
        raise ValueError("audio too short for the expected text")

    can_skip = np.zeros(S, dtype=bool)
    can_skip[2:] = (ext[2:] != blank) & (ext[2:] != ext[:-2])

    dp = np.full((T, S), NEG_INF)
    bp = np.zeros((T, S), dtype=np.int64)
    dp[0, 0] = log_probs[0, ext[0]]
    dp[0, 1] = log_probs[0, ext[1]]
    idx = np.arange(S)
    for t in range(1, T):
        stay = dp[t - 1]
        step = np.concatenate(([NEG_INF], dp[t - 1, :-1]))
        skip = np.where(can_skip, np.concatenate(([NEG_INF, NEG_INF], dp[t - 1, :-2])), NEG_INF)
        stacked = np.stack([stay, step, skip])
        choice = np.argmax(stacked, axis=0)
        dp[t] = stacked[choice, idx] + log_probs[t, ext]
        bp[t] = idx - choice

    s = S - 1 if dp[T - 1, S - 1] >= dp[T - 1, S - 2] else S - 2
    states = np.empty(T, dtype=np.int64)
    for t in range(T - 1, -1, -1):
        states[t] = s
        s = bp[t, s]

    spans: List[TokenSpan] = []
    for k in range(L):
        frames = np.nonzero(states == 2 * k + 1)[0]
        spans.append(TokenSpan(k, int(frames[0]), int(frames[-1])))
    return spans


def gop(log_probs: np.ndarray, token: int, span: TokenSpan, blank: int) -> float:
    """Average log-posterior margin of the expected token over its competitors (<= 0)."""
    seg = log_probs[span.first_frame:span.last_frame + 1]
    competitors = np.delete(seg, blank, axis=1)
    return float(np.mean(seg[:, token] - competitors.max(axis=1)))


def lpp(log_probs: np.ndarray, token: int, span: TokenSpan) -> float:
    """Mean log-posterior of the expected token over its span (<= 0)."""
    return float(np.mean(log_probs[span.first_frame:span.last_frame + 1, token]))


def margin(log_probs: np.ndarray, token: int, span: TokenSpan, blank: int) -> float:
    """Mean log-posterior lead of the expected token over the best *other* phone (signed)."""
    seg = log_probs[span.first_frame:span.last_frame + 1]
    others = np.delete(seg, [blank, token] if token != blank else [blank], axis=1)
    return float(np.mean(seg[:, token] - others.max(axis=1)))


def gop_to_score(value: float, scale: float = 2.0) -> float:
    """Map GOP (<= 0) to 0..100. `scale` needs calibration against rated learner data."""
    return float(100.0 * np.exp(min(value, 0.0) / scale))


# --- Expected vs. recognized phone sequences ---

_CLOSE_PAIRS = {
    frozenset(p): s
    for p, s in [
        (("ɝː", "ɚ"), 0.8), (("ʌ", "ə"), 0.8), (("ə", "ɪ"), 0.5), (("ə", "ɚ"), 0.5),
        (("iː", "ɪ"), 0.5), (("ʊ", "uː"), 0.5), (("ɑː", "ɔː"), 0.5), (("e", "æ"), 0.5),
        (("ɑː", "ʌ"), 0.4), (("oʊ", "ɔː"), 0.4), (("e", "eɪ"), 0.4),
        (("t", "d"), 0.6), (("θ", "s"), 0.3), (("θ", "t"), 0.3), (("ð", "d"), 0.3),
        (("ð", "z"), 0.3), (("s", "z"), 0.4), (("ʃ", "s"), 0.3), (("tʃ", "ʃ"), 0.4),
        (("v", "b"), 0.3), (("v", "w"), 0.3), (("l", "n"), 0.3), (("r", "l"), 0.3),
        (("ʒ", "ʃ"), 0.4), (("dʒ", "ʒ"), 0.4), (("p", "b"), 0.4), (("k", "ɡ"), 0.4),
    ]
}
GAP = -0.5


def phone_similarity(a: str, b: str) -> float:
    if a == b:
        return 1.0
    close = _CLOSE_PAIRS.get(frozenset((a, b)))
    if close is not None:
        return close
    va, vb = a in VOWELS, b in VOWELS
    if va and vb:
        return 0.2
    if not va and not vb:
        return 0.1
    return 0.0


@dataclass(frozen=True)
class AlignedPair:
    ref_index: Optional[int]
    expected: Optional[str]
    heard: Optional[str]

    @property
    def similarity(self) -> float:
        if self.expected is None or self.heard is None:
            return 0.0
        return phone_similarity(self.expected, self.heard)


def align_sequences(ref: Sequence[str], hyp: Sequence[str]) -> List[AlignedPair]:
    """Needleman-Wunsch alignment that maximizes phonetic similarity."""
    n, m = len(ref), len(hyp)
    score = np.zeros((n + 1, m + 1))
    move = np.zeros((n + 1, m + 1), dtype=np.int8)  # 0 diag, 1 up (deletion), 2 left (insertion)
    score[1:, 0] = GAP * np.arange(1, n + 1)
    score[0, 1:] = GAP * np.arange(1, m + 1)
    move[1:, 0] = 1
    move[0, 1:] = 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            options = (
                score[i - 1, j - 1] + phone_similarity(ref[i - 1], hyp[j - 1]),
                score[i - 1, j] + GAP,
                score[i, j - 1] + GAP,
            )
            k = int(np.argmax(options))
            score[i, j] = options[k]
            move[i, j] = k

    pairs: List[AlignedPair] = []
    i, j = n, m
    while i > 0 or j > 0:
        k = move[i, j]
        if k == 0:
            pairs.append(AlignedPair(i - 1, ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif k == 1:
            pairs.append(AlignedPair(i - 1, ref[i - 1], None))
            i -= 1
        else:
            pairs.append(AlignedPair(None, None, hyp[j - 1]))
            j -= 1
    pairs.reverse()
    return pairs


def heard_per_reference(ref: Sequence[str], hyp: Sequence[str]) -> List[Tuple[Optional[str], float]]:
    """For each reference phone: (what was heard instead or None if dropped, similarity)."""
    result: List[Tuple[Optional[str], float]] = [(None, 0.0)] * len(ref)
    for pair in align_sequences(ref, hyp):
        if pair.ref_index is not None:
            result[pair.ref_index] = (pair.heard, pair.similarity)
    return result
