import json
import random

import pytest
from fastapi.testclient import TestClient

from app import exam, exercises, main, path
from app.phonetics import PHONE_IPA, Lexicon


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


def answer(ex):
    return ex["options"][ex["answer"]]["word"]


def has(lex, word, sound, every_reading=False):
    readings = lex.pronunciations(word) if every_reading else [lex.lookup(word)]
    return any(sound in [p.id for p in r.phones] for r in readings)


def marked(ex):
    return [o["word"] for o, m in zip(ex["options"], ex["marks"]) if m]


def check_exercise(lex, ex):
    """What the app relies on: answers it can check on its own, and those answers are right."""
    assert ex["kind"] in ("sequence", "dictation", "sort", "build") and ex["sound"] in PHONE_IPA
    words = [o["word"] for o in ex["options"]]
    assert len(set(words)) == len(words)
    if ex["kind"] in ("sequence", "dictation"):
        assert path.minimal_pair(lex, *words) and ex["sound"] in path.minimal_pair(lex, *words)["contrast"]
    if ex["kind"] == "sequence":
        # Both words are read, so marking all three the same is never right.
        assert len(ex["order"]) == exercises.SEQUENCE_LENGTH and set(ex["order"]) == {0, 1}
    if ex["kind"] == "dictation":
        assert 0 <= ex["answer"] < 2 and ex["accept"][0] == answer(ex)
        assert words[1 - ex["answer"]] not in ex["accept"]
        assert exercises.BLANK in ex["text"] and answer(ex) in ex["sentence"].lower()
        assert ex["text"].replace(exercises.BLANK, answer(ex)).lower() == ex["sentence"].lower()
    if ex["kind"] == "sort":
        assert 3 <= len(words) <= 5 and len(ex["marks"]) == len(words)
        assert any(ex["marks"]) and not all(ex["marks"])
        for w, m in zip(words, ex["marks"]):
            assert exercises.has_sound(lex.lookup(w).phones, ex["sound"]) if m else not has(lex, w, ex["sound"], True)
    if ex["kind"] == "build":
        assert len(words) == 1
        assert ex["solution"] == [PHONE_IPA[p] for p in ex["options"][0]["phones"]]
        assert PHONE_IPA[ex["sound"]] in ex["solution"] and set(ex["solution"]) < set(ex["tiles"])
        assert len(ex["tiles"]) == len(set(ex["tiles"]))


def test_offline_sort_questions_share_letters(lex):
    pool = path.pool_for(lex)
    made = 0
    for sound in PHONE_IPA:
        for ex in exercises.rules_spelling(lex, pool.words, sound, random.Random(sound), 2, set()):
            check_exercise(lex, ex)
            letters = ex["note_vi"].split('"')[1]
            assert all(letters in o["word"] for o in ex["options"])
            assert all(w in ex["note_vi"] for w in marked(ex))
            made += 1
    assert made >= 60


def test_build_tiles_include_what_the_sound_is_confused_with(lex):
    ex = exercises.build(lex, "sheep", "IY", random.Random(2), contrast="IH")
    assert ex["solution"] == ["ʃ", "iː", "p"] and "ɪ" in ex["tiles"]
    # Too long to build, or the sound only unstressed: not asked.
    assert exercises.build(lex, "responsibility", "IH", random.Random(2)) is None
    assert exercises.build(lex, "happy", "IY", random.Random(2)) is None


def test_dictation_accepts_homophones(lex):
    checker = exercises.Checker(lex, ["IY"], random.Random(1))
    ex = checker.gap({"sentence": "Let's meet after lunch.", "target": "meet", "distractor": "mitt"})
    assert ex["kind"] == "dictation" and ex["accept"][0] == "meet" and "meat" in ex["accept"]


def test_unstressed_final_y_is_not_the_long_e(lex):
    # worry ends in an unstressed /i/; asking "which word has /iː/" with it as the answer would mislead.
    checker = exercises.Checker(lex, ["IY"], random.Random(1))
    assert checker.spelling({"words": ["worry", "mirror", "password"]}) is None
    assert marked(checker.spelling({"words": ["seat", "bread", "great"]})) == ["seat"]
    # The sorting needs at least one word without the sound.
    assert checker.spelling({"words": ["feet", "meet", "sheet"]}) is None


