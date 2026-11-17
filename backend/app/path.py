"""The personal path: an endless run of pronunciation lessons, each planned
from what the learner has done so far.

Planning is rule-based and always runs: every sound gets a "need" score from
the learner's speaking scores, listening mistakes and recent lessons. With an
LLM configured, the model picks the focus among the top candidates and writes
words, minimal pairs and sentences for the learner's topics; without one, the
lesson is assembled from path_pool. Either way every item is re-checked
against the lexicon the scorer uses, and anything that fails is replaced from
the pool.
"""
from __future__ import annotations

import json
import logging
import random
import re
from collections import Counter
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Dict, List, Optional, Sequence, Tuple

from pydantic import BaseModel, Field

from . import connected_speech, exercises, vocab
from .llm import LLMClient
from .path_pool import CONFUSABLE, COMMON_WORDS, L1_PRIOR, PAIRS, SENTENCES
from .phonetics import PHONE_IPA, VOWEL_IDS, Lexicon, UnknownWordError, WordPron, expected_intonation

log = logging.getLogger("openspeak.path")

LEVEL_DIFFICULTY = {"beginner": 1, "elementary": 1, "intermediate": 2, "advanced": 3}
MAX_SYLLABLES = {1: 2, 2: 3, 3: 6}
MAX_SENTENCE_WORDS = {1: 7, 2: 10, 3: 16}
DIFFICULTY_TEXT = {
    1: "dễ: từ 1-2 âm tiết rất thông dụng; câu 4-7 từ",
    2: "vừa: từ 1-3 âm tiết; câu 6-10 từ",
    3: "khó: từ nhiều âm tiết, cụm từ công việc; câu 8-14 từ, có nối âm",
}
WORD_RE = re.compile(r"[a-z][a-z']{0,19}")
SENTENCE_RE = re.compile(r"[A-Za-z][A-Za-z' ,.?!-]{3,118}")


class SoundStat(BaseModel):
    id: str
    speak: Optional[float] = None      # recent average speaking score, 0-100
    takes: int = 0                     # how many scored takes back that average
    heard_right: int = 0
    heard_wrong: int = 0
    learned: bool = False              # the foundation lesson for this sound is done


class LessonRecord(BaseModel):
    index: int
    focus: str
    contrast: Optional[str] = None
    difficulty: int = 2
    score: Optional[int] = None        # average score of the focus sound during the lesson


class PathRequest(BaseModel):
    level: str = "intermediate"
    topics: List[str] = Field(default_factory=list)
    next_index: int = Field(1, ge=1)
    sounds: List[SoundStat] = Field(default_factory=list)
    skills: Dict[str, int] = Field(default_factory=dict)
    history: List[LessonRecord] = Field(default_factory=list)
    recent_words: List[str] = Field(default_factory=list)


def sym(pid: str) -> str:
    return f"/{PHONE_IPA[pid]}/"


def ids(pron: WordPron) -> List[str]:
    return [p.id for p in pron.phones]


def syllables(pron: WordPron) -> int:
    return sum(p.id in VOWEL_IDS for p in pron.phones)


def word_dict(pron: WordPron, meaning: str = "") -> Dict:
    return {"word": pron.word, "ipa": pron.ipa, "phones": ids(pron), "meaning_vi": meaning}


# --- Planning ---

@dataclass
class Candidate:
    id: str
    need: float
    evidence: List[str] = field(default_factory=list)


@dataclass
class Plan:
    focus: str
    contrast: Optional[str]
    difficulty: int
    reason: str
    ranked: List[Candidate]


