# OpenSpeak

Ứng dụng iOS (SwiftUI) học phát âm tiếng Anh, giao diện theo cấu trúc của ELSA Speak (xem phần "Đối chiếu với ELSA"), dùng cho cá nhân. Gồm bốn mảng:

1. **Phiên âm**: học 41 âm IPA theo lộ trình nền tảng 15 bài, mỗi âm học kỹ như trẻ mẫu giáo học chữ cái. Các bước là làm quen (sơ đồ khẩu hình và từng bước đặt môi, hàm, lưỡi), nhận mặt ký hiệu, tô ký hiệu bằng tay (phải tô kín ký hiệu, không lệch ra ngoài, đủ từng nét), nghe và nhận âm (câu hỏi do LLM ra theo chủ đề của bạn, xem phần "Câu hỏi nghe"), rồi nói. Sau đó ôn lại theo lịch lặp ngắt quãng. Song song là **lộ trình cá nhân không có điểm dừng**: mỗi bài được lập từ kết quả của chính bạn (xem phần "Lộ trình cá nhân").
2. **Luyện nói**: AI chấm **trực tiếp từ âm thanh** từng âm vị, trọng âm, ngữ điệu, độ trôi chảy và nối âm (linking, flap t, nuốt âm...). Điểm đã hiệu chỉnh theo điểm chuyên gia (xem bên dưới). Có **khẩu hình động cho cả từ và cả câu** (xem phần "Khẩu hình động"), và chế độ **quay video miệng**: điện thoại đo môi từng khung hình, sau đó LLM thị giác xem ảnh cận miệng để chỉ cách sửa.
3. **Từ vựng**: 24 chủ đề cho người đi làm (họp, email, thuyết trình, small talk, gọi điện, đàm phán, dự án, khách hàng, tiền bạc, nêu ý kiến, cảm xúc, đi lại, thuê nhà, khẩn cấp...). Có **lộ trình từ vựng** không điểm kết thúc: mỗi bài 6 từ do LLM soạn theo chủ đề, trình độ và tình huống (luân phiên), tránh từ đã học và nhắc lại từ hay sai. Mỗi từ có thẻ học (nghĩa, IPA, ví dụ, **giọng người thật** từ Wikimedia Commons, nói, khẩu hình), rồi được nhớ lại 3 cách và app tự chấm. Ôn tập lặp lại ngắt quãng cũng bắt gõ lại từ, không tự đánh giá "nhớ/quên"; mỗi lượt ôn tối đa 15 từ, quá hạn lâu nhất trước. Có thêm tra từ điển.
4. **Hội thoại AI**: nhập vai tình huống công sở (8 tình huống có sẵn hoặc LLM tạo theo chủ đề bạn gõ). Mỗi tình huống có 3 nhiệm vụ. Bạn nói hoặc gõ; AI đáp lại, sửa lỗi câu, gợi ý cách nói tự nhiên hơn, đánh dấu nhiệm vụ đã xong. Lượt nói được ghi thành file âm thanh; nhận dạng giọng nói trên máy chỉ lấy ra chữ, còn chính bản ghi đó được gửi tới mô hình âm vị của backend để chấm phát âm từng âm và ngữ điệu, ngay dưới bong bóng chat (xem phần "Hội thoại: chấm phát âm từng lượt").

```
ios/       Ứng dụng SwiftUI (iOS 17+), project sinh bằng XcodeGen
backend/   API chấm phát âm (FastAPI + wav2vec2 + Praat) và cổng LLM
```

## Chạy backend

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Lần gọi `/v1/assess` đầu tiên sẽ tải mô hình ghi trong `app/calibration.json`, hiện là `mrrubino/wav2vec2-large-xlsr-53-l2-arctic-phoneme` (khoảng 1,2 GB). Có thể đổi bằng biến môi trường `PHONEME_MODEL`, nhưng khi đó điểm không còn khớp hiệu chỉnh. Xem phần "Hiệu chỉnh điểm trên nhiều mô hình".

Chạy test (không cần torch vì dùng bộ nhận dạng giả lập):

```bash
pip install pytest && python -m pytest -q
```

### Gắn LLM của bạn

Backend nói được 3 định dạng API, chọn bằng `LLM_API_FORMAT`:

| `LLM_API_FORMAT` | Gọi tới | Dùng cho |
|---|---|---|
| `openai-chat-completions` (mặc định) | `{base}/chat/completions` | OpenAI, OpenRouter, Groq, Ollama, vLLM, DeepSeek... |
| `openai-responses` | `{base}/responses` | OpenAI Responses API |
| `anthropic-messages` | `{base}/v1/messages` (`x-api-key`, `anthropic-version`) | Anthropic hoặc cổng tương thích |

```bash
export LLM_API_FORMAT=openai-chat-completions
export LLM_BASE_URL=https://api.openai.com/v1   # Anthropic: https://api.anthropic.com
export LLM_API_KEY=sk-...
export LLM_MODEL=gpt-4o-mini            # nhận xét phát âm, giao từ vựng, nghĩa từ, lộ trình
export LLM_VISION_MODEL=gpt-4o-mini     # xem ảnh cận miệng (mô hình phải nhận ảnh)
export LLM_TIMEOUT=160                  # giây; mô hình có "thinking" ra cả bài kiểm tra mất khoảng 110 giây
```

Cả 3 định dạng đều gửi được ảnh và yêu cầu trả JSON. Với `anthropic-messages`, `max_tokens` là 16000 vì các model có thinking dùng một phần ngân sách này để nghĩ trước khi viết; với 4096, claude-sonnet-5-5 hết ngân sách khi còn đang nghĩ và không trả chữ nào. Nếu nhà cung cấp từ chối một tham số tuỳ chọn (`temperature`, `response_format`, `text`), backend bỏ tham số đó và gọi lại một lần.

**Khoá của máy chủ hay của người học.** Có hai cách, dùng được cùng lúc:

- *Khoá đặt ở máy chủ* (các biến trên): người dùng app không cần làm gì, nhưng ai gọi được API là dùng được khoá này, mà API hiện chưa có đăng nhập.
- *Mỗi người tự nhập LLM của mình* trong app, ở Hồ sơ > "LLM của bạn": chọn định dạng, địa chỉ API, model, model đọc ảnh và khoá. Khoá lưu trong Keychain của iPhone. Mỗi yêu cầu tới backend mang theo các header `X-LLM-Format`, `X-LLM-Base-URL`, `X-LLM-Model`, `X-LLM-Vision-Model`, `X-LLM-Key`; backend dùng chúng cho đúng yêu cầu đó, không ghi ra đĩa hay log, và ưu tiên chúng hơn LLM của máy chủ. Nút "Kiểm tra LLM" gọi `POST /v1/llm/check`.

