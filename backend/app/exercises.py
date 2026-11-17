"""Multiple-choice exercises for one sound: questions where the learner has to
hear the sound or know which spellings carry it.

Three kinds, all answered by tapping one option:
- pair: hear one word of a minimal pair (seat / sit), pick it;
- gap: hear a whole sentence, pick which word of a minimal pair filled the gap;
- spelling: see three or four similarly spelled words (bread / seat / great), pick
  the only one that has the sound.

The LLM writes them for the learner's topics. The server never trusts its answers:
every word is looked up in the lexicon the scorer uses, minimal pairs are
re-derived, and for spelling questions the server itself works out which option
has the sound, rejecting the question unless exactly one does. Without an LLM,
pairs and spelling questions are built from path_pool.
"""
from __future__ import annotations

import json
import logging
import random
import re
from typing import Dict, Iterable, List, Optional, Sequence, Set

from pydantic import BaseModel, Field

from . import vocab
from .llm import LLMClient
from .path_pool import CONFUSABLE
from .phonetics import PHONE_IPA, VOWEL_IDS, Lexicon, UnknownWordError

log = logging.getLogger("openspeak.exercises")

WORD_RE = re.compile(r"[a-z][a-z']{0,19}")
SENTENCE_RE = re.compile(r"[A-Za-z][A-Za-z' ,.?!-]{3,118}")
BLANK = "___"

RULES_VI = (
    "Bài tập trắc nghiệm, mỗi câu người học chạm một đáp án. Chỉ ra loại câu buộc người học phải NGHE được âm "
    "hoặc biết cách viết nào đọc ra âm đó; không ra câu nhìn ký hiệu là đoán được. "
    "'pairs': cặp từ tối thiểu chỉ khác đúng một âm (âm luyện và âm dễ nhầm), app đọc một từ, người học chọn. "
    "'gaps': một câu tự nhiên theo chủ đề người học, chứa 'target'; 'distractor' là từ tạo cặp tối thiểu với "
    "target qua âm luyện. App đọc cả câu, người học chọn từ đã nghe. Thay target bằng distractor câu vẫn phải "
    "đúng ngữ pháp và có nghĩa, để không thể đoán bằng nghĩa mà phải nghe. "
    "'spelling': 3-4 từ thông dụng có cách viết giống nhau (cùng cụm chữ, ví dụ 'ea' trong bread, seat, great) "
    "nhưng CHỈ MỘT từ có âm luyện; 'note_vi' giải thích ngắn bẫy chính tả. "
    "Mọi từ là từ tiếng Anh đơn, viết thường (trừ trong câu), không tên riêng, không chữ số. "
    "Mỗi câu có 'topic' là id một chủ đề của người học; rải đều các chủ đề; không lặp lại từ khoá giữa các câu "
    "và không dùng từ trong 'avoid_words'. 'angles' gợi ý góc nhìn cho từng chủ đề để đề khác các lần trước."
)

# Rotated per request so two lessons on the same topic do not draw on the same situations.
ANGLES = [
    "con số, thời gian, lịch hẹn", "người và vai trò", "đồ vật và công cụ", "việc cần làm, hành động",
    "vấn đề phát sinh và cách xử lý", "cảm xúc, nhận xét", "địa điểm, đi lại", "kế hoạch sắp tới",
    "so sánh, lựa chọn", "lời đề nghị, xin phép",
]


def sym(pid: str) -> str:
    return f"/{PHONE_IPA[pid]}/"


def _text(value, limit: int) -> str:
    return str(value or "").strip()[:limit]


def with_symbols(text: str, ids: Iterable[str]) -> str:
    """Models sometimes write the sound ids they were given ("L, TH, IH") into titles; show IPA instead."""
    for pid in sorted(ids, key=len, reverse=True):
        text = re.sub(rf"(?<![\w/]){re.escape(pid)}(?![\w/])", f"/{PHONE_IPA[pid]}/", text)
    return text


def _word(value) -> str:
    return _text(value, 20).lower()


def items(value) -> list:
    return value if isinstance(value, list) else []


def word_dict(lexicon: Lexicon, word: str, meaning: str = "") -> Dict:
    pron = lexicon.lookup(word)
    return {"word": pron.word, "ipa": pron.ipa, "phones": [p.id for p in pron.phones], "meaning_vi": meaning}


