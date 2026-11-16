from __future__ import annotations

import json
import logging
import mimetypes
import os
import urllib.parse
from functools import lru_cache
from typing import List, Optional

from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import articulation, connected_speech, roleplay, vocab
from .audio import load_audio
from .dictionary import OpenDictionary, define
from .feedback import pronunciation_feedback
from .llm import Image, LLMClient, client_from_env
from .phonetics import Lexicon, UnknownWordError, expected_intonation
from .scoring import Assessor, NoSpeechError
from .word_audio import WordAudio

log = logging.getLogger("phonopath")
app = FastAPI(title="PhonoPath pronunciation API", version="0.2.0")

# Optional folder of files to hand out (e.g. a test build of the iOS app), served at /download/.
if os.getenv("DOWNLOAD_DIR"):
    # Unknown extensions fall back to text/plain, which Safari would try to display.
    mimetypes.add_type("application/octet-stream", ".ipa")
    app.mount("/download", StaticFiles(directory=os.environ["DOWNLOAD_DIR"]), name="download")


@lru_cache(maxsize=1)
def get_lexicon() -> Lexicon:
    return Lexicon()


@lru_cache(maxsize=1)
def get_assessor() -> Assessor:
    from .recognizer import Wav2Vec2PhonemeRecognizer

    return Assessor(Wav2Vec2PhonemeRecognizer(), get_lexicon())


@lru_cache(maxsize=1)
def get_llm() -> Optional[LLMClient]:
    return client_from_env()


@lru_cache(maxsize=1)
def get_dictionary() -> OpenDictionary:
    return OpenDictionary()


@lru_cache(maxsize=1)
def get_word_audio() -> WordAudio:
    return WordAudio()


def _unknown(e: UnknownWordError) -> HTTPException:
    return HTTPException(422, {"code": "unknown_words", "words": e.words})


@app.get("/health")
def health():
    return {"ok": True, "llm": get_llm() is not None, "dictionary": get_dictionary().available}


@app.get("/v1/phonemize")
def phonemize(text: str):
    try:
        words = get_lexicon().sentence(text)
    except UnknownWordError as e:
        raise _unknown(e)
    except ValueError as e:
        raise HTTPException(422, {"code": "bad_text", "message": str(e)})
    links = connected_speech.find_links(words)
    return {
        "text": text,
        "intonation": expected_intonation(text),
        "connected_ipa": connected_speech.connected_transcription(words, links),
        "links": [l.to_dict() for l in links],
        "words": [
            {"word": w.word, "ipa": w.ipa, "phones": [{"id": p.id, "ipa": p.ipa, "stress": p.stress} for p in w.phones]}
            for w in words
        ],
    }


@app.post("/v1/assess")
async def assess(
    text: str = Form(...),
    audio: UploadFile = File(...),
    reference_audio: Optional[UploadFile] = File(None),
    feedback: bool = Form(True),
):
    wav = load_audio(await audio.read())
    ref = load_audio(await reference_audio.read()) if reference_audio is not None else None
    try:
        result = await run_in_threadpool(get_assessor().assess, wav, text, ref)
    except UnknownWordError as e:
        raise _unknown(e)
    except NoSpeechError:
        raise HTTPException(422, {"code": "no_speech", "message": "Không nghe thấy giọng nói"})
    except ValueError as e:
        raise HTTPException(422, {"code": "bad_audio", "message": str(e)})

    result["feedback"] = None
    if feedback:
        try:
            result["feedback"] = await run_in_threadpool(pronunciation_feedback, get_llm(), result)
        except Exception:  # feedback is optional; scores are still useful without it
            log.exception("LLM feedback failed")
    return result


# --- Mouth shape (khẩu hình) ---

@app.get("/v1/articulation/{phone_id}")
def articulation_guide(phone_id: str):
    art = articulation.ARTICULATION.get(phone_id.upper())
    if art is None:
        raise HTTPException(404, {"code": "unknown_phone"})
    return {"id": phone_id.upper(), "articulation": art.to_dict(), "steps": articulation.steps_vi(phone_id.upper())}


class LipSampleIn(BaseModel):
    index: int
    word: str
    phone_id: str
    time: float
    open: float
    width: float


class ArticulationRequest(BaseModel):
    text: str
    samples: List[LipSampleIn] = Field(default_factory=list)


@app.post("/v1/articulation-feedback")
async def articulation_feedback(payload: str = Form(...), frames: List[UploadFile] = File(default=[])):
    """Lip measurements (from on-device Vision) + optional mouth close-ups.

    Frames are JPEGs named "<sample index>.jpg". Rule-based lip checks always
    run; a vision LLM, if configured, adds advice on teeth and tongue.
    """
    try:
        req = ArticulationRequest(**json.loads(payload))
    except (ValueError, TypeError) as e:
        raise HTTPException(422, {"code": "bad_payload", "message": str(e)})
    samples = [articulation.LipSample(**s.model_dump()) for s in req.samples]
    findings = articulation.check_lips(samples)
    result = {"text": req.text, "findings": [f.to_dict() for f in findings], "coach": None}

    client = get_llm()
    if client is not None and frames:
        by_index = {s.index: s for s in samples}
        found = {f.index: f for f in findings}
        images = []
        for upload in frames[:8]:
            try:
                idx = int((upload.filename or "").split(".")[0])
            except ValueError:
                continue
            s = by_index.get(idx)
            if s is None:
                continue
            steps = "; ".join(articulation.steps_vi(s.phone_id))
            auto = found[idx].message if idx in found else ""
            images.append(Image(await upload.read(),
                                f"Khung {idx}: từ '{s.word}', âm {s.phone_id}. Khẩu hình chuẩn: {steps}. Đo tự động: {auto}"))
        if images:
            try:
                result["coach"] = articulation.clean_coach(await run_in_threadpool(
                    client.chat_json, articulation.ARTICULATION_PROMPT, f"Câu luyện: {req.text}", images))
            except Exception:
                log.exception("vision LLM failed")
    return result


