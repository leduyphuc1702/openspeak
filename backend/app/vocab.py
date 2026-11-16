"""Topic vocabulary lessons: the LLM picks words for the learner's chosen topic
and level; pronunciations always come from the lexicon used for scoring."""
from __future__ import annotations

import json
import re
from typing import Dict, List, Optional, Sequence

from . import connected_speech
from .llm import LLMClient
from .phonetics import Lexicon, UnknownWordError

TOPICS: List[Dict[str, str]] = [
    {"id": "daily", "title": "Đời sống hằng ngày", "icon": "house.fill"},
    {"id": "travel", "title": "Du lịch", "icon": "airplane"},
    {"id": "food", "title": "Ẩm thực", "icon": "fork.knife"},
    {"id": "work", "title": "Công việc văn phòng", "icon": "briefcase.fill"},
    {"id": "interview", "title": "Phỏng vấn xin việc", "icon": "person.crop.rectangle.fill"},
    {"id": "shopping", "title": "Mua sắm", "icon": "bag.fill"},
    {"id": "health", "title": "Sức khoẻ", "icon": "heart.fill"},
    {"id": "technology", "title": "Công nghệ", "icon": "laptopcomputer"},
    {"id": "education", "title": "Học tập", "icon": "graduationcap.fill"},
    {"id": "social", "title": "Giao tiếp, kết bạn", "icon": "bubble.left.and.bubble.right.fill"},
    {"id": "meetings", "title": "Họp hành", "icon": "person.3.fill"},
    {"id": "email", "title": "Email, tin nhắn công việc", "icon": "envelope.fill"},
    {"id": "presentation", "title": "Thuyết trình, báo cáo số liệu", "icon": "chart.bar.doc.horizontal"},
    {"id": "smalltalk", "title": "Small talk ở văn phòng", "icon": "cup.and.saucer.fill"},
    {"id": "calls", "title": "Gọi điện, họp online", "icon": "phone.fill"},
    {"id": "negotiation", "title": "Đàm phán, hợp đồng", "icon": "signature"},
    {"id": "project", "title": "Quản lý dự án, tiến độ", "icon": "checklist"},
    {"id": "customer", "title": "Khách hàng, dịch vụ", "icon": "person.crop.circle.badge.checkmark"},
    {"id": "finance", "title": "Tiền bạc, ngân hàng", "icon": "banknote.fill"},
    {"id": "opinions", "title": "Nêu ý kiến, đồng ý, phản đối", "icon": "text.bubble.fill"},
    {"id": "feelings", "title": "Cảm xúc, trạng thái", "icon": "face.smiling"},
    {"id": "transport", "title": "Đi lại, giao thông", "icon": "car.fill"},
    {"id": "housing", "title": "Nhà cửa, thuê nhà", "icon": "building.2.fill"},
    {"id": "emergency", "title": "Tình huống khẩn cấp", "icon": "cross.case.fill"},
]
TOPIC_TITLES = {t["id"]: t["title"] for t in TOPICS}
LEVELS = {"beginner": "A1-A2", "elementary": "A2-B1", "intermediate": "B1-B2", "advanced": "C1"}