def _pair_options(lexicon: Lexicon, a: str, b: str, sound: str) -> Optional[List[Dict]]:
    from .path import minimal_pair     # path imports this module

    pair = minimal_pair(lexicon, a, b) if WORD_RE.fullmatch(a) and WORD_RE.fullmatch(b) else None
    if not pair or sound not in pair["contrast"]:
        return None
    return [pair["a"], pair["b"]]


def exercise(kind: str, sound: str, options: List[Dict], answer: int, rng: random.Random, topic: Optional[str] = None,
             text: Optional[str] = None, sentence: Optional[str] = None, note: str = "", meaning: str = "") -> Dict:
    order = list(range(len(options)))
    rng.shuffle(order)
    return {
        "kind": kind,
        "sound": sound,
        "options": [options[i] for i in order],
        "answer": order.index(answer),
        "text": text,
        "sentence": sentence,
        "note_vi": note or None,
        "meaning_vi": meaning or None,
        "topic": topic,
    }


class Checker:
    """Validates LLM items for a set of sounds, keeping keywords unique across everything it accepts."""

    def __init__(self, lexicon: Lexicon, sounds: Sequence[str], rng: random.Random, topics: Sequence[str] = (),
                 avoid: Iterable[str] = (), max_sentence_words: int = 14):
        self.lexicon, self.sounds, self.rng = lexicon, list(sounds), rng
        self.topics = list(topics)
        self.avoid = {w.lower() for w in avoid}
        self.used: Set[str] = set()
        self.max_sentence_words = max_sentence_words

    def sound(self, item: Dict) -> Optional[str]:
        s = item.get("sound")
        if s in self.sounds:
            return s
        return self.sounds[0] if len(self.sounds) == 1 else None

    def topic(self, item: Dict) -> Optional[str]:
        t = item.get("topic")
        return t if t in self.topics else None

    def fresh(self, *words: str, recent: bool = True) -> bool:
        """Not used elsewhere in this set and, unless recent=False, not in the learner's recent words."""
        return not any(w in self.used or (recent and w in self.avoid) for w in words)

    def take(self, *words: str) -> None:
        self.used.update(words)

    def pair(self, item) -> Optional[Dict]:
        if not isinstance(item, dict) or not (sound := self.sound(item)):
            return None
        a, b = _word(item.get("a")), _word(item.get("b"))
        options = _pair_options(self.lexicon, a, b, sound)
        # Classic pairs (ship / sheep) come back often and that is fine; only repeats inside one set are not.
        if not options or not self.fresh(a, b, recent=False):
            return None
        self.take(a, b)
        return exercise("pair", sound, options, self.rng.randrange(2), self.rng, self.topic(item))

    def gap(self, item) -> Optional[Dict]:
        if not isinstance(item, dict) or not (sound := self.sound(item)):
            return None
        target, distractor = _word(item.get("target")), _word(item.get("distractor"))
        sentence = " ".join(_text(item.get("sentence"), 120).split())
        options = _pair_options(self.lexicon, target, distractor, sound)
        if not options or not SENTENCE_RE.fullmatch(sentence) or not self.fresh(target, distractor):
            return None
        # The first option of a minimal pair is the first word given, i.e. the target.
        match = re.search(rf"\b{re.escape(target)}\b", sentence, re.IGNORECASE)
        if not match:
            return None
        try:
            words = self.lexicon.sentence(sentence)
        except (UnknownWordError, ValueError):
            return None
        if len(words) > self.max_sentence_words + 2:
            return None
        self.take(target, distractor)
        text = sentence[:match.start()] + BLANK + sentence[match.end():]
        return exercise("gap", sound, options, 0, self.rng, self.topic(item), text=text, sentence=sentence,
                        meaning=_text(item.get("meaning_vi"), 160))

    def spelling(self, item) -> Optional[Dict]:
        if not isinstance(item, dict) or not (sound := self.sound(item)):
            return None
        words = list(dict.fromkeys(_word(w) for w in (item.get("words") or [])[:4]))
        if len(words) < 3 or not all(WORD_RE.fullmatch(w) for w in words):
            return None
        try:
            readings = [self.lexicon.pronunciations(w) for w in words]
        except UnknownWordError:
            return None
        # The answer must have the sound in its main reading, and no other option in any reading.
        has_main = [has_sound(r[0].phones, sound) for r in readings]
        has_any = [any(sound in [p.id for p in x.phones] for x in r) for r in readings]
        if sum(has_main) != 1 or sum(has_any) != 1:
            return None
        answer = has_main.index(True)
        if not self.fresh(words[answer]):
            return None
        self.take(*words)
        options = [word_dict(self.lexicon, w) for w in words]
        return exercise("spelling", sound, options, answer, self.rng, self.topic(item),
                        note=_text(item.get("note_vi"), 200))

    def collect(self, data: Dict) -> Dict[str, List[Dict]]:
        out: Dict[str, List[Dict]] = {"pairs": [], "gaps": [], "spelling": []}
        for key, check in (("pairs", self.pair), ("gaps", self.gap), ("spelling", self.spelling)):
            for item in items(data.get(key)):
                if (ex := check(item)) is not None:
                    out[key].append(ex)
        return out