def rank_sounds(req: PathRequest) -> List[Candidate]:
    """Every sound with a need score: own scores where they exist, the L1 prior where they don't."""
    stats = {s.id: s for s in req.sounds if s.id in PHONE_IPA}
    history = req.history[-10:]
    last = history[-1] if history else None
    before = history[-2] if len(history) > 1 else None
    practised = Counter(r.focus for r in history)
    out = []
    for pid in PHONE_IPA:
        s = stats.get(pid)
        # Half weight: a sound the learner really scored 40 on must outrank one that is only hard on paper.
        prior = 0.5 * L1_PRIOR.get(pid, 0.3)
        needs: List[float] = []
        why: List[str] = []
        if s and s.takes > 0 and s.speak is not None:
            w = min(s.takes, 4) / 4
            needs.append(w * (100 - s.speak) / 100 + (1 - w) * prior)
            why.append(f"điểm nói {sym(pid)} của bạn trung bình {round(s.speak)}/100 qua {s.takes} lần chấm")
        heard = (s.heard_right + s.heard_wrong) if s else 0
        if heard:
            w = min(heard, 4) / 4
            needs.append(w * s.heard_wrong / heard + (1 - w) * prior)
            if s.heard_wrong:
                why.append(f"bạn nghe nhầm âm này {s.heard_wrong}/{heard} lần")
        if needs:
            need = max(needs)
        else:
            need = prior
            why.append("người Việt hay gặp khó ở âm này và bạn chưa có điểm cho nó" if L1_PRIOR.get(pid, 0) >= 0.5
                       else "bạn chưa có điểm cho âm này")
        if last and last.focus == pid:
            if last.score is not None and last.score < 70 and not (before and before.focus == pid):
                need += 0.25
                why.insert(0, f"bài trước bạn mới đạt {last.score} điểm với âm này, nên luyện thêm một lượt")
            else:
                need -= 0.6
        elif before and before.focus == pid:
            need -= 0.3
        need -= 0.08 * practised[pid]
        out.append(Candidate(pid, round(need, 3), why))
    out.sort(key=lambda c: -c.need)
    return out


def pick_difficulty(req: PathRequest) -> Tuple[int, Optional[str]]:
    """Start from the last lesson's difficulty and move one step on clear success or struggle."""
    d = req.history[-1].difficulty if req.history else LEVEL_DIFFICULTY.get(req.level, 2)
    d = min(max(d, 1), 3)
    scores = [r.score for r in req.history[-2:] if r.score is not None]
    if len(scores) < 2:
        return d, None
    avg = round(sum(scores) / len(scores))
    if avg >= 85 and d < 3:
        return d + 1, f"Hai bài gần nhất bạn đạt trung bình {avg} điểm nên bài này khó hơn một bậc."
    if avg < 60 and d > 1:
        return d - 1, f"Hai bài gần nhất bạn đạt trung bình {avg} điểm nên bài này dễ hơn một bậc."
    return d, None


def plan_next(req: PathRequest, pool: "Pool") -> Plan:
    ranked = rank_sounds(req)
    focus = ranked[0].id
    difficulty, note = pick_difficulty(req)
    reason = f"Bài này luyện {sym(focus)} vì " + "; ".join(ranked[0].evidence[:2]) + "."
    if note:
        reason += " " + note
    return Plan(focus, pick_contrast(focus, ranked, pool), difficulty, reason, ranked)


def pick_contrast(focus: str, ranked: Sequence[Candidate], pool: "Pool") -> Optional[str]:
    options = CONFUSABLE.get(focus, [])
    need = {c.id: c.need for c in ranked}
    with_pairs = [c for c in options if pool.pairs_with(focus, c)]
    if with_pairs:
        return max(with_pairs, key=lambda c: need.get(c, 0))
    return options[0] if options else None


# --- Material ---

def minimal_pair(lexicon: Lexicon, a: str, b: str) -> Optional[Dict]:
    """Two words whose pronunciations differ by one sound (or one sound added, e.g. bike / buy)."""
    try:
        pas, pbs = lexicon.pronunciations(a), lexicon.pronunciations(b)
    except UnknownWordError:
        return None
    found = []
    for pa in pas:
        for pb in pbs:
            ia, ib = ids(pa), ids(pb)
            if len(ia) == len(ib):
                diff = [i for i in range(len(ia)) if ia[i] != ib[i]]
                if len(diff) == 1:
                    found.append({"a": word_dict(pa), "b": word_dict(pb), "contrast": [ia[diff[0]], ib[diff[0]]]})
            elif abs(len(ia) - len(ib)) == 1:
                longer, shorter = (ia, ib) if len(ia) > len(ib) else (ib, ia)
                if any(longer[:i] + longer[i + 1:] == shorter for i in range(len(longer))):
                    extra = next(longer[i] for i in range(len(longer)) if longer[:i] + longer[i + 1:] == shorter)
                    found.append({"a": word_dict(pa), "b": word_dict(pb), "contrast": [extra]})
    # live / leave also align as /laɪv/ - /liːv/; prefer the reading that pairs commonly confused sounds.
    found.sort(key=lambda p: not (len(p["contrast"]) == 2 and p["contrast"][1] in CONFUSABLE.get(p["contrast"][0], [])))
    return found[0] if found else None


def sentence_dict(text: str, prons: Sequence[WordPron], meaning: str = "") -> Dict:
    links = connected_speech.find_links(list(prons))
    return {
        "text": text,
        "ipa": " ".join(w.ipa for w in prons),
        "connected_ipa": connected_speech.connected_transcription(list(prons), links),
        "links": [{"display": l.display, "type": l.type, "hint": l.hint} for l in links],
        "intonation": expected_intonation(text),
        "meaning_vi": meaning,
    }


