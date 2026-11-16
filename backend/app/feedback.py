"""Pronunciation feedback. The LLM never hears audio: it only explains the
acoustic measurements produced by scoring.Assessor."""
from __future__ import annotations

import json
from typing import Dict, List, Optional

from .llm import LLMClient

SYSTEM_PROMPT = (
    "Bạn là giáo viên phát âm tiếng Anh cho người Việt. Bạn nhận kết quả đo âm học "
    "(điểm từng âm vị, âm nghe được thay vì âm đúng, trọng âm, ngữ điệu, nối âm, tốc độ). "
    "Chỉ dựa vào số liệu được cung cấp, không bịa thêm lỗi. Viết bằng tiếng Việt, "
    "tối đa 5 câu: khen điểm tốt nhất, chỉ ra 1-2 lỗi quan trọng nhất kèm cách đặt "
    "lưỡi/môi cụ thể theo từng bước, và một mẹo luyện tập."
)


def summarize(assessment: Dict) -> Dict:
    """Compact, model-friendly view: only the problems and the headline numbers."""
    issues: List[Dict] = []
    for w in assessment["words"]:
        for p in w["phones"]:
            if p["status"] != "good":
                issues.append({"word": w["word"], "expected": p["expected"], "heard": p["heard"],
                               "status": p["status"], "score": p["score"]})
        if w.get("stress") and not w["stress"]["correct"]:
            issues.append({"word": w["word"], "stress_expected_syllable": w["stress"]["expected"] + 1,
                           "stress_detected_syllable": w["stress"]["detected"] + 1})
    for link in assessment.get("linking", {}).get("links", []):
        if not link["linked"]:
            issues.append({"linking": link["display"], "type": link["type"], "problem": link["problem"]})
    issues.sort(key=lambda i: i.get("score", 50))
    return {
        "text": assessment["text"],
        "scores": assessment["scores"],
        "issues": issues[:8],
        "intonation": assessment["intonation"],
        "fluency": assessment["fluency"],
    }


def pronunciation_feedback(client: Optional[LLMClient], assessment: Dict) -> Optional[str]:
    if client is None:
        return None
    return client.chat(SYSTEM_PROMPT, json.dumps(summarize(assessment), ensure_ascii=False))
