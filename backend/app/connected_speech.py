"""Connected speech (nối âm) in American English: where words should run
together, how the sounds change, and whether the learner actually did it."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

from .phonetics import VOWELS, WordPron

J_GLIDE_AFTER = frozenset({"iː", "eɪ", "aɪ", "ɔɪ"})
W_GLIDE_AFTER = frozenset({"uː", "oʊ", "aʊ"})
R_COLORED = frozenset({"ɝː", "ɚ"})
ASSIMILATION = {("t", "j"): "tʃ", ("d", "j"): "dʒ", ("s", "j"): "ʃ", ("z", "j"): "ʒ"}

HINTS = {
    "consonant_vowel": "Phụ âm cuối của từ trước nối thẳng sang nguyên âm của từ sau, đọc liền như một từ.",
    "flap_t": "/t/ nằm giữa hai nguyên âm: đầu lưỡi chạm lợi thật nhanh một cái, nghe gần như 'đ' nhẹ.",
    "j_glide": "Hai nguyên âm gặp nhau: chêm một âm /j/ (như 'y') rất nhẹ để nối, không ngắt hơi.",
    "w_glide": "Hai nguyên âm gặp nhau: chêm một âm /w/ rất nhẹ để nối, không ngắt hơi.",
    "linking_r": "Âm /r/ cuối từ nối sang nguyên âm phía sau.",
    "vowel_vowel": "Lướt từ nguyên âm này sang nguyên âm kia, không dừng.",
    "gemination": "Hai phụ âm giống nhau: chỉ đọc một lần nhưng giữ lâu hơn một chút.",
    "assimilation": "Hai âm hoà vào nhau thành âm mới, ví dụ 'did you' đọc thành /dɪdʒuː/.",
    "elision": "/t/ hoặc /d/ kẹp giữa hai phụ âm gần như bị lược, chỉ giữ khẩu hình.",
}


@dataclass
class Link:
    index: int                 # boundary between words[index] and words[index + 1]
    type: str
    display: str               # "turn‿off"
    connected_ipa: str         # how the joined pair sounds
    hint: str

    def to_dict(self) -> Dict:
        return {"index": self.index, "type": self.type, "display": self.display,
                "connected_ipa": self.connected_ipa, "hint": self.hint}


def classify(a: WordPron, b: WordPron) -> Optional[str]:
    last, first = a.phones[-1].ipa, b.phones[0].ipa
    before_last = a.phones[-2].ipa if len(a.phones) > 1 else None
    last_v, first_v = last in VOWELS, first in VOWELS

    if last == "t" and first_v and before_last is not None and (before_last in VOWELS or before_last == "r"):
        return "flap_t"
    if not last_v and first_v:
        return "linking_r" if last == "r" else "consonant_vowel"
    if last_v and first_v:
        if last in J_GLIDE_AFTER:
            return "j_glide"
        if last in W_GLIDE_AFTER:
            return "w_glide"
        return "linking_r" if last in R_COLORED else "vowel_vowel"
    if (last, first) in ASSIMILATION:
        return "assimilation"
    if not last_v and last == first:
        return "gemination"
    if last in ("t", "d") and before_last is not None and before_last not in VOWELS and len(a.phones) > 2:
        return "elision"
    return None


def _split_stress(symbol: str) -> Tuple[str, str]:
    return ("ˈ", symbol[1:]) if symbol.startswith("ˈ") else ("", symbol)


def apply_link(kind: str, left: List[str], right: List[str]) -> Tuple[List[str], str, List[str]]:
    """Sound change at a boundary: (new left symbols, separator, new right symbols).
    Symbols may carry a leading stress mark, which is preserved."""
    left, right = list(left), list(right)
    sep = "‿"
    if kind == "flap_t":
        mark, _ = _split_stress(left[-1])
        left[-1] = mark + "ɾ"
    elif kind == "j_glide":
        sep = "‿ʲ"
    elif kind == "w_glide":
        sep = "‿ʷ"
    elif kind == "assimilation":
        _, last = _split_stress(left[-1])
        mark, first = _split_stress(right[0])
        right[0] = mark + ASSIMILATION[(last, first)]
        left = left[:-1]
    elif kind == "gemination":
        left = left[:-1]
    elif kind == "elision":
        left[-1] = f"({left[-1]})"
    return left, sep, right


def find_links(words: Sequence[WordPron]) -> List[Link]:
    links = []
    for i in range(len(words) - 1):
        kind = classify(words[i], words[i + 1])
        if kind is None:
            continue
        left, sep, right = apply_link(kind, words[i].display_symbols(), words[i + 1].display_symbols())
        links.append(Link(i, kind, f"{words[i].word}‿{words[i + 1].word}",
                          "".join(left) + sep + "".join(right), HINTS[kind]))
    return links


def connected_transcription(words: Sequence[WordPron], links: Sequence[Link]) -> str:
    """Whole-sentence IPA with ‿ at every link and the sound changes applied."""
    symbols = [w.display_symbols() for w in words]
    seps = [" "] * max(len(words) - 1, 0)
    for link in links:
        i = link.index
        symbols[i], seps[i], symbols[i + 1] = apply_link(link.type, symbols[i], symbols[i + 1])
    out = "".join(symbols[0]) if symbols else ""
    for i, sep in enumerate(seps):
        out += sep + "".join(symbols[i + 1])
    return out


# --- Checking what the learner did ---

@dataclass
class LinkResult:
    link: Link
    linked: bool
    gap: float
    problem: Optional[str] = None   # "pause" or "glottal_stop"
    flap_realized: Optional[bool] = None

    def to_dict(self) -> Dict:
        d = self.link.to_dict()
        d.update({"linked": self.linked, "gap": round(self.gap, 3), "problem": self.problem,
                  "flap_realized": self.flap_realized})
        return d


def check_links(
    links: Sequence[Link],
    boundaries: Sequence[Tuple[float, float]],
    raw_tokens: Sequence[Tuple[str, float]],
    quiet_gaps: Sequence[Tuple[float, float]],
    max_gap: float = 0.25,
) -> List[LinkResult]:
    """`boundaries[i]` = (end of word i's last sound, start of word i+1's first sound).

    A link is broken by an audible stop: a glottal stop between the words, or a
    long gap that is actually quiet.
    """
    results = []
    for link in links:
        end_a, start_b = boundaries[link.index]
        gap = max(0.0, start_b - end_a)
        between = [t for t, at in raw_tokens if end_a - 0.02 <= at <= start_b + 0.02]
        problem = None
        if "ʔ" in between:
            problem = "glottal_stop"
        elif gap > max_gap and any(s < start_b and e > end_a for s, e in quiet_gaps):
            problem = "pause"
        flap = None
        if link.type == "flap_t":
            near = [t for t, at in raw_tokens if end_a - 0.12 <= at <= start_b + 0.02]
            flap = any(t in ("ɾ", "d") for t in near)
        results.append(LinkResult(link, problem is None, gap, problem, flap))
    return results
