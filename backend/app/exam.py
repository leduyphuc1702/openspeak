"""Checkpoint exams on the personal path: after every few lessons, a test of the
sounds the learner has just practised plus the one they need most.

The LLM writes listening questions, words and sentences for the learner's own
topics. Variety is enforced by the server rather than hoped for: no keyword
appears twice in one exam or in the learner's recent lessons and exams, items
are spread round-robin over the chosen topics, and each topic gets a different
angle every exam. Everything is re-checked against the lexicon and topped up
from the offline pool, so an exam is always complete.
"""
from __future__ import annotations

import json
import logging
import random
from collections import Counter
from typing import Dict, List, Optional, Sequence

from pydantic import Field

from . import exercises, vocab
from .llm import LLMClient
from .path import (DIFFICULTY_TEXT, MAX_SENTENCE_WORDS, SENTENCE_RE, PathRequest, Pool, ids, pick_contrast,
                   pick_difficulty, pool_for, rank_sounds, sentence_dict, sym, word_dict)
from .phonetics import PHONE_IPA, Lexicon, UnknownWordError

log = logging.getLogger("openspeak.exam")

LESSONS_PER_EXAM = 4
MAX_SOUNDS = 4
WORDS = 6
SENTENCES = 3


class ExamRequest(PathRequest):
    exam_index: int = Field(1, ge=1)


def exam_sounds(req: PathRequest) -> List[str]:
    """The sounds of the lessons since the last exam, then the most needed ones, up to MAX_SOUNDS."""
    out: List[str] = []
    for r in reversed(req.history[-LESSONS_PER_EXAM:]):
        if r.focus in PHONE_IPA and r.focus not in out:
            out.append(r.focus)
    for c in rank_sounds(req):
        if len(out) >= MAX_SOUNDS or (len(out) >= 3 and req.history):
            break
        if c.id not in out:
            out.append(c.id)
    return out[:MAX_SOUNDS]


def balanced(items: Sequence[Dict], n: int, topics: Sequence[str]) -> List[Dict]:
    """Up to n items, taking topics in turn so no topic crowds out the others."""
    queues = {t: [i for i in items if i.get("topic") == t] for t in topics}
    untagged = [i for i in items if i.get("topic") not in queues]
    out: List[Dict] = []
    while len(out) < n and (any(queues.values()) or untagged):
        for t in topics:
            if queues[t] and len(out) < n:
                out.append(queues[t].pop(0))
        if untagged and len(out) < n and not any(queues.values()):
            out.append(untagged.pop(0))
    return out


def covering(items: Sequence[Dict], n: int, sounds: Sequence[str], topics: Sequence[str]) -> List[Dict]:
    """Up to n items: one per sound first (sounds in the order given), each from the least-used topic, then
    the rest topic by topic."""
    out: List[Dict] = []
    used = Counter()
    for sound in sounds:
        mine = [i for i in items if i.get("sound") == sound and i not in out]
        if mine and len(out) < n:
            pick = min(mine, key=lambda i: used[i.get("topic")])
            out.append(pick)
            used[pick.get("topic")] += 1
    return out + balanced([i for i in items if i not in out], n - len(out), topics)


PROMPT = (
    "Bạn là giáo viên phát âm tiếng Anh giọng Mỹ, ra một BÀI KIỂM TRA giữa lộ trình cho một người Việt đi làm. "
    "Bài kiểm tra các âm trong 'sounds' (âm vừa học và âm người học cần nhất), theo đúng độ khó. "
    "Mọi từ và câu xoay quanh các chủ đề của người học, rải đều các chủ đề, mỗi câu ghi 'topic' là id chủ đề. "
    "Đa dạng từ khoá: không lặp từ khoá giữa các câu hỏi, không dùng từ trong 'avoid_words', đi theo 'angles' "
    "của từng chủ đề. Mỗi câu ghi 'sound' là id âm được kiểm tra. "
    "'words': 8 từ đơn để người học nói, mỗi từ chứa âm của nó (nếu là nguyên âm thì ở âm tiết có trọng âm); "
    "'sentences': 4 câu tự nhiên để đọc, không tên riêng, không chữ số. "
    "Câu hỏi nghe và chính tả theo quy tắc sau. " + exercises.RULES_VI +
    " Soạn 1 'pairs' cho mỗi âm, 3 'gaps', 3 'spelling'. "
    "'title_vi' là tên ngắn cho bài kiểm tra, ghi âm bằng ký hiệu IPA (/θ/), không ghi id âm (TH). "
    'Trả về JSON: {"title_vi": "...", '
    '"words": [{"sound": "R", "word": "...", "meaning_vi": "...", "topic": "..."}], '
    '"sentences": [{"sound": "R", "text": "...", "meaning_vi": "...", "topic": "..."}], '
    '"pairs": [{"sound": "R", "a": "...", "b": "...", "topic": "..."}], '
    '"gaps": [{"sound": "R", "sentence": "...", "target": "...", "distractor": "...", "meaning_vi": "...", "topic": "..."}], '
    '"spelling": [{"sound": "R", "words": ["...", "...", "...", "..."], "note_vi": "...", "topic": "..."}]}'
)


