"""The vocabulary programme: an endless sequence of short lessons, each one a
situation inside one of the learner's topics, written by the LLM for the
learner's level and what they already know.

Each word comes with a second sentence in a different situation from its
example. The app hides the word in that sentence and the learner types it,
so remembering a word means producing it in a new context rather than
recognising the card it was taught on. The server checks that the word really
occurs in the sentence and works out which form of it does (report, reports,
reported), since that form is the answer.

Without an LLM, lessons come from the starter words in vocab.SEED, with the
example sentence used for the gap.
"""
from __future__ import annotations

import json
import logging
import random
import re
from typing import Dict, List, Optional, Sequence

from pydantic import BaseModel, Field

from . import vocab
from .llm import LLMClient
from .phonetics import Lexicon

log = logging.getLogger("openspeak.vocab_path")

WORDS_PER_LESSON = 6
BLANK = "___"

# Situations inside a topic, rotated so consecutive lessons on the same topic differ.
SITUATIONS = [
    "mở đầu và chào hỏi", "hỏi và đưa thông tin", "gặp sự cố, xử lý vấn đề", "đề nghị, nhờ vả, xin phép",
    "so sánh và lựa chọn", "lên kế hoạch, hẹn giờ", "kể lại việc đã xảy ra", "nêu cảm nhận, nhận xét",
    "thương lượng, thoả thuận", "kết thúc, cảm ơn, hẹn gặp lại", "con số, giá cả, thời gian", "mô tả người, vật, nơi chốn",
]

PROMPT = (
    "Bạn soạn MỘT bài trong lộ trình từ vựng tiếng Anh (giọng Mỹ) cho một người Việt đi làm. "
    "Bài gồm đúng 6 từ hoặc cụm từ dùng trong tình huống 'situation' của chủ đề 'topic', đúng trình độ 'level'. "
    "Không dùng từ trong 'known' (người học đã học). 'weak' là các từ người học hay quên: chọn từ mới cùng trường "
    "nghĩa hoặc hay đi kèm với chúng để củng cố, nhưng không lặp lại chính các từ đó. "
    "Khoảng một phần ba là cụm từ/collocation hay gặp. Nghĩa tiếng Việt ngắn, đúng ngữ cảnh. "
    "'example_en' là câu ví dụ ngắn, tự nhiên trong tình huống. 'practice_en' là câu KHÁC, ở tình huống khác, "
    "dùng đúng từ đó (có thể chia thì/số nhiều) đúng một lần, sao cho người đọc nghĩa câu và 'practice_vi' "
    "đoán được phải điền từ nào. 'tip_vi' là mẹo nhớ hoặc mẹo phát âm ngắn (có thể rỗng). "
    "'title_vi' là tên ngắn của bài, 'goal_vi' là một câu nói người học sẽ làm được gì sau bài. "
    'Trả về JSON: {"title_vi": "...", "goal_vi": "...", "words": [{"word": "...", '
    '"pos": "noun|verb|adjective|adverb|phrase", "meaning_vi": "...", "example_en": "...", "example_vi": "...", '
    '"practice_en": "...", "practice_vi": "...", "tip_vi": "..."}]}'
)


class VocabPathRequest(BaseModel):
    level: str = "beginner"
    topics: List[str] = Field(default_factory=list)
    lesson_index: int = Field(1, ge=1)
    known: List[str] = Field(default_factory=list)
    weak: List[str] = Field(default_factory=list)


def forms(word: str) -> List[str]:
    """Forms of a word or phrase the gap may hold; for a phrase only its first word changes (follow / follows up)."""
    head, _, rest = word.lower().partition(" ")
    tail = f" {rest}" if rest else ""
    stems = {head, head + "s", head + "es", head + "ed", head + "d", head + "ing"}
    if head.endswith("e"):
        stems |= {head[:-1] + "ing", head[:-1] + "ed"}
    if head.endswith("y") and len(head) > 2:
        stems |= {head[:-1] + "ies", head[:-1] + "ied"}
    if re.fullmatch(r".*[^aeiou][aeiou][bdgmnpt]", head):
        stems |= {head + head[-1] + "ed", head + head[-1] + "ing"}
    return sorted({s + tail for s in stems}, key=len, reverse=True)