Vì khoá đi qua backend, chỉ bật LLM riêng khi backend là máy của bạn và dùng HTTPS. Để backend không bị dùng làm cầu gọi vào mạng nội bộ, địa chỉ API do app gửi phải là `https` và trỏ tới IP công khai; muốn thử với LLM chạy trên máy mình (`http://localhost...`) thì đặt `LLM_ALLOW_PRIVATE_URLS=1`. Đặt `LLM_CLIENT_CONFIG=0` để tắt hẳn việc nhận LLM từ app.

LLM **không** tự nghe audio. Phần nghe do mô hình âm học đảm nhận; LLM chỉ nhận kết quả đo đã có cấu trúc rồi viết lời khuyên. Khi chưa có LLM, app vẫn chạy đủ: chấm điểm, mẹo có sẵn cho âm yếu nhất, gói 144 từ và cụm từ có sẵn cho 24 chủ đề, và kiểm tra khẩu hình bằng quy tắc.

| Endpoint | Việc |
|---|---|
| `POST /v1/assess` | Chấm câu nói: âm vị, trọng âm, ngữ điệu, trôi chảy, nối âm. `skip_unknown=true` (cho lời nói tự do) bỏ qua các từ không có trong từ điển phát âm thay vì báo lỗi, và trả chúng trong `skipped_words` |
| `GET /v1/phonemize?text=` | Phiên âm, phiên âm nối âm (`‿`), chỗ nối và ngữ điệu cần có |
| `POST /v1/articulation-feedback` | Số đo môi theo từng âm (+ tối đa 8 ảnh JPEG cận miệng) → nhận xét khẩu hình |
| `GET /v1/articulation/{id}` | Mô tả cấu âm và các bước tiếng Việt cho một âm |
| `GET /v1/topics`, `POST /v1/vocab/lesson` | Chủ đề; bài từ mới do LLM giao (lọc theo từ đã học, có IPA từ CMUdict) |
| `POST /v1/vocab/next` | Bài tiếp theo của lộ trình từ vựng (`level`, `topics`, `lesson_index`, `known`, `weak`): 6 từ, mỗi từ có câu ví dụ và một câu luyện ở tình huống khác kèm chỗ trống |
| `GET /v1/dictionary/{word}` | Phiên âm, nghĩa (Wiktionary hoặc LLM), đường dẫn sang Cambridge |
| `GET /v1/audio/word/{word}` | Bản ghi giọng người thật của một từ (Wikimedia Commons), trả WAV kèm header ghi công `X-Audio-Artist/License/Source/Accent`; 404 nếu Commons không có, 503 + `Retry-After` nếu Commons đang giới hạn |
| `GET /v1/roleplay/scenarios` | 8 tình huống hội thoại công sở có sẵn |
| `POST /v1/roleplay/start` | Lấy tình huống có sẵn (`scenario_id`) hoặc để LLM tạo theo `topic` |
| `POST /v1/roleplay/turn` | Một lượt hội thoại: câu đáp, lỗi đã sửa, cách nói hay hơn, nhiệm vụ đã xong, gợi ý |
| `POST /v1/path/next` | Bài tiếp theo của lộ trình cá nhân, lập từ điểm nói, lỗi nghe và các bài đã học; kèm `exercises` (câu hỏi nghe) |
| `POST /v1/path/exam` | Bài kiểm tra sau mỗi 4 bài của lộ trình cá nhân |
| `POST /v1/exercises` | Câu hỏi nghe cho một âm (`sound`, `contrasts`, `topics`, `level`, `avoid_words`) |
| `POST /v1/llm/check` | Gọi thử LLM đang dùng (của app nếu có header `X-LLM-*`, không thì của máy chủ): trả model, thời gian, câu trả lời hoặc lỗi của nhà cung cấp |
| `GET /health` | `llm`: có LLM không; `llm_source`: `client` hoặc `server` |

### Lộ trình cá nhân

Lộ trình nền tảng chỉ có 15 bài. Sau đó (hoặc bất cứ lúc nào, ở mục "Lộ trình cá nhân" của tab Học) app xin backend bài kế tiếp qua `POST /v1/path/next`, gửi kèm điểm nói gần đây của từng âm, số lần nghe đúng/sai, kỹ năng, chủ đề, trình độ và 10 bài gần nhất. Không có bài cuối: học xong bài nào thì xin bài sau.

Cách chọn bài nằm trong `backend/app/path.py` và luôn chạy, dù có LLM hay không:

- **Âm cần luyện**: mỗi âm có một điểm "cần luyện". Âm đã có điểm nói thì dựa vào điểm đó (càng nhiều lần chấm càng tin), âm có lỗi nghe thì dựa vào tỷ lệ nghe nhầm. Âm chưa có dữ liệu thì dùng mức khó thường gặp của người Việt, tính nửa trọng số để âm bạn thật sự nói kém luôn được ưu tiên hơn âm chỉ khó trên lý thuyết. Âm vừa học ở bài trước bị hạ điểm để không lặp lại, trừ khi bài đó dưới 70 điểm thì được luyện thêm đúng một lượt.
- **Độ khó** (3 bậc): giữ bậc của bài trước; hai bài gần nhất trung bình từ 85 điểm thì lên một bậc, dưới 60 thì xuống một bậc.
- **Nội dung**: có LLM thì LLM chọn một trong 6 âm cần luyện nhất và viết từ, cặp âm tối thiểu, câu theo chủ đề của bạn. Không có LLM thì lấy từ kho có sẵn (`path_pool.py`). Trường hợp nào cũng vậy, mọi từ và câu đều được kiểm lại bằng từ điển phát âm mà bộ chấm dùng; mục nào không qua thì thay bằng mục trong kho.

Mỗi bài ghi rõ lý do chọn (ví dụ "Bài này luyện /θ/ vì điểm nói /θ/ của bạn trung bình 52/100 qua 4 lần chấm"), để bạn biết bài được cá nhân hoá từ dữ liệu nào.

### Câu hỏi nghe

Câu hỏi chọn 1 trong 2 cũ đoán được mà không cần nghe. Đo trên 8 câu điền chỗ trống (5 do LLM ra), một LLM không nghe được audio chọn đúng 6/8 chỉ nhờ nghĩa của câu; cùng các câu đó bắt gõ từ (không có lựa chọn) thì đúng 0/8. Với câu "đọc phiên âm, chọn từ", chỉ cần đoán theo chữ cái đầu đã đúng 55% (ngẫu nhiên là 25%). Vì vậy mọi câu hỏi giờ bắt người học **đánh dấu, gõ, phân loại hoặc ghép** thay vì chọn, đều do LLM ra đề rồi được backend kiểm lại trong `backend/app/exercises.py`:

| Loại | Người học làm gì | Backend kiểm |
|---|---|---|
| Nghe chuỗi (`sequence`) | Nghe 3 lần đọc (giọng có thể khác nhau), đánh dấu mỗi lần là từ nào của cặp âm tối thiểu (sit/seat). Cả hai từ đều có mặt, nên không đoán theo nghĩa được | Hai từ thật sự chỉ khác nhau ở âm đang học |
| Nghe chép (`dictation`) | Nghe cả câu, gõ từ còn thiếu. Nghe nhầm sang từ kia của cặp thì app chỉ ra khác nhau ở âm nào | Từ đáp án có trong câu, câu đủ ngắn theo độ khó; chấp nhận từ đồng âm (meet/meat) |
| Phân loại (`sort`) | 4–5 từ viết giống nhau, chạm vào **mọi** từ có âm đang học (có thể một hoặc nhiều). Sau khi trả lời mới hiện phiên âm và quy tắc chính tả | Backend tự tính từ từ điển phát âm: có cả từ đúng lẫn sai; từ đọc được hai kiểu thì bỏ |
| Ghép phiên âm (`build`) | Nghe một từ, ghép phiên âm từ các ô ký hiệu; ô nhiễu là âm dễ nhầm (ship: có cả /ɪ/ và /iː/) | Phiên âm lấy từ từ điển; từ tối đa 6 âm, âm đang học ở âm tiết nhấn |

Câu sai quay lại một lần ở cuối bước (chỉ lần đầu được tính điểm). Cuối bước có phần "Cần nhớ" (các từ đã nghe nhầm, kèm phiên âm và nút nghe) và các quy tắc chính tả đã gặp. Bước "Nhận mặt ký hiệu" đọc lẫn âm đang học với âm dễ nhầm, nên không thể luôn chọn ký hiệu trên tiêu đề; câu "đọc phiên âm" chọn từ nhiễu giống nhau về âm và chữ cái đầu.

LLM nhận chủ đề người học đã chọn, một "góc nhìn" cho mỗi chủ đề (đổi mỗi lần, ví dụ "lỗi và sự cố", "con số và thời gian") và các từ khoá đã dùng gần đây để tránh lặp. Câu nào sai thì bị bỏ; thiếu thì bù bằng câu ghép từ kho từ của máy chủ. Màn câu hỏi ghi rõ đề do AI ra hay ghép tự động. App cũ gửi kiểu `pair`/`gap`/`spelling` vẫn đọc được.

### Lộ trình từ vựng

Ở tab Khám phá, thẻ "Lộ trình từ vựng" xin bài kế tiếp qua `POST /v1/vocab/next` (`backend/app/vocab_path.py`). Backend xoay vòng chủ đề người học chọn và chọn một tình huống (con số và thời gian, nhờ vả và xin phép...), gửi LLM danh sách từ đã học (để tránh) và từ hay sai (để lồng vào câu). Mỗi từ được kiểm bằng từ điển phát âm; câu luyện phải chứa đúng một lần từ đó (hoặc một dạng của nó) và khác câu ví dụ. Không có LLM hoặc LLM lỗi thì lấy từ gói có sẵn, ghi rõ trên màn hình.

Một bài gồm:

1. Khởi động: gõ lại tối đa 4 từ cũ đến hạn ôn.
2. Làm quen 6 từ mới bằng thẻ học.
3. Nhớ lại mỗi từ 3 cách, app chấm: nghe và chọn nghĩa (các nghĩa nhiễu là nghĩa của từ khác trong bài), nghe và gõ từ theo nghĩa, gõ từ vào câu ở tình huống mới. Từ sai quay lại cuối bài.
4. Tổng kết: từ cần ôn sớm và từ đã nhớ. Kết quả đi vào lịch ôn lặp lại ngắt quãng; từ sai được gửi lên ở bài sau như từ yếu.

### Bài kiểm tra trong lộ trình cá nhân

Cứ học xong 4 bài lộ trình thì có một bài kiểm tra (`backend/app/exam.py`), hiện ngay sau bài thứ 4 với tên "Bài kiểm tra N". Đề gồm câu hỏi nghe (mỗi âm một cặp âm, thêm điền chỗ trống và chính tả bẫy), 6 từ để nói và 3 câu để đọc, về các âm của 4 bài vừa học và âm bạn cần nhất.

- Mỗi âm có ít nhất một từ để nói; câu đọc dành cho âm yếu nhất trước.
- Từ khoá không lặp trong đề và không trùng với các bài, bài kiểm tra gần đây.
- Các chủ đề được rải đều; màn giới thiệu ghi số mục của từng chủ đề.
- Điểm bài kiểm tra là trung bình của điểm nghe và điểm nói, kèm điểm nói từng âm; điểm nói được đưa vào dữ liệu lập bài sau.

### Hội thoại: chấm phát âm từng lượt

Nhận dạng giọng nói (Apple Speech) chỉ cho biết bạn nói chữ gì; nó cố đoán ra chữ đúng nên không dùng để chấm phát âm. Vì vậy mỗi lượt nói được ghi thành WAV. App gửi chữ nhận dạng được cho AI để hội thoại tiếp, đồng thời gửi chính bản ghi đó cùng chữ tới `POST /v1/assess` (`skip_unknown=true`). Mô hình âm vị nghe trực tiếp âm thanh và chấm từng âm, trọng âm và ngữ điệu, giống màn luyện nói.

Dưới lượt nói hiện vòng điểm, điểm phát âm và ngữ điệu, giọng lên hay xuống ở cuối câu, hai âm yếu nhất và từ chứa chúng; chữ trong bong bóng tô màu theo điểm từng từ. Chạm vào thẻ để xem đủ kết quả và luyện lại câu đó. Nếu máy nghe nhầm chữ, bạn sửa lại chữ và bản ghi được chấm lại theo chữ đúng.

### Từ điển: vì sao không lấy trực tiếp từ Cambridge

Nội dung của Cambridge Dictionary có bản quyền, và điều khoản sử dụng của họ không cho phép thu thập tự động để đưa vào sản phẩm khác. Dự án vì vậy dùng nguồn mở, kèm nút "Xem trên Cambridge" để mở trang gốc:

- **Phát âm**: CMUdict, khoảng 134.000 từ, trình bày theo kiểu IPA giọng Mỹ của Cambridge (ví dụ /ˈveri/, /həˈloʊ/).
- **Nghĩa tiếng Việt**: Wiktionary (CC BY-SA). Nhập dữ liệu một lần như sau:

  ```bash
  # tải dump tiếng Anh từ https://kaikki.org/dictionary/English/ (file .jsonl)
  python -m tools.import_wiktionary kaikki.org-dictionary-English.jsonl
  ```

  Lệnh này tạo `backend/data/dictionary.sqlite`. Từ không có trong đó sẽ được LLM giải nghĩa (nếu đã cấu hình LLM).

Nếu sau này có giấy phép dữ liệu (Cambridge, Oxford đều có API trả phí), chỉ cần thay `OpenDictionary` trong `backend/app/dictionary.py`.

### Deploy lên VPS Linux

Thư mục `deploy/` chứa cấu hình chạy backend bằng systemd, có HTTPS riêng ở cổng 8443, nên không đụng tới web server đang giữ cổng 80/443. Các bước trên Ubuntu 24.04:

```bash
# trên VPS, với /opt/openspeak/backend là bản sao của thư mục backend/ và /opt/openspeak/deploy là deploy/
useradd --system --home /opt/openspeak --shell /usr/sbin/nologin openspeak
cd /opt/openspeak && python3 -m venv venv
venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cpu
venv/bin/pip install -r backend/requirements.txt
cp deploy/openspeak.env.example /etc/openspeak.env && chmod 600 /etc/openspeak.env   # điền LLM nếu có
mkdir -p hf download backend/cache && chown -R openspeak:openspeak /opt/openspeak
```

Chứng chỉ: nếu máy chưa có tên miền, dùng `<ip-nối-bằng-gạch>.sslip.io` (trỏ sẵn về IP đó). Let's Encrypt kiểm tra qua thư mục `ACME_WEBROOT` mà web server ở cổng 80 đang phục vụ tại `/.well-known/acme-challenge/`:

```bash
docker run --rm -v /opt/openspeak/letsencrypt:/etc/letsencrypt -v /opt/openspeak/letsencrypt-lib:/var/lib/letsencrypt \
  -v $ACME_WEBROOT:/var/www/certbot certbot/certbot certonly --webroot -w /var/www/certbot \
  -d 1-2-3-4.sslip.io --agree-tos --register-unsafely-without-email
ln -sfn /opt/openspeak/letsencrypt/live/1-2-3-4.sslip.io /opt/openspeak/tls
cp deploy/*.service deploy/*.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now openspeak openspeak-renew.timer
```

Mô hình âm vị (khoảng 1,2 GB) được tải ở lần chấm đầu tiên; dịch vụ giới hạn 3 GB RAM để không lấn các dịch vụ khác. API hiện chưa có đăng nhập. Trước khi đặt `LLM_API_KEY` trên máy chủ mở ra Internet, nên thêm một lớp xác thực để người khác không dùng được khoá của bạn.

## Chạy app iOS

Cần Xcode 15 trở lên.

```bash
cd ios
brew install xcodegen   # nếu chưa có
xcodegen generate       # sinh lại OpenSpeak.xcodeproj sau khi thêm hoặc xoá file
open OpenSpeak.xcodeproj
```

Chọn Team ký ứng dụng trong mục Signing rồi chạy. Trên Simulator, backend mặc định là `http://localhost:8000`. Trên iPhone thật, app dùng máy chủ ghi trong `ios/Config/Server.local.xcconfig` (file này không đưa lên git), hoặc địa chỉ nhập ở **Hồ sơ → Máy chủ AI**. Quay khẩu hình cần camera trước nên phải chạy trên máy thật.

```
# ios/Config/Server.local.xcconfig — xcconfig coi "//" là chú thích nên viết https:/$()/
OPENSPEAK_SERVER_URL = https:/$()/may-chu-cua-ban:8443
```

### Tạo file IPA để cài thử

Không có tài khoản Apple Developer trả phí thì không ký được bản cài qua đường link. Cách làm là build bản chưa ký, rồi để Sideloadly hoặc AltStore ký lại bằng Apple ID của bạn khi cài:

```bash
cd ios && xcodegen generate
xcodebuild -project OpenSpeak.xcodeproj -scheme OpenSpeak -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p build/ipa/Payload && cp -R build/Build/Products/Release-iphoneos/OpenSpeak.app build/ipa/Payload/
(cd build/ipa && zip -qry OpenSpeak.ipa Payload)
```

Ứng dụng ký bằng Apple ID miễn phí chỉ chạy được 7 ngày, sau đó cần cài (ký) lại. Trên iPhone phải bật **Cài đặt → Quyền riêng tư & Bảo mật → Chế độ nhà phát triển**.

Nếu có chứng chỉ phân phối kèm provisioning profile Ad Hoc (đã đăng ký UDID của máy), bundle ID của app phải trùng App ID trong profile. Profile không dùng dấu `*` mà app vẫn giữ `com.example.openspeak` thì iOS từ chối cài, và khi cài qua link sẽ không hiện thông báo gì. Ký lại sau khi đổi `CFBundleIdentifier` và nhúng `embedded.mobileprovision`, rồi đặt file `.ipa`, một `manifest.plist` và một trang có link `itms-services://?action=download-manifest&url=…/manifest.plist` vào thư mục `DOWNLOAD_DIR` của backend. Safari trên iPhone sẽ cài thẳng từ link đó; máy chủ phải có HTTPS hợp lệ.

Cấu trúc màn hình:

Giao diện tối nền tím than, 5 tab như ELSA:

| Tab | Nội dung |
|---|---|
| Coach | Bộ đếm chuỗi ngày, XP, số âm đã thành thạo; thẻ Phân tích giọng nói, Huấn luyện phát âm, Huấn luyện hội thoại; bài tiếp theo, ôn tập |
| Học | Hai mục "Nền tảng IPA" và "Lộ trình cá nhân". Nền tảng IPA: danh sách Unit, mỗi Unit gồm các "Bài N" (bài đang học nền trắng, chấm xanh), ôn tập, bảng IPA, luyện nghe/đọc/cặp âm. Lộ trình cá nhân: bài kế tiếp kèm lý do chọn, và các bài đã học |
| Hội thoại | Danh sách tình huống, màn giới thiệu 3 nhiệm vụ, màn chat có micro |
| Khám phá | Tra từ điển, 24 chủ đề từ vựng, bài từ mới do AI giao, thẻ ôn, sổ từ |
| Tiến độ | Biểu đồ radar 6 kỹ năng, mức CEFR ước lượng (sau 5 lần chấm), XP 7 ngày, thống kê; nút bánh răng mở Hồ sơ và cài đặt |

### Chụp toàn bộ màn hình trên Simulator

Target `OpenSpeakUITests` gồm 18 bài test, đi qua mọi màn và lưu ảnh theo tên `<số test>-<bước>-<tên màn>.png`: onboarding, 5 tab, cả 7 bước của một bài học âm, bảng IPA và chi tiết âm, từng bước của hướng dẫn khẩu hình, ba bài luyện (nghe, đọc phiên âm, cặp âm) kể cả trạng thái đã trả lời đúng/sai và màn tổng kết, luyện nói và 5 tab kết quả, chi tiết từng từ, hội thoại, từ điển, thẻ từ, ôn tập, tiến độ, hồ sơ, các bước của một bài trong lộ trình cá nhân, hội thoại bằng giọng nói: lượt nói hiện ngay sau khi dừng ghi, được chấm phát âm và ngữ điệu, câu đáp của AI nằm trong màn hình (bài 16), bài kiểm tra của lộ trình (bài 17) và việc tô ký hiệu một nét hoặc vẽ lung tung không được qua (bài 18). Bài 11 và 14 mở lại các màn chính và các màn có nút thao tác với cỡ chữ Accessibility XL. Cả bộ chạy khoảng 20 phút.