def _word_item(lexicon: Lexicon, checker: exercises.Checker, item) -> Optional[Dict]:
    if not isinstance(item, dict) or not (sound := checker.sound(item)):
        return None
    word = exercises._word(item.get("word"))
    if not exercises.WORD_RE.fullmatch(word) or not checker.fresh(word):
        return None
    try:
        pron = lexicon.lookup(word)
    except UnknownWordError:
        return None
    if not exercises.has_sound(pron.phones, sound):
        return None
    checker.take(word)
    return {**word_dict(pron, exercises._text(item.get("meaning_vi"), 80)), "sound": sound,
            "topic": checker.topic(item)}


def _sentence_item(lexicon: Lexicon, checker: exercises.Checker, item, max_words: int, seen: set) -> Optional[Dict]:
    if not isinstance(item, dict) or not (sound := checker.sound(item)):
        return None
    text = " ".join(exercises._text(item.get("text"), 120).split())
    if not SENTENCE_RE.fullmatch(text) or text.lower() in seen:
        return None
    try:
        prons = lexicon.sentence(text)
    except (UnknownWordError, ValueError):
        return None
    if not any(sound in ids(w) for w in prons) or len(prons) > max_words + 2:
        return None
    seen.add(text.lower())
    return {**sentence_dict(text, prons, exercises._text(item.get("meaning_vi"), 160)), "sound": sound,
            "topic": checker.topic(item)}


def topic_words(pool: Pool, topics: Sequence[str]) -> Dict[str, str]:
    """Single words from the offline vocabulary of the learner's topics, so even an offline exam is on topic."""
    out: Dict[str, str] = {}
    for t in topics:
        for word, *_ in vocab.SEED.get(t, []):
            if word.lower() in pool.words:
                out.setdefault(word.lower(), t)
    return out


