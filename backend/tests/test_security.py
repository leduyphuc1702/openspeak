"""Access keys, rate limits and body limits for a server shared by several learners."""
import logging

from fastapi.testclient import TestClient

from app import main


def _client() -> TestClient:
    return TestClient(main.app)


def test_open_server_without_keys(monkeypatch):
    monkeypatch.delenv("OPENSPEAK_API_KEYS", raising=False)
    c = _client()
    assert c.get("/v1/topics").status_code == 200
    assert c.get("/health").json()["auth_required"] is False


def test_key_required_and_accepted_in_both_headers(monkeypatch):
    monkeypatch.setenv("OPENSPEAK_API_KEYS", "alpha, beta")
    c = _client()
    assert c.get("/v1/topics").status_code == 401
    assert c.get("/v1/topics", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert c.get("/v1/topics", headers={"Authorization": "Bearer alpha"}).status_code == 200
    assert c.get("/v1/topics", headers={"X-API-Key": "beta"}).status_code == 200
    assert c.get("/health").status_code == 200
    assert c.get("/health").json()["auth_required"] is True


def test_rate_limit_is_per_key_and_health_stays_open(monkeypatch):
    monkeypatch.setenv("OPENSPEAK_API_KEYS", "limited")
    monkeypatch.setenv("OPENSPEAK_RATE_LIMIT", "2")
    c = _client()
    headers = {"Authorization": "Bearer limited"}
    assert c.get("/v1/topics", headers=headers).status_code == 200
    assert c.get("/v1/topics", headers=headers).status_code == 200
    third = c.get("/v1/topics", headers=headers)
    assert third.status_code == 429
    assert third.headers["retry-after"].isdigit()
    assert third.json()["detail"]["code"] == "rate_limited"
    assert c.get("/health").status_code == 200


def test_large_body_is_refused(monkeypatch):
    monkeypatch.setenv("OPENSPEAK_API_KEYS", "big")
    monkeypatch.setenv("OPENSPEAK_MAX_BODY_MB", "1")
    c = _client()
    payload = {"sound": "iː", "topics": ["travel"], "pad": "a" * (2 * 1024 * 1024)}
    response = c.post("/v1/exercises", json=payload, headers={"Authorization": "Bearer big"})
    assert response.status_code == 413
    assert response.json()["detail"]["code"] == "too_large"


def test_access_log_never_contains_the_key(monkeypatch, caplog):
    monkeypatch.setenv("OPENSPEAK_API_KEYS", "very-secret-key")
    caplog.set_level(logging.INFO, logger="openspeak.access")
    _client().get("/v1/topics", headers={"Authorization": "Bearer very-secret-key"})
    assert "very-secret-key" not in caplog.text
    assert "openspeak.access" in caplog.text