def test_llm_items_are_checked_not_trusted(lex):
    llm = FakeLLM({
        "pairs": [{"a": "seat", "b": "sit", "topic": "work"}, {"a": "cat", "b": "dog"}, {"a": "seat", "b": "sit"}],
        "gaps": [
            {"sentence": "Please take a seat in the meeting room.", "target": "seat", "distractor": "sit"},
            {"sentence": "I will leave the office at six.", "target": "leave", "distractor": "live", "topic": "work"},
            {"sentence": "The report is on my desk.", "target": "sheep", "distractor": "ship"},
            {"sentence": "We met at 9 today.", "target": "meet", "distractor": "mitt"},
        ],
        "spelling": [
            {"words": ["bread", "heat", "great"], "note_vi": "ea", "topic": "work"},
            {"words": ["bread", "head", "dead"]},
            {"words": ["seat", "meet", "feet"]},
            {"words": ["xqzt", "seat", "bread"]},
        ],
    })
    req = exercises.ExerciseRequest(sound="IY", contrasts=["IH"], topics=["work", "meetings"], seed=4)
    out = exercises.for_sound(llm, lex, req)
    assert out["source"] == "llm" and out["contrast"] == "IH"
    kinds = [e["kind"] for e in out["exercises"]]
    for ex in out["exercises"]:
        check_exercise(lex, ex)
    gaps = [e for e in out["exercises"] if e["kind"] == "dictation"]
    # The seat/sit pair is taken by the first pair question, so its gap is dropped; the leave/live one stays.
    assert [g["sentence"] for g in gaps] == ["I will leave the office at six."]
    assert gaps[0]["text"] == "I will ___ the office at six." and gaps[0]["topic"] == "work"
    spelling = [e for e in out["exercises"] if e["kind"] == "sort"]
    assert marked(spelling[0]) == ["heat"] and spelling[0]["note_vi"] == "ea"
    assert kinds.count("sequence") >= 2 and kinds.count("sort") >= 2 and kinds.count("build") == 2
    assert kinds[:3] == ["sequence", "sort", "build"]
    sent = json.loads(llm.calls[0][1])
    assert sent["sound"]["ipa"] == "iː" and set(sent["angles"]) == {"work", "meetings"}


def test_exercises_without_llm_and_on_failure(lex):
    for client in (None, FakeLLM(error=TimeoutError())):
        out = exercises.for_sound(client, lex, exercises.ExerciseRequest(sound="TH"))
        assert out["source"] == "rules"
        assert {e["kind"] for e in out["exercises"]} == {"sequence", "sort", "build"}
        for ex in out["exercises"]:
            check_exercise(lex, ex)


def test_path_lessons_carry_checked_exercises(lex):
    for i, focus in enumerate(["IY", "TH", "R", "AE", "SH", "V", "M"], 1):
        lesson = path.next_lesson(None, lex, path.PathRequest(next_index=i, sounds=[{"id": focus, "speak": 20, "takes": 9}]))
        assert lesson["exercises"], focus
        for ex in lesson["exercises"]:
            assert ex["sound"] == lesson["focus"]
            check_exercise(lex, ex)


def test_llm_lesson_gaps_and_spelling(lex):
    llm = FakeLLM({
        "focus": "R", "contrast": "L", "words": [], "pairs": [{"a": "right", "b": "light"}], "sentences": [],
        "gaps": [{"sentence": "Turn right at the next corner.", "target": "right", "distractor": "light"},
                 {"sentence": "I think we took the wrong road.", "target": "wrong", "distractor": "long"}],
        "spelling": [{"words": ["write", "wrong", "word"]}],
    })
    lesson = path.next_lesson(llm, lex, path.PathRequest(sounds=[{"id": "R", "speak": 30, "takes": 9}], topics=["travel"]))
    gaps = [e for e in lesson["exercises"] if e["kind"] == "dictation"]
    assert [g["sentence"] for g in gaps] == ["I think we took the wrong road."]
    for ex in lesson["exercises"]:
        check_exercise(lex, ex)
    assert "'gaps'" in llm.calls[0][0] and "angles" in json.loads(llm.calls[0][1])


