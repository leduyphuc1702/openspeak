from __future__ import annotations

import json
import logging
import mimetypes
import os
import time
import urllib.parse
from contextvars import ContextVar
from functools import lru_cache
from typing import List, Optional

from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import articulation, connected_speech, exam, exercises, path, roleplay, vocab, vocab_path
from .audio import load_audio
from .dictionary import OpenDictionary, define
from .feedback import pronunciation_feedback
from .llm import HEADER_BASE_URL, HEADER_MODEL, Image, LLMClient, LLMConfigError, client_from_env, client_from_headers
from .phonetics import PHONE_IPA, Lexicon, UnknownWordError, expected_intonation, tokenize
from .scoring import Assessor, NoSpeechError
from .security import SecurityMiddleware, access_info
from .word_audio import Throttled, WordAudio

log = logging.getLogger("openspeak")
app = FastAPI(title="OpenSpeak pronunciation API", version="0.3.0")

# Optional folder of files to hand out (e.g. a test build of the iOS app), served at /download/.
if os.getenv("DOWNLOAD_DIR"):
    # Unknown extensions fall back to text/plain. Over-the-air installs need these two types.
    mimetypes.add_type("application/octet-stream", ".ipa")
    mimetypes.add_type("text/xml", ".plist")
    app.mount("/download", StaticFiles(directory=os.environ["DOWNLOAD_DIR"]), name="download")


@lru_cache(maxsize=1)
def get_lexicon() -> Lexicon:
    return Lexicon()


@lru_cache(maxsize=1)
def get_assessor() -> Assessor:
    from .recognizer import Wav2Vec2PhonemeRecognizer

    return Assessor(Wav2Vec2PhonemeRecognizer(), get_lexicon())


@lru_cache(maxsize=1)
def get_server_llm() -> Optional[LLMClient]:
    return client_from_env()


_client_llm: ContextVar[Optional[LLMClient]] = ContextVar("client_llm", default=None)


def get_llm() -> Optional[LLMClient]:
    """The learner's own LLM if the app sent one with this request, else the server's."""
    return _client_llm.get() or get_server_llm()


