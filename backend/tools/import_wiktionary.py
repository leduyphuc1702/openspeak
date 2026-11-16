"""Build data/dictionary.sqlite from a Wiktextract JSONL dump of English Wiktionary.

Download the English-language extract from kaikki.org (machine-readable
Wiktionary, CC BY-SA 4.0), then:

    python -m tools.import_wiktionary path/to/english.jsonl [--out data/dictionary.sqlite]

Credit Wiktionary in the app when shipping this data (CC BY-SA 4.0).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.dictionary import DEFAULT_DB, SCHEMA  # noqa: E402


def _ipa(sounds: Iterable[Dict], accent: str) -> Optional[str]:
    tags = {"US": {"US", "General-American", "GenAm"}, "UK": {"UK", "Received-Pronunciation", "RP"}}[accent]
    for s in sounds:
        if "ipa" in s and tags & set(s.get("tags", [])):
            return s["ipa"].strip("/[]")
    return None


def convert(entry: Dict) -> Optional[Dict]:
    if entry.get("lang_code") not in (None, "en"):
        return None
    vi_by_sense: Dict[str, List[str]] = {}
    for t in entry.get("translations", []):
        if t.get("code") == "vi" and t.get("word"):
            vi_by_sense.setdefault(t.get("sense", ""), []).append(t["word"])
    senses = []
    for s in entry.get("senses", []):
        glosses = s.get("glosses") or []
        if not glosses or "form-of" in s.get("tags", []):
            continue
        gloss = glosses[-1]
        vi = next((v for k, v in vi_by_sense.items() if k and k in gloss or gloss in k), [])
        senses.append({"gloss": gloss, "vi": vi})
    if not senses:
        return None
    if vi_by_sense and not any(s["vi"] for s in senses):
        senses[0]["vi"] = sorted({w for ws in vi_by_sense.values() for w in ws})[:6]
    sounds = entry.get("sounds", [])
    return {"word": entry["word"], "pos": entry.get("pos"), "ipa_us": _ipa(sounds, "US"),
            "ipa_uk": _ipa(sounds, "UK"), "senses": senses[:8]}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl", type=Path)
    ap.add_argument("--out", type=Path, default=DEFAULT_DB)
    args = ap.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(args.out)
    db.executescript(SCHEMA)
    count = 0
    with args.jsonl.open(encoding="utf-8") as f:
        for line in f:
            row = convert(json.loads(line))
            if row is None:
                continue
            db.execute("INSERT INTO entries VALUES (?, ?, ?, ?, ?)",
                       (row["word"], row["pos"], row["ipa_us"], row["ipa_uk"], json.dumps(row["senses"], ensure_ascii=False)))
            count += 1
            if count % 50000 == 0:
                db.commit()
                print(f"{count} entries…")
    db.commit()
    db.close()
    print(f"wrote {count} entries to {args.out}")


if __name__ == "__main__":
    main()