def history(*focuses):
    return [{"index": i, "focus": f, "difficulty": 2, "score": 70} for i, f in enumerate(focuses, 1)]


def test_exam_covers_recent_sounds_offline(lex):
    req = exam.ExamRequest(exam_index=1, next_index=5, topics=["meetings", "email"],
                           history=history("R", "IH", "TH", "AE"), recent_words=["attachment"])
    e = exam.next_exam(None, lex, req)
    assert e["source"] == "rules" and set(e["sounds"]) == {"R", "IH", "TH", "AE"} and e["after_lesson"] == 4
    assert {x["sound"] for x in e["listening"] if x["kind"] == "sequence"} == set(e["sounds"])
    builds = [x for x in e["listening"] if x["kind"] == "build"]
    assert builds and all(x["options"][0]["word"] in [w["word"] for w in e["words"]] for x in builds)
    for ex in e["listening"]:
        check_exercise(lex, ex)
    words = [w["word"] for w in e["words"]]
    assert len(words) == exam.WORDS and len(set(words)) == len(words) and "attachment" not in words
    assert all(has(lex, w["word"], w["sound"]) for w in e["words"])
    assert {w["sound"] for w in e["words"]} == set(e["sounds"])
    assert any(w["topic"] in ("meetings", "email") for w in e["words"])
    assert e["sentences"] and all(s["sound"] in e["sounds"] for s in e["sentences"])


def test_exam_keeps_keywords_unique_and_topics_balanced(lex):
    words = ([{"sound": "R", "word": w, "topic": "meetings"} for w in ["report", "agree", "proposal", "round"]]
             + [{"sound": "R", "word": "report", "topic": "email"}, {"sound": "R", "word": "reply", "topic": "email"},
                {"sound": "IH", "word": "inbox", "topic": "email"}, {"sound": "IH", "word": "minutes", "topic": "meetings"},
                {"sound": "IH", "word": "recent", "topic": "email"}, {"sound": "IH", "word": "big", "topic": "email"},
                {"sound": "M", "word": "meeting", "topic": "email"}, {"sound": "R", "word": "red", "topic": "nope"}])
    llm = FakeLLM({
        "title_vi": "Kiểm tra họp và email",
        "words": words,
        "sentences": [{"sound": "R", "text": "Please reply to the report by Friday.", "topic": "email"},
                      {"sound": "R", "text": "Please reply to the report by Friday.", "topic": "email"},
                      {"sound": "IH", "text": "Let's begin the meeting with the minutes.", "topic": "meetings"},
                      {"sound": "IH", "text": "I sent 2 files.", "topic": "email"}],
        "pairs": [{"sound": "R", "a": "right", "b": "light", "topic": "meetings"},
                  {"sound": "IH", "a": "ship", "b": "sheep", "topic": "email"}],
        "gaps": [], "spelling": [{"sound": "IH", "words": ["build", "guide", "fruit"], "topic": "email"}],
    })
    req = exam.ExamRequest(exam_index=2, next_index=9, topics=["meetings", "email"], history=history("R", "IH"),
                           recent_words=["agree"])
    e = exam.next_exam(llm, lex, req)
    assert e["source"] == "llm" and e["title"] == "Kiểm tra họp và email"
    got = [w["word"] for w in e["words"]]
    assert len(got) == len(set(got)) == exam.WORDS
    assert "agree" not in got and "meeting" not in got and "big" in got or len(got) == exam.WORDS
    llm_words = [w for w in e["words"] if w["topic"]]
    by_topic = {t: sum(w["topic"] == t for w in llm_words) for t in ("meetings", "email")}
    assert abs(by_topic["meetings"] - by_topic["email"]) <= 1, by_topic
    assert {s["text"] for s in e["sentences"]} >= {"Please reply to the report by Friday.",
                                                   "Let's begin the meeting with the minutes."}
    assert not any("2" in s["text"] for s in e["sentences"]) and len(e["sentences"]) == len({s["text"] for s in e["sentences"]})
    every_word = got + [o["word"] for x in e["listening"] for o in x["options"] if x["kind"] not in ("sequence", "build")]
    assert len(every_word) == len(set(every_word))
    assert {t["id"]: t["items"] for t in e["topics"]}["email"] >= 2
    sent = json.loads(llm.calls[0][1])
    assert [s["id"] for s in sent["sounds"]][:2] == ["IH", "R"] and "agree" in sent["avoid_words"]
    assert set(sent["angles"]) == {"meetings", "email"}