class ClientLLM:
    """Reads the LLM the learner set up in the app (X-LLM-* headers) for the current request.

    The key is used for this request only; it is never stored or logged.
    Set LLM_CLIENT_CONFIG=0 to ignore these headers.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or os.getenv("LLM_CLIENT_CONFIG", "1") == "0":
            return await self.app(scope, receive, send)
        headers = {k.decode("latin-1").lower(): v.decode("latin-1")
                   for k, v in scope["headers"] if k.lower().startswith(b"x-llm-")}
        if not (headers.get(HEADER_BASE_URL) or headers.get(HEADER_MODEL)):
            return await self.app(scope, receive, send)
        try:
            client = await run_in_threadpool(client_from_headers, headers,
                                             os.getenv("LLM_ALLOW_PRIVATE_URLS") == "1")
        except LLMConfigError as e:
            response = JSONResponse({"detail": {"code": "bad_llm_config", "message": str(e)}}, status_code=422)
            return await response(scope, receive, send)
        token = _client_llm.set(client)
        try:
            await self.app(scope, receive, send)
        finally:
            _client_llm.reset(token)


app.add_middleware(ClientLLM)
# Added last, so it runs first: access key, rate limit and body size before any parsing.
app.add_middleware(SecurityMiddleware)


@lru_cache(maxsize=1)
def get_dictionary() -> OpenDictionary:
    return OpenDictionary()


@lru_cache(maxsize=1)
def get_word_audio() -> WordAudio:
    return WordAudio()


def _unknown(e: UnknownWordError) -> HTTPException:
    return HTTPException(422, {"code": "unknown_words", "words": e.words})


def known_words_only(lexicon: Lexicon, text: str):
    """The text without words the lexicon lacks, keeping a final '?' so intonation is still judged."""
    kept, skipped = [], []
    for word in tokenize(text):
        try:
            lexicon.lookup(word)
            kept.append(word)
        except UnknownWordError:
            skipped.append(word)
    if not kept:
        raise _unknown(UnknownWordError(skipped))
    return " ".join(kept) + ("?" if text.strip().endswith("?") else "."), skipped


@app.get("/health")
async def health():
    source = "client" if _client_llm.get() else "server" if get_server_llm() else None
    return {"ok": True, "llm": source is not None, "llm_source": source,
            "dictionary": get_dictionary().available, **access_info()}


def _provider_error(body: str) -> str:
    """The human-readable part of an OpenAI- or Anthropic-style error body, or the body itself."""
    try:
        data = json.loads(body)
    except ValueError:
        return body
    error = data.get("error", data) if isinstance(data, dict) else data
    if isinstance(error, dict) and isinstance(error.get("message"), str):
        return error["message"]
    if isinstance(error, str):
        return error
    return body


@app.post("/v1/llm/check")
async def llm_check():
    """One short call to the LLM in use, so the app can tell the learner whether their setup works."""
    client = get_llm()
    if client is None:
        raise HTTPException(503, {"code": "llm_unavailable", "message": "Chưa cấu hình LLM."})
    started = time.monotonic()
    try:
        reply = await run_in_threadpool(
            client.chat_json, 'Bạn kiểm tra kết nối. Trả về JSON {"reply": "<một câu chào ngắn bằng tiếng Anh>"}.',
            "ping")
    except Exception as e:
        status = getattr(getattr(e, "response", None), "status_code", None)
        body = getattr(getattr(e, "response", None), "text", "") or str(e)
        raise HTTPException(502, {"code": "llm_failed", "status": status,
                                  "message": f"LLM báo lỗi{f' {status}' if status else ''}: {_provider_error(body)[:300]}"})
    return {"ok": True, "format": client.api_format, "model": client.model,
            "source": "client" if _client_llm.get() else "server",
            "reply": str(reply.get("reply", "") if isinstance(reply, dict) else reply)[:200],
            "ms": round((time.monotonic() - started) * 1000)}


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
    skip_unknown: bool = Form(False),
):
    """skip_unknown is for free speech (a recognised conversation turn): words missing from the
    pronunciation dictionary, such as names, are left out of the score instead of failing it."""
    wav = load_audio(await audio.read())
    ref = load_audio(await reference_audio.read()) if reference_audio is not None else None
    skipped: List[str] = []
    if skip_unknown:
        text, skipped = known_words_only(get_lexicon(), text)
    try:
        result = await run_in_threadpool(get_assessor().assess, wav, text, ref)
    except UnknownWordError as e:
        raise _unknown(e)
    except NoSpeechError:
        raise HTTPException(422, {"code": "no_speech", "message": "Không nghe thấy giọng nói"})
    except ValueError as e:
        raise HTTPException(422, {"code": "bad_audio", "message": str(e)})

    result["skipped_words"] = skipped
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


@app.post("/v1/vocab/next")
async def vocab_next(req: vocab_path.VocabPathRequest):
    """The next lesson of the vocabulary programme, for the learner's topics, level and known words."""
    return await run_in_threadpool(vocab_path.next_lesson, get_llm(), get_lexicon(), req)


# --- Personal path ---

@app.post("/v1/path/next")
async def path_next(req: path.PathRequest):
    """The next lesson of the endless personal path, planned from the learner's results."""
    return await run_in_threadpool(path.next_lesson, get_llm(), get_lexicon(), req)


@app.post("/v1/path/exam")
async def path_exam(req: exam.ExamRequest):
    """A checkpoint exam on the sounds of the last few path lessons, written for the learner's topics."""
    return await run_in_threadpool(exam.next_exam, get_llm(), get_lexicon(), req)


@app.post("/v1/exercises")
async def sound_exercises(req: exercises.ExerciseRequest):
    """Listening and spelling questions for one sound (the foundation course)."""
    if req.sound not in PHONE_IPA:
        raise HTTPException(422, {"code": "unknown_sound", "sound": req.sound})
    return await run_in_threadpool(exercises.for_sound, get_llm(), get_lexicon(), req)


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
    except Throttled as e:
        log.warning("word audio: %s", e)
        raise HTTPException(503, {"code": "commons_busy", "message": "Wikimedia Commons đang giới hạn lượt tải."},
                            headers={"Retry-After": str(int(e.retry_after) + 1)})
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