# --- Without an LLM ---

# Letters that often spell each sound, but not always: the raw material of a spelling trap
# (seat / bread / great all have "ea", only seat has /iː/).
GRAPHEMES: Dict[str, List[str]] = {
    "IY": ["ea", "ie", "ei", "ee", "e"], "IH": ["ui", "i", "e", "y"], "EH": ["ea", "ai", "e"],
    "AE": ["a"], "AA": ["o", "a"], "AO": ["au", "aw", "ou", "al", "o"], "UH": ["oo", "ou", "u"],
    "UW": ["oo", "ou", "ew", "ui", "u"], "AH": ["ou", "o", "u"], "ER": ["ear", "ir", "ur", "or", "er"],
    "EY": ["ai", "ea", "ei", "ey", "a"], "AY": ["igh", "ei", "i", "y"], "OY": ["oi", "oy"],
    "AW": ["ou", "ow"], "OW": ["ou", "ow", "oa", "o"], "TH": ["th"], "DH": ["th"],
    "SH": ["ch", "ti", "ci", "ss", "s"], "ZH": ["si", "s", "g"], "CH": ["ch", "tu", "t"],
    "JH": ["dg", "g", "j"], "Z": ["s", "x"], "S": ["sc", "c", "s"], "K": ["ch", "c"], "G": ["gu", "g"],
    "F": ["gh", "ph"], "NG": ["ng", "n"], "HH": ["wh", "h"], "W": ["wh", "o", "u"], "Y": ["u", "y"],
    "L": ["l"], "T": ["ed", "t"], "D": ["ed"], "B": ["b"], "P": ["p"],
}


# The plain spelling of a consonant: if the answer has it besides the trap letters, the sound came from it.
PLAIN = {"F": "f", "W": "w", "V": "v", "K": "k", "S": "s", "Z": "z", "SH": "sh", "JH": "j", "T": "t", "D": "d",
         "Y": "y", "G": "g", "CH": "ch", "HH": "h"}


def spelled_by(word: str, reading: Sequence, sound: str, letters: str) -> bool:
    """Rough check that these letters, not others, spell the sound: similar relative position in
    word and pronunciation, and no plain spelling of the sound elsewhere in the word."""
    i = word.find(letters)
    j = next((k for k, p in enumerate(reading) if p.id == sound), None)
    if i < 0 or j is None:
        return False
    if abs((i + len(letters) / 2) / len(word) - (j + 0.5) / len(reading)) > 0.2:
        return False
    plain = PLAIN.get(sound)
    return not (plain and plain != letters and plain in word.replace(letters, " "))


def has_sound(reading: Sequence, sound: str) -> bool:
    """The sound is in this reading; for a vowel it must carry stress (the -y of happy is not /iː/ to a learner)."""
    vowel = sound in VOWEL_IDS
    return any(p.id == sound and (not vowel or p.stress) for p in reading)


def rules_spelling(lexicon: Lexicon, words: Iterable[str], sound: str, rng: random.Random, n: int,
                   used: Set[str]) -> List[Dict]:
    """Spelling traps from a word list: one word where the letters spell the sound, two where they do not."""
    readings = {}
    for w in words:
        try:
            readings[w] = lexicon.pronunciations(w)
        except UnknownWordError:
            pass
    graphemes = [g for g in GRAPHEMES.get(sound, [])]
    rng.shuffle(graphemes)
    graphemes.sort(key=len, reverse=True)
    out = []
    for g in graphemes * 2:
        if len(out) >= n:
            break
        answers = [w for w, r in readings.items() if g in w and w not in used and has_sound(r[0].phones, sound)
                   and spelled_by(w, r[0].phones, sound, g)]
        others = [w for w, r in readings.items()
                  if g in w and w not in used and not any(sound in [p.id for p in x.phones] for x in r)]
        if not answers or len(others) < 2:
            continue
        answer = rng.choice(answers)
        distractors = rng.sample(others, 2)
        used.update([answer, *distractors])
        options = [word_dict(lexicon, w) for w in [answer, *distractors]]
        out.append(exercise("spelling", sound, options, 0, rng,
                            note=f"Cả ba từ đều có chữ \"{g}\", nhưng chỉ trong {answer} chữ đó đọc là {sym(sound)}."))
    return out


