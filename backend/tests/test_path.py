import json
import random

import pytest
from fastapi.testclient import TestClient

from app import main, path, path_pool
from app.phonetics import PHONE_IPA, Lexicon


@pytest.fixture(scope="module")
def lex():
    return Lexicon()


@pytest.fixture(scope="module")
def pool(lex):
    return path.pool_for(lex)


def req(**kw):
    return path.PathRequest(**kw)


def first_reading(lex, word):
    return [p.id for p in lex.lookup(word).phones]


def test_offline_pool_is_fully_valid(lex, pool):
    assert all(w in pool.words for w in path_pool.COMMON_WORDS)
    assert len(pool.sentences) == len(path_pool.SENTENCES)
    assert [p for p in path_pool.PAIRS if path.minimal_pair(lex, *p) is None] == []
    for pid in PHONE_IPA:
        assert sum(pid in path.ids(p) for p in pool.words.values()) >= 10, pid
        assert any(any(pid in path.ids(w) for w in s[2]) for s in pool.sentences), pid
    assert set(path_pool.L1_PRIOR) == set(PHONE_IPA) == set(path_pool.CONFUSABLE)


def test_minimal_pair_prefers_the_commonly_confused_reading(lex):
    assert path.minimal_pair(lex, "leave", "live")["contrast"] == ["IY", "IH"]
    assert path.minimal_pair(lex, "bike", "buy")["contrast"] == ["K"]
    assert path.minimal_pair(lex, "cat", "dog") is None


def test_without_scores_the_l1_prior_decides(pool):
    plan = path.plan_next(req(level="beginner"), pool)
    assert plan.focus == "TH" and plan.contrast in path_pool.CONFUSABLE["TH"]
    assert plan.difficulty == 1
    assert "người Việt" in plan.reason


def test_own_scores_outweigh_the_prior(pool):
    sounds = [{"id": "TH", "speak": 95, "takes": 10}, {"id": "DH", "speak": 92, "takes": 8},
              {"id": "R", "speak": 41, "takes": 12}]
    plan = path.plan_next(req(sounds=sounds), pool)
    assert plan.focus == "R"
    assert "41/100" in plan.reason


def test_listening_mistakes_count(pool):
    sounds = [{"id": s, "speak": 90, "takes": 6} for s in ("TH", "DH", "ZH", "Z", "R")]
    sounds.append({"id": "IH", "heard_right": 1, "heard_wrong": 5})
    plan = path.plan_next(req(sounds=sounds), pool)
    assert plan.focus == "IH" and "5/6" in plan.reason


def test_a_weak_lesson_is_repeated_once_then_the_path_moves_on(pool):
    weak = [{"index": 1, "focus": "TH", "score": 55}]
    assert path.plan_next(req(history=weak), pool).focus == "TH"
    twice = weak + [{"index": 2, "focus": "TH", "score": 58}]
    assert path.plan_next(req(history=twice), pool).focus != "TH"
    good = [{"index": 1, "focus": "TH", "score": 92}]
    assert path.plan_next(req(history=good), pool).focus != "TH"


def test_difficulty_follows_results(pool):
    up = [{"index": 1, "focus": "R", "difficulty": 2, "score": 90}, {"index": 2, "focus": "L", "difficulty": 2, "score": 88}]
    down = [{"index": 1, "focus": "R", "difficulty": 2, "score": 50}, {"index": 2, "focus": "L", "difficulty": 2, "score": 55}]
    assert path.plan_next(req(history=up), pool).difficulty == 3
    assert path.plan_next(req(history=down), pool).difficulty == 1
    assert "khó hơn" in path.plan_next(req(history=up), pool).reason


def test_rules_lesson_content_matches_the_scorer(lex, pool):
    lesson = path.next_lesson(None, lex, req(next_index=4, recent_words=["think", "three"]))
    focus = lesson["focus"]
    assert lesson["source"] == "rules" and lesson["index"] == 4
    assert len(lesson["words"]) == 5
    for w in lesson["words"]:
        assert focus in first_reading(lex, w["word"]) and w["word"] not in ("think", "three")
    assert lesson["pairs"] and all(focus in p["contrast"] for p in lesson["pairs"])
    assert lesson["sentences"]
    for s in lesson["sentences"]:
        assert any(focus in [p.id for p in w.phones] for w in lex.sentence(s["text"]))
        assert s["intonation"] in ("rising", "falling") and s["meaning_vi"]


