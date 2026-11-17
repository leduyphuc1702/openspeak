"""One client for every LLM use in the app: pronunciation feedback, topic
vocabulary, the personal path, roleplay, and mouth-shape coaching from video
frames.

Three wire formats are supported, named as in most LLM gateways:

- ``openai-chat-completions``: POST {base}/chat/completions (OpenAI, OpenRouter, Groq, Ollama, vLLM...)
- ``openai-responses``: POST {base}/responses (OpenAI Responses API)
- ``anthropic-messages``: POST {base}/v1/messages (Anthropic Messages API)

Image inputs need a vision-capable model (set the vision model if it differs).
"""
from __future__ import annotations

import base64
import ipaddress
import json
import os
import re
import socket
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Sequence
from urllib.parse import urlsplit

CHAT_COMPLETIONS = "openai-chat-completions"
RESPONSES = "openai-responses"
ANTHROPIC = "anthropic-messages"
FORMATS = (CHAT_COMPLETIONS, RESPONSES, ANTHROPIC)
ANTHROPIC_VERSION = "2023-06-01"
# Required by the Messages API. Models with built-in (adaptive) thinking spend part of it thinking before
# they write, and a full lesson or exam can need 5-6k tokens in total, so leave plenty of room.
MAX_TOKENS = 16000
JSON_ONLY = "Trả về đúng một đối tượng JSON, không kèm chữ nào khác."


class LLMUnavailable(RuntimeError):
    pass


class LLMConfigError(ValueError):
    pass


@dataclass
class Image:
    jpeg: bytes
    caption: str


def _data_url(img: Image) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(img.jpeg).decode()