Màn nào có nút thao tác chính (Tiếp tục, Phát, Bắt đầu ghi âm, Hoàn thành...) thì nút đó nằm trên một thanh ghim ở đáy màn hình, nội dung cuộn phía trên. Bài test kiểm tra điều này ở từng màn: nút phải bấm được và nằm trọn trong màn hình mà không cần cuộn, kể cả ở cỡ chữ lớn.

Mac không có micro thì dùng một file ghi âm có sẵn thay cho lần ghi, nhận dạng giọng nói trả một câu cố định (`OPENSPEAK_FAKE_TRANSCRIPT`), và bước tô ký hiệu được cho qua sau nét thứ hai (`OPENSPEAK_EASY_TRACE`, trừ bài 18). `OPENSPEAK_SEED_PATH=exam` tạo sẵn 4 bài lộ trình đã học để bài kiểm tra đến hạn. Tất cả chỉ có trong bản Debug. Backend phải đang chạy.

Target `OpenSpeakTests` (unit test) kiểm cách chấm bài tô ký hiệu: tô kín thì qua, một nét, nét chỉ qua một phần của ký hiệu hoặc vẽ cạnh ký hiệu thì không. Chạy bằng `-only-testing:OpenSpeakTests`.

```bash
cd ios
xcodegen generate
xcrun simctl privacy booted grant microphone com.example.openspeak
mkdir -p /tmp/shots
TEST_RUNNER_SHOTS_DIR=/tmp/shots \
TEST_RUNNER_FAKE_TAKE=$PWD/../backend/calib/speechocean762/WAVE/SPEAKER0001/000010011.WAV \
xcodebuild -project OpenSpeak.xcodeproj -scheme OpenSpeak \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Volumes/DATA/Xcode/DerivedData/OpenSpeak CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Bản simulator cần ký ad hoc (`CODE_SIGN_IDENTITY=-`); nếu tắt hẳn ký (`CODE_SIGNING_ALLOWED=NO`) thì Keychain từ chối lưu khoá LLM (mã -34018) và bài 15 sẽ hỏng.

Thêm `TEST_RUNNER_BACKEND_URL=https://may-chu-cua-ban:8443` để app trong bài test gọi máy chủ đã deploy thay cho localhost.

Bài 15 nhập LLM riêng trong Hồ sơ, kiểm tra lần lượt 3 định dạng, thử một model sai để chụp màn báo lỗi, rồi xin một bài lộ trình và đòi bài đó do AI soạn. Nó cần `TEST_RUNNER_LLM_BASE` (địa chỉ gốc, không có `/v1`) và `TEST_RUNNER_LLM_KEY`, cùng backend chạy với `LLM_ALLOW_PRIVATE_URLS=1` nếu địa chỉ là localhost. XCTest ghi lại chữ được gõ vào log kết quả, nên đừng đưa khoá thật: hãy dựng một relay cục bộ nhận một khoá giả rồi tự gắn khoá thật trước khi chuyển tiếp.

Bộ ảnh gần nhất (iPhone 17, iOS 27.2) nằm ở `docs/ui-walkthrough/`; các cặp ảnh trước/sau của những lỗi giao diện đã sửa nằm ở `docs/ui-walkthrough/review/`. Simulator không có camera nên màn "Quay khẩu hình" chỉ chụp được trạng thái báo lỗi. Ảnh của bài 03, 12, 16 và 17 chụp với backend có LLM (claude-sonnet-5-5 qua relay cục bộ), nên câu hỏi, bài kiểm tra và câu đáp trong hội thoại là do AI viết; các ảnh còn lại chụp khi chưa có LLM nên hội thoại ở bài 06 dừng ở thông báo lỗi máy chủ.

## Cách AI "nghe" phát âm

Nếu chuyển giọng nói thành chữ rồi đưa cho LLM, lỗi phát âm sẽ bị mất, vì mô hình nhận dạng tự sửa "sink" thành "think". Backend làm như sau:

1. **Nhận dạng âm vị** (`recognizer.py`): wav2vec2 được huấn luyện để xuất ra âm vị IPA thay vì chữ, nên người học nói /s/ thì mô hình nghe ra /s/.
2. **Căn chỉnh và chấm từng âm** (`alignment.py`):
   - Căn chỉnh CTC cưỡng bức (forced alignment) theo phiên âm chuẩn để biết mỗi âm nằm ở đoạn nào.
   - Điểm GOP (Goodness of Pronunciation) đo độ chắc chắn của mô hình với âm đúng so với các âm khác.
   - Thuật toán Needleman-Wunsch chỉ ra âm bị thay (ví dụ /θ/ thành /s/) hoặc bị bỏ.
3. **Ngữ điệu** (`prosody.py`): Praat trích đường cao độ F0 và đổi sang nửa cung so với giọng của chính người nói. Từ đó đo:
   - độ dốc cuối câu (câu hỏi Yes/No phải lên giọng),
   - độ biến thiên cao độ,
   - độ giống đường cao độ của giọng mẫu (DTW).
4. **Trọng âm**: so cao độ, độ to và độ dài của từng nguyên âm với trọng âm trong CMUdict.
5. **Nối âm** (`connected_speech.py`): đánh dấu các chỗ người bản xứ đọc liền, gồm phụ âm nối nguyên âm, flap /t/ thành /ɾ/, chèn /j/ hoặc /w/, linking r, đồng hoá /t/+/j/ thành /tʃ/, nuốt âm và hai phụ âm giống nhau. Chỗ nối bị tính là "đứt" khi có tắc thanh hầu /ʔ/ hoặc khoảng lặng dài.
6. **Khẩu hình** (`articulation.py`): mỗi âm có một tư thế môi, hàm và lưỡi. App iOS dùng Vision để đo độ mở và độ rộng của môi (chia cho khoảng cách hai mắt) tại thời điểm của từng âm. Backend so các số đo này với mức trung bình của chính người học. Những gì camera đo không được, như răng chạm môi ở /f v/ hay lưỡi giữa răng ở /θ ð/, thì gửi ảnh cận miệng cho LLM thị giác xem.

### Hiệu chỉnh điểm trên nhiều mô hình

Điểm từng âm được hiệu chỉnh và kiểm tra trên ba bộ dữ liệu, cùng với 7 mô hình nhận dạng âm vị lấy từ Hugging Face.

**Dữ liệu:**

| Bộ dữ liệu | Dùng để | Nội dung |
|---|---|---|
| **speechocean762** (OpenSLR 101, CC BY 4.0) | Hiệu chỉnh và chấm chính | Người học có tiếng mẹ đẻ là tiếng Trung, chỉ lấy người lớn: 67 người ở tập train, 61 người khác hoàn toàn ở tập test. Mỗi âm, từ, câu có điểm của 5 chuyên gia |
| **L2-ARCTIC**, phần chú thích tay (CC BY-NC 4.0, `chikingsley/l2-arctic-manual-v5.0-16k`) | Kiểm tra độc lập | 1.784 câu của 12 người với 6 tiếng mẹ đẻ, trong đó có 2 người Việt (THV, TLV). Mỗi âm được đánh dấu đúng, bị thay hoặc bị bỏ |
| **LibriSpeech** test-clean (CC BY 4.0) | Đối chứng người bản xứ | 359 câu của 40 người Mỹ. Đo xem app báo sai nhầm bao nhiêu âm khi người bản xứ nói |

