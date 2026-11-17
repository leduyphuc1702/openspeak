"""Reference pronunciations and the canonical phone inventory.

Canonical symbols follow the Cambridge Dictionary US-style IPA that Vietnamese
learners already know (iː, e, ɑː, ɝː ...). The iOS app's phonemes.json uses the
same ids and symbols, so the two sides agree on every phone.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

# id -> canonical IPA. AX and AXR are the unstressed forms of AH and ER.
PHONE_IPA: Dict[str, str] = {
    "IY": "iː", "IH": "ɪ", "EH": "e", "AE": "æ", "AA": "ɑː", "AO": "ɔː",
    "UH": "ʊ", "UW": "uː", "AH": "ʌ", "AX": "ə", "ER": "ɝː", "AXR": "ɚ",
    "EY": "eɪ", "AY": "aɪ", "OY": "ɔɪ", "AW": "aʊ", "OW": "oʊ",
    "P": "p", "B": "b", "T": "t", "D": "d", "K": "k", "G": "ɡ",
    "CH": "tʃ", "JH": "dʒ", "F": "f", "V": "v", "TH": "θ", "DH": "ð",
    "S": "s", "Z": "z", "SH": "ʃ", "ZH": "ʒ", "HH": "h",
    "M": "m", "N": "n", "NG": "ŋ", "L": "l", "R": "r", "W": "w", "Y": "j",
}
IPA_TO_ID: Dict[str, str] = {ipa: pid for pid, ipa in PHONE_IPA.items()}

VOWEL_IDS = frozenset(
    "IY IH EH AE AA AO UH UW AH AX ER AXR EY AY OY AW OW".split()
)
VOWELS = frozenset(PHONE_IPA[p] for p in VOWEL_IDS)

LEGAL_ONSETS = frozenset(
    tuple(o.split())
    for o in [
        "p l", "p r", "b l", "b r", "t r", "d r", "k l", "k r", "ɡ l", "ɡ r", "f l", "f r",
        "θ r", "ʃ r", "s p", "s t", "s k", "s m", "s n", "s l", "s w", "t w", "d w", "k w",
        "p j", "b j", "k j", "f j", "m j", "h j", "v j",
        "s p r", "s t r", "s k r", "s p l", "s k w", "s k j", "s p j",
    ]
)

WH_WORDS = frozenset("what where when why who whom whose which how".split())


@dataclass(frozen=True)
class Phone:
    id: str
    ipa: str
    stress: Optional[int] = None  # 0/1/2 for vowels, None for consonants

    @property
    def is_vowel(self) -> bool:
        return self.id in VOWEL_IDS


@dataclass(frozen=True)
class WordPron:
    word: str
    phones: Tuple[Phone, ...]

    @property
    def primary_stress_vowel(self) -> Optional[int]:
        """Index among this word's vowels that carries primary stress."""
        vowels = [p for p in self.phones if p.is_vowel]
        for i, p in enumerate(vowels):
            if p.stress == 1:
                return i
        return None

    @property
    def ipa(self) -> str:
        """IPA with ˈ at the start of the stressed syllable (maximal legal onset)."""
        return "".join(self.display_symbols())

    def display_symbols(self) -> List[str]:
        """One display string per phone; the stressed syllable's first phone carries ˈ."""
        # Dictionaries write unstressed IY (happy, very) as short /i/.
        symbols = ["i" if p.id == "IY" and p.stress == 0 else p.ipa for p in self.phones]
        if sum(p.is_vowel for p in self.phones) < 2:
            return symbols
        marks = set()
        for i, p in enumerate(self.phones):
            if not (p.is_vowel and p.stress == 1):
                continue
            j = i
            while j > 0 and not self.phones[j - 1].is_vowel:
                j -= 1
            onset_start = i
            for k in range(j, i):
                if tuple(symbols[k:i]) in LEGAL_ONSETS or i - k == 1:
                    onset_start = k
                    break
            marks.add(onset_start)
        return [("ˈ" if i in marks else "") + s for i, s in enumerate(symbols)]


