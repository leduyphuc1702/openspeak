"""Offline material for the personal path: what lessons are built from when no
LLM is configured, and what an LLM lesson is topped up with when some of its
items fail validation. Every item is checked against the lexicon at load time,
so a word the scorer cannot handle never reaches the app."""
from __future__ import annotations

from typing import Dict, List, Tuple

# Common everyday and workplace words (American English).
COMMON_WORDS = """
a about above accept account action actually address advice afraid after afternoon again age agree ahead
air airport allow almost alone already also always amazing amount angry animal another answer anyone
anything apartment apple appointment area arm around arrive art ask asleep attention aunt available
avoid away baby back bad bag bake bakery balance ball bank bath bathroom battery beach bear beautiful
because bed bedroom beef before begin behind believe bell best better between big bike bill bird birthday
bit bitter black blue board boat body boil book boring born borrow boss both bottle bought box boy brain
bread break breakfast breathe bridge bright bring brother brown budget build building bus business busy
butter buy cake call calm camera can card care careful carry case cash casual cat catch caught chair
chance change cheap check cheese chicken child choice choose church city class clean clear client climb
clock close clothes cloud coat coffee coin cold collect color come comfortable company compare complain
computer confirm connect contract cook cookie cool copy corner correct cost could count country couple
course cousin cover crazy cream credit cross crowd cry culture cup customer cut daily dance danger dark
data date daughter day deal dear decide decision deep delay delicious deliver dentist design desk detail
dinner direct dirty discuss doctor dog door double doubt down draw dream dress drink drive drop dry during
early earn easy eat edge egg eight either else email empty end enemy energy engineer enjoy enough enter
entire equal error evening event every exactly example excellent excited exercise expect expensive
explain eye face fact fail fair fall family famous far farm fast father fault favorite fear feel feet
fever few field fight file fill film final find fine finger finish fire first fish five fix flight floor
flower fly follow food foot forget fork form forward four free fresh friend front fruit full fun funny
future garage garden gas gather get gift girl give glad glass go gold good great green grow guess guest
guide gym hair half hall hand happen happy hard hat have head health hear heart heat heavy hello help
here high hill history hit hold holiday home hope horse hospital hot hotel hour house however huge human
hungry hurry hurt husband idea important improve include increase inside interest invite island issue
item job join joke journey judge juice jump just keep key kid kind kitchen knee knife know lake land
language large last late later laugh law lazy lead learn leave left leg leisure lend less lesson letter
level library lie life light like line list listen little live local lock long look lose loss lot loud
love lucky lunch machine main make manager many map market marry match matter maybe meal mean measure
meat medicine meet meeting member menu message metal middle might mind minute mirror miss mistake money
month moon more morning mother mountain mouth move movie much music must name nation near need neighbor
nervous never new news next nice night nine noise noon normal north nose note nothing notice now number
nurse ocean offer office often oil old open order other outside over own page pain paint pair paper
parent park part party pass past pay peace pen people pepper perfect person phone photo pick picture
piece pink place plan plane plant plate play please pleasure plenty pocket point police polite pool poor
popular possible pound power practice prepare present pretty price print problem project promise proud
pull push put quarter question quick quiet quite race rain raise rather reach read ready real reason
receive record red relax remember rent repair repeat reply report rest result return rice rich ride
right ring river road rock room round rule run sad safe salary salt same save say school sea season
seat second see sell send sense serious serve service share sheep shirt shoe shop short should shout
show shower sick side sign simple sing sister sit six size skill sky sleep slow small smart smell smile
snow soft some son song soon sorry sound soup south space speak special spend spoon sport spring staff
stand start station stay steak step still stop store story street strong student study sugar summer
sun sure surprise sweet swim table take talk tall taste taxi tea teach teacher team television tell ten
test thank theater there these thick thin thing think third thirsty this those though thought thousand
three through throw thumb ticket tidy time tired today together toilet tomorrow tonight tooth top total
touch tourist toward town toy traffic train travel treasure tree trip trouble true trust truth try turn
twelve two uncle under understand until usual usually vacation valley value vegetable very video view
village visit vision voice wait walk wall want warm wash watch water way wear weather wedding week
weekend weight welcome well west wet what wheel when where which while white who whole why wife will
win wind window wine winter wish with without woman wonder wood word work world worry would write wrong
yard year yellow yes yesterday yet young zero zone
""".split()

