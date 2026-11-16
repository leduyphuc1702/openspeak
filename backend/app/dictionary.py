"""Full English dictionary lookups from open data.

Pronunciations for scoring always come from CMUdict (~134k words). Meanings and
UK/US IPA come from a local SQLite file built from Wiktionary (CC BY-SA 4.0)
by tools/import_wiktionary.py. If neither the file nor an LLM is available,
lookups still return the pronunciation.
"""
from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import quote

from .llm import LLMClient
from .phonetics import Lexicon, UnknownWordError

DEFAULT_DB = Path(__file__).resolve().parents[1] / "data" / "dictionary.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS entries (
    word TEXT NOT NULL,
    pos TEXT,
    ipa_us TEXT,
    ipa_uk TEXT,
    senses TEXT NOT NULL      -- JSON list of {"gloss": str, "vi": [str]}
);
CREATE INDEX IF NOT EXISTS entries_word ON entries (word COLLATE NOCASE);
"""

DEFINE_PROMPT = (
    "Bạn là từ điển Anh-Việt. Cho một từ tiếng Anh, trả về JSON "
    '{"entries": [{"pos": "...", "senses": [{"gloss": "định nghĩa tiếng Anh ngắn", "vi": ["nghĩa tiếng Việt"]}]}]} '
    "với tối đa 2 từ loại, mỗi từ loại tối đa 3 nghĩa thông dụng nhất."
)


def cambridge_url(word: str) -> str:
    """Link out for learners who want Cambridge's own entry (content stays on their site)."""
    return "https://dictionary.cambridge.org/dictionary/english-vietnamese/" + quote(word.lower().replace(" ", "-"))


class OpenDictionary:
    def __init__(self, path: Optional[Path] = None):
        self.path = Path(path or os.getenv("DICT_DB", DEFAULT_DB))

    @property
    def available(self) -> bool:
        return self.path.exists()

    def lookup(self, word: str) -> List[Dict]:
        if not self.available:
            return []
        with sqlite3.connect(self.path) as db:
            rows = db.execute(
                "SELECT pos, ipa_us, ipa_uk, senses FROM entries WHERE word = ? COLLATE NOCASE", (word,)
            ).fetchall()
        return [{"pos": pos, "ipa_us": us, "ipa_uk": uk, "senses": json.loads(senses)} for pos, us, uk, senses in rows]


def _text(value) -> Optional[str]:
    return value.strip() if isinstance(value, str) and value.strip() else None


def clean_entries(raw) -> List[Dict]:
    """Coerces LLM output into the entry shape the app decodes; drops anything unusable."""
    entries = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        senses = []
        for sense in item.get("senses") or []:
            if not isinstance(sense, dict):
                continue
            vi = sense.get("vi")
            vi = [v.strip() for v in ([vi] if isinstance(vi, str) else vi or []) if isinstance(v, str) and v.strip()]
            gloss = _text(sense.get("gloss")) or ""
            if vi or gloss:
                senses.append({"gloss": gloss, "vi": vi})
        if senses:
            entries.append({"pos": _text(item.get("pos")), "ipa_us": _text(item.get("ipa_us")),
                            "ipa_uk": _text(item.get("ipa_uk")), "senses": senses})
    return entries


def define(word: str, lexicon: Lexicon, dictionary: OpenDictionary, client: Optional[LLMClient]) -> Dict:
    try:
        pron = lexicon.lookup(word)
        ipa, phones = pron.ipa, [p.id for p in pron.phones]
    except UnknownWordError:
        ipa, phones = None, []
    entries, source = dictionary.lookup(word), "wiktionary"
    if not entries and client is not None:
        data = client.chat_json(DEFINE_PROMPT, word)
        entries, source = clean_entries(data.get("entries") if isinstance(data, dict) else None), "llm"
    if not entries:
        source = None
    return {"word": word, "ipa": ipa, "phones": phones, "entries": entries, "source": source,
            "cambridge_url": cambridge_url(word)}
