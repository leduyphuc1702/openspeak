"""Articulatory targets per phone (khẩu hình).

One table drives three things: the parametric mouth diagrams in the iOS app,
the step-by-step Vietnamese instructions, and checking the learner's lips in
video (measured on-device with Vision face landmarks).
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Dict, List, Optional, Sequence


@dataclass(frozen=True)
class Pose:
    lips: str = "neutral"
    jaw: float = 0.3            # 0 closed .. 1 wide open
    tongue_height: float = 0.5  # body height, 0 low .. 1 high
    tongue_front: float = 0.5   # body position, 0 back .. 1 front
    tip: str = "rest"
    contact: bool = False       # tongue (or lips) fully block the air
    back_contact: bool = False  # back of tongue touches soft palate (k, g, ŋ)


@dataclass(frozen=True)
class Articulation:
    start: Pose
    end: Optional[Pose] = None  # diphthongs glide to this pose
    voiced: bool = True
    nasal: bool = False
    manner: str = "vowel"       # vowel, stop, fricative, affricate, nasal, approximant

    def to_dict(self) -> Dict:
        d = {"start": asdict(self.start), "voiced": self.voiced, "nasal": self.nasal, "manner": self.manner}
        d["end"] = asdict(self.end) if self.end else None
        return d


def _v(h: float, f: float, lips: str, jaw: float, tip: str = "rest") -> Pose:
    return Pose(lips=lips, jaw=jaw, tongue_height=h, tongue_front=f, tip=tip)


_IY = _v(.95, .95, "spread", .12)
_IH = _v(.80, .85, "neutral", .25)
_EH = _v(.55, .85, "neutral", .45)
_AA = _v(.12, .25, "neutral", .9)
_AO = _v(.35, .15, "rounded", .6)
_UH = _v(.75, .30, "rounded", .3)
_O = _v(.60, .20, "rounded", .4)

ARTICULATION: Dict[str, Articulation] = {
    "IY": Articulation(_IY), "IH": Articulation(_IH), "EH": Articulation(_EH),
    "AE": Articulation(_v(.25, .80, "spread", .8)), "AA": Articulation(_AA), "AO": Articulation(_AO),
    "UH": Articulation(_UH), "UW": Articulation(_v(.95, .20, "rounded", .12)),
    "AH": Articulation(_v(.45, .50, "neutral", .5)), "AX": Articulation(_v(.55, .55, "neutral", .3)),
    "ER": Articulation(_v(.60, .50, "rounded", .3, "retroflex")),
    "AXR": Articulation(_v(.60, .50, "neutral", .25, "retroflex")),
    "EY": Articulation(_EH, _IH), "AY": Articulation(_AA, _IH), "OY": Articulation(_AO, _IH),
    "AW": Articulation(_AA, _UH), "OW": Articulation(_O, _UH),

    "P": Articulation(Pose("closed", .1, contact=True), voiced=False, manner="stop"),
    "B": Articulation(Pose("closed", .1, contact=True), manner="stop"),
    "M": Articulation(Pose("closed", .1, contact=True), nasal=True, manner="nasal"),
    "T": Articulation(Pose("neutral", .2, .6, .7, "alveolar", contact=True), voiced=False, manner="stop"),
    "D": Articulation(Pose("neutral", .2, .6, .7, "alveolar", contact=True), manner="stop"),
    "N": Articulation(Pose("neutral", .2, .6, .7, "alveolar", contact=True), nasal=True, manner="nasal"),
    "L": Articulation(Pose("neutral", .25, .55, .7, "alveolar", contact=True), manner="approximant"),
    "K": Articulation(Pose("neutral", .25, 1.0, .1, back_contact=True), voiced=False, manner="stop"),
    "G": Articulation(Pose("neutral", .25, 1.0, .1, back_contact=True), manner="stop"),
    "NG": Articulation(Pose("neutral", .25, 1.0, .1, back_contact=True), nasal=True, manner="nasal"),
    "F": Articulation(Pose("labiodental", .15), voiced=False, manner="fricative"),
    "V": Articulation(Pose("labiodental", .15), manner="fricative"),
    "W": Articulation(Pose("rounded", .15, .9, .2), manner="approximant"),
    "TH": Articulation(Pose("neutral", .2, .5, .9, "dental"), voiced=False, manner="fricative"),
    "DH": Articulation(Pose("neutral", .2, .5, .9, "dental"), manner="fricative"),
    "S": Articulation(Pose("spread", .12, .6, .75, "alveolar"), voiced=False, manner="fricative"),
    "Z": Articulation(Pose("spread", .12, .6, .75, "alveolar"), manner="fricative"),
    "SH": Articulation(Pose("rounded", .15, .7, .6, "postalveolar"), voiced=False, manner="fricative"),
    "ZH": Articulation(Pose("rounded", .15, .7, .6, "postalveolar"), manner="fricative"),
    "CH": Articulation(Pose("rounded", .15, .7, .6, "postalveolar", contact=True), voiced=False, manner="affricate"),
    "JH": Articulation(Pose("rounded", .15, .7, .6, "postalveolar", contact=True), manner="affricate"),
    "R": Articulation(Pose("rounded", .2, .6, .5, "retroflex"), manner="approximant"),
    "Y": Articulation(Pose("spread", .15, .95, .95), manner="approximant"),
    "HH": Articulation(Pose("neutral", .4), voiced=False, manner="fricative"),
}

_LIPS_VI = {
    "closed": "Mím hai môi lại với nhau.",
    "rounded": "Chu tròn môi về phía trước như khi thổi nến.",
    "spread": "Kéo hai khoé môi sang hai bên như đang cười.",
    "neutral": "Môi thả lỏng tự nhiên.",
    "labiodental": "Đặt nhẹ răng cửa trên lên môi dưới.",
}
_TIP_VI = {
    "dental": "Đưa đầu lưỡi ra giữa hai hàm răng, chạm nhẹ răng trên.",
    "alveolar": "Đầu lưỡi đặt ở lợi ngay sau răng cửa trên.",
    "postalveolar": "Nâng mặt lưỡi về phía sau lợi, lùi hơn vị trí của /s/.",
    "retroflex": "Cong đầu lưỡi lên và lùi về sau, không chạm vòm miệng.",
}
_MANNER_VI = {
    "stop": "Chặn hơi lại rồi bật ra dứt khoát.",
    "fricative": "Để hơi đi qua khe hẹp, nghe tiếng gió xì liên tục.",
    "affricate": "Chặn hơi rồi nhả ra thành tiếng gió (bật + xì).",
    "nasal": "Hạ ngạc mềm cho hơi thoát ra đường mũi; bịt mũi thử sẽ mất âm.",
    "approximant": "Các bộ phận chỉ lại gần nhau, hơi đi ra êm, không có tiếng gió.",
}


def _jaw_vi(jaw: float) -> str:
    if jaw >= 0.7:
        return "Hạ hàm dưới, mở miệng rộng (khoảng 2 ngón tay)."
    if jaw >= 0.4:
        return "Mở miệng vừa phải (khoảng 1 ngón tay)."
    return "Hàm gần khép, miệng hé nhẹ."


def _tongue_vi(p: Pose) -> str:
    if p.tip in _TIP_VI:
        return _TIP_VI[p.tip]
    if p.back_contact:
        return "Nâng cuống lưỡi chạm vào ngạc mềm (phần mềm phía sau vòm miệng)."
    height = "nâng cao" if p.tongue_height >= 0.7 else "hạ thấp" if p.tongue_height <= 0.3 else "ở giữa"
    place = "phía trước" if p.tongue_front >= 0.7 else "phía sau" if p.tongue_front <= 0.3 else "ở giữa khoang miệng"
    return f"Thân lưỡi {height}, dồn {place}; đầu lưỡi chạm nhẹ chân răng dưới."


def steps_vi(pid: str) -> List[str]:
    """Numbered how-to steps for one sound, generated from its articulation."""
    a = ARTICULATION[pid]
    p = a.start
    steps = [f"Môi: {_LIPS_VI[p.lips]}"]
    if p.lips not in ("closed",):
        steps.append(f"Hàm: {_jaw_vi(p.jaw)}")
    steps.append(f"Lưỡi: {_tongue_vi(p)}")
    if a.manner in _MANNER_VI:
        steps.append(f"Hơi: {_MANNER_VI[a.manner]}")
    if a.manner != "vowel":
        steps.append("Thanh quản: " + ("đặt tay lên cổ, phải thấy rung." if a.voiced else "không rung, chỉ có hơi."))
    if a.end is not None:
        steps.append(f"Trượt: từ khẩu hình đầu, chuyển dần sang: {_LIPS_VI[a.end.lips].lower()} {_tongue_vi(a.end).lower()}")
    return steps


# --- Checking lips measured from the learner's video ---

@dataclass
class LipSample:
    """Vision face-landmark measurements at the middle of one expected phone.
    `open` and `width` are inner-lip height and outer-lip width divided by the
    distance between the eyes, so they do not depend on camera distance."""
    index: int
    word: str
    phone_id: str
    time: float
    open: float
    width: float


@dataclass
class LipFinding:
    index: int
    word: str
    phone_id: str
    status: str                 # "ok", "fix", "needs_visual"
    message: str

    def to_dict(self) -> Dict:
        return asdict(self)


VISUAL_ONLY = {"F": "răng trên có chạm môi dưới không", "V": "răng trên có chạm môi dưới không",
               "TH": "đầu lưỡi có thò ra giữa hai răng không", "DH": "đầu lưỡi có thò ra giữa hai răng không"}


def _median(values: Sequence[float]) -> float:
    s = sorted(values)
    n = len(s)
    return (s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2) if n else 0.0


def check_lips(samples: Sequence[LipSample]) -> List[LipFinding]:
    """Compare each phone's lip shape with the learner's own median shape."""
    if not samples:
        return []
    base_open = _median([s.open for s in samples]) or 1e-6
    base_width = _median([s.width for s in samples]) or 1e-6
    findings = []
    for s in samples:
        art = ARTICULATION.get(s.phone_id)
        if art is None:
            continue
        p = art.start
        status, msg = "ok", "Khẩu hình môi ổn."
        if s.phone_id in VISUAL_ONLY:
            status, msg = "needs_visual", f"Cần nhìn hình: {VISUAL_ONLY[s.phone_id]}."
        elif p.lips == "closed":
            if s.open > max(0.25 * base_open, 0.04):
                status, msg = "fix", "Hai môi chưa khép kín trước khi bật âm."
        elif p.lips == "rounded":
            if s.width > 0.95 * base_width:
                status, msg = "fix", "Chưa chu tròn môi; thu hẹp miệng và đẩy môi ra trước."
        elif p.lips == "spread":
            if s.width < 1.03 * base_width:
                status, msg = "fix", "Kéo khoé môi sang hai bên nhiều hơn."
        if status == "ok" and art.manner == "vowel" and p.jaw >= 0.7 and s.open < 1.2 * base_open:
            status, msg = "fix", "Mở miệng rộng hơn, hạ hàm dưới xuống."
        findings.append(LipFinding(s.index, s.word, s.phone_id, status, msg))
    return findings


def clean_coach(raw) -> Optional[Dict]:
    """Coerces the vision LLM's reply into {summary, frames:[{index, ok, advice}]}."""
    if not isinstance(raw, dict):
        return None
    summary = raw.get("summary") if isinstance(raw.get("summary"), str) else None
    frames = []
    for frame in raw.get("frames") or []:
        if not isinstance(frame, dict):
            continue
        try:
            index = int(frame.get("index"))
        except (TypeError, ValueError):
            continue
        advice = frame.get("advice")
        frames.append({"index": index, "ok": bool(frame.get("ok")),
                       "advice": advice.strip() if isinstance(advice, str) else ""})
    if summary is None and not frames:
        return None
    return {"summary": summary, "frames": frames}


ARTICULATION_PROMPT = (
    "Bạn là giáo viên phát âm tiếng Anh, chuyên sửa khẩu hình cho người Việt. "
    "Bạn nhận các khung hình cận miệng của học viên tại thời điểm phát từng âm, "
    "kèm khẩu hình chuẩn và kết quả đo môi tự động. Với mỗi khung hình, nhận xét "
    "môi, răng, lưỡi (nếu thấy được). Không đoán điều không nhìn thấy. Trả về JSON: "
    '{"summary": "2-3 câu tiếng Việt", "frames": [{"index": số, "ok": true/false, '
    '"advice": "một câu sửa cụ thể bằng tiếng Việt"}]}'
)
