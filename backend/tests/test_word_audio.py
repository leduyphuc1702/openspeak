import io
import json
import urllib.parse

import numpy as np
import soundfile as sf
from fastapi.testclient import TestClient

from app import main
from app.word_audio import WordAudio


def _ogg(seconds=0.6, rate=16000):
    t = np.arange(int(seconds * rate)) / rate
    tone = 0.3 * np.sin(2 * np.pi * 220 * t)
    audio = np.concatenate([np.zeros(rate // 2), tone, np.zeros(rate // 2)]).astype("float32")
    out = io.BytesIO()
    sf.write(out, audio, rate, format="OGG", subtype="VORBIS")
    return out.getvalue()


class FakeCommons:
    """Has En-us-schedule.ogg and a Lingua Libre 'deadline'; nothing else."""

    def __init__(self):
        self.calls = []

    def __call__(self, url):
        self.calls.append(url)
        if url.startswith("https://upload/"):
            return _ogg()
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
        if query.get("list") == "search":
            hits = [{"title": "File:LL-Q1860 (eng)-Someone-deadline.wav"}] if '"deadline"' in query["srsearch"] else []
            return json.dumps({"query": {"search": hits}}).encode()
        title = query["titles"]
        if title in ("File:En-us-schedule.ogg", "File:LL-Q1860 (eng)-Someone-deadline.wav"):
            info = {"url": "https://upload/" + title, "extmetadata": {
                "LicenseShortName": {"value": "CC BY-SA 3.0"},
                "Artist": {"value": '<a href="//commons.wikimedia.org/wiki/User:Ví_dụ">Ví dụ</a>'}}}
            return json.dumps({"query": {"pages": {"1": {"imageinfo": [info]}}}}).encode()
        return json.dumps({"query": {"pages": {"-1": {"missing": ""}}}}).encode()


def test_us_recording_is_decoded_trimmed_and_cached(tmp_path):
    fake = FakeCommons()
    audio = WordAudio(http_get=fake, cache_dir=tmp_path)
    wav, rec = audio.get("schedule")
    data, rate = sf.read(io.BytesIO(wav))
    assert rate == 16000 and len(data) < 0.85 * rate  # 1 s of silence trimmed away
    assert rec.accent == "en-US" and rec.license == "CC BY-SA 3.0" and rec.artist == "Ví dụ"
    calls = len(fake.calls)
    assert audio.get("Schedule")[1] == rec
    assert len(fake.calls) == calls


def test_falls_back_to_lingua_libre_then_caches_misses(tmp_path):
    fake = FakeCommons()
    audio = WordAudio(http_get=fake, cache_dir=tmp_path)
    rec = audio.get("deadline")[1]
    assert rec.accent == "unspecified" and rec.artist == "Ví dụ"
    assert audio.get("postpone") is None
    calls = len(fake.calls)
    assert audio.get("postpone") is None
    assert len(fake.calls) == calls


def test_endpoint_returns_wav_with_attribution(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "get_word_audio", lambda: WordAudio(http_get=FakeCommons(), cache_dir=tmp_path))
    c = TestClient(main.app)
    r = c.get("/v1/audio/word/schedule")
    assert r.status_code == 200 and r.headers["content-type"] == "audio/wav"
    assert urllib.parse.unquote(r.headers["x-audio-artist"]) == "Ví dụ"
    assert c.get("/v1/audio/word/postpone").status_code == 404
    assert c.get("/v1/audio/word/two words").status_code == 422


def test_rate_limit_fails_fast_and_pauses_lookups(tmp_path, monkeypatch):
    """upload.wikimedia.org answered 429 with Retry-After: 120; the app must not wait on it."""
    from app.word_audio import Throttled, USER_AGENT
    assert "https://" in USER_AGENT and "(" in USER_AGENT
    now = [100.0]

    class Busy(FakeCommons):
        def __call__(self, url):
            if url.startswith("https://upload/"):
                self.calls.append(url)
                raise Throttled(120)
            return super().__call__(url)

    fake = Busy()
    audio = WordAudio(http_get=fake, cache_dir=tmp_path, clock=lambda: now[0])
    import pytest
    with pytest.raises(Throttled):
        audio.get("schedule")
    calls = len(fake.calls)
    with pytest.raises(Throttled):
        audio.get("deadline")
    assert len(fake.calls) == calls, "looked up Commons again while throttled"
    now[0] += 121
    fake.__class__ = FakeCommons
    assert audio.get("schedule")[1].accent == "en-US"
    monkeypatch.setattr(main, "get_word_audio", lambda: WordAudio(http_get=Busy(), cache_dir=tmp_path / "x"))
    r = TestClient(main.app).get("/v1/audio/word/schedule")
    assert r.status_code == 503 and int(r.headers["retry-after"]) >= 120