def test_exam_gives_every_sound_a_keyword_even_when_the_llm_crowds_one_out(lex):
    """Seen with a real model: six words for three sounds and the weakest sound's word last, so it was cut."""
    words = [{"sound": s, "word": w, "topic": t} for s, w, t in [
        ("L", "leader", "meetings"), ("L", "pilot", "travel"), ("TH", "thanks", "email"), ("IH", "business", "meetings"),
        ("TH", "thief", "travel"), ("IH", "inbox", "email"), ("L", "lobby", "travel"), ("R", "receipt", "travel")]]
    sentences = [{"sound": s, "text": t, "topic": "travel"} for s, t in [
        ("L", "Our lawyer will join the call."), ("IH", "My editor will fix the typo."),
        ("L", "The hotel lobby looks lovely."), ("R", "We ran to the train.")]]
    llm = FakeLLM({"words": words, "sentences": sentences, "pairs": [], "gaps": [], "spelling": []})
    sounds = [{"id": "R", "speak": 30, "takes": 12}, {"id": "TH", "speak": 50, "takes": 12},
              {"id": "IH", "speak": 60, "takes": 12}, {"id": "L", "speak": 70, "takes": 12}]
    req = exam.ExamRequest(exam_index=1, next_index=5, topics=["meetings", "travel", "email"],
                           history=history("R", "IH", "TH", "L"), sounds=sounds)
    e = exam.next_exam(llm, lex, req)
    assert {w["sound"] for w in e["words"]} == {"R", "TH", "IH", "L"}
    assert "receipt" in [w["word"] for w in e["words"]]
    assert "We ran to the train." in [s["text"] for s in e["sentences"]]


def test_titles_show_ipa_not_sound_ids():
    assert exercises.with_symbols("Kiểm tra số 1: L, TH, IH, R", ["L", "TH", "IH", "R"]) == "Kiểm tra số 1: /l/, /θ/, /ɪ/, /r/"
    assert exercises.with_symbols("Âm /θ/ trong Email", ["TH", "L"]) == "Âm /θ/ trong Email"


def test_exam_angles_change_between_exams(lex):
    seen = set()
    for k in range(1, 6):
        llm = FakeLLM({})
        exam.next_exam(llm, lex, exam.ExamRequest(exam_index=k, next_index=4 * k + 1, topics=["work", "travel", "food"],
                                                  history=history("R", "L")))
        seen.add(json.dumps(json.loads(llm.calls[0][1])["angles"], sort_keys=True))
    assert len(seen) >= 4


def test_exam_and_exercise_endpoints(monkeypatch, lex):
    monkeypatch.setattr(main, "get_llm", lambda: None)
    monkeypatch.setattr(main, "get_lexicon", lambda: lex)
    c = TestClient(main.app)
    resp = c.post("/v1/path/exam", json={"exam_index": 1, "next_index": 5, "topics": ["work"],
                                         "history": history("Z", "V", "TH", "R")})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert {"index", "after_lesson", "title", "sounds", "listening", "words", "sentences", "topics", "source"} <= set(body)
    assert {"kind", "sound", "options", "answer", "order", "marks", "tiles", "solution", "accept", "text", "sentence",
            "note_vi", "topic"} <= set(body["listening"][0])
    resp = c.post("/v1/exercises", json={"sound": "IY", "contrasts": ["IH"], "topics": ["food"]})
    assert resp.status_code == 200 and resp.json()["exercises"]
    assert c.post("/v1/exercises", json={"sound": "QQ"}).status_code == 422