# (sentence, Vietnamese meaning). Short to long; everyday life and work.
SENTENCES: List[Tuple[str, str]] = [
    ("Thank you so much.", "Cảm ơn bạn rất nhiều."),
    ("I think so too.", "Tôi cũng nghĩ vậy."),
    ("See you next week.", "Hẹn gặp bạn tuần sau."),
    ("Is this seat free?", "Ghế này còn trống không?"),
    ("She is my sister.", "Cô ấy là chị gái tôi."),
    ("The shop is closed.", "Cửa hàng đóng cửa rồi."),
    ("Could you say that again?", "Bạn nói lại được không?"),
    ("I need a quick break.", "Tôi cần nghỉ một chút."),
    ("We have a meeting at three.", "Chúng ta có cuộc họp lúc ba giờ."),
    ("Let me check my schedule.", "Để tôi xem lịch đã."),
    ("This is the third time.", "Đây là lần thứ ba rồi."),
    ("My brother lives with my father.", "Anh trai tôi sống cùng bố tôi."),
    ("I usually read the news at noon.", "Tôi thường đọc tin tức vào buổi trưa."),
    ("Please send me the file today.", "Hôm nay gửi tôi tệp đó nhé."),
    ("The weather is warm this weekend.", "Cuối tuần này trời ấm."),
    ("I would like a cup of tea.", "Tôi muốn một tách trà."),
    ("He bought a new bike last week.", "Tuần trước anh ấy mua xe đạp mới."),
    ("Can we move the call to Monday?", "Mình dời cuộc gọi sang thứ Hai được không?"),
    ("The sheep is on the ship.", "Con cừu ở trên con tàu."),
    ("I feel much better today.", "Hôm nay tôi thấy khoẻ hơn nhiều."),
    ("Leave the bag by the bed.", "Để cái túi cạnh giường."),
    ("The man has a black cat.", "Người đàn ông có một con mèo đen."),
    ("Thank you for your help with the report.", "Cảm ơn bạn đã giúp làm báo cáo."),
    ("They both think the plan is good.", "Cả hai người đều nghĩ kế hoạch này tốt."),
    ("There are three things on the list.", "Có ba việc trong danh sách."),
    ("Those clothes are in the wash.", "Mấy bộ quần áo đó đang giặt."),
    ("Her voice was very clear on the phone.", "Giọng cô ấy qua điện thoại rất rõ."),
    ("We enjoy our coffee in the morning.", "Chúng tôi thích uống cà phê buổi sáng."),
    ("Make a choice and join the team.", "Hãy chọn và tham gia đội."),
    ("The noise from the street is too loud.", "Tiếng ồn ngoài đường to quá."),
    ("I could not find a good book.", "Tôi không tìm được cuốn sách hay nào."),
    ("You should look at the photo.", "Bạn nên xem bức ảnh này."),
    ("Put the sugar next to the cookies.", "Để đường cạnh mấy cái bánh quy."),
    ("The food was cool and the soup was good.", "Đồ ăn nguội nhưng súp thì ngon."),
    ("It is a pleasure to meet you.", "Rất vui được gặp bạn."),
    ("We usually watch television after dinner.", "Chúng tôi thường xem ti vi sau bữa tối."),
    ("That was a hard decision for the team.", "Đó là một quyết định khó cho cả đội."),
    ("Measure the room before you buy the table.", "Đo căn phòng trước khi mua bàn."),
    ("Please choose a chair near the window.", "Hãy chọn một cái ghế gần cửa sổ."),
    ("The children watch the teacher.", "Bọn trẻ nhìn cô giáo."),
    ("Just a joke, do not be angry.", "Đùa thôi, đừng giận nhé."),
    ("The judge was in the village in June.", "Thẩm phán ở trong làng vào tháng Sáu."),
    ("Her job is in a large city.", "Công việc của cô ấy ở một thành phố lớn."),
    ("Very few people have a van.", "Rất ít người có xe tải nhỏ."),
    ("I love the view from the valley.", "Tôi yêu khung cảnh nhìn từ thung lũng."),
    ("Five friends visit every week.", "Năm người bạn ghé thăm mỗi tuần."),
    ("The rain is ready to fall.", "Trời sắp mưa rồi."),
    ("Write the right answer on the board.", "Viết câu trả lời đúng lên bảng."),
    ("I like the light in the living room.", "Tôi thích ánh sáng trong phòng khách."),
    ("Nine people need a new lock.", "Chín người cần một ổ khoá mới."),
    ("The long line is near the station.", "Hàng dài ở gần nhà ga."),
    ("What a beautiful bird.", "Con chim đẹp quá."),
    ("The nurse works early in the morning.", "Cô y tá làm việc từ sáng sớm."),
    ("Her first job was at a bakery.", "Công việc đầu tiên của cô ấy là ở tiệm bánh."),
    ("The doctor is never late.", "Bác sĩ không bao giờ đến muộn."),
    ("I hope the hotel has a pool.", "Tôi hy vọng khách sạn có hồ bơi."),
    ("How about a walk in the park?", "Đi dạo trong công viên nhé?"),
    ("The house is down the road.", "Ngôi nhà ở cuối con đường."),
    ("Go home and get some sleep.", "Về nhà và ngủ một chút đi."),
    ("We made a plan to stay late.", "Chúng tôi định ở lại muộn."),
    ("My eyes are tired after a long night.", "Mắt tôi mỏi sau một đêm dài."),
    ("The price of rice went up this year.", "Năm nay giá gạo tăng."),
    ("Please keep the receipt for the client.", "Vui lòng giữ biên lai cho khách hàng."),
    ("She sells cheap shoes at the market.", "Cô ấy bán giày rẻ ở chợ."),
    ("Is the zoo open on Sunday?", "Sở thú có mở cửa vào Chủ nhật không?"),
    ("His dog is lazy and his cat is busy.", "Con chó của anh ấy lười còn con mèo thì bận rộn."),
    ("Wash your hands before you eat.", "Rửa tay trước khi ăn."),
    ("Which way is the hospital?", "Bệnh viện đi đường nào?"),
    ("Yes, I want to go there tomorrow.", "Vâng, tôi muốn đến đó vào ngày mai."),
    ("Ask the manager about the budget.", "Hỏi quản lý về ngân sách."),
    ("Thank you for being so patient with me.", "Cảm ơn bạn đã kiên nhẫn với tôi."),
    ("I think we should finish the project this month.", "Tôi nghĩ chúng ta nên làm xong dự án trong tháng này."),
    ("Could you share your screen with the rest of the team?", "Bạn chia sẻ màn hình cho cả nhóm được không?"),
    ("Let me think about it and get back to you.", "Để tôi suy nghĩ rồi trả lời bạn sau."),
    ("I am sorry, but I have to leave early today.", "Xin lỗi, hôm nay tôi phải về sớm."),
    ("The client asked us to change the design again.", "Khách hàng lại yêu cầu chúng tôi sửa thiết kế."),
    ("We should talk about this in the next meeting.", "Chúng ta nên bàn việc này trong cuộc họp tới."),
    ("My sister and her husband moved to a quiet village.", "Chị tôi và chồng chị chuyển về một ngôi làng yên tĩnh."),
    ("The weather this month has been warmer than usual.", "Thời tiết tháng này ấm hơn mọi năm."),
    ("Please check the numbers before you send the report.", "Vui lòng kiểm tra số liệu trước khi gửi báo cáo."),
]

