"""One client for every LLM use in the app: pronunciation feedback, topic
vocabulary, and mouth-shape coaching from video frames.

Any OpenAI-compatible /chat/completions endpoint works. Image inputs need a
vision-capable model (set LLM_VISION_MODEL if it differs from LLM_MODEL).
"""
from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from typing import Any, Dict, Optional, Sequence


class LLMUnavailable(RuntimeError):
    pass


@dataclass
class Image:
    jpeg: bytes
    caption: str


class LLMClient:
    def __init__(self, base_url: str, api_key: str, model: str, vision_model: Optional[str] = None, timeout: float = 45.0):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.vision_model = vision_model or model
        self.timeout = timeout

    def chat(self, system: str, user: str, images: Sequence[Image] = (), json_mode: bool = False, temperature: float = 0.4) -> str:
        import httpx

        if images:
            content: Any = [{"type": "text", "text": user}]
            for img in images:
                content.append({"type": "text", "text": img.caption})
                content.append({
                    "type": "image_url",
                    "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(img.jpeg).decode()},
                })
        else:
            content = user
        body: Dict[str, Any] = {
            "model": self.vision_model if images else self.model,
            "temperature": temperature,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
        }
        if json_mode:
            body["response_format"] = {"type": "json_object"}
        resp = httpx.post(
            f"{self.base_url}/chat/completions",
            headers={"Authorization": f"Bearer {self.api_key}"},
            json=body,
            timeout=self.timeout,
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"].strip()

    def chat_json(self, system: str, user: str, images: Sequence[Image] = ()) -> Any:
        return parse_json(self.chat(system, user, images, json_mode=True))


def parse_json(text: str) -> Any:
    """Parse model output that may be wrapped in a ```json fence."""
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    return json.loads(fenced.group(1) if fenced else text)


def client_from_env() -> Optional[LLMClient]:
    base_url, model = os.getenv("LLM_BASE_URL"), os.getenv("LLM_MODEL")
    if not (base_url and model):
        return None
    return LLMClient(base_url, os.getenv("LLM_API_KEY", ""), model, os.getenv("LLM_VISION_MODEL"))


def require(client: Optional[LLMClient]) -> LLMClient:
    if client is None:
        raise LLMUnavailable("LLM is not configured (set LLM_BASE_URL and LLM_MODEL)")
    return client