class Pool:
    """path_pool checked against one lexicon."""

    def __init__(self, lexicon: Lexicon):
        self.lexicon = lexicon
        self.meanings: Dict[str, str] = {}
        for rows in vocab.SEED.values():
            for word, _pos, meaning, *_ in rows:
                if " " not in word:
                    self.meanings[word.lower()] = meaning
        self.words: Dict[str, WordPron] = {}
        for w in list(dict.fromkeys(COMMON_WORDS + sorted(self.meanings))):
            try:
                self.words[w] = lexicon.lookup(w)
            except UnknownWordError:
                pass
        self.sentences: List[Tuple[str, str, List[WordPron]]] = []
        for text, meaning in SENTENCES:
            try:
                self.sentences.append((text, meaning, lexicon.sentence(text)))
            except (UnknownWordError, ValueError):
                pass
        self.pairs: List[Dict] = [p for a, b in PAIRS if (p := minimal_pair(lexicon, a, b))]

    def pairs_with(self, focus: str, contrast: Optional[str] = None) -> List[Dict]:
        return [p for p in self.pairs
                if focus in p["contrast"] and (contrast is None or contrast in p["contrast"] or len(p["contrast"]) == 1)]

    def words_for(self, focus: str, difficulty: int, avoid: set, rng: random.Random, n: int) -> List[Dict]:
        """Words containing the sound, mixing initial, middle and final positions."""
        def candidates(skip: set, max_syll: int) -> List[WordPron]:
            return [p for w, p in self.words.items()
                    if focus in ids(p) and w not in skip and syllables(p) <= max_syll]

        found = candidates(avoid, MAX_SYLLABLES[difficulty])
        if len(found) < n:
            found = candidates(set(), MAX_SYLLABLES[difficulty])
        if len(found) < n:
            found = candidates(set(), 9)
        rng.shuffle(found)
        if difficulty >= 2:
            found.sort(key=lambda p: syllables(p) < 2)
        groups: Dict[str, List[WordPron]] = {"start": [], "middle": [], "end": []}
        for p in found:
            i = ids(p).index(focus)
            groups["start" if i == 0 else "end" if i == len(p.phones) - 1 else "middle"].append(p)
        picked: List[WordPron] = []
        while len(picked) < n and any(groups.values()):
            for g in groups.values():
                if g and len(picked) < n:
                    picked.append(g.pop(0))
        return [word_dict(p, self.meanings.get(p.word, "")) for p in picked]

    def pairs_for(self, focus: str, contrast: Optional[str], rng: random.Random, n: int) -> List[Dict]:
        exact = self.pairs_with(focus, contrast) if contrast else []
        near = [p for c in CONFUSABLE.get(focus, []) for p in self.pairs_with(focus, c) if p not in exact]
        rest = [p for p in self.pairs_with(focus) if p not in exact and p not in near]
        out: List[Dict] = []
        for group in (exact, near, rest):
            group = group[:]
            rng.shuffle(group)
            out += group[: n - len(out)]
        return out

    def sentences_for(self, focus: str, difficulty: int, rng: random.Random, n: int) -> List[Dict]:
        found = [(t, m, p) for t, m, p in self.sentences if any(focus in ids(w) for w in p)]
        fitting = [s for s in found if len(s[2]) <= MAX_SENTENCE_WORDS[difficulty]] or found
        rng.shuffle(fitting)
        fitting.sort(key=lambda s: -sum(ids(w).count(focus) for w in s[2]))
        return [sentence_dict(t, p, m) for t, m, p in fitting[:n]]


@lru_cache(maxsize=4)
def pool_for(lexicon: Lexicon) -> Pool:
    return Pool(lexicon)


# --- Lessons ---

def rules_lesson(pool: Pool, req: PathRequest, plan: Plan) -> Dict:
    rng = random.Random(f"{req.next_index}:{plan.focus}")
    avoid = {w.lower() for w in req.recent_words}
    title = f"Âm {sym(plan.focus)}" + (f" và {sym(plan.contrast)}" if plan.contrast else "")
    lesson = {
        "index": req.next_index,
        "title": title,
        "focus": plan.focus,
        "contrast": plan.contrast,
        "difficulty": plan.difficulty,
        "reason_vi": plan.reason,
        "tip_vi": None,
        "words": pool.words_for(plan.focus, plan.difficulty, avoid, rng, 5),
        "pairs": pool.pairs_for(plan.focus, plan.contrast, rng, 3),
        "sentences": pool.sentences_for(plan.focus, plan.difficulty, rng, 3),
        "source": "rules",
    }
    lesson["exercises"] = lesson_exercises(pool, lesson, rng)
    return lesson


