"""Turns audio + target text into a structured pronunciation assessment."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np

from . import alignment, connected_speech, prosody
from .phonetics import IPA_TO_ID, Lexicon, WordPron, expected_intonation, normalize_recognized, to_model_tokens
from .recognizer import SAMPLE_RATE, Recognizer, greedy_decode_timed

ProsodyExtractor = Callable[[np.ndarray, int], prosody.ProsodyTrack]


class NoSpeechError(ValueError):
    pass


CALIBRATION_FILE = Path(__file__).with_name("calibration.json")


@dataclass(frozen=True)
class Calibration:
    """Phone score = weight * acoustic-score + (1 - weight) * sequence similarity.

    `feature` picks the acoustic measure: "gop" / "lpp" (<= 0, mapped by
    exp(x / scale)) or "margin" (signed, mapped by a logistic). Defaults are
    hand-picked; `tools/calibrate.py` fits them against expert ratings
    (speechocean762) and writes app/calibration.json.
    """
    gop_scale: float = 2.0
    gop_weight: float = 0.6
    good_threshold: float = 80.0
    feature: str = "gop"
    # Affine map onto the experts' 0-100 scale (fitted; does not change correlation).
    display_gain: float = 1.0
    display_offset: float = 0.0

    def acoustic_score(self, value: float) -> float:
        if self.feature == "margin":
            return float(100.0 / (1.0 + np.exp(-value / self.gop_scale)))
        return alignment.gop_to_score(value, self.gop_scale)

    def phone_score(self, features: Dict[str, float], similarity: float) -> float:
        a = self.acoustic_score(features[self.feature])
        raw = self.gop_weight * a + (1.0 - self.gop_weight) * 100.0 * similarity
        return float(min(100.0, max(0.0, self.display_offset + self.display_gain * raw)))

    @classmethod
    def load(cls, path: Path = CALIBRATION_FILE) -> "Calibration":
        if not path.exists():
            return cls()
        data = json.loads(path.read_text())
        kwargs = {k: float(data[k]) for k in ("gop_scale", "gop_weight", "good_threshold", "display_gain", "display_offset") if k in data}
        if data.get("feature") in ("gop", "lpp", "margin"):
            kwargs["feature"] = data["feature"]
        return cls(**kwargs)


def _status(score: float, heard: Optional[str], expected: str, good: float = 80.0) -> str:
    if heard is None:
        return "missing"
    if heard != expected:
        return "substituted"
    return "good" if score >= good else "weak"


def _mean(values: List[float]) -> Optional[float]:
    vals = [v for v in values if v is not None]
    return float(np.mean(vals)) if vals else None


def _round(v: Optional[float]) -> Optional[int]:
    return None if v is None else int(round(v))


@dataclass
class _PhoneSlot:
    word_index: int
    ipa: str
    is_vowel: bool
    model_ids: Tuple[int, ...]


class Assessor:
    def __init__(self, recognizer: Recognizer, lexicon: Lexicon, prosody_extractor: ProsodyExtractor = prosody.extract_prosody,
                 calibration: Optional[Calibration] = None):
        self.recognizer = recognizer
        self.lexicon = lexicon
        self.extract = prosody_extractor
        self.cal = calibration or Calibration.load()

    def reference(self, text: str) -> List[WordPron]:
        return self.lexicon.sentence(text)

    def assess(self, wav: np.ndarray, text: str, reference_wav: Optional[np.ndarray] = None) -> Dict:
        if wav.size < SAMPLE_RATE * 0.3 or float(np.max(np.abs(wav))) < 0.01:
            raise NoSpeechError("no speech detected")
        words = self.reference(text)
        vocab, blank = self.recognizer.vocab, self.recognizer.blank_id

        slots: List[_PhoneSlot] = []
        for wi, w in enumerate(words):
            for p in w.phones:
                toks = to_model_tokens(p.ipa, vocab)
                slots.append(_PhoneSlot(wi, p.ipa, p.is_vowel, tuple(vocab[t] for t in toks)))

        post = self.recognizer.posteriors(wav)
        lp, fs = post.log_probs, post.frame_seconds
        timed_tokens = greedy_decode_timed(post, vocab, blank)
        heard = normalize_recognized([t for t, _ in timed_tokens])
        if not heard:
            raise NoSpeechError("no speech detected")

        flat_ids = [i for s in slots for i in s.model_ids]
        spans = alignment.ctc_forced_align(lp, flat_ids, blank)

        # Per canonical phone: GOP over its model tokens and its time span.
        phone_gop, phone_lpp, phone_margin, phone_first, phone_last = [], [], [], [], []
        k = 0
        for s in slots:
            sp = spans[k:k + len(s.model_ids)]
            pairs = list(zip(s.model_ids, sp))
            phone_gop.append(float(np.mean([alignment.gop(lp, tid, span, blank) for tid, span in pairs])))
            phone_lpp.append(float(np.mean([alignment.lpp(lp, tid, span) for tid, span in pairs])))
            phone_margin.append(float(np.mean([alignment.margin(lp, tid, span, blank) for tid, span in pairs])))
            phone_first.append(sp[0].first_frame)
            phone_last.append(sp[-1].last_frame)
            k += len(s.model_ids)
        T = lp.shape[0]
        phone_start = [f * fs for f in phone_first]
        phone_end = [
            (phone_first[i + 1] if i + 1 < len(slots) else min(T, phone_last[i] + 6)) * fs
            for i in range(len(slots))
        ]

        heard_map = alignment.heard_per_reference([s.ipa for s in slots], heard)

        track = self.extract(wav, SAMPLE_RATE)

        word_results, phone_scores = [], []
        stress_checks: List[prosody.StressResult] = []
        for wi, w in enumerate(words):
            idx = [i for i, s in enumerate(slots) if s.word_index == wi]
            phones = []
            for i in idx:
                heard_ipa, sim = heard_map[i]
                score = self.cal.phone_score(
                    {"gop": phone_gop[i], "lpp": phone_lpp[i], "margin": phone_margin[i]}, sim)
                phone_scores.append(score)
                phones.append({
                    "id": IPA_TO_ID.get(slots[i].ipa),
                    "expected": slots[i].ipa,
                    "heard": heard_ipa,
                    "heard_id": IPA_TO_ID.get(heard_ipa) if heard_ipa else None,
                    "score": _round(score),
                    "status": _status(score, heard_ipa, slots[i].ipa, self.cal.good_threshold),
                    "gop": round(phone_gop[i], 3),
                    "lpp": round(phone_lpp[i], 3),
                    "margin": round(phone_margin[i], 3),
                    "similarity": round(sim, 3),
                    "start": round(phone_start[i], 3),
                    "end": round(phone_end[i], 3),
                })

            stress = None
            expected_stress = w.primary_stress_vowel
            vowel_idx = [i for i in idx if slots[i].is_vowel]
            if expected_stress is not None and len(vowel_idx) >= 2:
                detected = prosody.detect_stress(track, [(phone_start[i], phone_end[i]) for i in vowel_idx])
                if detected is not None:
                    res = prosody.StressResult(expected_stress, detected)
                    stress_checks.append(res)
                    stress = {"expected": res.expected, "detected": res.detected, "correct": res.correct}

            word_results.append({
                "word": w.word,
                "ipa": w.ipa,
                "score": _round(_mean([p["score"] for p in phones])),
                "start": phones[0]["start"],
                "end": phones[-1]["end"],
                "stress": stress,
                "phones": phones,
            })

        speech_start = phone_start[0]
        speech_end = phone_last[-1] * fs + fs

        # Intonation
        expected = expected_intonation(text)
        slope = prosody.final_slope(track, speech_end)
        semis = prosody.pitch_range(track)
        detected_dir = None if slope is None else ("rising" if slope > 1.0 else "falling" if slope < -1.0 else "flat")
        c_score, r_score = prosody.contour_score(expected, slope), prosody.range_score(semis)
        ref_similarity, ref_contour = None, None
        if reference_wav is not None:
            ref_track = self.extract(reference_wav, SAMPLE_RATE)
            a, b = prosody.resample_contour(track), prosody.resample_contour(ref_track)
            ref_contour = b
            if a is not None and b is not None:
                ref_similarity = prosody.similarity_from_distance(prosody.dtw_distance(a, b))
        parts = [(c_score, 0.45), (r_score, 0.25), (ref_similarity, 0.30)]
        parts = [(v, wgt) for v, wgt in parts if v is not None]
        intonation = sum(v * wgt for v, wgt in parts) / sum(wgt for _, wgt in parts) if parts else None

        # Fluency
        gaps = [(phone_last[_last_slot(slots, i)] * fs + fs, word_results[i + 1]["start"]) for i in range(len(words) - 1)]
        pauses = prosody.find_pauses(track, gaps)
        syllables = sum(s.is_vowel for s in slots)
        duration = max(speech_end - speech_start, 0.1)
        rate = syllables / duration
        fluency = max(0.0, prosody.rate_score(rate) - 15.0 * len(pauses))

        # Connected speech
        links = connected_speech.find_links(words)
        quiet = prosody.find_pauses(track, gaps, min_pause=0.2)
        link_results = connected_speech.check_links(links, gaps, timed_tokens, quiet)
        linking = 100.0 * np.mean([r.linked for r in link_results]) if link_results else None

        pronunciation = _mean(phone_scores)
        stress_score = 100.0 * np.mean([s.correct for s in stress_checks]) if stress_checks else None
        weighted = [(pronunciation, 0.55), (intonation, 0.15), (stress_score, 0.10), (fluency, 0.10), (linking, 0.10)]
        weighted = [(v, wgt) for v, wgt in weighted if v is not None]
        overall = sum(v * wgt for v, wgt in weighted) / sum(wgt for _, wgt in weighted)

        user_contour = [
            [round(float(t), 3), round(float(v), 2)]
            for t, v in zip(track.times, track.semitones) if not np.isnan(v)
        ]
        ref_points = None
        if ref_contour is not None and user_contour:
            grid = np.linspace(user_contour[0][0], user_contour[-1][0], len(ref_contour))
            ref_points = [[round(float(t), 3), round(float(v), 2)] for t, v in zip(grid, ref_contour)]

        return {
            "text": text,
            "scores": {
                "overall": _round(overall),
                "pronunciation": _round(pronunciation),
                "intonation": _round(intonation),
                "stress": _round(stress_score),
                "fluency": _round(fluency),
                "linking": _round(linking),
            },
            "words": word_results,
            "linking": {
                "connected_ipa": connected_speech.connected_transcription(words, links),
                "links": [r.to_dict() for r in link_results],
            },
            "heard_phones": heard,
            "intonation": {
                "expected": expected,
                "detected": detected_dir,
                "final_slope": None if slope is None else round(slope, 2),
                "pitch_range": None if semis is None else round(semis, 2),
                "reference_similarity": _round(ref_similarity),
            },
            "fluency": {
                "syllables_per_second": round(rate, 2),
                "pauses": [{"start": round(a, 3), "end": round(b, 3)} for a, b in pauses],
            },
            "pitch_contour": {"user": user_contour, "reference": ref_points},
        }


def _last_slot(slots: List[_PhoneSlot], word_index: int) -> int:
    return max(i for i, s in enumerate(slots) if s.word_index == word_index)
