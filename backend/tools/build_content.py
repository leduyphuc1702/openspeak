"""Generate the iOS lesson content from one source of truth.

All transcriptions come from the same lexicon the scoring backend uses, so
what the learner reads in the app is exactly what they are scored against.

    python -m tools.build_content
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app import articulation, connected_speech, vocab  # noqa: E402
from app.phonetics import PHONE_IPA, Lexicon, expected_intonation  # noqa: E402

OUT = ROOT.parent / "ios" / "PhonoPath" / "Resources" / "Content"
LEX = Lexicon()

# id, category, group, voiced, example words, tip (Vietnamese)
PHONEMES = [
    ("IY", "vowel", "Nguyên âm đơn", None, ["see", "team", "eat"],
     "Kéo môi sang hai bên như đang cười, lưỡi nâng cao ở phía trước. Đọc dài, khác với /ɪ/ ngắn."),
    ("IH", "vowel", "Nguyên âm đơn", None, ["sit", "ship", "big"],
     "Ngắn và lỏng hơn /iː/, miệng mở rộng hơn một chút, nằm giữa 'i' và 'ê'. Người Việt hay đọc thành 'i' dài."),
    ("EH", "vowel", "Nguyên âm đơn", None, ["bed", "ten", "said"],
     "Miệng mở vừa, lưỡi ở giữa, gần giống 'e' tiếng Việt nhưng gọn hơn."),
    ("AE", "vowel", "Nguyên âm đơn", None, ["cat", "man", "bad"],
     "Hạ hàm dưới, mở miệng rộng, môi kéo sang hai bên: âm nằm giữa 'a' và 'e'. Đừng đọc thành /e/ (bad khác bed)."),
    ("AA", "vowel", "Nguyên âm đơn", None, ["hot", "car", "father"],
     "Mở miệng rộng, lưỡi hạ thấp và lùi về sau, như 'a' tiếng Việt nhưng sâu và dài hơn."),
    ("AO", "vowel", "Nguyên âm đơn", None, ["saw", "talk", "law"],
     "Môi tròn nhẹ, miệng mở vừa, âm phát sâu trong khoang miệng, giống 'o' kéo dài."),
    ("UH", "vowel", "Nguyên âm đơn", None, ["book", "good", "put"],
     "Ngắn, môi tròn lỏng, không chu môi mạnh như /uː/."),
    ("UW", "vowel", "Nguyên âm đơn", None, ["food", "blue", "two"],
     "Chu tròn môi về phía trước, lưỡi nâng cao ở phía sau, đọc dài."),
    ("AH", "vowel", "Nguyên âm đơn", None, ["cup", "love", "sun"],
     "Ngắn, miệng mở vừa, lưỡi thả lỏng ở giữa, gần giống 'ă' tiếng Việt."),
    ("AX", "vowel", "Nguyên âm đơn", None, ["about", "banana", "sofa"],
     "Âm schwa, âm phổ biến nhất trong tiếng Anh, chỉ có ở âm tiết không nhấn. Thả lỏng hoàn toàn, rất ngắn và nhẹ, như 'ơ' lướt qua."),
    ("ER", "vowel", "Nguyên âm đơn", None, ["bird", "work", "learn"],
     "Cong đầu lưỡi lên nhưng không chạm vòm miệng, môi hơi tròn, đọc dài: như 'ơ' có âm r."),
    ("AXR", "vowel", "Nguyên âm đơn", None, ["teacher", "water", "doctor"],
     "Bản ngắn, không nhấn của /ɝː/, thường ở cuối từ."),
    ("EY", "diphthong", "Nguyên âm đôi", None, ["day", "make", "rain"],
     "Bắt đầu ở /e/ rồi trượt nhanh lên /ɪ/, giống 'ây'."),
    ("AY", "diphthong", "Nguyên âm đôi", None, ["my", "time", "buy"],
     "Trượt từ 'a' sang /ɪ/, giống 'ai'."),
    ("OY", "diphthong", "Nguyên âm đôi", None, ["boy", "coin", "toy"],
     "Trượt từ /ɔː/ sang /ɪ/, giống 'oi'."),
    ("AW", "diphthong", "Nguyên âm đôi", None, ["now", "house", "out"],
     "Trượt từ 'a' sang /ʊ/, giống 'ao'."),
    ("OW", "diphthong", "Nguyên âm đôi", None, ["go", "home", "show"],
     "Bắt đầu ở 'ô' rồi tròn môi dần sang /ʊ/. Đừng đọc thành 'ô' đơn."),
    ("P", "consonant", "Âm tắc", False, ["pen", "happy", "stop"],
     "Mím môi rồi bật hơi mạnh. Ở cuối từ phải khép môi rõ: người Việt hay nuốt âm cuối."),
    ("B", "consonant", "Âm tắc", True, ["bad", "baby", "job"],
     "Như /p/ nhưng rung dây thanh. Ở cuối từ (job) vẫn phải phát âm."),
    ("T", "consonant", "Âm tắc", False, ["top", "ten", "cat"],
     "Đầu lưỡi chạm lợi trên rồi bật hơi, mạnh hơn 't' tiếng Việt. Không bỏ /t/ ở cuối từ."),
    ("D", "consonant", "Âm tắc", True, ["dog", "day", "bed"],
     "Đầu lưỡi chạm lợi trên, rung dây thanh. Khác 'đ' tiếng Việt: không hút hơi vào."),
    ("K", "consonant", "Âm tắc", False, ["key", "cat", "book"],
     "Cuống lưỡi chạm vòm mềm rồi bật hơi."),
    ("G", "consonant", "Âm tắc", True, ["go", "big", "egg"],
     "Như /k/ nhưng rung dây thanh."),
    ("CH", "consonant", "Âm tắc xát", False, ["chair", "watch", "teacher"],
     "Chu môi nhẹ, mặt lưỡi chạm lợi rồi bật ra có hơi gió. Khác 'ch' tiếng Việt vốn không chu môi."),
    ("JH", "consonant", "Âm tắc xát", True, ["job", "age", "june"],
     "Như /tʃ/ nhưng rung dây thanh. Không đọc thành 'gi' hay /z/."),
    ("F", "consonant", "Âm xát", False, ["fish", "coffee", "laugh"],
     "Răng trên chạm nhẹ môi dưới, thổi hơi."),
    ("V", "consonant", "Âm xát", True, ["very", "love", "five"],
     "Như /f/ nhưng rung dây thanh. Không đọc thành /b/ hay /w/."),
    ("TH", "consonant", "Âm xát", False, ["think", "three", "bath"],
     "Đặt đầu lưỡi giữa hai hàm răng rồi thổi hơi, không rung dây thanh. Người Việt hay đọc thành /t/ hoặc /s/."),
    ("DH", "consonant", "Âm xát", True, ["this", "mother", "they"],
     "Lưỡi giữa hai hàm răng như /θ/ nhưng rung dây thanh. Không đọc thành 'đ' hay /z/."),
    ("S", "consonant", "Âm xát", False, ["see", "bus", "rice"],
     "Đầu lưỡi gần lợi trên, xì hơi. Ở cuối từ (bus, rice) phải nghe rõ tiếng xì."),
    ("Z", "consonant", "Âm xát", True, ["zoo", "rose", "easy"],
     "Như /s/ nhưng rung dây thanh, nghe như tiếng ong 'zzz'."),
    ("SH", "consonant", "Âm xát", False, ["she", "fish", "nation"],
     "Chu môi, lưỡi lùi sau hơn /s/, giống 's' uốn lưỡi trong tiếng Việt."),
    ("ZH", "consonant", "Âm xát", True, ["measure", "vision", "usual"],
     "Như /ʃ/ nhưng rung dây thanh."),
    ("HH", "consonant", "Âm xát", False, ["hat", "house", "ahead"],
     "Đẩy hơi nhẹ từ cổ họng, giống 'h' tiếng Việt."),
    ("M", "consonant", "Âm mũi", True, ["man", "time", "summer"],
     "Mím môi, hơi thoát qua mũi."),
    ("N", "consonant", "Âm mũi", True, ["no", "sun", "dinner"],
     "Đầu lưỡi chạm lợi trên, hơi qua mũi. Phân biệt với /l/ (night khác light)."),
    ("NG", "consonant", "Âm mũi", True, ["sing", "long", "thinking"],
     "Cuống lưỡi chạm vòm mềm như 'ng' tiếng Việt. Không thêm /ɡ/ phía sau."),
    ("L", "consonant", "Âm tiếp cận", True, ["light", "feel", "hello"],
     "Đầu lưỡi chạm lợi trên. Ở cuối từ (feel) vẫn giữ lưỡi chạm lợi, không bỏ âm."),
    ("R", "consonant", "Âm tiếp cận", True, ["red", "car", "very"],
     "Cuộn đầu lưỡi về sau, không chạm vòm miệng, môi hơi tròn. Không rung lưỡi như 'r' tiếng Việt."),
    ("W", "consonant", "Âm tiếp cận", True, ["we", "water", "quick"],
     "Chu tròn môi rồi mở nhanh sang nguyên âm, giống 'qu' hoặc 'oa'."),
    ("Y", "consonant", "Âm tiếp cận", True, ["yes", "you", "yellow"],
     "Lưỡi nâng cao phía trước rồi trượt sang nguyên âm, giống 'y' trong 'yêu'."),
]

# Apple's TTS IPA attribute expects ɹ for the English r.
SPEAK_OVERRIDES = {"R": "ɹ", "ER": "ɝ", "AXR": "ɚ"}

MINIMAL_PAIRS = [
    ("sheep", "ship", "IY", "IH", "Âm dài /iː/ kéo môi cười; âm ngắn /ɪ/ thả lỏng."),
    ("leave", "live", "IY", "IH", None),
    ("seat", "sit", "IY", "IH", None),
    ("bad", "bed", "AE", "EH", "/æ/ mở miệng rộng hơn hẳn /e/."),
    ("man", "men", "AE", "EH", None),
    ("think", "sink", "TH", "S", "/θ/ cần đặt lưỡi giữa hai hàm răng."),
    ("three", "tree", "TH", "T", None),
    ("they", "day", "DH", "D", "/ð/ cũng đặt lưỡi giữa răng nhưng rung dây thanh."),
    ("she", "see", "SH", "S", "/ʃ/ chu môi và lùi lưỡi về sau."),
    ("light", "night", "L", "N", "/n/ cho hơi qua mũi, /l/ cho hơi qua hai bên lưỡi."),
    ("very", "berry", "V", "B", "/v/ là răng chạm môi, /b/ là hai môi chạm nhau."),
    ("zoo", "sue", "Z", "S", "/z/ rung dây thanh, /s/ thì không."),
    ("full", "fool", "UH", "UW", "/uː/ chu môi và đọc dài."),
    ("cut", "cot", "AH", "AA", "/ɑː/ mở miệng rộng và sâu hơn /ʌ/."),
    ("chip", "ship", "CH", "SH", "/tʃ/ bắt đầu bằng một tiếng bật."),
    ("bike", "buy", "K", None, "Đừng bỏ phụ âm cuối: bike có /k/ ở cuối."),
    ("rice", "rye", "S", None, "Giữ tiếng xì /s/ ở cuối từ."),
]

# The IPA course: small units of related sounds, easiest contrasts first.
# (id, title, sounds, confusable sounds used as distractors)
UNITS = [
    ("u1", "i dài và i ngắn", ["IY", "IH"], []),
    ("u2", "Hai âm e", ["EH", "AE"], ["IH"]),
    ("u3", "a sâu và ă", ["AA", "AH"], ["AE"]),
    ("u4", "Nhóm môi tròn", ["AO", "UH", "UW"], ["AA"]),
    ("u5", "Schwa và âm cong lưỡi", ["AX", "ER", "AXR"], ["AH"]),
    ("u6", "Nguyên âm đôi lướt lên /ɪ/", ["EY", "AY", "OY"], ["EH", "IY"]),
    ("u7", "Nguyên âm đôi lướt về /ʊ/", ["AW", "OW"], ["AO", "UW"]),
    ("u8", "Âm hai môi", ["P", "B", "M"], ["F", "V"]),
    ("u9", "Âm đầu lưỡi", ["T", "D", "N", "L"], []),
    ("u10", "Âm cuống lưỡi", ["K", "G", "NG"], ["N"]),
    ("u11", "Răng chạm môi", ["F", "V", "W"], ["B", "P"]),
    ("u12", "Âm lưỡi giữa răng", ["TH", "DH"], ["T", "D", "S", "Z"]),
    ("u13", "Âm gió xì", ["S", "Z", "SH", "ZH"], ["TH"]),
    ("u14", "Âm bật xì", ["CH", "JH"], ["SH", "ZH"]),
    ("u15", "Âm lướt và âm h", ["R", "Y", "HH"], ["L", "W"]),
]

READING_WORDS = """
cat dog fish bird book food water teacher think this ship sheep red yellow
green blue house home school time music happy family morning night light
coffee measure thank weather mother father brother sister purple orange
chair job age vision usual nation picture garden window question answer
language beautiful computer banana tomorrow
""".split()

SENTENCES = [
    ("Thank you very much.", 1), ("Nice to meet you.", 1), ("How are you today?", 1),
    ("Are you ready?", 1), ("I think it is three o'clock.", 2), ("This is my brother.", 2),
    ("She sells sea shells.", 2), ("Do you like coffee?", 2), ("What time is it?", 1),
    ("The weather is beautiful this morning.", 3), ("Could you help me with this question?", 3),
    ("I usually measure the water carefully.", 3),
]


def _camel(value):
    """snake_case keys -> camelCase for Swift's default Codable."""
    if isinstance(value, dict):
        return {re.sub(r"_(\w)", lambda m: m.group(1).upper(), k): _camel(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_camel(v) for v in value]
    return value


def word_entry(word: str, contains: Optional[str] = None) -> dict:
    """First CMUdict variant, or the first that has `contains` (so a pair shows the contrasting reading)."""
    prons = LEX.pronunciations(word)
    pron = next((p for p in prons if contains in [ph.id for ph in p.phones]), prons[0]) if contains else prons[0]
    return {"word": word, "ipa": pron.ipa, "phones": [p.id for p in pron.phones]}


def build() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    assert {p[0] for p in PHONEMES} == set(PHONE_IPA), "phoneme list must cover the inventory"

    phonemes = []
    for pid, cat, group, voiced, words, tip in PHONEMES:
        examples = [word_entry(w) for w in words]
        for e in examples:
            assert pid in e["phones"], f"{e['word']} does not contain {pid}"
        phonemes.append({
            "id": pid, "symbol": PHONE_IPA[pid], "category": cat, "group": group,
            "voiced": voiced, "examples": examples, "tip": tip,
            "speakIPA": SPEAK_OVERRIDES.get(pid, PHONE_IPA[pid]),
            "articulation": _camel(articulation.ARTICULATION[pid].to_dict()),
            "steps": articulation.steps_vi(pid),
        })

    unit_ids = [pid for _, _, sounds, _ in UNITS for pid in sounds]
    assert sorted(unit_ids) == sorted(PHONE_IPA), "every sound must appear in exactly one unit"
    units = [{"id": uid, "title": title, "sounds": sounds, "confusables": conf}
             for uid, title, sounds, conf in UNITS]

    pairs = []
    for i, (a, b, ca, cb, note) in enumerate(MINIMAL_PAIRS):
        pairs.append({"id": f"pair-{i}", "a": word_entry(a, ca), "b": word_entry(b, cb),
                      "contrast": [c for c in (ca, cb) if c], "note": note})

    sentences = []
    for i, (text, level) in enumerate(SENTENCES):
        words = LEX.sentence(text)
        links = connected_speech.find_links(words)
        sentences.append({
            "id": f"s-{i}", "text": text, "ipa": " ".join(w.ipa for w in words),
            "connectedIPA": connected_speech.connected_transcription(words, links),
            "links": [{"display": l.display, "type": l.type, "hint": l.hint} for l in links],
            "level": level, "intonation": expected_intonation(text),
        })

    files = {
        "phonemes.json": phonemes,
        "units.json": units,
        "minimal_pairs.json": pairs,
        "reading_words.json": [word_entry(w) for w in READING_WORDS],
        "sentences.json": sentences,
        "topics.json": vocab.TOPICS,
    }
    for name, data in files.items():
        (OUT / name).write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"wrote {OUT / name} ({len(data)} items)")


if __name__ == "__main__":
    build()
