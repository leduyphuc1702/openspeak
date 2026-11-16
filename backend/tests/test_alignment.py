import numpy as np

from app.alignment import align_sequences, ctc_forced_align, gop, heard_per_reference

from .conftest import VOCAB, ScriptedRecognizer


def test_forced_alignment_finds_each_token_in_order():
    post = ScriptedRecognizer(["θ", "ɪ", "ŋ", "k"]).posteriors(np.zeros(1))
    ids = [VOCAB[t] for t in ["θ", "ɪ", "ŋ", "k"]]
    spans = ctc_forced_align(post.log_probs, ids, 0)
    starts = [s.first_frame for s in spans]
    assert starts == sorted(starts)
    # Scripted layout: 2 blanks, then 3 frames per token + 2 blanks.
    assert starts == [2, 7, 12, 17]
    assert all(s.last_frame - s.first_frame == 2 for s in spans)


def test_forced_alignment_handles_repeated_tokens():
    post = ScriptedRecognizer(["s", "s"]).posteriors(np.zeros(1))
    spans = ctc_forced_align(post.log_probs, [VOCAB["s"], VOCAB["s"]], 0)
    assert spans[0].last_frame < spans[1].first_frame


def test_gop_is_low_when_a_different_sound_was_produced():
    post = ScriptedRecognizer(["s", "ɪ", "ŋ", "k"]).posteriors(np.zeros(1))
    ids = [VOCAB[t] for t in ["θ", "ɪ", "ŋ", "k"]]
    spans = ctc_forced_align(post.log_probs, ids, 0)
    scores = [gop(post.log_probs, tid, sp, 0) for tid, sp in zip(ids, spans)]
    assert scores[0] < -3
    assert all(abs(s) < 1e-6 for s in scores[1:])


def test_sequence_alignment_reports_substitution_and_deletion():
    heard = heard_per_reference(["θ", "ɪ", "ŋ", "k"], ["s", "ɪ", "ŋ"])
    assert heard[0][0] == "s"
    assert heard[1] == ("ɪ", 1.0)
    assert heard[3][0] is None  # dropped final consonant


def test_sequence_alignment_keeps_insertions_out_of_reference():
    pairs = align_sequences(["b", "aɪ", "k"], ["b", "aɪ", "k", "ə"])
    assert [p.expected for p in pairs] == ["b", "aɪ", "k", None]
