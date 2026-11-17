"""AI roleplay: short workplace conversations with tasks, corrected turn by turn.

Scenarios are seeded (work without an LLM); the conversation itself needs the
user's LLM. Every LLM output is normalized before it reaches the app.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Sequence

from .llm import LLMClient

SCENARIOS: List[Dict[str, Any]] = [
    {"id": "standup", "title": "Daily stand-up update", "title_vi": "Báo cáo trong họp giao ban", "minutes": "3-5",
     "level": "Dễ", "partner": "your team lead", "setting_vi": "Họp nhanh buổi sáng với trưởng nhóm.",
     "tasks": [{"en": "Say what you finished yesterday.", "vi": "Nói việc bạn đã xong hôm qua."},
               {"en": "Say what you will do today.", "vi": "Nói việc bạn sẽ làm hôm nay."},
               {"en": "Mention one blocker and ask for help.", "vi": "Nêu một vướng mắc và nhờ hỗ trợ."}],
     "opening": "Morning! Let's go around quickly. What's your update today?"},
    {"id": "meeting_reschedule", "title": "Rescheduling a meeting", "title_vi": "Dời lịch họp", "minutes": "3-5",
     "level": "Dễ", "partner": "a colleague from another team", "setting_vi": "Bạn cần dời cuộc họp vì trùng lịch.",
     "tasks": [{"en": "Explain why you can't make the meeting.", "vi": "Giải thích vì sao bạn không dự được."},
               {"en": "Suggest two new times.", "vi": "Đề xuất hai khung giờ mới."},
               {"en": "Confirm the new time and say thanks.", "vi": "Chốt giờ mới và cảm ơn."}],
     "opening": "Hi, I saw your message about tomorrow's meeting. What's going on?"},
    {"id": "laptop", "title": "Choosing a laptop for work", "title_vi": "Chọn laptop cho công việc", "minutes": "3-5",
     "level": "Trung bình", "partner": "an IT colleague", "setting_vi": "Bạn nhờ đồng nghiệp IT tư vấn máy mới.",
     "tasks": [{"en": "Ask for a laptop recommendation.", "vi": "Nhờ gợi ý một chiếc laptop."},
               {"en": "Say what you will use it for.", "vi": "Nói bạn dùng máy để làm gì."},
               {"en": "Say which specs matter to you.", "vi": "Nói cấu hình nào quan trọng với bạn."}],
     "opening": "Hey! I heard you need a new laptop. How can I help?"},
    {"id": "client_call", "title": "First call with a client", "title_vi": "Cuộc gọi đầu tiên với khách hàng",
     "minutes": "5-7", "level": "Trung bình", "partner": "a new client", "setting_vi": "Gọi giới thiệu và tìm hiểu nhu cầu.",
     "tasks": [{"en": "Introduce yourself and your role.", "vi": "Giới thiệu bản thân và vai trò."},
               {"en": "Ask about the client's main problem.", "vi": "Hỏi vấn đề chính của khách."},
               {"en": "Agree on the next step.", "vi": "Thống nhất bước tiếp theo."}],
     "opening": "Hello, this is Sarah from Northwind. Thanks for calling. Who am I speaking with?"},
    {"id": "deadline", "title": "Asking for more time", "title_vi": "Xin lùi hạn chót", "minutes": "3-5",
     "level": "Trung bình", "partner": "your manager", "setting_vi": "Dự án có thể trễ, bạn cần xin thêm thời gian.",
     "tasks": [{"en": "Explain the problem clearly.", "vi": "Trình bày vấn đề rõ ràng."},
               {"en": "Propose a new deadline.", "vi": "Đề xuất hạn mới."},
               {"en": "Offer a plan to reduce the risk.", "vi": "Đưa ra kế hoạch giảm rủi ro."}],
     "opening": "You wanted to talk about the project? Sure, what's up?"},
    {"id": "presentation_qa", "title": "Answering questions after a presentation", "title_vi": "Trả lời câu hỏi sau thuyết trình",
     "minutes": "5-7", "level": "Khó", "partner": "a senior stakeholder", "setting_vi": "Bạn vừa trình bày kết quả quý.",
     "tasks": [{"en": "Summarize your main point in one sentence.", "vi": "Tóm tắt ý chính trong một câu."},
               {"en": "Answer a question with a number or example.", "vi": "Trả lời kèm số liệu hoặc ví dụ."},
               {"en": "Handle a question you can't answer yet.", "vi": "Xử lý câu hỏi bạn chưa trả lời được."}],
     "opening": "Thanks for the presentation. Can you tell me in one sentence what the key takeaway is?"},
    {"id": "salary", "title": "Asking for a raise", "title_vi": "Đề nghị tăng lương", "minutes": "5-7",
     "level": "Khó", "partner": "your manager", "setting_vi": "Buổi nói chuyện một-một với quản lý.",
     "tasks": [{"en": "Say what you want to discuss.", "vi": "Nói rõ điều bạn muốn trao đổi."},
               {"en": "Give two achievements as evidence.", "vi": "Nêu hai thành tích làm bằng chứng."},
               {"en": "Respond politely to a 'not now'.", "vi": "Phản hồi lịch sự khi bị từ chối tạm thời."}],
     "opening": "Come in, have a seat. You said you wanted to talk about something?"},
    {"id": "lunch", "title": "Small talk at lunch", "title_vi": "Nói chuyện phiếm giờ trưa", "minutes": "3-5",
     "level": "Dễ", "partner": "a friendly coworker", "setting_vi": "Ăn trưa cùng đồng nghiệp mới.",
     "tasks": [{"en": "Ask about their weekend.", "vi": "Hỏi về cuối tuần của họ."},
               {"en": "Talk about a hobby of yours.", "vi": "Kể về một sở thích của bạn."},
               {"en": "Suggest having lunch again.", "vi": "Rủ ăn trưa lần sau."}],
     "opening": "Mind if I sit here? I don't think we've really talked before. I'm Alex."},
]
_BY_ID = {s["id"]: s for s in SCENARIOS}

SCENARIO_PROMPT = (
    "Bạn thiết kế bài nhập vai hội thoại tiếng Anh nơi công sở cho người Việt đi làm. "
    "Từ chủ đề và trình độ, tạo một tình huống ngắn. Trả về JSON: "
    '{"title": "tiếng Anh", "title_vi": "tiếng Việt", "minutes": "3-5", "level": "Dễ|Trung bình|Khó", '
    '"partner": "vai của AI, tiếng Anh", "setting_vi": "bối cảnh 1 câu", '
    '"tasks": [{"en": "...", "vi": "..."}] (đúng 3 nhiệm vụ), "opening": "câu mở đầu của AI, tiếng Anh tự nhiên"}'
)

TURN_PROMPT = (
    "Bạn đóng vai {partner} trong tình huống: {title}. Bối cảnh: {setting}. "
    "Học viên là người Việt đi làm, trình độ {level}. Nhiệm vụ của học viên: {tasks}. "
    "Đọc lịch sử hội thoại và câu mới nhất của học viên, rồi: (1) trả lời tự nhiên, ngắn (1-2 câu), "
    "ở đúng trình độ, và gợi mở để học viên làm nhiệm vụ còn lại; (2) sửa lỗi ngữ pháp/từ vựng/diễn đạt "
    "chưa tự nhiên trong câu mới nhất (tối đa 3 lỗi, bỏ qua lỗi viết hoa và dấu câu vì câu đến từ nhận dạng giọng nói); "
    "Câu nói được nhận dạng từ giọng nói, nên một từ lạc ngữ cảnh có thể do phát âm sai (ví dụ 'sink' thay cho "
    "'think', 'ship' thay cho 'sheep'): khi đó thêm vào corrections và giải thích cách phát âm từ đúng trong explain_vi. "
    "(3) đánh dấu nhiệm vụ nào học viên đã hoàn thành tính đến giờ. Trả về JSON: "
    '{{"reply": "...", "corrections": [{{"original": "...", "better": "...", "explain_vi": "..."}}], '
    '"tasks_done": [true/false, ...], "better_version": "cả câu của học viên viết lại tự nhiên hơn", '
    '"hint_vi": "gợi ý ngắn cho lượt tiếp theo"}}'
)


def _text(value: Any, limit: int = 400) -> str:
    return value.strip()[:limit] if isinstance(value, str) else ""


def scenario(scenario_id: str) -> Optional[Dict[str, Any]]:
    return _BY_ID.get(scenario_id)


def clean_scenario(raw: Any, fallback_id: str = "custom") -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict):
        return None
    tasks = [{"en": _text(t.get("en"), 160), "vi": _text(t.get("vi"), 160)}
             for t in raw.get("tasks", []) if isinstance(t, dict) and _text(t.get("en"))][:3]
    title, opening = _text(raw.get("title"), 80), _text(raw.get("opening"), 300)
    if not (title and opening and tasks):
        return None
    level = raw.get("level") if raw.get("level") in ("Dễ", "Trung bình", "Khó") else "Trung bình"
    return {"id": fallback_id, "title": title, "title_vi": _text(raw.get("title_vi"), 80) or title,
            "minutes": _text(raw.get("minutes"), 10) or "3-5", "level": level,
            "partner": _text(raw.get("partner"), 60) or "a colleague",
            "setting_vi": _text(raw.get("setting_vi"), 200), "tasks": tasks, "opening": opening}


def clean_turn(raw: Any, task_count: int) -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict) or not _text(raw.get("reply")):
        return None
    corrections = []
    for c in raw.get("corrections", []) or []:
        if isinstance(c, dict) and _text(c.get("original")) and _text(c.get("better")):
            if _text(c.get("original")).lower() != _text(c.get("better")).lower():
                corrections.append({"original": _text(c["original"], 200), "better": _text(c["better"], 200),
                                    "explain_vi": _text(c.get("explain_vi"), 240)})
    done = raw.get("tasks_done") if isinstance(raw.get("tasks_done"), list) else []
    done = [bool(d) for d in done[:task_count]] + [False] * max(0, task_count - len(done))
    return {"reply": _text(raw["reply"], 500), "corrections": corrections[:3], "tasks_done": done,
            "better_version": _text(raw.get("better_version"), 400) or None,
            "hint_vi": _text(raw.get("hint_vi"), 200) or None}


def generate_scenario(client: LLMClient, topic: str, level: str) -> Optional[Dict[str, Any]]:
    data = client.chat_json(SCENARIO_PROMPT, json.dumps({"topic": topic, "level": level}, ensure_ascii=False))
    return clean_scenario(data)


def take_turn(client: LLMClient, sc: Dict[str, Any], history: Sequence[Dict[str, str]], message: str,
              level: str) -> Optional[Dict[str, Any]]:
    tasks = "; ".join(f"{i + 1}. {t['en']}" for i, t in enumerate(sc["tasks"]))
    system = TURN_PROMPT.format(partner=sc["partner"], title=sc["title"], setting=sc.get("setting_vi", ""),
                                level=level, tasks=tasks)
    lines = [f"{'AI' if h.get('role') == 'ai' else 'Học viên'}: {_text(h.get('text'), 500)}" for h in history[-12:]]
    lines.append(f"Học viên (câu mới nhất): {_text(message, 500)}")
    return clean_turn(client.chat_json(system, "\n".join(lines)), len(sc["tasks"]))