# Offline starter words so the vocabulary tab works before an LLM is configured.
# (word, part of speech, Vietnamese meaning, example, example translation)
SEED: Dict[str, List[tuple]] = {
    "daily": [
        ("breakfast", "noun", "bữa sáng", "I usually have breakfast at seven.", "Tôi thường ăn sáng lúc bảy giờ."),
        ("laundry", "noun", "quần áo cần giặt; việc giặt giũ", "I do the laundry on Sunday.", "Tôi giặt đồ vào Chủ nhật."),
        ("neighbor", "noun", "hàng xóm", "Our neighbor has a friendly dog.", "Nhà hàng xóm có một chú chó thân thiện."),
        ("commute", "verb", "đi lại hằng ngày (đi làm, đi học)", "I commute to work by bus.", "Tôi đi làm bằng xe buýt."),
        ("tidy", "adjective", "gọn gàng", "Please keep your room tidy.", "Hãy giữ phòng con gọn gàng nhé."),
        ("errand", "noun", "việc vặt phải đi làm", "I have a few errands to run.", "Tôi có vài việc vặt phải đi làm."),
    ],
    "travel": [
        ("passport", "noun", "hộ chiếu", "Don't forget your passport.", "Đừng quên hộ chiếu nhé."),
        ("luggage", "noun", "hành lý", "My luggage is too heavy.", "Hành lý của tôi nặng quá."),
        ("reservation", "noun", "sự đặt chỗ trước", "I have a reservation for two nights.", "Tôi đã đặt phòng hai đêm."),
        ("departure", "noun", "sự khởi hành", "The departure time is nine a.m.", "Giờ khởi hành là chín giờ sáng."),
        ("souvenir", "noun", "quà lưu niệm", "I bought a souvenir for my mom.", "Tôi mua quà lưu niệm cho mẹ."),
        ("itinerary", "noun", "lịch trình chuyến đi", "Our itinerary is very busy.", "Lịch trình của chúng tôi rất dày."),
    ],
    "food": [
        ("delicious", "adjective", "ngon", "This soup is delicious.", "Món súp này ngon quá."),
        ("recipe", "noun", "công thức nấu ăn", "Can you share the recipe?", "Bạn chia sẻ công thức được không?"),
        ("spicy", "adjective", "cay", "I can't eat spicy food.", "Tôi không ăn được đồ cay."),
        ("vegetable", "noun", "rau củ", "Eat more vegetables.", "Hãy ăn nhiều rau hơn."),
        ("dessert", "noun", "món tráng miệng", "What would you like for dessert?", "Bạn muốn ăn tráng miệng món gì?"),
        ("bill", "noun", "hoá đơn", "Could we have the bill, please?", "Cho chúng tôi xin hoá đơn."),
    ],
    "work": [
        ("deadline", "noun", "hạn chót", "The deadline is next Friday.", "Hạn chót là thứ Sáu tới."),
        ("colleague", "noun", "đồng nghiệp", "My colleague helped me a lot.", "Đồng nghiệp đã giúp tôi rất nhiều."),
        ("schedule", "noun", "lịch làm việc", "Let me check my schedule.", "Để tôi xem lịch đã."),
        ("report", "noun", "báo cáo", "I need to finish this report.", "Tôi cần làm xong bản báo cáo này."),
        ("meeting", "noun", "cuộc họp", "The meeting starts at ten.", "Cuộc họp bắt đầu lúc mười giờ."),
        ("promotion", "noun", "sự thăng chức", "She got a promotion last month.", "Cô ấy được thăng chức tháng trước."),
    ],
    "interview": [
        ("experience", "noun", "kinh nghiệm", "I have three years of experience.", "Tôi có ba năm kinh nghiệm."),
        ("strength", "noun", "điểm mạnh", "My biggest strength is teamwork.", "Điểm mạnh nhất của tôi là làm việc nhóm."),
        ("weakness", "noun", "điểm yếu", "What is your greatest weakness?", "Điểm yếu lớn nhất của bạn là gì?"),
        ("salary", "noun", "lương", "What salary do you expect?", "Bạn mong muốn mức lương bao nhiêu?"),
        ("candidate", "noun", "ứng viên", "She is a strong candidate.", "Cô ấy là một ứng viên sáng giá."),
        ("responsible", "adjective", "có trách nhiệm", "I was responsible for sales.", "Tôi phụ trách mảng bán hàng."),
    ],
    "shopping": [
        ("discount", "noun", "giảm giá", "Is there a discount today?", "Hôm nay có giảm giá không?"),
        ("receipt", "noun", "biên lai", "Keep the receipt, please.", "Vui lòng giữ lại biên lai."),
        ("cashier", "noun", "thu ngân", "Please pay at the cashier.", "Vui lòng thanh toán ở quầy thu ngân."),
        ("expensive", "adjective", "đắt", "This jacket is too expensive.", "Cái áo khoác này đắt quá."),
        ("refund", "noun", "tiền hoàn lại", "Can I get a refund?", "Tôi có được hoàn tiền không?"),
        ("size", "noun", "kích cỡ", "Do you have this in a smaller size?", "Có cỡ nhỏ hơn không?"),
    ],
    "health": [
        ("headache", "noun", "đau đầu", "I have a terrible headache.", "Tôi bị đau đầu kinh khủng."),
        ("medicine", "noun", "thuốc", "Take this medicine twice a day.", "Uống thuốc này hai lần một ngày."),
        ("appointment", "noun", "cuộc hẹn (khám bệnh)", "I have a doctor's appointment.", "Tôi có hẹn với bác sĩ."),
        ("exercise", "verb", "tập thể dục", "I exercise every morning.", "Tôi tập thể dục mỗi sáng."),
        ("fever", "noun", "sốt", "She has a high fever.", "Cô ấy sốt cao."),
        ("healthy", "adjective", "khoẻ mạnh, lành mạnh", "Eat healthy food.", "Hãy ăn đồ ăn lành mạnh."),
    ],
    "technology": [
        ("password", "noun", "mật khẩu", "Change your password often.", "Hãy đổi mật khẩu thường xuyên."),
        ("download", "verb", "tải xuống", "Download the app for free.", "Tải ứng dụng miễn phí."),
        ("battery", "noun", "pin", "My phone battery is low.", "Điện thoại tôi sắp hết pin."),
        ("update", "noun", "bản cập nhật", "Install the latest update.", "Cài bản cập nhật mới nhất."),
        ("screen", "noun", "màn hình", "The screen is cracked.", "Màn hình bị nứt."),
        ("wireless", "adjective", "không dây", "I use wireless headphones.", "Tôi dùng tai nghe không dây."),
    ],
    "education": [
        ("homework", "noun", "bài tập về nhà", "Did you finish your homework?", "Con làm xong bài tập chưa?"),
        ("exam", "noun", "kỳ thi", "The exam is on Monday.", "Kỳ thi vào thứ Hai."),
        ("scholarship", "noun", "học bổng", "He won a scholarship.", "Cậu ấy giành được học bổng."),
        ("knowledge", "noun", "kiến thức", "Reading improves your knowledge.", "Đọc sách giúp mở mang kiến thức."),
        ("practice", "verb", "luyện tập", "Practice speaking every day.", "Hãy luyện nói mỗi ngày."),
        ("graduate", "verb", "tốt nghiệp", "I graduated in 2020.", "Tôi tốt nghiệp năm 2020."),
    ],
    "social": [
        ("introduce", "verb", "giới thiệu", "Let me introduce myself.", "Cho tôi giới thiệu bản thân."),
        ("hobby", "noun", "sở thích", "What are your hobbies?", "Sở thích của bạn là gì?"),
        ("invite", "verb", "mời", "I want to invite you to dinner.", "Tôi muốn mời bạn ăn tối."),
        ("weekend", "noun", "cuối tuần", "What did you do last weekend?", "Cuối tuần trước bạn làm gì?"),
        ("friendly", "adjective", "thân thiện", "Everyone here is friendly.", "Mọi người ở đây đều thân thiện."),
        ("chat", "verb", "trò chuyện", "Let's chat over coffee.", "Mình vừa uống cà phê vừa trò chuyện nhé."),
    ],
    "meetings": [
        ("agenda", "noun", "chương trình cuộc họp", "Let's go through the agenda.", "Chúng ta cùng xem qua chương trình họp."),
        ("postpone", "verb", "hoãn, dời lại", "Can we postpone the meeting to Thursday?", "Mình dời cuộc họp sang thứ Năm được không?"),
        ("summarize", "verb", "tóm tắt", "Let me summarize the main points.", "Để tôi tóm tắt các ý chính."),
        ("follow up", "phrase", "liên hệ lại, theo sát tiếp", "I'll follow up with the client tomorrow.", "Mai tôi sẽ liên hệ lại với khách hàng."),
        ("action item", "phrase", "việc cần làm sau cuộc họp", "Who owns this action item?", "Ai phụ trách đầu việc này?"),
        ("minutes", "noun", "biên bản cuộc họp", "Could you take the minutes today?", "Hôm nay bạn ghi biên bản họp được không?"),
    ],
    "email": [
        ("attachment", "noun", "tệp đính kèm", "Please see the attachment.", "Vui lòng xem tệp đính kèm."),
        ("regarding", "preposition", "về việc, liên quan đến", "I'm writing regarding your order.", "Tôi viết thư về đơn hàng của bạn."),
        ("reply", "noun", "thư trả lời", "Sorry for the late reply.", "Xin lỗi vì trả lời muộn."),
        ("forward", "verb", "chuyển tiếp (email)", "I'll forward you the email.", "Tôi sẽ chuyển tiếp email cho bạn."),
        ("confirm", "verb", "xác nhận", "Could you confirm the date?", "Bạn xác nhận giúp ngày được không?"),
        ("in advance", "phrase", "trước (cảm ơn trước)", "Thanks in advance for your help.", "Cảm ơn trước vì đã giúp đỡ."),
    ],
    "presentation": [
        ("slide", "noun", "trang trình chiếu", "Let's move on to the next slide.", "Chúng ta chuyển sang slide tiếp theo."),
        ("audience", "noun", "người nghe, khán giả", "Look at your audience when you speak.", "Hãy nhìn người nghe khi nói."),
        ("chart", "noun", "biểu đồ", "This chart shows our sales.", "Biểu đồ này thể hiện doanh số của chúng tôi."),
        ("increase", "verb", "tăng", "Revenue increased by ten percent.", "Doanh thu tăng mười phần trăm."),
        ("highlight", "verb", "nhấn mạnh, làm nổi bật", "I'd like to highlight three points.", "Tôi muốn nhấn mạnh ba điểm."),
        ("conclusion", "noun", "phần kết luận", "In conclusion, the project was a success.", "Tóm lại, dự án đã thành công."),
    ],
    "smalltalk": [
        ("weather", "noun", "thời tiết", "The weather is lovely today.", "Hôm nay trời đẹp quá."),
        ("traffic", "noun", "giao thông, tắc đường", "The traffic was terrible this morning.", "Sáng nay tắc đường kinh khủng."),
        ("grab a coffee", "phrase", "đi uống cà phê nhanh", "Do you want to grab a coffee?", "Đi uống cà phê không?"),
        ("busy", "adjective", "bận", "It's been a busy week.", "Tuần này bận quá."),
        ("vacation", "noun", "kỳ nghỉ", "Where are you going on vacation?", "Bạn đi nghỉ ở đâu?"),
        ("catch up", "phrase", "hàn huyên, cập nhật tình hình", "Let's catch up next week.", "Tuần sau mình nói chuyện nhé."),
    ],
    "calls": [
        ("hold on", "phrase", "chờ một chút", "Hold on, let me check.", "Chờ chút, để tôi kiểm tra."),
        ("mute", "noun", "chế độ tắt mic", "I think you're on mute.", "Hình như bạn đang tắt mic."),
        ("connection", "noun", "kết nối mạng", "Sorry, my connection is bad.", "Xin lỗi, mạng của tôi yếu."),
        ("repeat", "verb", "nhắc lại", "Could you repeat that, please?", "Bạn nhắc lại được không?"),
        ("share my screen", "phrase", "chia sẻ màn hình", "Let me share my screen.", "Để tôi chia sẻ màn hình."),
        ("message", "noun", "lời nhắn", "Can I take a message?", "Tôi nhận lời nhắn giúp nhé?"),
    ],
    "negotiation": [
        ("offer", "noun", "lời đề nghị", "That's a fair offer.", "Đó là một đề nghị hợp lý."),
        ("budget", "noun", "ngân sách", "It's over our budget.", "Vượt quá ngân sách của chúng tôi."),
        ("compromise", "noun", "sự dung hoà, thoả hiệp", "Let's find a compromise.", "Hãy tìm một giải pháp dung hoà."),
        ("contract", "noun", "hợp đồng", "Please sign the contract.", "Vui lòng ký hợp đồng."),
        ("negotiate", "verb", "đàm phán, thương lượng", "We need to negotiate the price.", "Chúng ta cần thương lượng giá."),
        ("deal", "noun", "thoả thuận", "It's a deal!", "Chốt vậy nhé!"),
    ],
    "project": [
        ("milestone", "noun", "mốc quan trọng", "We hit our first milestone.", "Chúng ta đã đạt mốc đầu tiên."),
        ("priority", "noun", "việc ưu tiên", "This task is our top priority.", "Việc này là ưu tiên hàng đầu."),
        ("delay", "noun", "sự chậm trễ", "Sorry for the delay.", "Xin lỗi vì sự chậm trễ."),
        ("progress", "noun", "tiến độ", "Can you update me on your progress?", "Cập nhật tiến độ cho tôi nhé."),
        ("assign", "verb", "giao (việc)", "I'll assign this task to Nam.", "Tôi sẽ giao việc này cho Nam."),
        ("on track", "phrase", "đúng tiến độ", "We're on track to finish by Friday.", "Chúng ta vẫn kịp xong trước thứ Sáu."),
    ],
    "customer": [
        ("complaint", "noun", "lời phàn nàn, khiếu nại", "We received a complaint this morning.", "Sáng nay chúng tôi nhận một khiếu nại."),
        ("apologize", "verb", "xin lỗi", "I apologize for the inconvenience.", "Tôi xin lỗi vì sự bất tiện."),
        ("solution", "noun", "giải pháp", "We'll find a solution.", "Chúng tôi sẽ tìm giải pháp."),
        ("delivery", "noun", "việc giao hàng", "The delivery is late.", "Hàng giao trễ."),
        ("available", "adjective", "còn hàng; rảnh", "Is this item available?", "Mặt hàng này còn không?"),
        ("satisfied", "adjective", "hài lòng", "Are you satisfied with our service?", "Bạn có hài lòng với dịch vụ không?"),
    ],
    "finance": [
        ("account", "noun", "tài khoản", "I'd like to open an account.", "Tôi muốn mở tài khoản."),
        ("transfer", "verb", "chuyển khoản", "I'll transfer the money today.", "Hôm nay tôi sẽ chuyển tiền."),
        ("invoice", "noun", "hoá đơn thanh toán", "Please send me the invoice.", "Gửi tôi hoá đơn nhé."),
        ("loan", "noun", "khoản vay", "We took out a loan.", "Chúng tôi đã vay một khoản."),
        ("interest", "noun", "tiền lãi, lãi suất", "The interest rate is high.", "Lãi suất cao."),
        ("afford", "verb", "đủ khả năng chi trả", "I can't afford a new car.", "Tôi không đủ tiền mua xe mới."),
    ],
    "opinions": [
        ("agree", "verb", "đồng ý", "I totally agree with you.", "Tôi hoàn toàn đồng ý với bạn."),
        ("disagree", "verb", "không đồng ý", "I'm afraid I disagree.", "E là tôi không đồng ý."),
        ("suggest", "verb", "đề xuất", "I suggest we start early.", "Tôi đề xuất mình bắt đầu sớm."),
        ("point", "noun", "ý, luận điểm", "That's a good point.", "Ý đó hay đấy."),
        ("in my opinion", "phrase", "theo tôi", "In my opinion, it's too risky.", "Theo tôi, như vậy quá rủi ro."),
        ("actually", "adverb", "thực ra", "Actually, I think it's fine.", "Thực ra tôi thấy ổn mà."),
    ],
    "feelings": [
        ("excited", "adjective", "háo hức", "I'm excited about the trip.", "Tôi háo hức về chuyến đi."),
        ("nervous", "adjective", "hồi hộp, lo lắng", "I'm nervous about the interview.", "Tôi hồi hộp về buổi phỏng vấn."),
        ("frustrated", "adjective", "bực bội, nản", "I'm frustrated with this problem.", "Tôi bực mình với vấn đề này."),
        ("relieved", "adjective", "nhẹ nhõm", "I'm relieved it's over.", "Tôi nhẹ nhõm vì đã xong."),
        ("exhausted", "adjective", "kiệt sức", "I'm exhausted after work.", "Tan làm tôi kiệt sức."),
        ("grateful", "adjective", "biết ơn", "I'm grateful for your help.", "Tôi rất biết ơn sự giúp đỡ của bạn."),
    ],
    "transport": [
        ("fare", "noun", "giá vé", "How much is the fare?", "Giá vé bao nhiêu?"),
        ("pick up", "phrase", "đón (ai đó)", "Can you pick me up at six?", "Sáu giờ bạn đón tôi được không?"),
        ("drop off", "phrase", "cho xuống, thả (ai đó)", "Please drop me off here.", "Cho tôi xuống đây nhé."),
        ("parking", "noun", "chỗ đỗ xe", "Is there parking nearby?", "Gần đây có chỗ đỗ xe không?"),
        ("rush hour", "phrase", "giờ cao điểm", "Avoid driving at rush hour.", "Tránh lái xe giờ cao điểm."),
        ("platform", "noun", "sân ga", "Which platform does the train leave from?", "Tàu chạy từ sân ga nào?"),
    ],
    "housing": [
        ("rent", "noun", "tiền thuê nhà", "The rent is due on the first.", "Tiền nhà đóng vào ngày mùng một."),
        ("landlord", "noun", "chủ nhà (cho thuê)", "I called the landlord about the leak.", "Tôi đã gọi chủ nhà về chỗ dột."),
        ("furnished", "adjective", "có sẵn nội thất", "Is the apartment furnished?", "Căn hộ có sẵn nội thất không?"),
        ("deposit", "noun", "tiền đặt cọc", "The deposit is one month's rent.", "Tiền cọc là một tháng tiền nhà."),
        ("utilities", "noun", "chi phí điện nước", "Are utilities included?", "Đã gồm tiền điện nước chưa?"),
        ("neighborhood", "noun", "khu phố", "It's a quiet neighborhood.", "Đó là một khu phố yên tĩnh."),
    ],
    "emergency": [
        ("emergency", "noun", "trường hợp khẩn cấp", "This is an emergency!", "Đây là trường hợp khẩn cấp!"),
        ("injured", "adjective", "bị thương", "Is anyone injured?", "Có ai bị thương không?"),
        ("ambulance", "noun", "xe cấp cứu", "Please call an ambulance!", "Làm ơn gọi xe cấp cứu!"),
        ("stolen", "adjective", "bị đánh cắp", "My wallet was stolen.", "Ví của tôi bị trộm."),
        ("lost", "adjective", "bị lạc", "I think I'm lost.", "Hình như tôi bị lạc."),
        ("allergic", "adjective", "bị dị ứng", "I'm allergic to peanuts.", "Tôi dị ứng đậu phộng."),
    ],
}