```bash
cd backend
pip install pyarrow                     # đọc file parquet của L2-ARCTIC / LibriSpeech
calib/run_all.sh                        # chạy 7 mô hình × 3 bộ dữ liệu, chạy tiếp được nếu bị ngắt
python -m tools.calibrate compare --write   # so sánh, ghi mô hình tốt nhất vào app/calibration.json
```

File parquet đặt ở `calib/l2arctic/{validation,test}.parquet` và `calib/librispeech/test-clean.parquet`. Lệnh `extract --model M --dataset D --split S` chạy từng phần riêng.

**Cách làm với mỗi mô hình:**
1. Thử ba đặc trưng âm học, mỗi đặc trưng với nhiều thang và trọng số, rồi chọn bộ có tương quan Pearson cao nhất với chuyên gia trên tập train:
   - GOP;
   - LPP, là log-xác suất trung bình của âm đúng;
   - margin, là khoảng cách với âm cạnh tranh mạnh nhất.
2. Ánh xạ tuyến tính sang thang 0–100.
3. Chọn ngưỡng "Đúng / Gần đúng" có balanced accuracy cao nhất.

Mọi mô hình được so trên cùng một tập câu.

**Kết quả trên tập test:**

| Mô hình | Âm | Từ | Câu | AUC trên L2-ARCTIC | AUC với người Việt | Báo sai nhầm người bản xứ |
|---|---|---|---|---|---|---|
| `mrrubino/wav2vec2-large-xlsr-53-l2-arctic-phoneme` **(đang dùng)** | **0,548** | **0,501** | 0,694 | (0,939)* | (0,971)* | 8,4% |
| `Peacockery/hubert-base-phoneme-en` | 0,503 | 0,479 | **0,726** | 0,671 | 0,747 | **4,7%** |
| `facebook/wav2vec2-lv-60-espeak-cv-ft` (bản trước) | 0,459 | 0,425 | 0,667 | 0,665 | 0,770 | 19,7% |
| `vitouphy/wav2vec2-xls-r-300m-timit-phoneme` | 0,449 | 0,417 | 0,635 | 0,785 | 0,861 | 15,4% |
| `facebook/wav2vec2-xlsr-53-espeak-cv-ft` | 0,399 | 0,377 | 0,687 | 0,701 | 0,807 | 8,0% |
| `ginic/…-xlsr-53-buckeye-ipa` | 0,378 | 0,318 | 0,653 | 0,787 | 0,854 | 15,9% |
| `bookbot/wav2vec2-ljspeech-gruut` | 0,339 | 0,311 | 0,653 | 0,670 | 0,752 | 8,6% |

Cách đọc bảng:
- Ba cột đầu là tương quan với điểm chuyên gia của speechocean762.
- AUC là xác suất một âm bị chú thích là sai có điểm thấp hơn một âm đúng: 0,5 là đoán bừa, 1 là hoàn hảo.
- \* mrrubino được huấn luyện trên chính L2-ARCTIC, nên hai số AUC của nó không phải kiểm tra độc lập và **không được dùng để chọn mô hình**.

Mô hình được chọn theo tương quan từng âm trên speechocean762, là bộ không mô hình nào được huấn luyện trên đó. Lấy mẫu lại theo người nói (bootstrap, 1.000 lần) cho thấy khoảng cách là thật:
- mrrubino hơn bản trước +0,087, khoảng tin cậy 95% là [+0,057; +0,113].
- mrrubino hơn HuBERT +0,045, khoảng tin cậy [+0,030; +0,059].

Với mrrubino, ngưỡng âm "Đúng" là 89 điểm. Điểm trôi chảy khớp chuyên gia khá tốt (0,699).

**Giới hạn còn lại:**
- **Ngữ điệu gần như không khớp** điểm "prosodic" của chuyên gia (0,012), nên hãy coi điểm ngữ điệu là gợi ý về hướng lên/xuống giọng.
- Với người Việt, các âm hay sai nhất trong L2-ARCTIC là /z/ (73% số lần), /ð/ (71%), /ɝ/ (60%), /θ/, /d/ và /v/. Với các mô hình không học trên L2-ARCTIC, /ð/ và /ɝ/ là hai âm khó phát hiện nhất: AUC chỉ khoảng 0,52 đến 0,65.
- Số người Việt có chú thích còn rất ít, và speechocean762 là người Trung Quốc.
- Bản ghi YouTube không dùng được để hiệu chỉnh vì không có điểm chuyên gia.
- Bộ `tiennguyenbnbk/gopt-vh-gold` (6.361 câu IELTS của người Việt, có điểm từng âm) phù hợp nhất nhưng không ghi giấy phép, nên chưa dùng.
- Giấy phép: L2-ARCTIC là CC BY-NC, và mrrubino được huấn luyện trên dữ liệu đó, nên chỉ dùng cho mục đích cá nhân, phi thương mại.

## Hình khẩu hình và hướng dẫn từng bước

Mỗi âm có một thẻ khẩu hình (trang chi tiết âm, bước "Làm quen" của bài học, hướng dẫn trong màn luyện nói):

- **Mặt cắt khoang miệng** vẽ bằng code: da mặt, môi, răng, lợi, ngạc cứng, ngạc mềm, lưỡi, khoang mũi và dây thanh, mỗi phần một màu. Nhãn tiếng Việt nằm trong ô nền trắng cỡ chữ cố định 11 pt nên không đè lên nhau; khi hình nhỏ hơn 200 pt thì nhãn được ẩn.
- **Môi nhìn thẳng** đặt cạnh mặt cắt.
- **Chú thích màu** ngay dưới hình: luồng hơi, điểm chạm, dây thanh rung hay không rung. Màu nào cũng có chữ đi kèm.
- **"Tập từng bước"**: các bước mô tả cấu âm (Môi, Hàm, Lưỡi, Luồng hơi, Dây thanh, Trượt sang âm sau) được tách thành từng trang. Ở mỗi bước, bộ phận đang nói tới được viền trắng hoặc khoanh nét đứt, phần còn lại mờ đi, và các bước trước vẫn giữ nguyên tư thế, nên khẩu hình được dựng dần cho tới bước cuối. Có thanh tiến độ, "Bước n/N", nút "Bước trước" và "Bước sau"; ở bước cuối nút đổi thành "Xem toàn bộ".
- Khi bật Giảm chuyển động (Reduce Motion), hình chuyển bước không có hiệu ứng và luồng hơi đứng yên.

