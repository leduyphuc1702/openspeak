import copy

import httpx
import pytest
from fastapi.testclient import TestClient

from app import llm, main
from app.llm import ANTHROPIC, CHAT_COMPLETIONS, RESPONSES, Image, LLMClient, LLMConfigError, client_from_headers


class Recorder:
    """Stands in for httpx.post: records each call and answers from a queue."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, url, headers=None, json=None, timeout=None):
        self.calls.append({"url": url, "headers": headers, "json": copy.deepcopy(json)})
        status, payload = self.answers.pop(0)
        request = httpx.Request("POST", url)
        if isinstance(payload, str):
            return httpx.Response(status, text=payload, request=request)
        return httpx.Response(status, json=payload, request=request)


@pytest.fixture
def post(monkeypatch):
    def install(*answers):
        rec = Recorder(*answers)
        monkeypatch.setattr(httpx, "post", rec)
        return rec
    return install


def test_chat_completions_format(post):
    rec = post((200, {"choices": [{"message": {"content": '{"a": 1}'}}]}))
    client = LLMClient("https://api.example.com/v1/", "sk-1", "m")
    assert client.chat_json("sys", "hi") == {"a": 1}
    call = rec.calls[0]
    assert call["url"] == "https://api.example.com/v1/chat/completions"
    assert call["headers"] == {"Authorization": "Bearer sk-1"}
    assert call["json"]["messages"][0] == {"role": "system", "content": "sys"}
    assert call["json"]["response_format"] == {"type": "json_object"}


def test_responses_format_reads_output_items(post):
    rec = post((200, {"output": [
        {"type": "reasoning", "summary": []},
        {"type": "message", "content": [{"type": "output_text", "text": '{"b": 2}'}]},
    ]}))
    client = LLMClient("https://api.example.com/v1", "sk-2", "m", vision_model="v", api_format=RESPONSES)
    assert client.chat_json("sys", "hi", [Image(b"\xff\xd8", "frame 1")]) == {"b": 2}
    call = rec.calls[0]
    assert call["url"] == "https://api.example.com/v1/responses"
    body = call["json"]
    assert body["model"] == "v" and body["instructions"] == "sys"
    assert body["text"] == {"format": {"type": "json_object"}}
    kinds = [c["type"] for c in body["input"][0]["content"]]
    assert kinds == ["input_text", "input_text", "input_image", "input_text"]
    assert "JSON" in body["input"][0]["content"][3]["text"]
    assert body["input"][0]["content"][2]["image_url"].startswith("data:image/jpeg;base64,")


def test_anthropic_format(post):
    rec = post((200, {"content": [{"type": "thinking", "thinking": "..."},
                                  {"type": "text", "text": 'Here you go: {"c": 3}'}]}))
    client = LLMClient("http://localhost:8081", "key-3", "claude-x", api_format=ANTHROPIC)
    assert client.chat_json("sys", "hi", [Image(b"\xff\xd8", "frame")]) == {"c": 3}
    call = rec.calls[0]
    assert call["url"] == "http://localhost:8081/v1/messages"
    assert call["headers"] == {"anthropic-version": "2023-06-01", "x-api-key": "key-3"}
    body = call["json"]
    assert body["system"] == "sys" and body["max_tokens"] > 0
    image = body["messages"][0]["content"][2]
    assert image["type"] == "image" and image["source"]["media_type"] == "image/jpeg"


def test_anthropic_base_with_v1_is_not_doubled(post):
    rec = post((200, {"content": [{"type": "text", "text": "ok"}]}))
    LLMClient("https://api.anthropic.com/v1", "k", "m", api_format=ANTHROPIC).chat("s", "u")
    assert rec.calls[0]["url"] == "https://api.anthropic.com/v1/messages"


def test_a_rejected_temperature_is_dropped_and_retried(post):
    rec = post((400, '{"error": {"message": "Unsupported parameter: temperature"}}'),
               (200, {"choices": [{"message": {"content": "fine"}}]}))
    assert LLMClient("https://x.example/v1", "k", "m").chat("s", "u") == "fine"
    assert "temperature" in rec.calls[0]["json"] and "temperature" not in rec.calls[1]["json"]


def test_other_errors_are_raised(post):
    post((401, '{"error": "bad key"}'))
    with pytest.raises(httpx.HTTPStatusError):
        LLMClient("https://x.example/v1", "k", "m").chat("s", "u")


def test_unknown_format_is_refused():
    with pytest.raises(LLMConfigError):
        LLMClient("https://x.example", "k", "m", api_format="gemini")


def public(host):
    return ["104.18.2.3"]


def test_headers_build_the_learners_client():
    client = client_from_headers({"x-llm-format": ANTHROPIC, "x-llm-base-url": "https://api.anthropic.com",
                                  "x-llm-model": "claude-x", "x-llm-key": "k"}, resolve=public)
    assert (client.api_format, client.model, client.api_key) == (ANTHROPIC, "claude-x", "k")
    assert client_from_headers({}, resolve=public) is None


@pytest.mark.parametrize("headers", [
    {"x-llm-base-url": "https://api.example.com"},                                  # no model
    {"x-llm-base-url": "http://api.example.com", "x-llm-model": "m"},               # key would go out in clear text
    {"x-llm-base-url": "https://api.example.com", "x-llm-model": "m", "x-llm-format": "gemini"},
    {"x-llm-base-url": "ftp://api.example.com", "x-llm-model": "m"},
])
def test_bad_headers_are_refused(headers):
    with pytest.raises(LLMConfigError):
        client_from_headers(headers, resolve=public)


@pytest.mark.parametrize("address", ["127.0.0.1", "10.0.0.5", "172.17.0.2", "192.168.1.9", "169.254.169.254", "::1"])
def test_urls_into_the_servers_network_are_refused(address):
    with pytest.raises(LLMConfigError):
        client_from_headers({"x-llm-base-url": "https://sneaky.example", "x-llm-model": "m"},
                            resolve=lambda host: [address])


def test_private_urls_can_be_allowed_for_local_use():
    client = client_from_headers({"x-llm-base-url": "http://localhost:8081", "x-llm-model": "m"},
                                 allow_private=True, resolve=lambda host: ["127.0.0.1"])
    assert client.base_url == "http://localhost:8081"


def test_env_selects_the_format(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://x.example/v1")
    monkeypatch.setenv("LLM_MODEL", "m")
    monkeypatch.setenv("LLM_API_FORMAT", RESPONSES)
    assert llm.client_from_env().api_format == RESPONSES


def test_requests_use_the_learners_llm_over_the_servers(monkeypatch, post):
    monkeypatch.setattr(main, "get_server_llm", lambda: None)
    monkeypatch.setattr(llm, "_resolve", public)
    api = TestClient(main.app)
    assert api.get("/health").json()["llm_source"] is None

    headers = {"X-LLM-Format": CHAT_COMPLETIONS, "X-LLM-Base-URL": "https://api.example.com/v1",
               "X-LLM-Model": "m", "X-LLM-Key": "sk-own"}
    assert api.get("/health", headers=headers).json()["llm_source"] == "client"

    rec = post((200, {"choices": [{"message": {"content": '{"reply": "Hello!"}'}}]}))
    body = api.post("/v1/llm/check", headers=headers).json()
    assert body["reply"] == "Hello!" and body["source"] == "client" and body["model"] == "m"
    assert rec.calls[0]["headers"] == {"Authorization": "Bearer sk-own"}


def test_an_unsafe_learner_llm_gets_a_clear_error(monkeypatch):
    monkeypatch.setattr(llm, "_resolve", lambda host: ["127.0.0.1"])
    monkeypatch.delenv("LLM_ALLOW_PRIVATE_URLS", raising=False)
    resp = TestClient(main.app).get("/health", headers={"X-LLM-Base-URL": "https://evil.example", "X-LLM-Model": "m"})
    assert resp.status_code == 422
    assert resp.json()["detail"]["code"] == "bad_llm_config"


def test_check_reports_provider_errors(monkeypatch, post):
    monkeypatch.setattr(main, "get_server_llm", lambda: LLMClient("https://x.example/v1", "k", "m"))
    post((401, '{"error": "invalid api key"}'))
    resp = TestClient(main.app).post("/v1/llm/check")
    assert resp.status_code == 502
    assert resp.json()["detail"]["message"] == "LLM báo lỗi 401: invalid api key"


@pytest.mark.parametrize("body, shown", [
    ('{"error": {"message": "No such model", "type": "invalid_request_error"}}', "No such model"),
    ('{"type": "error", "error": {"type": "not_found_error", "message": "model: x"}}', "model: x"),
    ('{"message": "Invalid API key", "code": "INVALID_API_KEY"}', "Invalid API key"),
    ("upstream timeout", "upstream timeout"),
])
def test_provider_error_text(body, shown):
    assert main._provider_error(body) == shown


def test_anthropic_thinking_that_uses_the_whole_budget_is_reported():
    from app.llm import _read_anthropic
    import pytest as _pytest
    with _pytest.raises(ValueError, match="max_tokens"):
        _read_anthropic({"stop_reason": "max_tokens", "content": [{"type": "thinking", "thinking": ""}]})
    assert _read_anthropic({"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "{}"}]}) == "{}"
