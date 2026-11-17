import io

import numpy as np
import soundfile as sf
from fastapi.testclient import TestClient

from app import main, vocab
from app.phonetics import Lexicon
from app.scoring import Assessor, Calibration

from .conftest import LEXICON, ScriptedRecognizer, make_track


def wav_bytes(seconds: float = 1.0, sr: int = 22050) -> bytes:
    buf = io.BytesIO()
    noise = np.random.default_rng(1).uniform(-0.4, 0.4, int(sr * seconds)).astype(np.float32)
    sf.write(buf, noise, sr, format="WAV", subtype="FLOAT")
    return buf.getvalue()


def client(monkeypatch, spoken):
    assessor = Assessor(ScriptedRecognizer(spoken), LEXICON, lambda wav, sr: make_track(1.0, 160, 140), Calibration())
    monkeypatch.setattr(main, "get_assessor", lambda: assessor)
    monkeypatch.setattr(main, "get_lexicon", lambda: LEXICON)
    return TestClient(main.app)


def test_assess_endpoint_returns_scored_phones(monkeypatch):
    c = client(monkeypatch, ["s", "ɪ", "ŋ", "k"])
    resp = c.post(
        "/v1/assess",
        data={"text": "think", "feedback": "false"},
        files={"audio": ("take.wav", wav_bytes(), "audio/wav"),
               "reference_audio": ("ref.wav", wav_bytes(), "audio/wav")},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["words"][0]["phones"][0]["heard"] == "s"
    assert body["feedback"] is None
    assert set(body["scores"]) == {"overall", "pronunciation", "intonation", "stress", "fluency", "linking"}


def test_assess_reports_linking_for_multiword_text(monkeypatch):
    c = client(monkeypatch, ["h", "ə", "l", "oʊ", "w", "ʌ", "t"])
    resp = c.post("/v1/assess", data={"text": "hello what", "feedback": "false"},
                  files={"audio": ("take.wav", wav_bytes(), "audio/wav")})
    assert resp.status_code == 200, resp.text
    assert "connected_ipa" in resp.json()["linking"]


def test_articulation_feedback_without_llm(monkeypatch):
    c = client(monkeypatch, ["θ"])
    monkeypatch.setattr(main, "get_llm", lambda: None)
    payload = {"text": "boot", "samples": [
        {"index": 0, "word": "boot", "phone_id": "B", "time": 0.1, "open": 0.02, "width": 1.0},
        {"index": 1, "word": "boot", "phone_id": "UW", "time": 0.2, "open": 0.2, "width": 1.2},
        {"index": 2, "word": "boot", "phone_id": "T", "time": 0.3, "open": 0.1, "width": 1.0},
    ]}
    import json as _json
    resp = c.post("/v1/articulation-feedback", data={"payload": _json.dumps(payload)})
    assert resp.status_code == 200, resp.text
    statuses = {f["phone_id"]: f["status"] for f in resp.json()["findings"]}
    assert statuses["B"] == "ok" and statuses["UW"] == "fix"
    assert resp.json()["coach"] is None


def test_topics_and_seed_lesson_without_llm(monkeypatch):
    c = client(monkeypatch, ["θ"])
    monkeypatch.setattr(main, "get_llm", lambda: None)
    monkeypatch.setattr(main, "get_lexicon", lambda: Lexicon())
    assert len(c.get("/v1/topics").json()["topics"]) == len(vocab.TOPICS)
    lesson = c.post("/v1/vocab/lesson", json={"topic": "food"}).json()
    assert lesson["source"] == "seed" and lesson["words"][0]["word"] == "delicious"


def test_articulation_guide(monkeypatch):
    c = client(monkeypatch, ["θ"])
    body = c.get("/v1/articulation/th").json()
    assert body["articulation"]["start"]["tip"] == "dental"
    assert body["steps"]


def test_unknown_words_are_reported(monkeypatch):
    c = client(monkeypatch, ["θ"])
    resp = c.get("/v1/phonemize", params={"text": "think blorptastic"})
    assert resp.status_code == 422
    assert resp.json()["detail"] == {"code": "unknown_words", "words": ["blorptastic"]}


def test_phonemize(monkeypatch):
    c = client(monkeypatch, ["θ"])
    resp = c.get("/v1/phonemize", params={"text": "Hello, think!"})
    assert [w["ipa"] for w in resp.json()["words"]] == ["həˈloʊ", "θɪŋk"]


def test_free_speech_skips_words_the_lexicon_lacks(monkeypatch):
    c = client(monkeypatch, ["θ", "ɪ", "ŋ", "k"])
    files = {"audio": ("take.wav", wav_bytes(), "audio/wav")}
    resp = c.post("/v1/assess", data={"text": "think zzqx?", "feedback": "false", "skip_unknown": "true"}, files=files)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["skipped_words"] == ["zzqx"] and [w["word"] for w in body["words"]] == ["think"]
    strict = c.post("/v1/assess", data={"text": "think zzqx?", "feedback": "false"},
                    files={"audio": ("take.wav", wav_bytes(), "audio/wav")})
    assert strict.status_code == 422 and strict.json()["detail"]["words"] == ["zzqx"]
    nothing = c.post("/v1/assess", data={"text": "zzqx", "feedback": "false", "skip_unknown": "true"},
                     files={"audio": ("take.wav", wav_bytes(), "audio/wav")})
    assert nothing.status_code == 422


def test_known_words_only_keeps_the_question_mark():
    lexicon = Lexicon()
    assert main.known_words_only(lexicon, "Do you think zzqx?") == ("Do you think?", ["zzqx"])
    assert main.known_words_only(lexicon, "Zzqx is fine") == ("is fine.", ["Zzqx"])