def arpabet_to_phone(symbol: str) -> Phone:
    m = re.fullmatch(r"([A-Z]+)([012])?", symbol)
    if not m:
        raise ValueError(f"bad ARPAbet symbol {symbol!r}")
    base, digit = m.group(1), m.group(2)
    stress = int(digit) if digit is not None else None
    if base == "AH" and stress == 0:
        base = "AX"
    elif base == "ER" and stress == 0:
        base = "AXR"
    if base not in PHONE_IPA:
        raise ValueError(f"unknown ARPAbet phone {symbol!r}")
    return Phone(base, PHONE_IPA[base], stress)


class UnknownWordError(LookupError):
    def __init__(self, words: Sequence[str]):
        super().__init__(", ".join(words))
        self.words = list(words)


class Lexicon:
    """Word -> pronunciation, backed by CMUdict unless entries are injected."""

    def __init__(self, entries: Optional[Dict[str, List[List[str]]]] = None):
        self._entries = entries
        self._by_sound: Optional[Dict[Tuple[str, ...], List[str]]] = None

    def _dict(self) -> Dict[str, List[List[str]]]:
        if self._entries is None:
            import cmudict  # lazy: ~3 MB load

            self._entries = cmudict.dict()
        return self._entries

    def lookup(self, word: str) -> WordPron:
        return self.pronunciations(word)[0]

    def pronunciations(self, word: str) -> List[WordPron]:
        """Every CMUdict variant, most common first (e.g. live: /lɪv/ verb, /laɪv/ adjective)."""
        prons = self._dict().get(word.lower())
        if not prons:
            raise UnknownWordError([word])
        return [WordPron(word, tuple(arpabet_to_phone(s) for s in p)) for p in prons]

    def homophones(self, word: str) -> List[str]:
        """Other spellings of the word's main pronunciation, stress ignored (meet: meat, mete)."""
        if self._by_sound is None:
            index: Dict[Tuple[str, ...], List[str]] = {}
            for w, prons in self._dict().items():
                for p in prons:
                    index.setdefault(tuple(s.rstrip("012") for s in p), []).append(w)
            self._by_sound = index
        main = tuple(s.rstrip("012") for s in self._dict().get(word.lower(), [[]])[0])
        return [w for w in self._by_sound.get(main, []) if w != word.lower()] if main else []

    def sentence(self, text: str) -> List[WordPron]:
        words = tokenize(text)
        if not words:
            raise ValueError("empty text")
        result, missing = [], []
        for w in words:
            try:
                result.append(self.lookup(w))
            except UnknownWordError:
                missing.append(w)
        if missing:
            raise UnknownWordError(missing)
        return result


def tokenize(text: str) -> List[str]:
    return re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", text)


def expected_intonation(text: str) -> str:
    """'rising' for yes/no questions, 'falling' for statements and wh-questions."""
    words = tokenize(text)
    if text.strip().endswith("?") and words and words[0].lower() not in WH_WORDS:
        return "rising"
    return "falling"


# --- Mapping between canonical phones and the acoustic model's vocabulary ---

# Candidate token sequences in the espeak-style vocabulary of the wav2vec2
# phoneme model, tried in order. The first fully-present candidate wins.
MODEL_CANDIDATES: Dict[str, List[Tuple[str, ...]]] = {
    "iː": [("iː",), ("i",)], "e": [("ɛ",), ("e",)], "ɑː": [("ɑː",), ("ɑ",)],
    "ɔː": [("ɔː",), ("ɔ",), ("ɑ",)], "uː": [("uː",), ("u",)], "ʌ": [("ʌ",), ("ɐ",), ("ə",)],
    "ɝː": [("ɜː",), ("ɝ",), ("ɚ",), ("ɹ̩",), ("ə", "ɹ")], "ɚ": [("ɚ",), ("ɹ̩",), ("ə",)],
    "eɪ": [("eɪ",), ("e", "ɪ")], "aɪ": [("aɪ",), ("a", "ɪ")],
    "ɔɪ": [("ɔɪ",), ("ɔ", "ɪ")], "aʊ": [("aʊ",), ("a", "ʊ")],
    "oʊ": [("oʊ",), ("o", "ʊ")], "tʃ": [("tʃ",), ("ʧ",), ("t͡ʃ",), ("t", "ʃ")],
    "dʒ": [("dʒ",), ("ʤ",), ("d͡ʒ",), ("d", "ʒ")], "r": [("ɹ",), ("r",)], "ɡ": [("ɡ",), ("g",)],
    # Last resorts for models trained on smaller inventories (e.g. TIMIT, L2-ARCTIC).
    "ə": [("ə",), ("ɐ",), ("ʌ",)], "ʒ": [("ʒ",), ("ʃ",)],
}