VOCAB_PROMPT = (
    "Bạn soạn bài từ vựng tiếng Anh (giọng Mỹ) cho người Việt. Chọn các từ hoặc cụm từ "
    "thông dụng, thực tế nhất cho chủ đề và trình độ được yêu cầu, không trùng danh sách "
    "đã học. Người học là người đi làm: ưu tiên từ dùng hằng ngày ở công sở và đời sống, "
    "khoảng một phần ba là cụm từ/collocation hay gặp (vd. 'follow up', 'on track'). Nghĩa tiếng Việt phải ngắn gọn, đúng ngữ cảnh chủ đề. Câu ví dụ ngắn, tự nhiên. "
    'Trả về JSON: {"words": [{"word": "...", "pos": "noun|verb|adjective|adverb|phrase", '
    '"meaning_vi": "...", "example_en": "...", "example_vi": "...", "tip_vi": "mẹo phát âm ngắn hoặc chuỗi rỗng"}]}'
)


def _pronounce(lexicon: Lexicon, text: str) -> Optional[Dict]:
    try:
        words = lexicon.sentence(text)
    except (UnknownWordError, ValueError):
        return None
    links = connected_speech.find_links(words)
    return {
        "ipa": " ".join(w.ipa for w in words),
        "connected_ipa": connected_speech.connected_transcription(words, links) if links else None,
        "phones": [p.id for w in words for p in w.phones],
        "syllables": sum(p.is_vowel for w in words for p in w.phones),
    }