# Word pairs that differ in a single sound, chosen for contrasts Vietnamese
# speakers often merge. The lexicon decides which sounds each pair contrasts.
PAIRS: List[Tuple[str, str]] = [
    ("sheep", "ship"), ("leave", "live"), ("seat", "sit"), ("feel", "fill"), ("heel", "hill"), ("beat", "bit"),
    ("cheap", "chip"), ("eat", "it"), ("green", "grin"), ("sleep", "slip"), ("peel", "pill"), ("meal", "mill"),
    ("bad", "bed"), ("man", "men"), ("sad", "said"), ("pan", "pen"), ("bag", "beg"), ("had", "head"), ("sat", "set"),
    ("land", "lend"), ("cat", "cut"), ("bag", "bug"), ("cap", "cup"), ("hat", "hut"), ("ran", "run"), ("match", "much"),
    ("fan", "fun"), ("track", "truck"), ("cut", "cot"), ("luck", "lock"), ("duck", "dock"), ("cup", "cop"), ("nut", "not"),
    ("full", "fool"), ("pull", "pool"), ("late", "let"), ("wait", "wet"), ("pain", "pen"), ("sale", "sell"),
    ("taste", "test"), ("gate", "get"), ("coat", "caught"), ("low", "law"), ("boat", "bought"), ("so", "saw"),
    ("like", "lake"), ("time", "tame"), ("bike", "bake"), ("white", "wait"), ("bird", "bud"), ("hurt", "hut"),
    ("turn", "ton"), ("shirt", "shut"), ("girl", "gull"), ("burn", "bun"), ("work", "walk"), ("learn", "lawn"), ("found", "fond"), ("shout", "shot"), ("boy", "buy"), ("toy", "tie"),
    ("boil", "bile"), ("foil", "file"),
    ("think", "sink"), ("thank", "sank"), ("thick", "sick"), ("mouth", "mouse"), ("path", "pass"), ("faith", "face"),
    ("thumb", "sum"), ("worth", "worse"), ("math", "mass"), ("three", "tree"), ("thin", "tin"), ("thank", "tank"),
    ("tenth", "tent"), ("bath", "bat"), ("thought", "taught"), ("through", "true"), ("three", "free"),
    ("thought", "fought"), ("thin", "fin"), ("they", "day"), ("those", "doze"), ("then", "den"), ("though", "dough"),
    ("there", "dare"), ("breathe", "breed"), ("breathe", "breeze"),
    ("see", "she"), ("sip", "ship"), ("save", "shave"), ("sort", "short"), ("seat", "sheet"), ("sell", "shell"),
    ("mass", "mash"), ("class", "clash"), ("sign", "shine"), ("sock", "shock"), ("sue", "zoo"), ("rice", "rise"),
    ("place", "plays"), ("peace", "peas"), ("bus", "buzz"), ("ice", "eyes"), ("price", "prize"), ("race", "raise"),
    ("chip", "ship"), ("cheap", "sheep"), ("chair", "share"), ("watch", "wash"), ("match", "mash"), ("cheat", "sheet"),
    ("chop", "shop"), ("catch", "cash"), ("choose", "shoes"), ("jet", "yet"), ("jam", "yam"), ("joke", "yolk"),
    ("jeep", "cheap"), ("joke", "choke"), ("ridge", "rich"), ("badge", "batch"), ("junk", "chunk"),
    ("light", "night"), ("low", "no"), ("lock", "knock"), ("line", "nine"), ("lot", "not"), ("lead", "need"),
    ("lap", "nap"), ("collect", "connect"), ("light", "right"), ("long", "wrong"), ("lead", "read"), ("fly", "fry"),
    ("glass", "grass"), ("play", "pray"), ("lock", "rock"), ("low", "row"),
    ("very", "berry"), ("vote", "boat"), ("van", "ban"), ("vest", "best"), ("curve", "curb"), ("vest", "west"),
    ("vine", "wine"), ("vet", "wet"), ("verse", "worse"), ("fan", "pan"), ("fine", "pine"), ("fast", "past"),
    ("coffee", "copy"), ("leaf", "leap"),
    ("bike", "buy"), ("rice", "rye"), ("meet", "me"), ("card", "car"), ("wait", "way"), ("light", "lie"),
    ("seed", "see"), ("made", "may"), ("road", "row"), ("time", "tie"), ("life", "lie"),
    ("sin", "sing"), ("thin", "thing"), ("ran", "rang"), ("win", "wing"), ("ban", "bang"), ("kin", "king"),
    ("run", "rung"), ("mail", "nail"), ("some", "sun"), ("map", "nap"), ("coat", "goat"), ("back", "bag"),
    ("cold", "gold"), ("pick", "pig"), ("class", "glass"), ("pig", "big"), ("pack", "back"), ("pear", "bear"),
    ("cap", "cab"), ("rope", "robe"), ("pull", "bull"), ("peach", "beach"), ("time", "dime"), ("tie", "die"),
    ("write", "ride"), ("bat", "bad"), ("cart", "card"), ("seat", "seed"), ("hair", "air"), ("heat", "eat"),
    ("hold", "old"), ("hat", "at"), ("hand", "and"), ("hill", "ill"),
]

