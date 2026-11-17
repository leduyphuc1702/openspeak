import XCTest

/// Walks every screen and saves a screenshot of each, so the UI can be reviewed on a real simulator.
///
/// Screenshots are attached to the test result and, when SHOTS_DIR is set
/// (`TEST_RUNNER_SHOTS_DIR=/path xcodebuild test ...`), also written there as PNG.
final class WalkthroughTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private var prefix = ""

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ prefix: String, onboarded: Bool, extra: [String: String] = [:], arguments: [String] = []) {
        self.prefix = prefix
        app = XCUIApplication()
        app.launchArguments += arguments
        // TEST_RUNNER_BACKEND_URL points the app at a deployed server instead of localhost.
        if let backend = ProcessInfo.processInfo.environment["BACKEND_URL"] {
            app.launchArguments += ["-backendURL", backend]
        }
        if onboarded {
            app.launchArguments += ["-prefs.onboarded", "YES", "-prefs.topics", "work,meetings,travel",
                                    "-prefs.level", "intermediate"]
        } else {
            app.launchEnvironment["OPENSPEAK_RESET_PREFS"] = "1"
        }
        // Every run opens the Học tab on the foundation course, whatever an earlier test left selected.
        app.launchEnvironment["OPENSPEAK_RESET_SEGMENT"] = "1"
        app.launchEnvironment["OPENSPEAK_RESET_LLM"] = "1"
        app.launchEnvironment.merge(extra) { $1 }
        app.launch()
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        step += 1
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = String(format: "%@-%02d-%@", prefix, step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(attachment.name ?? name).png")
            try? image.pngRepresentation.write(to: url)
        }
    }

    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("missing: \(element.debugDescription.prefix(200))")
            return false
        }
        if !element.isHittable { app.swipeUp() }
        element.tap()
        return true
    }

    /// The screen's main action has to be visible as soon as the screen opens: on screen, tappable
    /// and above the home indicator, without any scrolling.
    private func assertPinned(_ element: XCUIElement, _ name: String) {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("\(name): main action missing")
            return
        }
        let screen = app.frame
        let onScreen = element.isHittable && element.frame.minY >= screen.minY && element.frame.maxY <= screen.maxY - 30
        XCTAssertTrue(onScreen, "\(name): main action off screen at \(element.frame) in \(screen)")
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    private func buttons(where format: String, _ arguments: CVarArg...) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: format, argumentArray: arguments))
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts[label].firstMatch
    }

    private func field() -> XCUIElement {
        app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
    }

    private func back() {
        let nav = app.navigationBars.buttons.element(boundBy: 0)
        if nav.exists { nav.tap() }
    }

    private func tab(_ label: String) {
        tap(app.tabBars.buttons[label])
    }

    private func scrollShots(_ name: String, pages: Int = 2) {
        shot(name)
        for i in 1..<pages {
            app.swipeUp()
            shot("\(name)-\(i + 1)")
        }
    }

    private func scrollToTop() {
        for _ in 0..<3 { app.swipeDown() }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Pulls the frontmost sheet down until it closes.
    private func dismissSheet() {
        let frame = app.frame
        point(frame.midX, frame.height * 0.09).press(forDuration: 0.05, thenDragTo: point(frame.midX, frame.height * 0.98))
        Thread.sleep(forTimeInterval: 0.8)
    }

    func test01Onboarding() {
        launch("01", onboarded: false)
        shot("onboarding-welcome")
        tap(button("Tiếp tục"))
        shot("onboarding-purpose-empty")
        tap(button("Giao tiếp công việc"))
        tap(button("Họp, thuyết trình"))
        shot("onboarding-purpose")
        tap(button("Tiếp tục"))
        tap(buttons(where: "label CONTAINS 'Trung cấp'").firstMatch)
        shot("onboarding-level")
        tap(button("Tiếp tục"))
        shot("onboarding-goal")
        tap(button("Tiếp tục"))
        scrollShots("onboarding-topics")
        tap(button("Bắt đầu học"))
        shot("after-onboarding")
    }

    func test02CoachTab() {
        launch("02", onboarded: true)
        scrollShots("coach", pages: 3)
    }

    /// One whole sound lesson, all seven steps.
    func test03Lesson() {
        launch("03", onboarded: true, extra: ["OPENSPEAK_EASY_TRACE": "1"])
        tab("Học")
        scrollShots("learn", pages: 3)
        scrollToTop()
        guard tap(buttons(where: "label CONTAINS 'Âm /'").firstMatch) else { return }
        assertPinned(button("Mình đã hiểu"), "lesson meet")
        scrollShots("lesson-1-meet", pages: 2)
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/' AND label ENDSWITH '/'")).firstMatch
        let symbol = header.label.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard tap(button("Mình đã hiểu")) else { return }

        shot("lesson-2-recognise")
        XCTAssertFalse(symbol.isEmpty)
        answerRecognise("lesson-2", context: "lesson recognise")

        guard text("Tô ký hiệu").waitForExistence(timeout: 5) else { shot("lesson-3-missing"); return }
        assertPinned(button("Tiếp tục"), "lesson trace")
        shot("lesson-3-trace")
        let message = text("Dùng ngón tay tô theo ký hiệu.")
        if message.exists {
            let box = CGPoint(x: message.frame.midX, y: message.frame.minY - 16 - 130)
            point(box.x - 30, box.y - 50).press(forDuration: 0.05, thenDragTo: point(box.x - 30, box.y + 60))
            shot("lesson-3-trace-partial")
            point(box.x + 40, box.y - 20).press(forDuration: 0.05, thenDragTo: point(box.x + 40, box.y + 30))
            shot("lesson-3-trace-passed")
        }
        guard tap(button("Tiếp tục")) else { return }

        XCTAssertFalse(text("Tìm âm trong từ").exists, "the trivial find-the-symbol step is gone")
        answerExercises("lesson-4", context: "lesson listen")
        XCTAssertFalse(text("Tìm âm trong từ").exists, "the trivial find-the-symbol step is gone")

        guard text("Nói thành tiếng").waitForExistence(timeout: 5) else { shot("lesson-6-missing"); return }
        assertPinned(button("Bỏ qua bước nói"), "lesson speak")
        shot("lesson-6-speak")
        let card = buttons(where: "identifier BEGINSWITH 'speak.'").firstMatch
        if card.exists {
            card.tap()
            _ = button("Bắt đầu ghi âm").waitForExistence(timeout: 5)
            shot("lesson-6-speak-session")
            dismissSheet()
        }
        guard tap(button("Bỏ qua bước nói")) else { return }
        assertPinned(button("Hoàn thành"), "lesson done")
        shot("lesson-7-done")
        tap(button("Hoàn thành"))
        shot("learn-after-lesson")
    }

    func test04LearnPractice() {
        launch("04", onboarded: true)
        tab("Học")
        func open(_ label: String) -> Bool {
            let link = buttons(where: "label CONTAINS %@", label).firstMatch
            for _ in 0..<6 where !link.isHittable { app.swipeUp() }
            return tap(link)
        }

        if open("Bảng IPA đầy đủ") {
            scrollShots("ipa-chart", pages: 2)
            scrollToTop()
            for category in ["Nguyên âm đôi", "Phụ âm"] where button(category).exists {
                button(category).tap()
                scrollShots("ipa-chart-\(category)", pages: 2)
                scrollToTop()
            }
            if tap(buttons(where: "identifier BEGINSWITH 'phoneme.'").firstMatch) {
                assertPinned(buttons(where: "label CONTAINS 'bài học' OR label CONTAINS 'Học lại'").firstMatch, "phoneme detail")
                scrollShots("phoneme-detail", pages: 3)
                scrollToTop()
                mouthSteps("mouth-step")
                let mouth = buttons(where: "label BEGINSWITH 'Khẩu hình cả từ'").firstMatch
                for _ in 0..<4 where !mouth.isHittable { app.swipeUp() }
                if mouth.exists, mouth.isHittable {
                    mouth.tap()
                    assertPinned(button("Phát"), "mouth guide word")
                    scrollShots("mouth-guide-word", pages: 2)
                    scrollToTop()
                    if button("Từng âm").exists {
                        button("Từng âm").tap()
                        scrollShots("mouth-guide-sounds", pages: 2)
                    }
                    dismissSheet()
                }
                back()
            }
            back()
        }

        if open("Nghe và nhận diện") {
            assertPinned(button("Tiếp tục"), "listen quiz")
            shot("listen-quiz")
            for question in 0..<10 {
                // Alternate so that both a right and a wrong answer are likely to be captured.
                let option = button("option.\(question % 4)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("listen-quiz-answered-\(question + 1)") }
                guard tap(button("Tiếp tục")) else { break }
            }
            assertPinned(button("Làm lại"), "listen quiz summary")
            shot("listen-quiz-summary")
            back()
        }

        if open("Đọc phiên âm") {
            assertPinned(button("Tiếp tục"), "read ipa")
            shot("read-ipa")
            for question in 0..<10 {
                guard text("Phiên âm này là từ nào?").waitForExistence(timeout: 3) else { break }
                let option = button("option.\(question % 4)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("read-ipa-answered-\(question + 1)") }
                guard tap(button("Tiếp tục")) else { break }
            }
            assertPinned(button("Làm lại"), "read ipa summary")
            shot("read-ipa-summary")
            back()
        }

        if open("Cặp âm dễ nhầm") {
            scrollShots("minimal-pairs", pages: 2)
            scrollToTop()
            if tap(buttons(where: "label CONTAINS '·'").firstMatch) {
                assertPinned(button("Tiếp tục"), "pair drill")
                shot("pair-drill")
                for round in 0..<8 {
                    let option = button("option.\(round % 2)")
                    guard option.waitForExistence(timeout: 3) else { break }
                    option.tap()
                    if round < 3 { shot("pair-drill-answered-\(round + 1)") }
                    guard tap(button("Tiếp tục")) else { break }
                }
                assertPinned(button("Làm lại"), "pair drill summary")
                shot("pair-drill-summary")
                back()
            }
            back()
        }
    }

    /// Walks the step-by-step mouth guide of the sound on screen, one screenshot per step.
    private func mouthSteps(_ name: String) {
        let start = button("mouth.steps.start")
        guard start.waitForExistence(timeout: 3) else { XCTFail("no step-by-step guide"); return }
        nudge(until: start)
        shot("\(name)-overview")
        start.tap()
        let next = button("mouth.steps.next")
        for index in 1...6 {
            guard next.waitForExistence(timeout: 2) else { break }
            Thread.sleep(forTimeInterval: 0.8)
            shot("\(name)-\(index)")
            nudge(until: next)
            next.tap()
        }
        shot("\(name)-done")
    }

    /// Scrolls a third of a screen at a time until the element can be tapped.
    private func nudge(until element: XCUIElement) {
        let frame = app.frame
        for _ in 0..<4 where !element.isHittable || element.frame.maxY > frame.height * 0.86 {
            point(frame.midX, frame.height * 0.60).press(forDuration: 0.05, thenDragTo: point(frame.midX, frame.height * 0.32))
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    func test05Speaking() {
        let take = ProcessInfo.processInfo.environment["FAKE_TAKE"] ?? ""
        launch("05", onboarded: true, extra: take.isEmpty ? [:] : ["OPENSPEAK_FAKE_TAKE": take])
        let all = button("Xem tất cả")
        for _ in 0..<4 where !all.isHittable { app.swipeUp() }
        guard tap(all) else { return }
        scrollShots("speaking-list", pages: 2)
        scrollToTop()
        // Same words as the prepared take, so the scores mean something.
        let input = field()
        guard tap(input) else { return }
        input.typeText("We call it bear.")
        guard tap(buttons(where: "label CONTAINS 'Luyện câu này'").firstMatch) else { return }
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/'")).firstMatch.waitForExistence(timeout: 10)
        shot("speaking-session")
        if tap(button("Khẩu hình")) {
            assertPinned(button("Phát"), "mouth guide sentence")
            scrollShots("mouth-guide-sentence", pages: 2)
            dismissSheet()
        }
        guard !take.isEmpty, tap(button("Bắt đầu ghi âm")) else { return }
        Thread.sleep(forTimeInterval: 1.5)
        shot("speaking-recording")
        tap(button("Dừng ghi âm"))
        guard button("tab.Tổng quan").waitForExistence(timeout: 120) else { shot("result-timeout"); return }
        scrollShots("result-overview", pages: 2)
        for name in ["Phát âm", "Trôi chảy", "Ngữ điệu", "Nối âm"] where button("tab.\(name)").exists {
            button("tab.\(name)").tap()
            scrollShots("result-\(name)", pages: 2)
        }
        button("tab.Tổng quan").tap()
        scrollToTop()
        let word = buttons(where: "label BEGINSWITH 'call'").firstMatch
        for _ in 0..<3 where !word.isHittable { app.swipeUp() }
        if word.exists, word.isHittable {
            word.tap()
            shot("word-detail")
            point(app.frame.midX, app.frame.height * 0.75).press(forDuration: 0.05, thenDragTo: point(app.frame.midX, app.frame.height * 0.15))
            scrollShots("word-detail-large", pages: 2)
            dismissSheet()
        }
    }

    func test06Roleplay() {
        launch("06", onboarded: true)
        tab("Hội thoại")
        let first = buttons(where: "label CONTAINS 'phút'").firstMatch
        _ = first.waitForExistence(timeout: 10)
        scrollShots("roleplay-list", pages: 2)
        scrollToTop()
        let topic = field()
        if topic.exists {
            topic.tap()
            topic.typeText("Xin nghỉ phép hai ngày")
            shot("roleplay-custom-typed")
            tap(button("Tạo tình huống"))
            Thread.sleep(forTimeInterval: 3)
            shot("roleplay-custom-result")
        }
        scrollToTop()
        guard tap(first, timeout: 10) else { return }
        shot("roleplay-intro")
        buttons(where: "label CONTAINS 'tiếng Việt'").firstMatch.tapIfPresent()
        shot("roleplay-intro-vi")
        guard tap(button("Bắt đầu hội thoại")) else { return }
        Thread.sleep(forTimeInterval: 3)
        shot("roleplay-chat")
        button("Gõ phím").tapIfPresent()
        shot("roleplay-keyboard")
        let reply = field()
        if reply.exists {
            reply.tap()
            reply.typeText("Yesterday I finished the report.\n")
            Thread.sleep(forTimeInterval: 4)
            shot("roleplay-reply")
        }
    }

    func test07Discover() {
        launch("07", onboarded: true)
        tab("Khám phá")
        scrollShots("discover", pages: 2)
        scrollToTop()
        let search = app.textFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap(); search.typeText("schedule")
            shot("dictionary-typed")
            if tap(button("Tra")) {
                _ = text("schedule").waitForExistence(timeout: 15)
                scrollShots("dictionary-result", pages: 2)
                back()
            }
        }
        let topic = buttons(where: "label CONTAINS 'Công việc' OR label CONTAINS 'Họp'").firstMatch
        for _ in 0..<4 where !topic.isHittable { app.swipeUp() }
        if tap(topic) {
            _ = button("Từ tiếp theo").waitForExistence(timeout: 30)
            assertPinned(button("Từ tiếp theo"), "vocab lesson card")
            scrollShots("vocab-lesson", pages: 2)
            for _ in 0..<12 where button("Từ tiếp theo").exists { button("Từ tiếp theo").tap() }
            if tap(button("Bắt đầu nhớ lại")) {
                answerDrills("topic-recall", until: button("Học thêm từ mới"))
            }
            assertPinned(button("Học thêm từ mới"), "vocab lesson done")
            shot("vocab-lesson-done")
            back()
        }
        scrollToTop()
        let review = app.buttons["vocab.review"]
        if review.waitForExistence(timeout: 3), review.isHittable {
            review.tap()
            answerDrills("word-review", until: button("Xong"))
            assertPinned(button("Xong"), "word review summary")
            shot("word-review-summary")
            button("Xong").tapIfPresent()
            Thread.sleep(forTimeInterval: 0.8)
        } else {
            shot("word-review-none-due")
        }
        let saved = buttons(where: "label BEGINSWITH 'Sổ từ của tôi'").firstMatch
        for _ in 0..<8 where !saved.isHittable { app.swipeUp() }
        if saved.exists, saved.isHittable {
            saved.tap()
            scrollShots("saved-words", pages: 2)
        } else {
            shot("saved-words-missing")
        }
    }

    func test08Progress() {
        launch("08", onboarded: true)
        tab("Tiến độ")
        assertPinned(button("Luyện nói để cập nhật"), "progress")
        scrollShots("progress", pages: 3)
        assertPinned(button("Luyện nói để cập nhật"), "progress scrolled")
        scrollToTop()
        if tap(button("Hồ sơ và cài đặt")) {
            scrollShots("profile", pages: 3)
        }
    }

    /// Runs last, once the earlier tests have left sounds and words to review.
    func test09Reviews() {
        launch("09", onboarded: true)
        scrollShots("coach-with-data", pages: 3)
        scrollToTop()
        let sounds = buttons(where: "label CONTAINS 'Âm cần ôn'").firstMatch
        for _ in 0..<3 where !sounds.isHittable { app.swipeUp() }
        if sounds.exists, sounds.isEnabled, sounds.isHittable {
            sounds.tap()
            assertPinned(button("Tiếp"), "sound review")
            shot("sound-review")
            for question in 0..<12 {
                let option = button("option.\(question % 3)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("sound-review-answered-\(question + 1)") }
                guard tap(button("Tiếp")) else { break }
            }
            assertPinned(button("Xong"), "sound review summary")
            shot("sound-review-summary")
            button("Xong").tapIfPresent()
        }
        let weak = buttons(where: "label BEGINSWITH '/'").firstMatch
        for _ in 0..<4 where !weak.isHittable { app.swipeUp() }
        if weak.exists, weak.isHittable {
            weak.tap()
            shot("phoneme-detail-from-coach")
        }
    }

    /// The camera coach. The simulator has no camera, so this records the fallback state.
    func test10MouthCoach() {
        launch("10", onboarded: true)
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Cho phép"] where alert.buttons[label].firstMatch.exists {
                alert.buttons[label].firstMatch.tap()
                return true
            }
            return false
        }
        let all = button("Xem tất cả")
        for _ in 0..<4 where !all.isHittable { app.swipeUp() }
        guard tap(all) else { return }
        guard tap(buttons(where: "label CONTAINS 'How are you'").firstMatch.exists
                  ? buttons(where: "label CONTAINS 'How are you'").firstMatch
                  : app.scrollViews.buttons.element(boundBy: 1)) else { return }
        shot("speaking-session-preset")
        guard tap(button("Quay miệng")) else { return }
        Thread.sleep(forTimeInterval: 2)
        app.tap()
        // Without a camera (the simulator) the screen offers "Thử lại" instead of recording.
        let noCamera = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'camera'")).firstMatch.exists
        assertPinned(button(noCamera ? "Thử lại" : "Bắt đầu ghi âm"), "mouth coach")
        scrollShots("mouth-coach", pages: 2)
    }
}

extension WalkthroughTests {
    /// The same screens at an accessibility text size (AX3, about 235% of the default body size).
    func test11LargeText() {
        launch("11", onboarded: true,
               arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        scrollShots("large-coach", pages: 3)
        tab("Học")
        scrollShots("large-learn", pages: 2)
        let chart = buttons(where: "label CONTAINS %@", "Bảng IPA đầy đủ").firstMatch
        for _ in 0..<12 where !chart.isHittable { app.swipeUp() }
        if tap(chart) {
            shot("large-ipa-chart")
            if tap(buttons(where: "identifier BEGINSWITH 'phoneme.'").firstMatch) {
                scrollShots("large-phoneme-detail", pages: 3)
                scrollToTop()
                mouthSteps("large-mouth-step")
                back()
            }
            back()
        }
        let quiz = buttons(where: "label CONTAINS %@", "Nghe và nhận diện").firstMatch
        for _ in 0..<12 where !quiz.isHittable { app.swipeUp() }
        if tap(quiz) {
            shot("large-listen-quiz")
            if button("option.0").waitForExistence(timeout: 3) {
                button("option.0").tap()
                shot("large-listen-quiz-answered")
            }
            back()
        }
        tab("Hội thoại")
        shot("large-roleplay")
        tab("Tiến độ")
        assertPinned(button("Luyện nói để cập nhật"), "large progress")
        scrollShots("large-progress", pages: 2)
    }
}

extension WalkthroughTests {
    /// The endless personal path: the server plans a lesson from seeded results, the learner takes it,
    /// and the next lesson is planned from the new score.
    func test12PersonalPath() {
        let take = ProcessInfo.processInfo.environment["FAKE_TAKE"] ?? ""
        var extra = ["OPENSPEAK_SEED_PATH": "1"]
        if !take.isEmpty { extra["OPENSPEAK_FAKE_TAKE"] = take }
        launch("12", onboarded: true, extra: extra)
        tab("Học")
        guard tap(button("tab.Lộ trình cá nhân")) else { return }
        shot("path-loading")
        let current = app.buttons["path.current"]
        guard current.waitForExistence(timeout: 200) else { shot("path-failed"); return }
        scrollShots("path-first", pages: 2)
        scrollToTop()
        guard tap(current) else { return }
        let start = button("Bắt đầu")
        assertPinned(start, "path intro")
        guard tap(start) else { return }
        answerExercises("path-listen", context: "path listen")
        guard text("Nói từ").waitForExistence(timeout: 5) else { shot("path-words-missing"); return }
        assertPinned(button("Tiếp tục").exists ? button("Tiếp tục") : button("Bỏ qua bước này"), "path words")
        scrollShots("path-words", pages: 2)
        scrollToTop()
        let card = buttons(where: "identifier BEGINSWITH 'speak.'").firstMatch
        if card.exists {
            card.tap()
            _ = button("Bắt đầu ghi âm").waitForExistence(timeout: 5)
            shot("path-word-session")
            if !take.isEmpty, tap(button("Bắt đầu ghi âm")) {
                Thread.sleep(forTimeInterval: 1.5)
                tap(button("Dừng ghi âm"))
                if button("tab.Tổng quan").waitForExistence(timeout: 120) { shot("path-word-result") }
            }
            dismissSheet()
            assertPinned(button("Tiếp tục").exists ? button("Tiếp tục") : button("Bỏ qua bước này"), "path words after")
            shot("path-words-after")
        }
        let onward = button("Tiếp tục").exists ? button("Tiếp tục") : button("Bỏ qua bước này")
        for _ in 0..<4 where !onward.isHittable { app.swipeUp() }
        guard tap(onward) else { return }
        if text("Nói câu").waitForExistence(timeout: 5) {
            assertPinned(button("Bỏ qua bước này"), "path sentences")
            scrollShots("path-sentences", pages: 2)
            let skip = button("Bỏ qua bước này")
            for _ in 0..<4 where !skip.isHittable { app.swipeUp() }
            guard tap(skip) else { return }
        }
        guard button("Hoàn thành").waitForExistence(timeout: 5) else { shot("path-done-missing"); return }
        assertPinned(button("Hoàn thành"), "path done")
        shot("path-done")
        tap(button("Hoàn thành"))
        shot("path-after-first")
        _ = text("Bài tiếp theo").waitForExistence(timeout: 90)
        scrollShots("path-second", pages: 2)
    }

    /// The intro screen of a planned lesson, and the Coach card once every foundation sound is learned.
    func test13PathIntroAndHome() {
        launch("13", onboarded: true, extra: ["OPENSPEAK_SEED_PATH": "graduated"])
        scrollShots("graduated-coach", pages: 2)
        scrollToTop()
        guard tap(buttons(where: "label CONTAINS 'Lộ trình cá nhân'").firstMatch) else { return }
        let current = app.buttons["path.current"]
        guard current.waitForExistence(timeout: 90) else { shot("graduated-path-failed"); return }
        shot("graduated-learn")
        guard tap(current) else { return }
        assertPinned(button("Bắt đầu"), "path intro graduated")
        scrollShots("path-intro", pages: 3)
        tap(button("Đóng"))
        tab("Coach")
        shot("graduated-coach-lesson")
    }
}

extension WalkthroughTests {
    /// Task screens at an accessibility text size: the main action must still be on screen.
    func test14LargeTextTasks() {
        launch("14", onboarded: true, extra: ["OPENSPEAK_SEED_PATH": "graduated"],
               arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        tab("Học")
        let lesson = buttons(where: "label CONTAINS 'Âm /'").firstMatch
        for _ in 0..<8 where !lesson.isHittable { app.swipeUp() }
        if tap(lesson) {
            assertPinned(button("Mình đã hiểu"), "large lesson meet")
            scrollShots("large-lesson-meet", pages: 2)
            tap(button("Mình đã hiểu"))
            shot("large-lesson-recognise")
            tap(button("Đóng"))
        }
        scrollToTop()
        let chart = buttons(where: "label CONTAINS %@", "Bảng IPA đầy đủ").firstMatch
        for _ in 0..<12 where !chart.isHittable { app.swipeUp() }
        if tap(chart), tap(buttons(where: "identifier BEGINSWITH 'phoneme.'").firstMatch) {
            assertPinned(buttons(where: "label CONTAINS 'bài học' OR label CONTAINS 'Học lại'").firstMatch, "large phoneme detail")
            shot("large-phoneme-detail-top")
            let mouth = buttons(where: "label BEGINSWITH 'Khẩu hình cả từ'").firstMatch
            for _ in 0..<8 where !mouth.isHittable { app.swipeUp() }
            if mouth.exists, mouth.isHittable {
                mouth.tap()
                assertPinned(button("Phát"), "large mouth guide word")
                scrollShots("large-mouth-guide-word", pages: 2)
                dismissSheet()
            }
            back()
            back()
        }
        scrollToTop()
        guard tap(button("tab.Lộ trình cá nhân")) else { return }
        let current = app.buttons["path.current"]
        guard current.waitForExistence(timeout: 90) else { shot("large-path-failed"); return }
        for _ in 0..<8 where !current.isHittable { app.swipeUp() }
        guard tap(current) else { return }
        assertPinned(button("Bắt đầu"), "large path intro")
        scrollShots("large-path-intro", pages: 2)
    }
}

extension WalkthroughTests {
    /// The learner's own LLM in each of the three API formats, checked through the server, then used
    /// to plan a path lesson. Needs TEST_RUNNER_LLM_BASE (a base URL without the /v1 suffix) and
    /// TEST_RUNNER_LLM_KEY; the key is typed into the app, so point it at a local relay holding a
    /// placeholder, not a real key.
    func test15UserLLM() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LLM_BASE"], let key = env["LLM_KEY"] else {
            XCTFail("set TEST_RUNNER_LLM_BASE and TEST_RUNNER_LLM_KEY")
            return
        }
        let anthropicModel = env["LLM_ANTHROPIC_MODEL"] ?? "claude-sonnet-5-5"
        let openAIModel = env["LLM_OPENAI_MODEL"] ?? "gpt-6.1-sol"
        launch("15", onboarded: true, extra: ["OPENSPEAK_SEED_PATH": "1"])
        tab("Tiến độ")
        guard tap(button("Hồ sơ và cài đặt")) else { return }
        let toggle = app.switches["llm.enabled"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        shot("llm-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        _ = app.textFields["llm.baseURL"].waitForExistence(timeout: 3)
        shot("llm-empty")

        let status = app.staticTexts.matching(identifier: "llm.status").firstMatch
        func fill(_ id: String, _ value: String, secure: Bool = false) {
            let field = secure ? app.secureTextFields[id] : app.textFields[id]
            guard tap(field) else { return }
            let clear = field.buttons.firstMatch
            if clear.exists && clear.isHittable { clear.tap() }
            field.typeText(value + "\n")
        }
        func check(_ name: String, expectOK: Bool) {
            let button = app.buttons["llm.check"]
            guard button.waitForExistence(timeout: 5) else { XCTFail("no check button"); return }
            button.tap()
            let done = NSPredicate(format: "label CONTAINS %@", expectOK ? "trả lời sau" : "Lỗi")
            let reached = expectation(for: done, evaluatedWith: status)
            wait(for: [reached], timeout: 150)
            for _ in 0..<3 where !status.isHittable { app.swipeUp() }
            shot(name)
        }
        func choose(_ title: String) {
            guard tap(app.buttons["llm.format"]) else { return }
            tap(app.buttons[title])
        }

        let configs = [("OpenAI Chat Completions", "\(base)/v1", openAIModel, "chat"),
                       ("OpenAI Responses", "\(base)/v1", openAIModel, "responses"),
                       ("Anthropic Messages", base, anthropicModel, "anthropic")]
        for (index, config) in configs.enumerated() {
            choose(config.0)
            fill("llm.baseURL", config.1)
            fill("llm.model", config.2)
            if index == 0 { fill("llm.key", key, secure: true) }
            if index == 0 { shot("llm-filled") }
            check("llm-ok-\(config.3)", expectOK: true)
        }

        fill("llm.model", "no-such-model")
        check("llm-error", expectOK: false)
        fill("llm.model", anthropicModel)
        tap(app.buttons["llm.save"])
        shot("llm-saved")

        back()
        tab("Học")
        guard tap(button("tab.Lộ trình cá nhân")) else { return }
        let current = app.buttons["path.current"]
        guard current.waitForExistence(timeout: 150) else { shot("llm-path-failed"); return }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'AI soạn'")).firstMatch.exists
                      || current.label.contains("AI soạn"), "path lesson was not written by the learner's LLM")
        shot("llm-path")
    }
}

extension WalkthroughTests {
    /// A spoken roleplay turn: record, stop, and the turn must show up in the conversation with its
    /// pronunciation score (or a visible reason why not). Uses the prepared take ("We call it bear.").
    func test16RoleplayVoice() {
        let take = ProcessInfo.processInfo.environment["FAKE_TAKE"] ?? ""
        var extra: [String: String] = [:]
        if !take.isEmpty {
            extra["OPENSPEAK_FAKE_TAKE"] = take
            // Without this the simulator shows the "could not recognise" error instead of a turn.
            if ProcessInfo.processInfo.environment["REAL_RECOGNIZER"] == nil { extra["OPENSPEAK_FAKE_TRANSCRIPT"] = "We call it bear." }
        }
        launch("16", onboarded: true, extra: extra)
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Cho phép"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        tab("Hội thoại")
        let first = buttons(where: "label CONTAINS 'phút'").firstMatch
        guard tap(first, timeout: 10) else { return }
        guard tap(button("Bắt đầu hội thoại")) else { return }
        Thread.sleep(forTimeInterval: 2)
        shot("voice-chat")
        let mic = buttons(where: "identifier == 'roleplay.mic' OR label CONTAINS[c] 'mic' OR label CONTAINS[c] 'micrô'").firstMatch
        guard mic.waitForExistence(timeout: 5) else { XCTFail("no mic button"); return }
        let micFrame = mic.frame
        mic.tap()
        Thread.sleep(forTimeInterval: 1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK', 'Cho phép'}")).firstMatch
            guard allow.waitForExistence(timeout: 2) else { break }
            allow.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        app.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("voice-recording")
        point(micFrame.midX, micFrame.midY).tap()
        let turn = app.staticTexts.matching(NSPredicate(format: "identifier == 'roleplay.userTurn' OR identifier == 'roleplay.error'")).firstMatch
        let appeared = turn.waitForExistence(timeout: 30)
        shot("voice-after-stop")
        XCTAssertTrue(appeared, "nothing appeared in the conversation after stopping the recording")
        let score = app.buttons.matching(NSPredicate(format: "identifier == 'roleplay.pronunciation'")).firstMatch
        if score.waitForExistence(timeout: 150) {
            // The AI's answer (second AI bubble) must end up on screen, not hidden under the input bar.
            let reply = app.staticTexts.matching(identifier: "roleplay.aiTurn").element(boundBy: 1)
            if reply.waitForExistence(timeout: 150) {
                Thread.sleep(forTimeInterval: 1.5)
                shot("voice-scored")
                let input = mic.frame
                XCTAssertTrue(reply.frame.maxY <= input.minY && reply.frame.minY >= 0,
                              "AI reply \(reply.frame) is off screen (input bar starts at \(input.minY))")
            } else {
                shot("voice-scored")
            }
            for _ in 0..<3 where !score.isHittable { app.swipeDown() }
            shot("voice-scored-card")
            Thread.sleep(forTimeInterval: 1)
            score.tap()
            XCTAssertTrue(button("tab.Tổng quan").waitForExistence(timeout: 5), "turn detail did not open")
            scrollShots("voice-detail", pages: 2)
            assertPinned(button("Luyện nói lại câu này"), "turn detail")
            tap(button("Luyện nói lại câu này"))
            _ = button("Bắt đầu ghi âm").waitForExistence(timeout: 5)
            shot("voice-practice")
            back()
            back()
            let edit = app.buttons["roleplay.editTranscript"].firstMatch
            if tap(edit) {
                shot("voice-edit")
                let input = app.alerts.textFields.firstMatch
                if input.waitForExistence(timeout: 3) {
                    input.tap()
                    input.buttons.firstMatch.tapIfPresent()
                    input.typeText("We call it bear?")
                    shot("voice-edit-typed")
                    tap(app.alerts.buttons["Chấm lại"])
                    _ = score.waitForExistence(timeout: 120)
                    Thread.sleep(forTimeInterval: 1)
                    shot("voice-rescored")
                }
            }
        } else {
            XCTFail("no pronunciation score for the spoken turn")
            shot("voice-no-score")
        }
    }
}

extension WalkthroughTests {
    /// Hear a sound, tap its symbol, until four rounds are right first time. The test cannot hear, so it tries the
    /// symbols in turn; a miss does not count and the step asks again.
    func answerRecognise(_ prefix: String, context: String) {
        var shotWrong = false, shotRight = false
        for _ in 0..<40 where !text("Tô ký hiệu").exists {
            let symbols = buttons(where: "identifier BEGINSWITH 'symbol.'")
            guard symbols.firstMatch.waitForExistence(timeout: 5) else { break }
            for i in 0..<symbols.count where !button("Tiếp").exists {
                symbols.element(boundBy: i).tap()
                if !button("Tiếp").exists, !shotWrong { shotWrong = true; shot("\(prefix)-recognise-wrong") }
            }
            guard button("Tiếp").exists else { break }
            if !shotRight {
                shotRight = true
                assertPinned(button("Tiếp"), context)
                shot("\(prefix)-recognise-right")
            }
            button("Tiếp").tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Answers every question of a "Nghe và nhận âm" step, with shots of the first question of each kind before
    /// and after checking. The test cannot hear, so most answers are wrong: those questions come back once at the
    /// end, which is shot too. Asserts no question can be answered by tapping one of two options.
    func answerExercises(_ prefix: String, context: String) {
        guard text("Nghe và nhận âm").waitForExistence(timeout: 60) else {
            shot("\(prefix)-missing")
            XCTFail("\(context): listening step missing")
            return
        }
        let check = button("Kiểm tra")
        var seen = Set<String>()
        var retryShot = false
        for _ in 0..<30 where text("Nghe và nhận âm").exists && !button("Tiếp tục").exists {
            // The first question may still be coming from a language model.
            guard check.waitForExistence(timeout: seen.isEmpty ? 180 : 5) else { break }
            XCTAssertFalse(buttons(where: "identifier BEGINSWITH 'option.'").firstMatch.exists, "a pick-one-of-two question is still shown")
            let kind: String
            if button("seq.0.0").exists { kind = "sequence" }
            else if app.textFields["dictation.field"].exists { kind = "dictation" }
            else if button("sort.0").exists { kind = "sort" }
            else if buttons(where: "identifier BEGINSWITH 'tile.'").firstMatch.exists { kind = "build" }
            else { kind = "other" }
            let first = seen.insert(kind).inserted
            if first {
                assertPinned(check, "\(context) \(kind)")
                XCTAssertEqual(check.isEnabled, kind == "sort", "\(kind): Kiểm tra enabled before answering")
                shot("\(prefix)-\(kind)")
            }
            if !retryShot, text("Làm lại câu sai").exists { retryShot = true; shot("\(prefix)-retry-\(kind)") }
            switch kind {
            case "sequence":
                for slot in 0..<3 { button("seq.\(slot).\(slot % 2)").tapIfPresent() }
            case "dictation":
                let field = app.textFields["dictation.field"]
                field.tap()
                field.typeText("ship\n")
            case "sort":
                button("sort.0").tapIfPresent()
            case "build":
                let tile = buttons(where: "identifier BEGINSWITH 'tile.'").firstMatch
                for _ in 0..<8 where !check.isEnabled { tile.tap() }
            default:
                break
            }
            if first, kind != "sort" { shot("\(prefix)-\(kind)-filled") }
            guard check.isEnabled, tap(check) else { shot("\(prefix)-\(kind)-stuck"); break }
            if first {
                assertPinned(button("Tiếp"), "\(context) \(kind) answered")
                shot("\(prefix)-\(kind)-answered")
            }
            guard tap(button("Tiếp")) else { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if button("Tiếp tục").waitForExistence(timeout: 5) {
            assertPinned(button("Tiếp tục"), "\(context) summary")
            scrollShots("\(prefix)-summary", pages: 2)
            scrollToTop()
            tap(button("Tiếp tục"))
        } else {
            shot("\(prefix)-summary-missing")
            XCTFail("\(context): listening summary missing, kinds seen: \(seen.sorted())")
        }
    }

    /// Recall drills of the vocabulary programme and review: pick the meaning, or type the word. The test does not
    /// know the words, so a first try is a guess; the answer it is then shown is used when the drill comes back,
    /// so both the wrong and the right states are seen.
    func answerDrills(_ prefix: String, until done: XCUIElement, limit: Int = 60, studied: [String: String] = [:]) {
        var seen = Set<String>()
        var learned = studied
        for _ in 0..<limit where !done.exists {
            let field = app.textFields["vocab.field"]
            let meaning = button("meaning.0")
            guard field.waitForExistence(timeout: 3) || meaning.exists else { break }
            let kind = meaning.exists ? "meaning" : text("Điền từ đã học vào chỗ trống").exists ? "cloze" : "spell"
            let prompt = "\(kind):" + app.staticTexts["drill.prompt"].firstMatch.label
            let known = learned[prompt]
            let tag = "\(kind)\(known == nil ? "" : "-known")"
            let first = seen.insert(tag).inserted
            if first {
                assertPinned(button("Không nhớ"), "\(prefix) \(tag)")
                shot("\(prefix)-\(tag)")
            }
            let choices = buttons(where: "identifier BEGINSWITH 'meaning.'")
            if kind == "meaning" {
                let pick = known.map { k in choices.matching(NSPredicate(format: "label == %@", k)).firstMatch } ?? choices.element(boundBy: 1)
                pick.tap()
                if learned[prompt] == nil {
                    learned[prompt] = choices.matching(NSPredicate(format: "value == 'đúng'")).firstMatch.label
                }
            } else {
                field.tap()
                field.typeText(known ?? "xyz")
                if first { shot("\(prefix)-\(tag)-typed") }
                guard tap(button("Kiểm tra")) else { break }
                let verdict = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Đáp án: '")).firstMatch
                if verdict.waitForExistence(timeout: 1) {
                    learned[prompt] = String(verdict.label.dropFirst("Đáp án: ".count))
                }
            }
            if first {
                assertPinned(button("Tiếp"), "\(prefix) \(tag) answered")
                shot("\(prefix)-\(tag)-answered")
            }
            guard tap(button("Tiếp")) else { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// The first checkpoint exam, due after four finished path lessons: intro, questions, speaking, result.
    func test17PathExam() {
        let env = ProcessInfo.processInfo.environment
        let take = env["FAKE_TAKE"] ?? ""
        var extra = ["OPENSPEAK_SEED_PATH": "exam"]
        if !take.isEmpty { extra["OPENSPEAK_FAKE_TAKE"] = take }
        launch("17", onboarded: true, extra: extra)
        tab("Học")
        guard tap(button("tab.Lộ trình cá nhân")) else { return }
        let exam = app.buttons["path.exam"]
        guard exam.waitForExistence(timeout: 200) else { shot("exam-failed"); return }
        for _ in 0..<8 where !exam.isHittable { app.swipeUp() }
        shot("exam-row")
        guard tap(exam) else { return }
        let start = button("Bắt đầu kiểm tra")
        assertPinned(start, "exam intro")
        scrollShots("exam-intro", pages: 2)
        guard tap(start) else { return }
        answerExercises("exam-listen", context: "exam listen")
        guard text("Nói từ").waitForExistence(timeout: 5) else { shot("exam-words-missing"); return }
        scrollShots("exam-words", pages: 2)
        scrollToTop()
        let card = buttons(where: "identifier BEGINSWITH 'speak.'").firstMatch
        if card.exists, !take.isEmpty {
            card.tap()
            if tap(button("Bắt đầu ghi âm")) {
                Thread.sleep(forTimeInterval: 1.5)
                tap(button("Dừng ghi âm"))
                if button("tab.Tổng quan").waitForExistence(timeout: 120) { shot("exam-word-result") }
            }
            dismissSheet()
        }
        let onward = button("Tiếp tục").exists ? button("Tiếp tục") : button("Bỏ qua bước này")
        assertPinned(onward, "exam words")
        guard tap(onward) else { return }
        if text("Nói câu").waitForExistence(timeout: 5) {
            scrollShots("exam-sentences", pages: 2)
            let next = button("Tiếp tục").exists ? button("Tiếp tục") : button("Bỏ qua bước này")
            assertPinned(next, "exam sentences")
            guard tap(next) else { return }
        }
        guard button("Hoàn thành").waitForExistence(timeout: 5) else { shot("exam-done-missing"); return }
        assertPinned(button("Hoàn thành"), "exam done")
        scrollShots("exam-done", pages: 2)
        tap(button("Hoàn thành"))
        Thread.sleep(forTimeInterval: 1)
        scrollShots("exam-after", pages: 2)
    }

    /// Tracing with the real rules: one stroke on part of the symbol must not pass.
    func test18TraceStrict() {
        launch("18", onboarded: true)
        tab("Học")
        guard tap(buttons(where: "label CONTAINS 'Âm /'").firstMatch) else { return }
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/' AND label ENDSWITH '/'")).firstMatch
        let symbol = header.label.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard tap(button("Mình đã hiểu")) else { return }
        XCTAssertFalse(symbol.isEmpty)
        answerRecognise("strict", context: "strict recognise")
        guard text("Tô ký hiệu").waitForExistence(timeout: 5) else { shot("strict-missing"); return }
        let message = text("Dùng ngón tay tô theo ký hiệu.")
        guard message.exists else { shot("strict-no-message"); return }
        shot("strict-trace")
        let box = CGPoint(x: message.frame.midX, y: message.frame.minY - 16 - 130)
        point(box.x - 30, box.y - 50).press(forDuration: 0.05, thenDragTo: point(box.x - 30, box.y + 60))
        shot("strict-one-stroke")
        XCTAssertFalse(button("Tiếp tục").isEnabled, "one stroke passed the tracing step")
        for i in 0..<6 {
            let y = box.y - 100 + CGFloat(i) * 40
            point(box.x - 120, y).press(forDuration: 0.05, thenDragTo: point(box.x + 120, y + 20))
        }
        shot("strict-scribble")
        XCTAssertFalse(button("Tiếp tục").isEnabled, "scribbling across the box passed the tracing step")
    }
}

extension WalkthroughTests {
    /// The vocabulary programme: a lesson written for the learner's topics, learned and recalled, then the next one.
    func test19VocabPath() {
        launch("19", onboarded: true)
        tab("Khám phá")
        let path = app.buttons["vocab.path"]
        guard path.waitForExistence(timeout: 10) else { shot("vocab-path-missing"); return }
        shot("vocab-home")
        let before = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'bài đã học'")).count > 0
            ? Int(path.label.components(separatedBy: ", ")[safe: 2] ?? "") ?? -1 : -1
        path.tap()
        shot("vocab-path-loading")
        let start = button("Bắt đầu")
        guard start.waitForExistence(timeout: 200) else { shot("vocab-path-failed"); return }
        assertPinned(start, "vocab path intro")
        scrollShots("vocab-path-intro", pages: 2)
        scrollToTop()
        tap(start)
        if button("Không nhớ").waitForExistence(timeout: 3) { answerDrills("vocab-warmup", until: button("Từ tiếp theo")) }
        guard button("Từ tiếp theo").waitForExistence(timeout: 5) else { shot("vocab-learn-missing"); return }
        assertPinned(button("Từ tiếp theo"), "vocab path learn")
        scrollShots("vocab-learn-1", pages: 2)
        scrollToTop()
        // What a learner reads on the cards: the meaning of every word and how every word is spelled.
        var studied: [String: String] = [:]
        func study() {
            let word = app.staticTexts["card.word"].firstMatch.label, meaning = app.staticTexts["card.meaning"].firstMatch.label
            studied["meaning:" + word] = meaning
            studied["spell:" + meaning] = word
        }
        for i in 0..<8 where button("Từ tiếp theo").exists {
            study()
            button("Từ tiếp theo").tap()
            if i == 0 { shot("vocab-learn-2") }
        }
        study()
        guard tap(button("Bắt đầu nhớ lại")) else { return }
        answerDrills("vocab-recall", until: button("Hoàn thành"), limit: 60, studied: studied)
        guard button("Hoàn thành").waitForExistence(timeout: 5) else { shot("vocab-done-missing"); return }
        assertPinned(button("Hoàn thành"), "vocab path done")
        scrollShots("vocab-done", pages: 2)
        scrollToTop()
        tap(button("Hoàn thành"))
        Thread.sleep(forTimeInterval: 1)
        shot("vocab-home-after")
        let after = Int(path.label.components(separatedBy: ", ")[safe: 2] ?? "") ?? -2
        XCTAssertEqual(after, before + 1, "finished lessons go up by one: \(path.label)")
        XCTAssertTrue(path.label.contains("Bài \(after + 1) ·"), "programme moves to the next lesson: \(path.label)")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension XCUIElement {
    func tapIfPresent() {
        if exists && isHittable { tap() }
    }
}
