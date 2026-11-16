"""Human recordings of single words from Wikimedia Commons (CC BY-SA etc.).

Prefers the US-English series "En-us-<word>.ogg"; falls back to Lingua Libre
("LL-Q1860 (eng)-<speaker>-<word>.wav"), whose speakers' accents vary. Files are
decoded here because iOS cannot play Ogg Vorbis, then cached on disk as WAV with
their attribution, which every response must carry.
"""
from __future__ import annotations

import html
import io
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Optional, Tuple

import numpy as np
import soundfile as sf

API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "OpenSpeak/0.2 (personal pronunciation study app)"
CACHE_DIR = Path(__file__).resolve().parent.parent / "cache" / "word_audio"
WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]{0,39}")

HttpGet = Callable[[str], bytes]


@dataclass(frozen=True)
class Recording:
    word: str
    title: str          # Commons file title, e.g. "File:En-us-schedule.ogg"
    page: str           # Commons description page (attribution link)
    license: str
    artist: str
    accent: str         # "en-US" or "unspecified"


def _http_get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.read()
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt:
                raise
            time.sleep(min(float(e.headers.get("Retry-After") or 3), 10))
    raise AssertionError("unreachable")


def _strip_html(text: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", text or "")).strip()


class WordAudio:
    def __init__(self, http_get: HttpGet = _http_get, cache_dir: Path = CACHE_DIR):
        self.http_get = http_get
        self.cache_dir = cache_dir

    def _api(self, **params) -> dict:
        params["format"] = "json"
        return json.loads(self.http_get(API + "?" + urllib.parse.urlencode(params)))

    def _file_info(self, title: str) -> Optional[Tuple[str, dict]]:
        data = self._api(action="query", titles=title, prop="imageinfo", iiprop="url|extmetadata")
        page = next(iter(data.get("query", {}).get("pages", {}).values()), {})
        info = (page.get("imageinfo") or [None])[0]
        if not info:
            return None
        return info["url"].split("?")[0], info.get("extmetadata", {})

    def _lingua_libre_title(self, word: str) -> Optional[str]:
        data = self._api(action="query", list="search", srnamespace=6, srlimit=20,
                         srsearch=f'intitle:"LL-Q1860 (eng)" intitle:"{word}"')
        suffix = f"-{word}.wav".lower()
        for hit in data.get("query", {}).get("search", []):
            if hit["title"].lower().endswith(suffix):
                return hit["title"]
        return None

    def find(self, word: str) -> Optional[Tuple[str, Recording]]:
        """Returns (download URL, attribution) or None when Commons has no recording."""
        candidates = [(f"File:En-us-{word}.ogg", "en-US")]
        if word != word.lower():
            candidates.append((f"File:En-us-{word.lower()}.ogg", "en-US"))
        for title, accent in candidates:
            found = self._file_info(title)
            if found:
                return found[0], self._recording(word, title, found[1], accent)
        title = self._lingua_libre_title(word)
        if title:
            found = self._file_info(title)
            if found:
                return found[0], self._recording(word, title, found[1], "unspecified")
        return None

    @staticmethod
    def _recording(word: str, title: str, meta: dict, accent: str) -> Recording:
        def value(key: str) -> str:
            return _strip_html(str(meta.get(key, {}).get("value", "")))
        page = "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))
        artist = re.sub(r"\s+", " ", value("Artist"))
        speaker = re.search(r"Speaker:\s*(.+?)(?:\s*Recorder:|$)", artist)
        return Recording(word=word, title=title, page=page, license=value("LicenseShortName") or "see page",
                         artist=(speaker.group(1) if speaker else artist) or "unknown", accent=accent)

    def get(self, word: str) -> Optional[Tuple[bytes, Recording]]:
        """WAV bytes plus attribution, from the disk cache when possible."""
        if not WORD_RE.fullmatch(word):
            raise ValueError("word must be a single English word")
        key = word.lower()
        wav_path = self.cache_dir / f"{key}.wav"
        meta_path = self.cache_dir / f"{key}.json"
        if meta_path.exists():
            meta = json.loads(meta_path.read_text())
            if meta is None:
                return None
            if wav_path.exists():
                return wav_path.read_bytes(), Recording(**meta)
        found = self.find(word)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        if found is None:
            meta_path.write_text("null")
            return None
        url, recording = found
        wav = _to_wav(self.http_get(url))
        wav_path.write_bytes(wav)
        meta_path.write_text(json.dumps(asdict(recording), ensure_ascii=False))
        return wav, recording


def _to_wav(data: bytes) -> bytes:
    """Mono, silence trimmed, peak-normalised 16-bit WAV."""
    audio, rate = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 0:
        loud = np.flatnonzero(np.abs(audio) > peak * 0.02)
        pad = int(0.05 * rate)
        audio = audio[max(loud[0] - pad, 0): loud[-1] + pad]
        audio = audio * (0.9 / peak)
    out = io.BytesIO()
    sf.write(out, audio, rate, format="WAV", subtype="PCM_16")
    return out.getvalue()