def enrich(lexicon: Lexicon, items: Sequence[Dict]) -> List[Dict]:
    """Attach lexicon pronunciations; drop items the scorer could not handle."""
    out, seen = [], set()
    for item in items:
        word = str(item.get("word", "")).strip()
        if not word or word.lower() in seen or not re.fullmatch(r"[A-Za-z' -]{1,40}", word):
            continue
        pron = _pronounce(lexicon, word)
        if pron is None:
            continue
        seen.add(word.lower())
        out.append({
            "word": word,
            "pos": item.get("pos", ""),
            "meaning_vi": item.get("meaning_vi", ""),
            "example_en": item.get("example_en", ""),
            "example_vi": item.get("example_vi", ""),
            "tip_vi": item.get("tip_vi") or None,
            **pron,
        })
    return out


def seed_lesson(lexicon: Lexicon, topic: str) -> List[Dict]:
    keys = ("word", "pos", "meaning_vi", "example_en", "example_vi")
    return enrich(lexicon, [dict(zip(keys, row)) for row in SEED.get(topic, [])])


def generate_lesson(
    client: Optional[LLMClient], lexicon: Lexicon, topic: str, level: str, count: int, known: Sequence[str]
) -> Dict:
    title = TOPIC_TITLES.get(topic, topic)
    if client is None:
        return {"topic": topic, "title": title, "source": "seed", "words": seed_lesson(lexicon, topic)}
    request = {
        "topic": title, "level": LEVELS.get(level, level), "count": count,
        "already_learned": list(known)[-200:],
    }
    data = client.chat_json(VOCAB_PROMPT, json.dumps(request, ensure_ascii=False))
    items = data.get("words", []) if isinstance(data, dict) else []
    known_lower = {k.lower() for k in known}
    words = [w for w in enrich(lexicon, items) if w["word"].lower() not in known_lower]
    return {"topic": topic, "title": title, "source": "llm", "words": words[:count]}
