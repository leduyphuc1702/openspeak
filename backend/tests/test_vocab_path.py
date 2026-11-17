import json

import pytest
from fastapi.testclient import TestClient

from app import main, vocab_path
from app.phonetics import Lexicon


@pytest.fixture(scope="module")
def lex():
    return Lexicon()


class FakeLLM:
    def __init__(self, payload=None, error=None):
        self.payload, self.error, self.calls = payload, error, []

    def chat_json(self, system, user, images=()):
        self.calls.append((system, user))
        if self.error:
            raise self.error
        return self.payload


def test_cloze_finds_the_form_used_once():
    assert vocab_path.cloze("She reported the delay.", "report") == {"text": "She ___ the delay.", "answer": "reported"}
    assert vocab_path.cloze("We follow up every Friday.", "follow up")["answer"] == "follow up"
    assert vocab_path.cloze("He follows up quickly.", "follow up")["answer"] == "follows up"
    assert vocab_path.cloze("Plan the plans.", "plan") is None      # twice: which one is the gap?
    assert vocab_path.cloze("No match here.", "budget") is None
    assert vocab_path.cloze("We are planning it.", "plan")["answer"] == "planning"


def test_llm_lesson_is_checked(lex):
    words = [
        {"word": "deadline", "pos": "noun", "meaning_vi": "hạn chót", "example_en": "The deadline is Friday.",
         "example_vi": "Hạn chót là thứ Sáu.", "practice_en": "We missed two deadlines last month.", "practice_vi": "..."},
        {"word": "postpone", "pos": "verb", "meaning_vi": "hoãn", "example_en": "Let's postpone the call.",
         "example_vi": "Hoãn cuộc gọi nhé.", "practice_en": "The launch was postponed because of the rain.", "practice_vi": "..."},
        # The practice sentence does not contain the word: falls back to the example.
        {"word": "agenda", "pos": "noun", "meaning_vi": "chương trình họp", "example_en": "Here is the agenda.",
         "example_vi": "Đây là chương trình họp.", "practice_en": "Here is the plan.", "practice_vi": "..."},
        {"word": "colleague", "meaning_vi": "đồng nghiệp", "example_en": "My colleague is here.", "example_vi": "..."},
        {"word": "xqzt", "meaning_vi": "?", "example_en": "xqzt", "example_vi": "?"},
    ]
    llm = FakeLLM({"title_vi": "Lịch họp bị dời", "goal_vi": "Báo dời lịch", "words": words})
    req = vocab_path.VocabPathRequest(level="intermediate", topics=["meetings", "travel"], lesson_index=3,
                                      known=["colleague"], weak=["agenda item"])
    out = vocab_path.next_lesson(llm, lex, req)
    assert out["source"] == "llm" and out["topic"] == "meetings" and out["title"] == "Lịch họp bị dời"
    got = {w["word"]: w for w in out["words"]}
    assert set(got) == {"deadline", "postpone", "agenda"}
    assert got["deadline"]["cloze_en"] == "We missed two ___ last month." and got["deadline"]["cloze_answer"] == "deadlines"
    assert got["postpone"]["cloze_answer"] == "postponed"
    assert got["agenda"]["practice_en"] == "Here is the agenda." and got["agenda"]["cloze_en"] == "Here is the ___."
    assert all(w["ipa"] and w["phones"] for w in out["words"])
    sent = json.loads(llm.calls[0][1])
    assert sent["known"] == ["colleague"] and sent["weak"] == ["agenda item"] and sent["situation"] in vocab_path.SITUATIONS


def test_topics_and_situations_rotate(lex):
    seen = [vocab_path.plan(vocab_path.VocabPathRequest(topics=["work", "travel", "food"], lesson_index=i)) for i in range(1, 7)]
    assert [p["topic"] for p in seen] == ["work", "travel", "food"] * 2
    assert len({(p["topic"], p["situation"]) for p in seen}) == 6


def test_offline_lessons_skip_known_words_and_move_on(lex):
    req = vocab_path.VocabPathRequest(topics=["food"], lesson_index=1)
    first = vocab_path.next_lesson(None, lex, req)
    assert first["source"] == "seed" and first["topic"] == "food" and first["words"]
    assert all(w["cloze_answer"] and vocab_path.BLANK in w["cloze_en"] for w in first["words"])
    known = [w["word"] for w in first["words"]]
    second = vocab_path.next_lesson(FakeLLM(error=TimeoutError()), lex, vocab_path.VocabPathRequest(topics=["food"], lesson_index=2, known=known))
    assert second["source"] == "seed" and not set(known) & {w["word"] for w in second["words"]}


def test_endpoint(monkeypatch, lex):
    monkeypatch.setattr(main, "get_llm", lambda: None)
    monkeypatch.setattr(main, "get_lexicon", lambda: lex)
    resp = TestClient(main.app).post("/v1/vocab/next", json={"topics": ["work"], "lesson_index": 1})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert {"index", "topic", "topic_title", "title", "words", "source"} <= set(body)
    assert {"word", "meaning_vi", "ipa", "cloze_en", "cloze_answer", "practice_vi"} <= set(body["words"][0])
