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
            app.launchEnvironment["PHONOPATH_RESET_PREFS"] = "1"
        }
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
        launch("03", onboarded: true, extra: ["PHONOPATH_EASY_TRACE": "1"])
        tab("Học")
        scrollShots("learn", pages: 3)
        scrollToTop()
        guard tap(buttons(where: "label CONTAINS 'Âm /'").firstMatch) else { return }
        scrollShots("lesson-1-meet", pages: 2)
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/' AND label ENDSWITH '/'")).firstMatch
        let symbol = header.label.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard tap(button("Mình đã hiểu")) else { return }

        shot("lesson-2-recognise")
        let wrong = buttons(where: "label != %@ AND label MATCHES %@", symbol, "^\\S{1,2}$").firstMatch
        if wrong.exists { wrong.tap(); shot("lesson-2-recognise-wrong") }
        for round in 0..<3 {
            guard tap(button(symbol)) else { return }
            if round == 0 { shot("lesson-2-recognise-right") }
            guard tap(button("Tiếp")) else { return }
            Thread.sleep(forTimeInterval: 0.6)
        }

        guard text("Tô ký hiệu").waitForExistence(timeout: 5) else { shot("lesson-3-missing"); return }
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

        _ = text("Nghe phân biệt").waitForExistence(timeout: 5)
        for question in 0..<6 where text("Nghe phân biệt").exists {
            if question == 0 { shot("lesson-4-listen") }
            let answer = button("Có").exists ? button("Có") : buttons(where: "label CONTAINS '/'").firstMatch
            guard answer.exists else { break }
            answer.tap()
            if question < 2 { shot("lesson-4-listen-answered-\(question + 1)") }
            guard tap(button("Tiếp")) else { break }
            Thread.sleep(forTimeInterval: 0.6)
        }

        _ = text("Tìm âm trong từ").waitForExistence(timeout: 5)
        for word in 0..<4 where text("Tìm âm trong từ").exists {
            if word == 0 { shot("lesson-5-find") }
            let targets = buttons(where: "label == %@", symbol)
            guard targets.count > 0 else { break }
            for index in 0..<targets.count { targets.element(boundBy: index).tap() }
            if word == 0 { shot("lesson-5-find-found") }
            guard tap(button("Tiếp")) else { break }
            Thread.sleep(forTimeInterval: 0.6)
        }

        guard text("Nói thành tiếng").waitForExistence(timeout: 5) else { shot("lesson-6-missing"); return }
        shot("lesson-6-speak")
        let card = buttons(where: "identifier BEGINSWITH 'speak.'").firstMatch
        if card.exists {
            card.tap()
            _ = button("Bắt đầu ghi âm").waitForExistence(timeout: 5)
            shot("lesson-6-speak-session")
            dismissSheet()
        }
        guard tap(button("Bỏ qua bước nói")) else { return }
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
                scrollShots("phoneme-detail", pages: 3)
                scrollToTop()
                mouthSteps("mouth-step")
                let mouth = buttons(where: "label BEGINSWITH 'Khẩu hình cả từ'").firstMatch
                for _ in 0..<3 where !mouth.isHittable { app.swipeDown() }
                if mouth.exists, mouth.isHittable {
                    mouth.tap()
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
            shot("listen-quiz")
            for question in 0..<10 {
                // Alternate so that both a right and a wrong answer are likely to be captured.
                let option = button("option.\(question % 4)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("listen-quiz-answered-\(question + 1)") }
                guard tap(button("Tiếp tục")) else { break }
            }
            shot("listen-quiz-summary")
            back()
        }

        if open("Đọc phiên âm") {
            shot("read-ipa")
            for question in 0..<10 {
                guard text("Phiên âm này là từ nào?").waitForExistence(timeout: 3) else { break }
                let option = button("option.\(question % 4)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("read-ipa-answered-\(question + 1)") }
                guard tap(button("Tiếp tục")) else { break }
            }
            shot("read-ipa-summary")
            back()
        }

        if open("Cặp âm dễ nhầm") {
            scrollShots("minimal-pairs", pages: 2)
            scrollToTop()
            if tap(buttons(where: "label CONTAINS '·'").firstMatch) {
                shot("pair-drill")
                for round in 0..<8 {
                    let option = button("option.\(round % 2)")
                    guard option.waitForExistence(timeout: 3) else { break }
                    option.tap()
                    if round < 3 { shot("pair-drill-answered-\(round + 1)") }
                    guard tap(button("Tiếp tục")) else { break }
                }
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
        launch("05", onboarded: true, extra: take.isEmpty ? [:] : ["PHONOPATH_FAKE_TAKE": take])
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
            _ = button("Học từ này").waitForExistence(timeout: 15)
            scrollShots("vocab-lesson", pages: 2)
            for card in 0..<12 where button("Học từ này").exists {
                button("Học từ này").tap()
                if card < 2 { scrollShots("word-card-\(card + 1)", pages: 2) }
            }
            shot("vocab-lesson-done")
            back()
        }
        scrollToTop()
        let review = buttons(where: "label CONTAINS 'đến hạn'").firstMatch
        if review.exists, review.isHittable {
            review.tap()
            shot("word-review-front")
            buttons(where: "label CONTAINS 'Chạm để xem nghĩa'").firstMatch.tapIfPresent()
            shot("word-review-back")
            for _ in 0..<20 where !button("Xong").exists {
                buttons(where: "label CONTAINS 'Chạm để xem nghĩa'").firstMatch.tapIfPresent()
                guard button("Nhớ").waitForExistence(timeout: 2) else { break }
                button("Nhớ").tap()
            }
            shot("word-review-summary")
            button("Xong").tapIfPresent()
            Thread.sleep(forTimeInterval: 0.8)
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
        scrollShots("progress", pages: 3)
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
            shot("sound-review")
            for question in 0..<12 {
                let option = button("option.\(question % 3)")
                guard option.waitForExistence(timeout: 3) else { break }
                option.tap()
                if question < 3 { shot("sound-review-answered-\(question + 1)") }
                guard tap(button("Tiếp")) else { break }
            }
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
            for label in ["Allow", "OK", "Cho phép"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
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
        scrollShots("large-progress", pages: 2)
    }
}

private extension XCUIElement {
    func tapIfPresent() {
        if exists && isHittable { tap() }
    }
}