## Khẩu hình động

Nút "Khẩu hình" ở thẻ từ, câu luyện và trang chi tiết âm mở trình phát khẩu hình cho **cả từ hoặc cả câu**:

- Chuỗi âm lấy từ IPA. Thời lượng mỗi âm theo cách phát âm, âm nhấn dài hơn, âm cuối câu kéo dài; /p t k/ đầu từ hoặc trước âm nhấn được bật hơi.
- Mỗi khung có mặt cắt khoang miệng (môi, răng, lưỡi, ngạc mềm, dây thanh có ghi chú) và môi nhìn thẳng. Luồng hơi chạy thành vệt động: hít vào, chặn hơi (vòng đỏ), bật hơi, xì qua khe, đi êm, đi qua mũi. Dây thanh rung khi âm hữu thanh.
- Dải cao độ phía trên cho thấy giọng lên/xuống, âm nhấn được tô đậm. Thời gian khớp với audio mẫu bằng căn chỉnh của backend.
- Chạy chậm 0,5× hoặc 0,25×, đi từng âm, kéo để tua. Danh sách gợi ý tiếng Việt cho môi, răng, lưỡi, hơi, giọng ở âm đang xem.

## Nội dung bài học

Phiên âm, mô tả khẩu hình, lộ trình bài học, cặp âm tối thiểu và câu luyện có chú thích nối âm đều được sinh từ cùng mã nguồn với backend:

```bash
cd backend && python -m tools.build_content
```

Lệnh này ghi JSON vào `ios/OpenSpeak/Resources/Content/`. Mẹo tiếng Việt, thứ tự bài học và câu luyện được sửa trong `backend/tools/build_content.py`.

## Theo Human Interface Guidelines của Apple