# Sounds learners tend to swap for each sound; used to pick the contrast of a lesson.
CONFUSABLE: Dict[str, List[str]] = {
    "IY": ["IH"], "IH": ["IY", "EH"], "EH": ["AE", "IH", "EY"], "AE": ["EH", "AH"], "AA": ["AH", "AO"],
    "AO": ["AA", "OW"], "UH": ["UW"], "UW": ["UH"], "AH": ["AA", "AE"], "AX": ["AH"], "ER": ["AH", "AO", "AXR"],
    "AXR": ["ER"], "EY": ["EH", "AY"], "AY": ["EY", "OY"], "OY": ["AY"], "AW": ["AA", "OW"], "OW": ["AO", "AW"],
    "P": ["B", "F"], "B": ["P", "V"], "T": ["D", "TH"], "D": ["T", "DH"], "K": ["G"], "G": ["K"],
    "CH": ["SH", "JH"], "JH": ["CH", "Y"], "F": ["P", "V"], "V": ["B", "W", "F"], "TH": ["S", "T", "F"],
    "DH": ["D", "Z"], "S": ["SH", "Z", "TH"], "Z": ["S", "DH"], "SH": ["S", "CH"], "ZH": ["SH", "JH"],
    "HH": [], "M": ["N"], "N": ["L", "NG"], "NG": ["N"], "L": ["N", "R"], "R": ["L"], "W": ["V"], "Y": ["JH"],
}

# Starting priorities before the learner has any scores: how often Vietnamese
# speakers struggle with a sound (the same errors the lesson tips warn about,
# e.g. /θ/ said as /t/ or /s/, dropped final consonants, /l/ and /n/ merged).
L1_PRIOR: Dict[str, float] = {
    "TH": 0.9, "DH": 0.85, "ZH": 0.75, "Z": 0.7, "R": 0.7, "JH": 0.6, "V": 0.6, "AE": 0.6, "IH": 0.55,
    "SH": 0.55, "S": 0.55, "CH": 0.5, "ER": 0.5, "OW": 0.5, "L": 0.45, "UH": 0.45, "AX": 0.45, "D": 0.45,
    "T": 0.4, "P": 0.4, "G": 0.4, "AXR": 0.4, "AH": 0.4, "AO": 0.4, "EH": 0.4, "N": 0.35, "NG": 0.35,
    "K": 0.35, "B": 0.35, "AA": 0.35, "IY": 0.35, "UW": 0.35, "W": 0.35, "EY": 0.35, "AY": 0.3, "AW": 0.3,
    "OY": 0.3, "F": 0.3, "Y": 0.2, "HH": 0.2, "M": 0.15,
}