# --- Vocabulary ---

@app.get("/v1/topics")
def topics():
    return {"topics": vocab.TOPICS}


class LessonRequest(BaseModel):
    topic: str
    level: str = "beginner"
    count: int = Field(8, ge=3, le=20)
    known: List[str] = Field(default_factory=list)


@app.post("/v1/vocab/lesson")
async def vocab_lesson(req: LessonRequest):
    try:
        return await run_in_threadpool(
            vocab.generate_lesson, get_llm(), get_lexicon(), req.topic, req.level, req.count, req.known)
    except Exception:
        log.exception("LLM lesson generation failed; serving starter words")
        return {"topic": req.topic, "title": vocab.TOPIC_TITLES.get(req.topic, req.topic), "source": "seed",
                "words": vocab.seed_lesson(get_lexicon(), req.topic)}


# --- AI roleplay ---

@app.get("/v1/roleplay/scenarios")
def roleplay_scenarios():
    return {"scenarios": roleplay.SCENARIOS}


class RoleplayStart(BaseModel):
    scenario_id: Optional[str] = None
    topic: Optional[str] = None
    level: str = "intermediate"


@app.post("/v1/roleplay/start")
async def roleplay_start(req: RoleplayStart):
    if req.scenario_id and roleplay.scenario(req.scenario_id):
        return roleplay.scenario(req.scenario_id)
    client = get_llm()
    if not req.topic:
        raise HTTPException(422, {"code": "bad_request", "message": "Chọn một tình huống có sẵn hoặc nhập chủ đề."})
    if client is None:
        raise HTTPException(503, {"code": "llm_unavailable", "message": "Chưa cấu hình LLM trên máy chủ."})
    try:
        sc = await run_in_threadpool(roleplay.generate_scenario, client, req.topic, vocab.LEVELS.get(req.level, req.level))
    except Exception:
        log.exception("roleplay scenario generation failed")
        sc = None
    if sc is None:
        raise HTTPException(502, {"code": "llm_failed", "message": "LLM không tạo được tình huống, thử lại."})
    return sc


class RoleplayTurn(BaseModel):
    scenario: dict
    history: List[dict] = Field(default_factory=list)
    message: str = Field(..., min_length=1, max_length=600)
    level: str = "intermediate"


@app.post("/v1/roleplay/turn")
async def roleplay_turn(req: RoleplayTurn):
    client = get_llm()
    if client is None:
        raise HTTPException(503, {"code": "llm_unavailable", "message": "Chưa cấu hình LLM trên máy chủ."})
    sc = roleplay.clean_scenario(req.scenario, str(req.scenario.get("id", "custom")))
    if sc is None:
        raise HTTPException(422, {"code": "bad_scenario", "message": "Tình huống không hợp lệ."})
    try:
        turn = await run_in_threadpool(roleplay.take_turn, client, sc, req.history, req.message,
                                       vocab.LEVELS.get(req.level, req.level))
    except Exception:
        log.exception("roleplay turn failed")
        turn = None
    if turn is None:
        raise HTTPException(502, {"code": "llm_failed", "message": "LLM không phản hồi được, thử lại."})
    return turn


@app.get("/v1/dictionary/{word}")
async def dictionary(word: str):
    try:
        return await run_in_threadpool(define, word, get_lexicon(), get_dictionary(), get_llm())
    except Exception:
        log.exception("dictionary lookup failed")
        return define(word, get_lexicon(), get_dictionary(), None)


@app.get("/v1/audio/word/{word}")
async def word_audio(word: str):
    """A real person saying the word (Wikimedia Commons), with attribution headers."""
    try:
        found = await run_in_threadpool(get_word_audio().get, word)
    except ValueError as e:
        raise HTTPException(422, {"code": "bad_word", "message": str(e)})
    except Exception:
        log.exception("word audio lookup failed")
        raise HTTPException(502, {"code": "commons_failed", "message": "Không lấy được audio từ Wikimedia Commons."})
    if found is None:
        raise HTTPException(404, {"code": "no_recording", "message": "Commons chưa có bản ghi cho từ này."})
    wav, rec = found
    quote = lambda v: urllib.parse.quote(v, safe=" ():/.,-")
    return Response(wav, media_type="audio/wav", headers={
        "X-Audio-License": quote(rec.license),
        "X-Audio-Artist": quote(rec.artist),
        "X-Audio-Source": quote(rec.page),
        "X-Audio-Accent": rec.accent,
        "Cache-Control": "max-age=2592000",
    })