def test_the_path_never_ends_and_varies(lex):
    """Simulate the app: each finished lesson adds speaking scores for its sound."""
    rng = random.Random(3)
    history, words, focuses, scores = [], [], [], {}
    for i in range(1, 41):
        sounds = [{"id": s, "speak": sum(v[-20:]) / len(v[-20:]), "takes": len(v)} for s, v in scores.items()]
        lesson = path.next_lesson(None, lex, req(level="intermediate", next_index=i, history=history[-10:],
                                                  sounds=sounds, recent_words=words[-60:]))
        assert len(lesson["words"]) >= 4 and lesson["sentences"], lesson
        focuses.append(lesson["focus"])
        words += [w["word"] for w in lesson["words"]]
        score = rng.randint(50, 95)
        scores.setdefault(lesson["focus"], []).extend([score] * 6)
        history.append({"index": i, "focus": lesson["focus"], "contrast": lesson["contrast"],
                        "difficulty": lesson["difficulty"], "score": score})
    assert len(set(focuses)) >= 12
    assert not any(a == b == c for a, b, c in zip(focuses, focuses[1:], focuses[2:]))
    assert max(focuses.count(f) for f in set(focuses)) <= 8


class FakeLLM:
    def __init__(self, payload=None, error=None):
        self.payload, self.error, self.calls = payload, error, []

    def chat_json(self, system, user, images=()):
        self.calls.append((system, user))
        if self.error:
            raise self.error
        return self.payload


def test_llm_lesson_is_validated_and_topped_up(lex):
    llm = FakeLLM({
        "focus": "R", "contrast": "L", "title_vi": "R trong họp hành", "reason_vi": "Điểm /r/ thấp nhất.",
        "tip_vi": "Cong lưỡi, không chạm vòm.",
        "words": [{"word": "report", "meaning_vi": "báo cáo"}, {"word": "xqzt"}, {"word": "meeting"},
                  {"word": "Project!"}, {"word": "review", "meaning_vi": "xem lại"}],
        "pairs": [{"a": "right", "b": "light"}, {"a": "cat", "b": "dog"}, {"a": "right", "b": "light"}],
        "sentences": [{"text": "Please review the report for Friday.", "meaning_vi": "Xem lại báo cáo nhé."},
                      {"text": "We have 3 reports.", "meaning_vi": "x"}],
    })
    sounds = [{"id": "R", "speak": 40, "takes": 10}]
    lesson = path.next_lesson(llm, lex, req(sounds=sounds, topics=["meetings"], next_index=9))
    assert lesson["source"] == "llm" and lesson["focus"] == "R" and lesson["contrast"] == "L"
    words = [w["word"] for w in lesson["words"]]
    assert words[:2] == ["report", "review"] and "meeting" not in words and len(words) >= 4
    assert all("R" in first_reading(lex, w) for w in words)
    assert lesson["pairs"][0]["contrast"] == ["R", "L"] and len(lesson["pairs"]) >= 2
    assert lesson["sentences"][0]["text"] == "Please review the report for Friday."
    assert all("3" not in s["text"] for s in lesson["sentences"])
    assert lesson["title"] == "/r/ trong họp hành" and lesson["tip_vi"]
    sent = json.loads(llm.calls[0][1])
    assert sent["candidates"][0]["sound"] == "R" and "41" not in sent["candidates"][0]["evidence"][0]
    assert "Họp hành" in sent["learner"]["topics"]


def test_llm_cannot_pick_a_sound_outside_the_candidates(lex):
    llm = FakeLLM({"focus": "M", "words": [], "pairs": [], "sentences": []})
    lesson = path.next_lesson(llm, lex, req())
    assert lesson["focus"] == "TH" and len(lesson["words"]) >= 4 and lesson["sentences"]


def test_llm_failure_falls_back_to_rules(lex):
    lesson = path.next_lesson(FakeLLM(error=TimeoutError()), lex, req())
    assert lesson["source"] == "rules"


def test_path_endpoint(monkeypatch, lex):
    monkeypatch.setattr(main, "get_llm", lambda: None)
    monkeypatch.setattr(main, "get_lexicon", lambda: lex)
    body = {"level": "advanced", "topics": ["work"], "next_index": 12,
            "sounds": [{"id": "Z", "speak": 35.5, "takes": 9, "heard_right": 2, "heard_wrong": 1, "learned": True}],
            "skills": {"pronunciation": 70}, "history": [{"index": 11, "focus": "TH", "difficulty": 3, "score": 80}],
            "recent_words": ["zoo"]}
    resp = TestClient(main.app).post("/v1/path/next", json=body)
    assert resp.status_code == 200, resp.text
    lesson = resp.json()
    assert lesson["index"] == 12 and lesson["focus"] == "Z" and lesson["difficulty"] == 3
    assert {"word", "ipa", "phones", "meaning_vi"} <= set(lesson["words"][0])
    assert {"text", "ipa", "connected_ipa", "links", "intonation", "meaning_vi"} <= set(lesson["sentences"][0])