def cloze(sentence: str, word: str) -> Optional[Dict[str, str]]:
    """The sentence with the word hidden, and the exact form hidden; None unless it occurs exactly once."""
    hits = []
    for form in forms(word):
        hits += [m for m in re.finditer(rf"(?<![A-Za-z']){re.escape(form)}(?![A-Za-z'])", sentence, re.IGNORECASE)
                 if not any(m.start() < h.end() and h.start() < m.end() for h in hits)]
    if len(hits) != 1:
        return None
    m = hits[0]
    return {"text": sentence[:m.start()] + BLANK + sentence[m.end():], "answer": m.group(0).lower()}


def _text(value, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def with_practice(lexicon: Lexicon, items: Sequence[Dict], known: Sequence[str]) -> List[Dict]:
    """Words the scorer can pronounce, not already known, whose practice sentence (or example) hides them once."""
    known_lower = {k.lower() for k in known}
    raw = {str(i.get("word", "")).strip().lower(): i for i in items if isinstance(i, dict)}
    out = []
    for w in vocab.enrich(lexicon, [i for i in items if isinstance(i, dict)]):
        if w["word"].lower() in known_lower:
            continue
        item = raw.get(w["word"].lower(), {})
        practice, practice_vi = _text(item.get("practice_en"), 160), _text(item.get("practice_vi"), 200)
        gap = cloze(practice, w["word"]) if practice else None
        if gap is None or practice.lower() == w["example_en"].lower():
            practice, practice_vi = w["example_en"], w["example_vi"]
            gap = cloze(practice, w["word"])
        if gap is None:
            continue
        out.append({**w, "practice_en": practice, "practice_vi": practice_vi, "cloze_en": gap["text"],
                    "cloze_answer": gap["answer"]})
    return out


def plan(req: VocabPathRequest) -> Dict[str, str]:
    topics = [t for t in req.topics if t in vocab.TOPIC_TITLES] or ["daily", "work", "social"]
    topic = topics[(req.lesson_index - 1) % len(topics)]
    rng = random.Random(f"vocab:{req.lesson_index}:{topic}")
    return {"topic": topic, "situation": rng.choice(SITUATIONS)}


def seed_words(lexicon: Lexicon, topic: str, known: Sequence[str]) -> List[Dict]:
    keys = ("word", "pos", "meaning_vi", "example_en", "example_vi")
    return with_practice(lexicon, [dict(zip(keys, row)) for row in vocab.SEED.get(topic, [])], known)


def next_lesson(client: Optional[LLMClient], lexicon: Lexicon, req: VocabPathRequest) -> Dict:
    p = plan(req)
    topic, situation = p["topic"], p["situation"]
    title, goal, words, source = "", "", [], "seed"
    if client is not None:
        payload = {"topic": vocab.TOPIC_TITLES[topic], "situation": situation,
                   "level": vocab.LEVELS.get(req.level, req.level), "lesson_number": req.lesson_index,
                   "known": req.known[-300:], "weak": req.weak[-20:]}
        try:
            data = client.chat_json(PROMPT, json.dumps(payload, ensure_ascii=False))
            if isinstance(data, dict):
                words = with_practice(lexicon, data.get("words") if isinstance(data.get("words"), list) else [], req.known + req.weak)
                title, goal = _text(data.get("title_vi"), 60), _text(data.get("goal_vi"), 160)
                source = "llm" if len(words) >= 3 else "seed"
        except Exception:
            log.exception("LLM vocabulary lesson failed; using starter words")
    if source == "seed":
        # The learner's topics in turn, starting from this lesson's, until one still has unknown starter words.
        topics = [t for t in req.topics if t in vocab.SEED] or list(vocab.SEED)
        start = topics.index(topic) if topic in topics else 0
        for t in topics[start:] + topics[:start] + [t for t in vocab.SEED if t not in topics]:
            words = seed_words(lexicon, t, req.known)
            if words:
                topic = t
                break
        title, goal, situation = "", "", ""
    return {
        "index": req.lesson_index,
        "topic": topic,
        "topic_title": vocab.TOPIC_TITLES.get(topic, topic),
        "situation_vi": situation or None,
        "title": title or vocab.TOPIC_TITLES.get(topic, topic),
        "goal_vi": goal or None,
        "words": words[:WORDS_PER_LESSON],
        "source": source,
    }
