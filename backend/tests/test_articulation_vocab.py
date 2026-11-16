from app import articulation, vocab
from app.dictionary import OpenDictionary, cambridge_url, define
from app.phonetics import PHONE_IPA, Lexicon

LEX = Lexicon()


def test_every_phone_has_articulation_and_steps():
    assert set(articulation.ARTICULATION) == set(PHONE_IPA)
    for pid in PHONE_IPA:
        steps = articulation.steps_vi(pid)
        assert steps[0].startswith("Môi:")
    assert any("răng" in s for s in articulation.steps_vi("TH"))
    assert any(s.startswith("Trượt:") for s in articulation.steps_vi("AY"))


def sample(i, pid, open_, width):
    return articulation.LipSample(i, "w", pid, i * 0.1, open_, width)


def test_lip_checks_against_own_baseline():
    samples = [
        sample(0, "AX", 0.30, 1.00), sample(1, "AX", 0.30, 1.00), sample(2, "AX", 0.30, 1.00),
        sample(3, "UW", 0.20, 1.02),   # should be rounded but lips are wide -> fix
        sample(4, "IY", 0.15, 1.10),   # spread -> ok
        sample(5, "P", 0.20, 1.00),    # lips not closed -> fix
        sample(6, "TH", 0.20, 1.00),   # needs a picture
    ]
    status = {f.phone_id: f.status for f in articulation.check_lips(samples)}
    assert status["UW"] == "fix"
    assert status["IY"] == "ok"
    assert status["P"] == "fix"
    assert status["TH"] == "needs_visual"


def test_seed_lessons_cover_all_topics_with_pronunciations():
    for topic in vocab.TOPICS:
        words = vocab.seed_lesson(LEX, topic["id"])
        assert len(words) == len(vocab.SEED[topic["id"]]), topic["id"]
        assert all(w["ipa"] and w["phones"] for w in words)


class FakeLLM:
    def __init__(self, data):
        self.data = data

    def chat_json(self, system, user, images=()):
        return self.data


def test_llm_lesson_is_enriched_filtered_and_deduped():
    llm = FakeLLM({"words": [
        {"word": "boarding pass", "pos": "phrase", "meaning_vi": "thẻ lên máy bay"},
        {"word": "passport", "meaning_vi": "hộ chiếu"},           # already known
        {"word": "zzqxw", "meaning_vi": "?"},                     # not in lexicon
        {"word": "Boarding pass", "meaning_vi": "trùng"},         # duplicate
        {"word": "<script>", "meaning_vi": "x"},                  # rejected
    ]})
    lesson = vocab.generate_lesson(llm, LEX, "travel", "beginner", 8, ["passport"])
    assert [w["word"] for w in lesson["words"]] == ["boarding pass"]
    assert lesson["words"][0]["ipa"] == "ˈbɔːrdɪŋ pæs"
    assert lesson["source"] == "llm"


def test_dictionary_falls_back_to_pronunciation_only(tmp_path):
    result = define("weather", LEX, OpenDictionary(tmp_path / "none.sqlite"), None)
    assert result["ipa"] == "ˈweðɚ"
    assert result["entries"] == [] and result["source"] is None
    assert cambridge_url("ice cream").endswith("/english-vietnamese/ice-cream")


def test_clean_coach_coerces_llm_output():
    from app.articulation import clean_coach

    raw = {"summary": "Môi chưa tròn.", "frames": [{"index": "2", "ok": False, "advice": " Chu môi. "},
                                                   {"index": "x"}, "junk", {"index": 3, "ok": True}]}
    assert clean_coach(raw) == {"summary": "Môi chưa tròn.", "frames": [
        {"index": 2, "ok": False, "advice": "Chu môi."}, {"index": 3, "ok": True, "advice": ""}]}
    assert clean_coach("not json") is None
    assert clean_coach({"frames": []}) is None


def test_clean_entries_drops_unusable_senses():
    from app.dictionary import clean_entries

    raw = [{"pos": "noun", "senses": [{"gloss": "a hot drink", "vi": "cà phê"}, {"vi": []}, "junk"]},
           {"pos": "verb", "senses": []}, "junk"]
    assert clean_entries(raw) == [{"pos": "noun", "ipa_us": None, "ipa_uk": None,
                                   "senses": [{"gloss": "a hot drink", "vi": ["cà phê"]}]}]
    assert clean_entries(None) == []