Giao diện đã được rà theo [HIG](https://developer.apple.com/design/human-interface-guidelines). Mỗi thay đổi dưới đây dựa trên một câu cụ thể trong HIG:

| Quy tắc HIG (trang) | Thay đổi trong app |
|---|---|
| Chữ cỡ tới 17 pt cần tương phản tối thiểu 4.5:1 (Accessibility, Dark Mode) | Nút có chữ trắng dùng bộ màu nền đậm riêng (`Theme.primaryFill`, `goodFill`, `okFill`, `badFill`), đạt từ 4.68:1 đến 5.09:1. Màu cũ chỉ đạt 1.96:1 đến 3.10:1. Chữ tím và chữ đỏ trên thẻ được làm sáng hơn, đạt 7.0:1 và 6.43:1 |
| Không truyền tải thông tin chỉ bằng màu (Accessibility, Color) | Đáp án đúng/sai có thêm biểu tượng ✓ hoặc ✗ và nhãn VoiceOver; từ điểm thấp trong kết quả có gạch chân chấm; mọi màu trên hình khẩu hình có chú thích bằng chữ |
| Vùng chạm tối thiểu 44×44 pt (Accessibility) | Nút gửi tin, chip âm vị, nút đóng bài học, nút lùi/tiến âm trong trình phát khẩu hình được nới tới 44 hoặc 52 pt |
| Hỗ trợ cỡ chữ lớn, ít nhất 200% (Accessibility) | Chữ dùng kiểu chữ hệ thống (Dynamic Type) thay cho cỡ cố định. Ở cỡ Accessibility, hàng thống kê và mục tiêu ngày ở trang chủ, thanh điểm chuyển sang xếp dọc; ô bảng IPA rộng theo cỡ chữ; màn câu hỏi cuộn được khi không đủ chỗ. Trong "Tập từng bước", mỗi lần chuyển bước thẻ tự cuộn để hình khẩu hình hiện cùng lời hướng dẫn, và nút "Bước trước" thu thành mũi tên (VoiceOver vẫn đọc đủ tên) để hai nút nằm chung một hàng |
| Chuyển động phải tắt được (Motion) | Hình khẩu hình, trình phát khẩu hình, vòng điểm và quầng micro không chuyển động khi bật Giảm chuyển động |
| Hạn chế phần tử giới hạn thời gian (Accessibility) | Bước "Nhận mặt ký hiệu" và các câu hỏi nghe không tự chuyển sau 0,6–0,7 giây. Người học thấy phản hồi rồi tự bấm "Tiếp" |
| Việc phức tạp mở dạng modal toàn màn hình; luôn có cách đóng rõ ràng (Modality); tab bar chỉ được che khi có modal (Tab bars) | Bài học, ôn tập, bài luyện, luyện nói và hội thoại mở dạng modal toàn màn hình, không còn ẩn tab bar trong màn được đẩy vào |
| Dùng nút Close chuẩn, không dùng chữ "Đóng" (Toolbars) | Modal và sheet dùng nút đóng của hệ thống (`Button(role: .close)` trên iOS 26, biểu tượng xmark trên iOS cũ hơn) |
| Sheet đổi được cỡ thì có thanh kéo (Sheets) | Sheet chi tiết từ hiện thanh kéo |
| Ô nhập có nút xoá ở cuối (Text fields) | Mọi ô nhập một dòng hiện nút xoá khi đang gõ |
| Nhãn tab nên là một từ (Tab bars) | Tab "Hội thoại AI" đổi thành "Hội thoại"; tiêu đề màn vẫn là "Hội thoại AI" |

Không làm theo: HIG khuyên hỗ trợ cả giao diện sáng và tối. App vẫn chỉ dùng nền tối để giữ giao diện giống ELSA; HIG cho phép điều này "trong một số ít trường hợp".

Cặp ảnh trước/sau của các thay đổi này (hình khẩu hình, từng bước, dấu đúng/sai, modal có nút đóng, tương phản nút, bỏ tự chuyển bước, hội thoại, ôn tập âm) nằm ở `docs/ui-walkthrough/review/hig/`.

## Giao diện, asset và giấy phép

App đi theo **luồng trải nghiệm** của các app luyện phát âm: onboarding hỏi trình độ, mục tiêu và chủ đề; trang chủ có chuỗi ngày học và bài tiếp theo; lộ trình dạng đường đi; màn luyện nói có micro lớn và chữ tô màu theo điểm; chạm vào từ để xem chi tiết từng âm. Mọi hình ảnh đều tự làm, không chứa asset, hình ảnh, âm thanh hay nhận diện thương hiệu của ELSA hoặc app khác.

- Biểu tượng: SF Symbols, được phép dùng trong app iOS.
- Sơ đồ khẩu hình (mặt cắt khoang miệng và môi nhìn thẳng): vẽ bằng code từ bảng cấu âm, không dùng ảnh.
- Âm mẫu cho từ đơn: **giọng người thật từ Wikimedia Commons**, ưu tiên bộ `En-us-<từ>.ogg` (giọng Mỹ), nếu không có thì Lingua Libre (giọng không xác định vùng). Backend tải một lần, giải mã sang WAV, lưu trong `backend/cache/` và app lưu trong Caches. Thẻ từ hiện tên người ghi âm, giấy phép (thường là CC BY-SA) và đường dẫn tới file gốc. Đo trên 96 trong 144 từ có sẵn: 77 có giọng Mỹ, 18 chỉ có Lingua Libre, 1 không có. Cụm từ, câu và từ không có bản ghi dùng giọng đọc của iOS. Backend gửi User-Agent có tên app và địa chỉ liên hệ theo chính sách của Wikimedia. Trước đây User-Agent mặc định bị trả 429 và backend chờ rồi thử lại, nên app đợi tới hàng chục giây mới phát được một từ. Giờ gặp 429 thì backend trả 503 ngay và tạm ngừng hỏi Commons trong thời gian `Retry-After`. App luôn phát ngay (bản ghi nếu đã có, không thì giọng iOS) và tải trước bản ghi của các từ trong bài ở nền. Đo trên VPS: lần đầu 0,4–2 giây mỗi từ, đã lưu thì khoảng 10 ms.
- Âm IPA đơn lẻ: giọng đọc của iOS. Muốn có âm IPA đơn lẻ chuẩn hơn, đặt file `phoneme_<ID>.m4a` (ví dụ `phoneme_TH.m4a`) vào `ios/OpenSpeak/Resources/` và app sẽ ưu tiên dùng file này. Bộ audio IPA trên Wikimedia Commons phần lớn là CC BY-SA hoặc public domain; cần kiểm tra giấy phép và ghi công từng file.
- Dữ liệu và mô hình:
  - CMUdict: giấy phép kiểu BSD.
  - Wiktionary: CC BY-SA, phải ghi nguồn.
  - Mô hình âm vị `mrrubino/wav2vec2-large-xlsr-53-l2-arctic-phoneme`: thẻ mô hình ghi Apache 2.0, nhưng mô hình được huấn luyện trên L2-ARCTIC (CC BY-NC 4.0), nên chỉ dùng cho mục đích phi thương mại.
  - Praat/parselmouth: GPL. Chỉ chạy trên server nên không phân phối kèm app.
- Biểu tượng ứng dụng: tự vẽ bằng code (vòng bong bóng thoại hở quanh 5 vạch sóng giọng nói, nét gradient trên nền trắng). Vẽ lại bằng `python ios/tools/make_app_icon.py` (cần Pillow); lệnh ghi đè `AppIcon.appiconset/AppIcon.png`.

## Đối chiếu với ELSA

Cấu trúc giao diện được đối chiếu từ hai nguồn chính thức, không dựa vào phỏng đoán và không dùng bản IPA giải mã:

1. Ảnh chụp màn hình ELSA Speak 9.2.6 trên App Store và Google Play.
2. Gói APK chính thức ELSA Speak 9.2.6 tải từ APKMirror. Gói đã được kiểm chứng như sau:
   - Tên gói `us.nobarriers.elsa`, phiên bản 9.2.6 (mã 9067).
   - Chữ ký APK v2/v3, chứng chỉ `CN=nobarriers`, SHA-256 `6d02ac8e2b0b4a957ffa36d6883fb7054c9a02d342c7aa0721dab76d65f7ae8c`. Dấu vân tay này trùng với chứng chỉ APKMirror công bố cho ELSA.
   - SHA-256 của gói `.apkm`: `d5c2208b8fcf57c032b5d63e0fe6513158f8eaf7bfa3ba727795cd10aab94950`.

   App viết bằng Flutter (kèm Unity, Rive, Lottie). Từ `libapp.so` chỉ đọc **tên lớp màn hình và widget** để biết cấu trúc. Không lấy hình ảnh, âm thanh, chữ hay mã nào của ELSA vào dự án, và gói APK không nằm trong repo.

Những gì thấy trong ảnh và đã làm theo:

- Nền tối gradient tím, 5 tab Coach / Learn / AI Chats / Discover / Progress.
- Hàng bộ đếm trên cùng: chuỗi ngày, điểm thưởng, cúp.
- Thẻ Coach có nút "Practice"; onboarding chọn mục tiêu và trình độ bằng chip phát sáng.
- Learning Path: "N Units · CEFR", danh sách "Lesson N" kèm loại bài, bài hiện tại nền trắng có chấm xanh, "Unit 2 0/5 Lessons".
- Roleplay: tên tình huống, "3–5 Minutes · Medium", danh sách 3 nhiệm vụ, nút "Start Conversation", nút chuyển tiếng Việt.
- Progress: radar kỹ năng có điểm, nhãn trình độ CEFR, nút xanh dương sang bài học.

Ảnh cửa hàng không có màn kết quả chấm phát âm. Các phần sau lấy từ tên lớp trong APK và đã làm theo:

| Thấy trong APK | OpenSpeak |
|---|---|
| `PhonemeScoreType` với 3 mức `correct` / `almostCorrect` / `incorrect` | Mỗi âm có 3 mức: Đúng / Gần đúng / Sai (bị thay hoặc bị bỏ), kèm chú thích màu |
| `AdvanceFeedbackTappedWordPage`, `WordPronunciationAnalysisView` | Chạm một từ để mở chi tiết từng âm, trọng âm và cách sửa khẩu hình |
| `SaOverallPage`, `SaPronunciationPage`, `SaFluencyPage`, `SaIntonationPage` | Màn kết quả chia tab: Tổng quan, Phát âm, Trôi chảy, Ngữ điệu (thêm Nối âm) |
| `SpeakingPaceGauge`, `SaSpeakingPaceBand`, `HesitationTranscriptLegend` | Thanh tốc độ Chậm / Tự nhiên / Nhanh và câu nói có đánh dấu ⏸ ở chỗ ngắt dài |
| `IntonationProminenceDisplaySegment` | Biểu đồ cao độ của bạn so với giọng mẫu |
| Nhãn "COMPARE HOW IT SOUNDS" | Nút "So sánh cách nói": phát giọng bạn rồi đến giọng mẫu |
| `SLPhonemeErrorItem` | Tab Phát âm liệt kê các âm sai, sắp xếp từ sai nhất, ghi "nghe như /s/" hoặc "bị bỏ mất" |

Thấy trong APK nhưng **chưa làm**:

- Speech Analyzer chấm ngữ pháp và từ vựng khi nói tự do (`SaGrammarPage`, `SaVocabularyPage`).
- Đếm từ đệm như "um", "uh" (`SLFluencyTopFiller`).
- Shadowing (`ShadowingPracticePage`), Vocab Coach, bảng xếp hạng.

Ba mức âm của OpenSpeak được xác định như sau:
- **Sai**: mô hình nghe ra âm khác, hoặc không nghe thấy âm.
- **Đúng** và **Gần đúng**: phân định bằng ngưỡng điểm hiệu chỉnh trên speechocean762.

Đây **không** phải ngưỡng của ELSA. Tên lớp trong APK không cho biết ELSA chấm thế nào.
