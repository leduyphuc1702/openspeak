from app.connected_speech import Link, check_links, connected_transcription, find_links
from app.phonetics import Lexicon

LEX = Lexicon()


def links_for(text):
    words = LEX.sentence(text)
    return words, {l.display: l for l in find_links(words)}


def test_consonant_to_vowel_link():
    _, links = links_for("turn off")
    assert links["turn‿off"].type == "consonant_vowel"


def test_flap_t_between_vowels():
    _, links = links_for("get it")
    assert links["get‿it"].type == "flap_t"
    assert links["get‿it"].connected_ipa == "ɡeɾ‿ɪt"


def test_glides_between_vowels():
    _, links = links_for("I am")
    assert links["I‿am"].type == "j_glide"
    _, links = links_for("go away")
    assert links["go‿away"].connected_ipa.startswith("ɡoʊ‿ʷ")


def test_assimilation_did_you():
    _, links = links_for("did you")
    assert links["did‿you"].type == "assimilation"
    assert links["did‿you"].connected_ipa == "dɪ‿dʒuː"


def test_gemination_and_no_link():
    _, links = links_for("bus stop")
    assert links["bus‿stop"].type == "gemination"
    _, links = links_for("big dog")
    assert links == {}


def test_full_sentence_transcription_chains_links():
    words, _ = links_for("Turn it off")
    links = find_links(words)
    assert connected_transcription(words, links) == "tɝːn‿ɪɾ‿ɔːf"


def test_check_links_detects_pause_and_glottal_stop():
    link0 = Link(0, "consonant_vowel", "turn‿off", "", "")
    link1 = Link(1, "consonant_vowel", "x‿y", "", "")
    boundaries = [(0.5, 0.9), (1.2, 1.25)]
    quiet = [(0.55, 0.85)]
    res = check_links([link0, link1], boundaries, [("ʔ", 1.22)], quiet)
    assert res[0].linked is False and res[0].problem == "pause"
    assert res[1].linked is False and res[1].problem == "glottal_stop"
    ok = check_links([link0], [(0.5, 0.58)], [], [])
    assert ok[0].linked