def lesson_exercises(pool: Pool, lesson: Dict, rng: random.Random, found: Optional[Dict] = None,
                     used: Optional[set] = None) -> List[Dict]:
    """The lesson's pairs as listening questions, plus spelling and gap questions (the LLM's, topped up offline)."""
    focus = lesson["focus"]
    found = found or {}
    used = set(used or ()) | {p[k]["word"] for p in lesson["pairs"] for k in ("a", "b")}
    spelling = list(found.get("spelling", []))
    if len(spelling) < 2:
        spelling += exercises.rules_spelling(pool.lexicon, pool.words, focus, rng, 2 - len(spelling), used)
    return exercises.interleave(exercises.pairs_as_exercises(lesson["pairs"], focus, rng),
                                spelling[:2], found.get("gaps", [])[:2])


PATH_PROMPT = (
    "Bạn là giáo viên phát âm tiếng Anh giọng Mỹ, soạn một lộ trình không có điểm kết thúc cho một người Việt "
    "đi làm. Mỗi lần bạn soạn MỘT bài tiếp theo, cá nhân hoá theo dữ liệu người học. "
    "Chọn 'focus' trong danh sách 'candidates' (đã xếp theo mức cần luyện, kèm bằng chứng). Thường chọn ứng viên "
    "đầu; chỉ chọn ứng viên khác khi có lý do rõ (ví dụ âm đó vừa luyện liên tiếp mà điểm đã tốt). "
    "'contrast' là một âm dễ nhầm với focus (lấy trong 'confusable' của ứng viên), hoặc null. "
    "Nội dung theo các chủ đề người học quan tâm và đúng độ khó yêu cầu. Quy tắc: "
    "'words' là 6 từ tiếng Anh đơn, thông dụng, viết thường, mỗi từ chứa âm focus, không trùng 'avoid_words'; "
    "'pairs' là 3 cặp từ tối thiểu chỉ khác nhau đúng một âm (focus và contrast); "
    "'sentences' là 3 câu tự nhiên, chứa âm focus nhiều lần, không có tên riêng, không có chữ số. "
    "'reason_vi' giải thích ngắn bằng tiếng Việt vì sao bài này phù hợp với người học lúc này, dựa trên bằng chứng. "
    "'tip_vi' là một mẹo phát âm cụ thể cho focus (vị trí lưỡi, môi, hơi). "
    "Ngoài ra soạn 2 'gaps' và 2 'spelling' cho âm focus theo quy tắc sau. " + exercises.RULES_VI + " "
    'Trả về JSON: {"focus": "TH", "contrast": "S", "title_vi": "...", "reason_vi": "...", "tip_vi": "...", '
    '"words": [{"word": "...", "meaning_vi": "..."}], "pairs": [{"a": "...", "b": "..."}], '
    '"sentences": [{"text": "...", "meaning_vi": "..."}], '
    '"gaps": [{"sentence": "...", "target": "...", "distractor": "...", "meaning_vi": "...", "topic": "..."}], '
    '"spelling": [{"words": ["...", "...", "..."], "note_vi": "...", "topic": "..."}]}'
)


def _text(value, limit: int) -> str:
    return str(value or "").strip()[:limit]


