import numpy as np
import pytest

from app.feedback import summarize
from app.scoring import Assessor, Calibration, NoSpeechError

from .conftest import LEXICON, ScriptedRecognizer, make_track

SPEECH = np.random.default_rng(0).uniform(-0.5, 0.5, 16000)


def assessor(spoken, f0=(160, 150)):
    return Assessor(ScriptedRecognizer(spoken), LEXICON, lambda wav, sr: make_track(1.0, *f0), Calibration())


def test_correct_pronunciation_scores_high():
    result = assessor(["θ", "ɪ", "ŋ", "k"]).assess(SPEECH, "think")
    phones = result["words"][0]["phones"]
    assert [p["status"] for p in phones] == ["good"] * 4
    assert result["scores"]["pronunciation"] >= 95


def test_th_said_as_s_is_flagged_with_what_was_heard():
    result = assessor(["s", "ɪ", "ŋ", "k"]).assess(SPEECH, "think")
    th = result["words"][0]["phones"][0]
    assert th["expected"] == "θ" and th["id"] == "TH"
    assert th["heard"] == "s" and th["heard_id"] == "S"
    assert th["status"] == "substituted"
    assert th["score"] < 40
    assert result["scores"]["pronunciation"] < 90


def test_dropped_final_consonant_is_missing():
    result = assessor(["ʃ", "iː"]).assess(SPEECH, "sheep")
    assert result["words"][0]["phones"][-1]["status"] == "missing"


def test_yes_no_question_needs_rising_pitch():
    rising = assessor(["ɑː", "ɹ", "j", "uː"], f0=(150, 260)).assess(SPEECH, "Are you?")
    falling = assessor(["ɑː", "ɹ", "j", "uː"], f0=(260, 150)).assess(SPEECH, "Are you?")
    assert rising["intonation"]["expected"] == "rising"
    assert rising["intonation"]["detected"] == "rising"
    assert falling["intonation"]["detected"] == "falling"
    assert rising["scores"]["intonation"] > falling["scores"]["intonation"]


def test_reference_audio_adds_contour_similarity():
    result = assessor(["θ", "ɪ", "ŋ", "k"]).assess(SPEECH, "think", reference_wav=SPEECH)
    assert result["intonation"]["reference_similarity"] == 100
    assert result["pitch_contour"]["reference"]


def test_silence_is_rejected():
    with pytest.raises(NoSpeechError):
        assessor(["θ"]).assess(np.zeros(16000), "think")


def test_feedback_summary_lists_only_problems():
    result = assessor(["s", "ɪ", "ŋ", "k"]).assess(SPEECH, "think")
    issues = summarize(result)["issues"]
    assert issues[0]["expected"] == "θ" and issues[0]["heard"] == "s"
    assert all(i.get("expected") != "ɪ" for i in issues)
