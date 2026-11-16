"""Acoustic phoneme model: produces CTC log-posteriors over IPA tokens.

The model hears *sounds*, not words, so a learner who says "sink" for "think"
yields /s/ here. A speech-to-text model would silently "correct" it.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Protocol, Tuple

import numpy as np

DEFAULT_MODEL = "facebook/wav2vec2-lv-60-espeak-cv-ft"
SAMPLE_RATE = 16_000
CALIBRATION_FILE = Path(__file__).with_name("calibration.json")


def configured_model() -> str:
    """PHONEME_MODEL if set, else the model the scores were calibrated on."""
    if os.getenv("PHONEME_MODEL"):
        return os.environ["PHONEME_MODEL"]
    if CALIBRATION_FILE.exists():
        return json.loads(CALIBRATION_FILE.read_text()).get("model", DEFAULT_MODEL)
    return DEFAULT_MODEL


@dataclass
class Posteriors:
    log_probs: np.ndarray   # frames x vocab
    frame_seconds: float


class Recognizer(Protocol):
    vocab: Dict[str, int]
    blank_id: int

    def posteriors(self, wav: np.ndarray) -> Posteriors: ...


def greedy_decode_timed(post: Posteriors, vocab: Dict[str, int], blank_id: int) -> List[Tuple[str, float]]:
    """Best-path tokens with the time (seconds) each one starts."""
    inv = {i: t for t, i in vocab.items()}
    best = post.log_probs.argmax(axis=1)
    out, prev = [], None
    for frame, i in enumerate(best):
        if i != prev and i != blank_id:
            out.append((inv[int(i)], frame * post.frame_seconds))
        prev = i
    return out


def greedy_decode(post: Posteriors, vocab: Dict[str, int], blank_id: int) -> List[str]:
    return [t for t, _ in greedy_decode_timed(post, vocab, blank_id)]


class Wav2Vec2PhonemeRecognizer:
    """Any Hugging Face CTC phone model (wav2vec2, HuBERT) with an IPA or ARPAbet vocabulary."""

    def __init__(self, model_name: str = None, device: str = None):
        import torch
        from huggingface_hub import hf_hub_download
        from transformers import AutoModelForCTC, Wav2Vec2FeatureExtractor

        self.model_name = model_name or configured_model()
        self._torch = torch
        self.device = device or ("mps" if torch.backends.mps.is_available() else "cpu")
        # Read vocab.json directly: the model's tokenizer class needs espeak-ng
        # installed just to construct, and we never tokenize text with it.
        with open(hf_hub_download(self.model_name, "vocab.json"), encoding="utf-8") as f:
            self.vocab: Dict[str, int] = json.load(f)
        try:
            self.extractor = Wav2Vec2FeatureExtractor.from_pretrained(self.model_name)
        except OSError:
            self.extractor = Wav2Vec2FeatureExtractor(sampling_rate=SAMPLE_RATE, do_normalize=True)
        self.model = AutoModelForCTC.from_pretrained(self.model_name).to(self.device).eval()
        # The CTC blank is the pad token; its spelling differs between models (<pad>, [PAD]).
        pad = self.model.config.pad_token_id
        self.blank_id = pad if pad is not None else self.vocab.get("<pad>", self.vocab.get("[PAD]", 0))

    def posteriors(self, wav: np.ndarray) -> Posteriors:
        torch = self._torch
        inputs = self.extractor(wav, sampling_rate=SAMPLE_RATE, return_tensors="pt")
        with torch.inference_mode():
            logits = self.model(inputs.input_values.to(self.device)).logits[0]
        log_probs = torch.log_softmax(logits.float(), dim=-1).cpu().numpy()
        frame_seconds = len(wav) / SAMPLE_RATE / max(log_probs.shape[0], 1)
        return Posteriors(log_probs, frame_seconds)