def top_up(pool: Pool, sounds: Sequence[str], topics: Sequence[str], difficulty: int, checker: exercises.Checker,
           found: Dict[str, List[Dict]], rng: random.Random, contrasts: Dict[str, Optional[str]]) -> None:
    lexicon = pool.lexicon
    # Words: on-topic ones first, then the general pool; every sound gets at least one.
    on_topic = topic_words(pool, topics)
    have = Counter(w["sound"] for w in found["words"])
    # First pass: every sound gets one word; second: share out the rest.
    for sound, target in [(s, 1) for s in sounds] + [(s, -(-WORDS // len(sounds))) for s in sounds]:
        while have[sound] < target and len(found["words"]) < WORDS:
            options = [w for w, t in on_topic.items()
                       if checker.fresh(w) and exercises.has_sound(pool.words[w].phones, sound)]
            if options:
                word = rng.choice(options)
                found["words"].append({**word_dict(pool.words[word], pool.meanings.get(word, "")),
                                       "sound": sound, "topic": on_topic[word]})
            else:
                taken = checker.used | checker.avoid
                picked = pool.words_for(sound, difficulty, taken, rng, 1)
                if not picked or picked[0]["word"] in checker.used:
                    break
                word = picked[0]["word"]
                found["words"].append({**picked[0], "sound": sound, "topic": None})
            checker.take(word)
            have[sound] += 1
    # Sentences.
    seen = {s["text"] for s in found["sentences"]}
    for sound in sounds:
        if len(found["sentences"]) >= SENTENCES:
            break
        if any(s["sound"] == sound for s in found["sentences"]):
            continue
        for s in pool.sentences_for(sound, difficulty, rng, 3):
            if s["text"] not in seen:
                found["sentences"].append({**s, "sound": sound, "topic": None})
                seen.add(s["text"])
                break
    # One minimal pair per sound, then spelling traps.
    paired = {e["sound"] for e in found["pairs"]}
    for sound in sounds:
        if sound in paired:
            continue
        for p in pool.pairs_for(sound, contrasts.get(sound), rng, 4):
            if checker.fresh(p["a"]["word"], p["b"]["word"], recent=False):
                checker.take(p["a"]["word"], p["b"]["word"])
                found["pairs"] += exercises.pairs_as_exercises([p], sound, rng)
                break
    for sound in sounds:
        if len(found["spelling"]) >= 2:
            break
        if not any(e["sound"] == sound for e in found["spelling"]):
            found["spelling"] += exercises.rules_spelling(lexicon, pool.words, sound, rng, 1, checker.used)


def next_exam(client: Optional[LLMClient], lexicon: Lexicon, req: ExamRequest) -> Dict:
    pool = pool_for(lexicon)
    rng = random.Random(f"exam:{req.exam_index}:{req.next_index}")
    sounds = exam_sounds(req)
    ranked = rank_sounds(req)
    contrasts = {s: pick_contrast(s, ranked, pool) for s in sounds}
    order = [c.id for c in ranked]
    # There are fewer sentences than sounds, so the weakest sounds get theirs first.
    by_need = sorted(sounds, key=lambda s: order.index(s) if s in order else len(order))
    difficulty, _ = pick_difficulty(req)
    topics = [t for t in req.topics if t in vocab.TOPIC_TITLES] or ["daily"]
    angles = exercises.angles_for(topics, rng)
    checker = exercises.Checker(lexicon, sounds, rng, topics, req.recent_words[-150:], MAX_SENTENCE_WORDS[difficulty])
    found: Dict[str, List[Dict]] = {"words": [], "sentences": [], "pairs": [], "gaps": [], "spelling": []}
    source, title = "rules", ""
    if client is not None:
        payload = {
            "sounds": [{"id": s, "ipa": PHONE_IPA[s], "contrast": contrasts[s],
                        "contrast_ipa": PHONE_IPA.get(contrasts[s] or "", None)} for s in sounds],
            "learner": {"level": vocab.LEVELS.get(req.level, req.level),
                        "topics": [{"id": t, "title": vocab.TOPIC_TITLES[t]} for t in topics]},
            "difficulty": DIFFICULTY_TEXT[difficulty],
            "angles": angles,
            "exam_number": req.exam_index,
            "avoid_words": req.recent_words[-150:],
        }
        try:
            data = client.chat_json(PROMPT, json.dumps(payload, ensure_ascii=False))
            if not isinstance(data, dict):
                raise ValueError("LLM did not return an object")
            title = exercises.with_symbols(exercises._text(data.get("title_vi"), 60), sounds)
            seen: set = set()
            found["words"] = [w for i in exercises.items(data.get("words")) if (w := _word_item(lexicon, checker, i))]
            found["sentences"] = [s for i in exercises.items(data.get("sentences"))
                                  if (s := _sentence_item(lexicon, checker, i, MAX_SENTENCE_WORDS[difficulty], seen))]
            found.update(checker.collect(data))
            found["words"] = covering(found["words"], WORDS, by_need, topics)
            found["sentences"] = covering(found["sentences"], SENTENCES, by_need, topics)
            source = "llm" if found["words"] or found["sentences"] or any(found[k] for k in ("pairs", "gaps", "spelling")) else "rules"
        except Exception:
            log.exception("LLM exam failed; building it from the offline pool")
            checker.used.clear()
            found = {k: [] for k in found}
    top_up(pool, by_need, topics, difficulty, checker, found, rng, contrasts)

    pairs = balanced(found["pairs"], len(sounds), topics)
    # Transcriptions to build from the exam's own words, one sound each, weakest sounds first.
    builder = exercises.Checker(lexicon, sounds, rng)
    builds = []
    for sound in by_need:
        candidates = [w["word"] for w in found["words"] if w["sound"] == sound]
        builds += exercises.builds_from(builder, candidates, sound, 1, contrasts.get(sound))
    listening = exercises.interleave(pairs, balanced(found["spelling"], 3, topics), builds[:2],
                                     balanced(found["gaps"], 3, topics))
    everything = found["words"] + found["sentences"] + listening
    covered = Counter(i["topic"] for i in everything if i.get("topic"))
    after = req.history[-1].index if req.history else 0
    return {
        "index": req.exam_index,
        "after_lesson": after,
        "title": title or "Kiểm tra " + ", ".join(sym(s) for s in sounds),
        "sounds": sounds,
        "difficulty": difficulty,
        "listening": listening,
        "words": found["words"][:WORDS],
        "sentences": found["sentences"][:SENTENCES],
        "topics": [{"id": t, "title": vocab.TOPIC_TITLES[t], "items": covered.get(t, 0)} for t in topics],
        "source": source,
    }