def pairs_as_exercises(pairs: Sequence[Dict], sound: str, rng: random.Random) -> List[Dict]:
    return [exercise("pair", sound, [p["a"], p["b"]], rng.randrange(2), rng) for p in pairs]


def interleave(*groups: Sequence[Dict]) -> List[Dict]:
    """Mix kinds so the learner does not answer three of the same in a row."""
    out, groups = [], [list(g) for g in groups]
    while any(groups):
        for g in groups:
            if g:
                out.append(g.pop(0))
    return out


# --- One sound, for the foundation course ---

class ExerciseRequest(BaseModel):
    sound: str
    contrasts: List[str] = Field(default_factory=list)
    level: str = "intermediate"
    topics: List[str] = Field(default_factory=list)
    avoid_words: List[str] = Field(default_factory=list)
    seed: int = 0


PROMPT = (
    "Bạn là giáo viên phát âm tiếng Anh giọng Mỹ cho người Việt đi làm. Soạn bài tập cho một âm. " + RULES_VI +
    " Soạn 3 'pairs', 2 'gaps', 3 'spelling'. "
    'Trả về JSON: {"pairs": [{"sound": "IY", "a": "seat", "b": "sit", "topic": "work"}], '
    '"gaps": [{"sound": "IY", "sentence": "...", "target": "...", "distractor": "...", "meaning_vi": "...", "topic": "..."}], '
    '"spelling": [{"sound": "IY", "words": ["...", "...", "..."], "note_vi": "...", "topic": "..."}]}'
)


def choose_contrast(sound: str, offered: Sequence[str]) -> Optional[str]:
    near = CONFUSABLE.get(sound, [])
    return next((c for c in near if c in offered), None) or (near[0] if near else None)


def angles_for(topics: Sequence[str], rng: random.Random) -> Dict[str, str]:
    return {t: rng.choice(ANGLES) for t in topics}


def for_sound(client: Optional[LLMClient], lexicon: Lexicon, req: ExerciseRequest) -> Dict:
    from .path import pool_for

    if req.sound not in PHONE_IPA:
        raise ValueError(f"unknown sound {req.sound}")
    pool = pool_for(lexicon)
    rng = random.Random(f"{req.seed}:{req.sound}")
    contrast = choose_contrast(req.sound, req.contrasts)
    topics = [t for t in req.topics if t in vocab.TOPIC_TITLES] or ["daily"]
    found: Dict[str, List[Dict]] = {"pairs": [], "gaps": [], "spelling": []}
    source = "rules"
    checker = Checker(lexicon, [req.sound], rng, topics, req.avoid_words[-80:], 10)
    if client is not None:
        payload = {
            "sound": {"id": req.sound, "ipa": PHONE_IPA[req.sound]},
            "contrast": {"id": contrast, "ipa": PHONE_IPA[contrast]} if contrast else None,
            "learner": {"level": vocab.LEVELS.get(req.level, req.level),
                        "topics": [{"id": t, "title": vocab.TOPIC_TITLES[t]} for t in topics]},
            "angles": angles_for(topics, rng),
            "avoid_words": req.avoid_words[-80:],
        }
        try:
            data = client.chat_json(PROMPT, json.dumps(payload, ensure_ascii=False))
            if isinstance(data, dict):
                found = checker.collect(data)
                source = "llm" if any(found.values()) else "rules"
        except Exception:
            log.exception("LLM exercises failed; building them from the offline pool")
    used = checker.used
    if len(found["pairs"]) < 2:
        taken = {w for ex in found["pairs"] for w in (o["word"] for o in ex["options"])}
        extra = [p for p in pool.pairs_for(req.sound, contrast, rng, 4)
                 if p["a"]["word"] not in taken and p["b"]["word"] not in taken]
        found["pairs"] += pairs_as_exercises(extra[: 3 - len(found["pairs"])], req.sound, rng)
    if len(found["spelling"]) < 2:
        found["spelling"] += rules_spelling(lexicon, pool.words, req.sound, rng, 2 - len(found["spelling"]), used)
    return {
        "sound": req.sound,
        "contrast": contrast,
        "exercises": interleave(found["pairs"][:3], found["spelling"][:3], found["gaps"][:2]),
        "source": source,
    }