class LLMClient:
    def __init__(self, base_url: str, api_key: str, model: str, vision_model: Optional[str] = None,
                 timeout: float = 60.0, api_format: str = CHAT_COMPLETIONS):
        if api_format not in FORMATS:
            raise LLMConfigError(f"unknown LLM format {api_format!r}; use one of {', '.join(FORMATS)}")
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.vision_model = vision_model or model
        self.timeout = timeout
        self.api_format = api_format

    def chat(self, system: str, user: str, images: Sequence[Image] = (), json_mode: bool = False, temperature: float = 0.4) -> str:
        model = self.vision_model if images else self.model
        build = {CHAT_COMPLETIONS: self._chat_completions, RESPONSES: self._responses, ANTHROPIC: self._anthropic}
        url, headers, body, optional, read = build[self.api_format](model, system, user, images, json_mode, temperature)
        return read(self._post(url, headers, body, optional)).strip()

    def chat_json(self, system: str, user: str, images: Sequence[Image] = ()) -> Any:
        return parse_json(self.chat(system, user, images, json_mode=True))

    def _post(self, url: str, headers: Dict[str, str], body: Dict[str, Any], optional: Sequence[str]) -> Dict[str, Any]:
        """POST, dropping an optional parameter (temperature, JSON mode) once if the model rejects it."""
        import httpx

        body = dict(body)
        while True:
            resp = httpx.post(url, headers=headers, json=body, timeout=self.timeout)
            rejected = [p for p in optional if p in body and p in resp.text] if resp.status_code == 400 else []
            if not rejected:
                resp.raise_for_status()
                return resp.json()
            body.pop(rejected[0])

    def _bearer(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}

    def _chat_completions(self, model, system, user, images, json_mode, temperature):
        content: Any = user
        if images:
            content = [{"type": "text", "text": user}]
            for img in images:
                content.append({"type": "text", "text": img.caption})
                content.append({"type": "image_url", "image_url": {"url": _data_url(img)}})
        body: Dict[str, Any] = {
            "model": model,
            "temperature": temperature,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
        }
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        return (f"{self.base_url}/chat/completions", self._bearer(), body,
                ("response_format", "temperature"), _read_chat_completions)

    def _responses(self, model, system, user, images, json_mode, temperature):
        content: List[Dict[str, Any]] = [{"type": "input_text", "text": user}]
        for img in images:
            content.append({"type": "input_text", "text": img.caption})
            content.append({"type": "input_image", "image_url": _data_url(img)})
        if json_mode:
            # JSON mode is refused unless the input itself (not the instructions) mentions JSON.
            content.append({"type": "input_text", "text": JSON_ONLY})
        body: Dict[str, Any] = {
            "model": model,
            "instructions": system,
            "input": [{"role": "user", "content": content}],
            "temperature": temperature,
        }
        if json_mode:
            body["text"] = {"format": {"type": "json_object"}}
        return f"{self.base_url}/responses", self._bearer(), body, ("text", "temperature"), _read_responses

    def _anthropic(self, model, system, user, images, json_mode, temperature):
        content: List[Dict[str, Any]] = [{"type": "text", "text": user}]
        for img in images:
            content.append({"type": "text", "text": img.caption})
            content.append({"type": "image", "source": {
                "type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(img.jpeg).decode()}})
        if json_mode:
            content.append({"type": "text", "text": JSON_ONLY})
        body: Dict[str, Any] = {
            "model": model,
            "max_tokens": MAX_TOKENS,
            "system": system,
            "messages": [{"role": "user", "content": content}],
            "temperature": temperature,
        }
        base = self.base_url if self.base_url.endswith("/v1") else self.base_url + "/v1"
        headers = {"anthropic-version": ANTHROPIC_VERSION}
        if self.api_key:
            headers["x-api-key"] = self.api_key
        return f"{base}/messages", headers, body, ("temperature",), _read_anthropic


def _read_chat_completions(data: Dict[str, Any]) -> str:
    content = data["choices"][0]["message"].get("content")
    if isinstance(content, list):
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    if not content:
        raise ValueError("LLM returned no text")
    return content


def _read_responses(data: Dict[str, Any]) -> str:
    if isinstance(data.get("output_text"), str) and data["output_text"]:
        return data["output_text"]
    parts = [c.get("text", "")
             for item in data.get("output") or [] if item.get("type") == "message"
             for c in item.get("content") or [] if c.get("type") in ("output_text", "text")]
    if not any(parts):
        raise ValueError("LLM returned no text")
    return "".join(parts)


def _read_anthropic(data: Dict[str, Any]) -> str:
    parts = [b.get("text", "") for b in data.get("content") or [] if b.get("type") == "text"]
    if not any(parts):
        if data.get("stop_reason") == "max_tokens":
            raise ValueError("LLM used its whole token budget (max_tokens) before writing an answer")
        raise ValueError("LLM returned no text")
    return "".join(parts)


def parse_json(text: str) -> Any:
    """Parse model output that may be wrapped in a ```json fence or surrounded by a sentence."""
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    text = fenced.group(1) if fenced else text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            raise
        return json.loads(text[start:end + 1])


def env_timeout() -> float:
    # A thinking model writing a whole exam was measured at about 110 s; the app waits up to 180 s.
    return float(os.getenv("LLM_TIMEOUT", "160"))


def client_from_env() -> Optional[LLMClient]:
    base_url, model = os.getenv("LLM_BASE_URL"), os.getenv("LLM_MODEL")
    if not (base_url and model):
        return None
    return LLMClient(base_url, os.getenv("LLM_API_KEY", ""), model, os.getenv("LLM_VISION_MODEL"),
                     timeout=env_timeout(),
                     api_format=os.getenv("LLM_API_FORMAT", CHAT_COMPLETIONS))


# --- The learner's own LLM, sent by the app with each request ---

HEADER_FORMAT = "x-llm-format"
HEADER_BASE_URL = "x-llm-base-url"
HEADER_MODEL = "x-llm-model"
HEADER_VISION_MODEL = "x-llm-vision-model"
HEADER_KEY = "x-llm-key"


def _check_base_url(url: str, allow_private: bool, resolve: Callable[[str], List[str]]) -> None:
    """The server makes the request, so a learner-supplied URL must not reach the server's own network."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise LLMConfigError("Địa chỉ LLM phải bắt đầu bằng https://")
    if allow_private:
        return
    if parts.scheme != "https":
        raise LLMConfigError("Địa chỉ LLM phải dùng https:// để khoá API không bị gửi dạng chữ thường")
    try:
        addresses = resolve(parts.hostname)
    except OSError:
        raise LLMConfigError(f"Không tìm thấy máy chủ {parts.hostname}")
    for address in addresses:
        ip = ipaddress.ip_address(address.split("%")[0])
        if not ip.is_global:
            raise LLMConfigError(f"Máy chủ {parts.hostname} trỏ vào mạng nội bộ ({ip}), không dùng được")


def _resolve(host: str) -> List[str]:
    return sorted({info[4][0] for info in socket.getaddrinfo(host, None)})


def client_from_headers(headers: Dict[str, str], allow_private: bool = False,
                        resolve: Optional[Callable[[str], List[str]]] = None) -> Optional[LLMClient]:
    """The LLM the learner set up in the app, or None if the request carries none.

    Headers are lower-case. Raises LLMConfigError for an incomplete or unsafe setup.
    """
    base_url = headers.get(HEADER_BASE_URL, "").strip()
    model = headers.get(HEADER_MODEL, "").strip()
    if not base_url and not model:
        return None
    if not (base_url and model):
        raise LLMConfigError("Cần cả địa chỉ và tên mô hình LLM")
    api_format = headers.get(HEADER_FORMAT, CHAT_COMPLETIONS).strip() or CHAT_COMPLETIONS
    if api_format not in FORMATS:
        raise LLMConfigError(f"Định dạng LLM không hỗ trợ: {api_format}")
    _check_base_url(base_url, allow_private, resolve or _resolve)
    return LLMClient(base_url, headers.get(HEADER_KEY, "").strip(), model,
                     headers.get(HEADER_VISION_MODEL, "").strip() or None,
                     timeout=env_timeout(), api_format=api_format)


def require(client: Optional[LLMClient]) -> LLMClient:
    if client is None:
        raise LLMUnavailable("LLM is not configured (set LLM_BASE_URL and LLM_MODEL)")
    return client
