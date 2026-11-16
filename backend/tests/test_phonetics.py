from app.phonetics import (
    Lexicon,
    arpabet_to_phone,
    expected_intonation,
    normalize_recognized,
    to_model_tokens,
)

from .conftest import VOCAB


def test_unstressed_ah_and_er_become_schwa_forms():
    assert arpabet_to_phone("AH0").ipa == "ə"
    assert arpabet_to_phone("AH1").ipa == "ʌ"
    assert arpabet_to_phone("ER0").ipa == "ɚ"
    assert arpabet_to_phone("ER1").ipa == "ɝː"


def test_word_ipa_marks_primary_stress(lexicon):
    hello = lexicon.lookup("hello")
    assert hello.ipa == "həˈloʊ"
    assert hello.primary_stress_vowel == 1


def test_stress_mark_keeps_legal_onset_clusters_together():
    lex = Lexicon()
    assert lex.lookup("about").ipa == "əˈbaʊt"
    assert lex.lookup("teacher").ipa == "ˈtiːtʃɚ"
    assert lex.lookup("instead").ipa == "ɪnˈsted"
    assert lex.lookup("extreme").ipa == "ekˈstriːm"


def test_real_cmudict_covers_common_words():
    words = Lexicon().sentence("Can you think about the weather?")
    assert [w.word for w in words] == ["Can", "you", "think", "about", "the", "weather"]
    assert words[2].ipa == "θɪŋk"


def test_intonation_expectation():
    assert expected_intonation("Are you ready?") == "rising"
    assert expected_intonation("What time is it?") == "falling"
    assert expected_intonation("I like coffee.") == "falling"


def test_model_token_mapping_uses_vocab_variants():
    assert to_model_tokens("r", VOCAB) == ("ɹ",)
    assert to_model_tokens("θ", VOCAB) == ("θ",)


def test_normalize_merges_split_diphthongs():
    assert normalize_recognized(["h", "ə", "l", "o", "ʊ", "|", "ɹ"]) == ["h", "ə", "l", "oʊ", "r"]


def test_model_tokens_fall_back_for_small_inventories():
    from app.phonetics import to_model_tokens

    timit = {t: i for i, t in enumerate("ɑ æ ə ʧ ʤ ɝ ɹ g ʃ z".split())}
    assert to_model_tokens("tʃ", timit) == ("ʧ",)
    assert to_model_tokens("ʌ", timit) == ("ə",)
    assert to_model_tokens("ɔː", timit) == ("ɑ",)
    assert to_model_tokens("ʒ", timit) == ("ʃ",)
    l2 = {t: i for i, t in enumerate("ʌ ɚ t ʃ".split())}
    assert to_model_tokens("ə", l2) == ("ʌ",)
    assert to_model_tokens("tʃ", l2) == ("t", "ʃ")


def test_arpabet_models_use_phone_ids():
    from app.phonetics import normalize_recognized, to_model_tokens

    arpabet = {t: i for i, t in enumerate("AH ER TH S IY [PAD]".split())}
    assert to_model_tokens("θ", arpabet) == ("TH",)
    assert to_model_tokens("ə", arpabet) == ("AH",)
    assert to_model_tokens("ɚ", arpabet) == ("ER",)
    assert normalize_recognized(["TH", "[PAD]", "IY"]) == ["θ", "iː"]


def test_syllabic_r_stands_in_for_r_coloured_vowels():
    from app.phonetics import normalize_recognized, to_model_tokens

    buckeye = {t: i for i, t in enumerate(["ɹ̩", "ɹ", "ə"])}
    assert to_model_tokens("ɝː", buckeye) == ("ɹ̩",)
    assert to_model_tokens("ɚ", buckeye) == ("ɹ̩",)
    assert normalize_recognized(["ɹ̩"]) == ["ɚ"]