def llm_lesson(client: LLMClient, pool: Pool, req: PathRequest, plan: Plan) -> Dict:
    candidates = plan.ranked[:6]
    payload = {
        "learner": {"level": vocab.LEVELS.get(req.level, req.level),
                    "topics": [vocab.TOPIC_TITLES.get(t, t) for t in req.topics],
                    "topic_ids": req.topics},
        "angles": exercises.angles_for(req.topics, random.Random(req.next_index)),
        "lesson_number": req.next_index,
        "difficulty": DIFFICULTY_TEXT[plan.difficulty],
        "candidates": [{"sound": c.id, "ipa": PHONE_IPA[c.id], "need": c.need, "evidence": c.evidence,
                        "confusable": [{"sound": x, "ipa": PHONE_IPA[x]} for x in CONFUSABLE.get(c.id, [])]}
                       for c in candidates],
        "suggested": {"focus": plan.focus, "contrast": plan.contrast},
        "recent_lessons": [{"focus": r.focus, "contrast": r.contrast, "score": r.score} for r in req.history[-8:]],
        "skills": req.skills,
        "avoid_words": req.recent_words[-80:],
    }
    data = client.chat_json(PATH_PROMPT, json.dumps(payload, ensure_ascii=False))
    if not isinstance(data, dict):
        raise ValueError("LLM did not return an object")

    lexicon = pool.lexicon
    focus = data.get("focus") if data.get("focus") in {c.id for c in candidates} else plan.focus
    contrast = data.get("contrast")
    if contrast not in PHONE_IPA or contrast == focus:
        contrast = plan.contrast if focus == plan.focus else pick_contrast(focus, plan.ranked, pool)
    avoid = {w.lower() for w in req.recent_words}

    words: List[Dict] = []
    for item in data.get("words") or []:
        word = _text(item.get("word") if isinstance(item, dict) else item, 20).lower()
        if not WORD_RE.fullmatch(word) or word in avoid or any(w["word"] == word for w in words):
            continue
        try:
            pron = lexicon.lookup(word)
        except UnknownWordError:
            continue
        if focus in ids(pron):     # the first reading is the one the scorer expects
            words.append(word_dict(pron, _text(item.get("meaning_vi") if isinstance(item, dict) else "", 80)))

    pairs: List[Dict] = []
    for item in data.get("pairs") or []:
        if not isinstance(item, dict):
            continue
        a, b = _text(item.get("a"), 20).lower(), _text(item.get("b"), 20).lower()
        pair = minimal_pair(lexicon, a, b) if WORD_RE.fullmatch(a) and WORD_RE.fullmatch(b) else None
        if pair and focus in pair["contrast"] and all({pair["a"]["word"], pair["b"]["word"]} != {p["a"]["word"], p["b"]["word"]} for p in pairs):
            pairs.append(pair)

    sentences: List[Dict] = []
    for item in data.get("sentences") or []:
        if not isinstance(item, dict):
            continue
        text = " ".join(_text(item.get("text"), 120).split())
        if not SENTENCE_RE.fullmatch(text):
            continue
        try:
            prons = lexicon.sentence(text)
        except (UnknownWordError, ValueError):
            continue
        if any(focus in ids(w) for w in prons) and len(prons) <= MAX_SENTENCE_WORDS[plan.difficulty] + 2:
            sentences.append(sentence_dict(text, prons, _text(item.get("meaning_vi"), 160)))

    rng = random.Random(f"{req.next_index}:{focus}")
    if len(words) < 4:
        taken = avoid | {w["word"] for w in words}
        words += pool.words_for(focus, plan.difficulty, taken, rng, 5 - len(words))
    if len(pairs) < 2:
        pairs += [p for p in pool.pairs_for(focus, contrast, rng, 3) if p not in pairs][: 3 - len(pairs)]
    if len(sentences) < 2:
        known = {s["text"] for s in sentences}
        sentences += [s for s in pool.sentences_for(focus, plan.difficulty, rng, 3) if s["text"] not in known][: 3 - len(sentences)]

    fallback_title = f"Âm {sym(focus)}" + (f" và {sym(contrast)}" if contrast else "")
    reason = _text(data.get("reason_vi"), 300)
    if not reason:
        reason = plan.reason if focus == plan.focus else f"Bài này luyện {sym(focus)}."
    lesson = {
        "index": req.next_index,
        "title": exercises.with_symbols(_text(data.get("title_vi"), 60), [focus, contrast] if contrast else [focus])
                 or fallback_title,
        "focus": focus,
        "contrast": contrast,
        "difficulty": plan.difficulty,
        "reason_vi": reason,
        "tip_vi": _text(data.get("tip_vi"), 300) or None,
        "words": words[:6],
        "pairs": pairs[:3],
        "sentences": sentences[:3],
        "source": "llm",
    }
    checker = exercises.Checker(lexicon, [focus], rng, req.topics, (), MAX_SENTENCE_WORDS[plan.difficulty])
    checker.take(*(p[k]["word"] for p in lesson["pairs"] for k in ("a", "b")))
    found = {"gaps": [g for g in map(checker.gap, exercises.items(data.get("gaps"))) if g],
             "spelling": [q for q in map(checker.spelling, exercises.items(data.get("spelling"))) if q]}
    lesson["exercises"] = lesson_exercises(pool, lesson, rng, found, checker.used)
    return lesson


def next_lesson(client: Optional[LLMClient], lexicon: Lexicon, req: PathRequest) -> Dict:
    pool = pool_for(lexicon)
    plan = plan_next(req, pool)
    if client is not None:
        try:
            return llm_lesson(client, pool, req, plan)
        except Exception:
            log.exception("LLM path lesson failed; building it from the offline pool")
    return rules_lesson(pool, req, plan)
