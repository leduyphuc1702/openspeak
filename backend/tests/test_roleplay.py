import json

from fastapi.testclient import TestClient

from app import main, roleplay


class FakeLLM:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def chat_json(self, system, user, images=()):
        self.calls.append((system, user))
        return self.payload


def test_seed_scenarios_are_complete():
    for sc in roleplay.SCENARIOS:
        assert roleplay.clean_scenario(sc, sc["id"]) == sc
        assert len(sc["tasks"]) == 3


def test_clean_turn_normalizes_llm_output():
    raw = {"reply": " Sure, what time works? ", "tasks_done": [1, 0],
           "corrections": [{"original": "I very busy", "better": "I'm very busy", "explain_vi": "Thiếu động từ to be"},
                           {"original": "same", "better": "Same"}, "junk"]}
    turn = roleplay.clean_turn(raw, 3)
    assert turn["reply"] == "Sure, what time works?"
    assert turn["tasks_done"] == [True, False, False]
    assert [c["better"] for c in turn["corrections"]] == ["I'm very busy"]
    assert roleplay.clean_turn({"corrections": []}, 3) is None


def test_turn_prompt_includes_tasks_and_history():
    llm = FakeLLM({"reply": "Okay!", "tasks_done": [True, False, False]})
    sc = roleplay.scenario("standup")
    turn = roleplay.take_turn(llm, sc, [{"role": "ai", "text": sc["opening"]}], "I finished the login page", "B1-B2")
    system, user = llm.calls[0]
    assert "Say what you finished yesterday." in system
    assert "I finished the login page" in user and sc["opening"] in user
    assert turn["tasks_done"][0] is True


def test_roleplay_endpoints(monkeypatch):
    client = TestClient(main.app)
    assert len(client.get("/v1/roleplay/scenarios").json()["scenarios"]) == len(roleplay.SCENARIOS)
    assert client.post("/v1/roleplay/start", json={"scenario_id": "lunch"}).json()["id"] == "lunch"

    monkeypatch.setattr(main, "get_llm", lambda: None)
    body = {"scenario": roleplay.scenario("lunch"), "message": "Hi Alex, nice to meet you"}
    r = client.post("/v1/roleplay/turn", json=body)
    assert r.status_code == 503 and r.json()["detail"]["code"] == "llm_unavailable"

    monkeypatch.setattr(main, "get_llm", lambda: FakeLLM({"reply": "Nice to meet you too!", "tasks_done": []}))
    r = client.post("/v1/roleplay/turn", json=body)
    assert r.status_code == 200 and r.json()["tasks_done"] == [False, False, False]
    assert json.dumps(r.json(), ensure_ascii=False)