# Model token -> canonical IPA, for decoding what the learner actually said.
MODEL_TO_CANONICAL: Dict[str, str] = {
    "i": "iː", "iː": "iː", "ɛ": "e", "e": "e", "ɑ": "ɑː", "ɑː": "ɑː",
    "ɔ": "ɔː", "ɔː": "ɔː", "u": "uː", "uː": "uː", "ɐ": "ʌ", "ʌ": "ʌ",
    "ɜː": "ɝː", "ɜ": "ɝː", "ɝ": "ɝː", "ɚ": "ɚ", "ᵻ": "ɪ", "ɪ": "ɪ",
    "ɹ": "r", "r": "r", "g": "ɡ", "ɡ": "ɡ", "ɫ": "l", "ɾ": "t", "ʔ": "t",
    "o": "oʊ", "oː": "ɔː", "a": "æ", "aː": "ɑː", "ɒ": "ɑː",
    "eɪ": "eɪ", "aɪ": "aɪ", "ɔɪ": "ɔɪ", "aʊ": "aʊ", "oʊ": "oʊ",
    "ɹ̩": "ɚ", "l̩": "l", "m̩": "m", "n̩": "n",
    "tʃ": "tʃ", "dʒ": "dʒ", "ʧ": "tʃ", "ʤ": "dʒ", "t͡ʃ": "tʃ", "d͡ʒ": "dʒ",
}
_MERGE = {
    ("e", "ɪ"): "eɪ", ("a", "ɪ"): "aɪ", ("ɔ", "ɪ"): "ɔɪ", ("a", "ʊ"): "aʊ",
    ("o", "ʊ"): "oʊ", ("t", "ʃ"): "tʃ", ("d", "ʒ"): "dʒ",
}
_IGNORED_TOKENS = frozenset({"<pad>", "<s>", "</s>", "<unk>", "[PAD]", "[UNK]", "|", " ", "", "͡", "ˌ", "ˈ"})


def to_model_tokens(ipa: str, vocab: Dict[str, int]) -> Tuple[str, ...]:
    # ARPAbet models (tokens like "AH", "TH") have no unstressed AX / AXR.
    arpabet = {"AX": "AH", "AXR": "ER"}
    pid = IPA_TO_ID.get(ipa)
    for token in (pid, arpabet.get(pid)):
        if token and token in vocab:
            return (token,)
    for cand in MODEL_CANDIDATES.get(ipa, []) + [(ipa,), tuple(ipa.replace("ː", ""))]:
        if cand and all(t in vocab for t in cand):
            return cand
    chars = tuple(c for c in ipa if c in vocab)
    if not chars:
        raise KeyError(f"phone {ipa!r} cannot be expressed in model vocabulary")
    return chars


def normalize_recognized(tokens: Sequence[str]) -> List[str]:
    """Collapse model tokens into canonical phones (merging split diphthongs)."""
    toks = [t for t in tokens if t not in _IGNORED_TOKENS]
    out: List[str] = []
    i = 0
    while i < len(toks):
        pair = tuple(toks[i:i + 2])
        if len(pair) == 2 and pair in _MERGE:
            out.append(_MERGE[pair])
            i += 2
            continue
        t = toks[i]
        if t in PHONE_IPA:
            canon = PHONE_IPA[t]
        else:
            canon = MODEL_TO_CANONICAL.get(t, t.replace("ː", "") if t.replace("ː", "") in IPA_TO_ID else t)
        out.append(canon)
        i += 1
    return out
