import XCTest

/// Smoke + regression UI tests. They walk the main flows, take screenshots, and fail if the app crashes or a flow dead-ends.
final class PrismUITests: XCTestCase {
    var app: XCUIApplication!
    static var shot = 0

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-lang", "zh"]
        app.launch()
        waitReady()
    }

    // MARK: helpers
    func snap(_ name: String) {
        Self.shot += 1
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? Optional("/tmp/prism-shots") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let n = String(format: "%03d", Self.shot)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(n)-\(name.replacingOccurrences(of: "/", with: "_")).png"))
        }
    }
    func alive(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "App not running after: \(step)", file: file, line: line)
    }
    func waitReady() {
        // Content download screen on first launch.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if app.buttons["课本"].exists || app.staticTexts["课本"].exists || app.cells.staticTexts["课本"].exists { return }
            sleep(2)
        }
        snap("not-ready")
    }
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad && app.windows.firstMatch.frame.width > 700 }
    func section(_ name: String) {
        let candidates = [app.cells.staticTexts[name], app.buttons[name], app.tabBars.buttons[name], app.staticTexts[name]]
        if let e = candidates.first(where: { $0.exists && $0.isHittable }) { e.tap() }
        else if app.tabBars.buttons["更多"].exists {
            app.tabBars.buttons["更多"].tap()
            let c = app.cells.staticTexts[name]; if c.waitForExistence(timeout: 3) { c.tap() }
        }
        sleep(1); alive("section \(name)")
    }
    func back(_ times: Int = 1) {
        for _ in 0..<times {
            let b = app.navigationBars.buttons.element(boundBy: 0)
            if b.exists && b.isHittable { b.tap(); usleep(500_000) }
        }
    }
    /// Taps the first visible content cell whose label isn't excluded.
    @discardableResult
    func tapCell(_ index: Int = 0, skip: [String] = []) -> Bool {
        let cells = app.collectionViews.cells.allElementsBoundByIndex.filter { c in
            c.isHittable && !skip.contains(where: { c.label.contains($0) })
        }
        let main = cells.filter { $0.frame.minX > (isPad ? 300 : -1) }
        guard index < main.count else { return false }
        main[index].tap(); sleep(1); return true
    }
    func tapButton(_ labels: [String], timeout: TimeInterval = 2) -> Bool {
        for l in labels {
            let b = app.buttons[l]
            if b.waitForExistence(timeout: timeout), b.isHittable { b.tap(); usleep(700_000); return true }
            let p = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", l)).firstMatch
            if p.exists, p.isHittable { p.tap(); usleep(700_000); return true }
        }
        return false
    }

    // MARK: precise helpers
    @discardableResult
    func tapText(_ pred: String, _ timeout: TimeInterval = 8, _ name: String = "") -> Bool {
        let q = NSPredicate(format: pred)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for kind in [app.buttons, app.staticTexts, app.cells] {
                let all = kind.matching(q).allElementsBoundByIndex.filter { $0.exists && $0.isHittable && (!isPad || $0.frame.minX > 300) }
                if let e = all.first { e.tap(); usleep(800_000); return true }
            }
            usleep(400_000)
        }
        XCTFail("not found: \(name.isEmpty ? pred : name)"); snap("missing-\(name.isEmpty ? "x" : name)")
        return false
    }
    func home(_ s: String) { section(s); back(6) }
    func answerAndHandIn(_ tag: String) {
        for _ in 0..<4 {
            let opt = app.buttons.matching(NSPredicate(format: "label MATCHES '^[A-D][.、 ].*' OR label IN {'A','B','C','D'}")).allElementsBoundByIndex.first { $0.isHittable }
            opt?.tap(); usleep(400_000)
            if app.buttons["下一题"].exists && app.buttons["下一题"].isHittable { app.buttons["下一题"].tap(); usleep(400_000) }
        }
        snap("\(tag)-answering")
        if app.buttons["交卷"].waitForExistence(timeout: 4) {
            app.buttons["交卷"].firstMatch.tap(); sleep(1)
            let confirm = app.alerts.buttons["交卷"].exists ? app.alerts.buttons["交卷"] : app.sheets.buttons["交卷"]
            if confirm.exists { confirm.tap() } else if app.buttons.matching(identifier: "交卷").count > 1 { app.buttons.matching(identifier: "交卷").element(boundBy: 1).tap() }
            sleep(2); snap("\(tag)-result"); alive("\(tag) 交卷")
            if app.buttons["完成"].exists { app.buttons["完成"].firstMatch.tap(); sleep(1); let c = app.alerts.buttons["完成"]; if c.exists { c.tap() } ; snap("\(tag)-done"); alive("\(tag) 完成") }
        } else { snap("\(tag)-no-handin") }
    }

    // MARK: precise flows
    func test10_LearnMaths() {
        home("课本")
        tapText("label CONTAINS '数学'", 8, "learn-maths")
        snap("m-books")
        guard tapText("label BEGINSWITH 'Ch'", 10, "m-chapter") else { return }
        sleep(3); snap("m-chapter")
        if tapText("label CONTAINS '知识卡' OR label CONTAINS '卡'", 4, "m-cards-tab") { sleep(2); snap("m-cards") }
        app.swipeLeft(); usleep(600_000); snap("m-cards-swipe"); alive("maths cards")
        if app.buttons["问 DeepSeek"].waitForExistence(timeout: 3) {
            app.buttons["问 DeepSeek"].tap(); sleep(2); snap("m-ds-sheet"); alive("ds sheet")
            if isPad, app.buttons["选项"].waitForExistence(timeout: 3) {
                app.buttons["选项"].tap(); usleep(700_000)
                if app.buttons["固定到侧边"].waitForExistence(timeout: 2) {
                    app.buttons["固定到侧边"].tap(); sleep(2); snap("m-ds-pinned"); alive("ds pinned")
                    XCTAssertTrue(app.buttons["问 DeepSeek"].exists, "chapter screen lost after pin")
                    app.swipeLeft(); usleep(600_000)
                    if app.buttons["选项"].exists { app.buttons["选项"].firstMatch.tap(); usleep(700_000); if app.buttons["改为弹出窗口"].exists { app.buttons["改为弹出窗口"].tap(); sleep(2); snap("m-ds-unpinned") } }
                } else { XCTFail("pin item missing") }
            }
            if app.buttons["完成"].exists { app.buttons["完成"].firstMatch.tap(); sleep(1) }
        } else { XCTFail("no ✨ on maths cards"); snap("m-no-ds") }
        home("课本")
        XCTAssertTrue(tapText("label CONTAINS '中文'", 6, "learn-after-ds"), "课本 broken after DeepSeek")
        snap("after-ds-zh"); alive("after ds")
    }

    func test11_LearnZhIct() {
        home("课本"); tapText("label CONTAINS '中文'", 8, "zh")
        tapText("label CONTAINS '論仁'", 8, "zh-text"); sleep(4); snap("zh-text"); alive("zh text")
        home("课本"); tapText("label CONTAINS '资讯'", 8, "ict")
        tapText("label CONTAINS 'Information Processing (1)'", 6, "ict-group"); snap("ict-group")
        if tapText("label BEGINSWITH 'A' OR label CONTAINS 'Ch'", 4, "ict-ch") { sleep(2); snap("ict-chapter") }
        alive("ict learn")
    }

    func test12_QuizIct() {
        home("测验"); tapText("label CONTAINS '资讯'", 8, "q-ict")
        if tapText("label CONTAINS '生成测验'", 6, "q-ict-gen") { sleep(2); snap("q-ict-run"); answerAndHandIn("q-ict") }
    }

    func test13_QuizMaths() {
        home("测验"); tapText("label CONTAINS '数学'", 8, "q-m")
        if tapText("label BEGINSWITH 'Ch'", 8, "q-m-set") {
            sleep(2); snap("q-m-set")
            if app.buttons.matching(NSPredicate(format: "label BEGINSWITH '开始' OR label BEGINSWITH '開始'")).firstMatch.exists { tapText("label BEGINSWITH '开始' OR label BEGINSWITH '開始'", 3, "q-m-start") }
            else { tapText("label CONTAINS '套' OR label CONTAINS 'MC' OR label CONTAINS '题'", 4, "q-m-row") }
            sleep(2); answerAndHandIn("q-m")
        }
    }

    func test14_QuizZh() {
        home("测验"); tapText("label CONTAINS '中文'", 8, "q-zh")
        for _ in 0..<4 { app.swipeUp() }
        if app.buttons["全部取消"].exists { app.buttons["全部取消"].tap() }
        if app.buttons["全選"].exists && !app.buttons["全部取消"].exists { snap("q-zh-none"); alive("zh 0 selected") }
        for _ in 0..<3 { app.swipeUp() }
        snap("q-zh-none-bottom"); alive("zh 0 selected bottom")
        for _ in 0..<6 { app.swipeDown() }
        if tapText("label BEGINSWITH '開始' OR label BEGINSWITH '开始'", 5, "q-zh-start") { sleep(2); answerAndHandIn("q-zh") }
    }

    func test15_PapersMaths() {
        home("真题"); tapText("label CONTAINS '数学'", 8, "p-m"); sleep(2); snap("p-m")
        if tapText("label CONTAINS 'HKCEE' OR label CONTAINS '会考'", 4, "p-m-cee") { sleep(2); snap("p-m-cee"); alive("hkcee"); if tapText("label BEGINSWITH 'Ch' OR label CONTAINS '19'", 3, "p-m-cee-set") { sleep(2); snap("p-m-cee-set"); answerAndHandIn("p-cee") } }
        home("真题"); tapText("label CONTAINS '数学'", 8, "p-m2")
        if tapText("label CONTAINS '学校卷' OR label CONTAINS '20'", 4, "p-m-school") { sleep(2); snap("p-m-school"); alive("school papers") }
        home("真题"); tapText("label CONTAINS '资讯'", 8, "p-ict"); if tapText("label CONTAINS '2019' OR label CONTAINS '2020'", 5, "p-ict-year") { sleep(2); snap("p-ict-year"); alive("dse year") }
    }

    // MARK: tests
    func test01_Sections() {
        snap("launch")
        for s in ["每日练习", "课本", "真题", "测验", "备考计划", "工具", "进度", "设置"] {
            section(s); snap("section-\(s)")
        }
        section("课本"); XCTAssertTrue(app.state == .runningForeground)
    }

    func skip_TextbookDeep() {
        section("课本")
        for subj in 0..<3 {
            section("课本"); back(4)
            guard tapCell(subj) else { break }
            snap("learn-subject-\(subj)")
            if tapCell(0) { snap("learn-book-\(subj)") }
            if tapCell(0) { snap("learn-chapter-\(subj)") }
            // Open cards if there is a cards row
            if tapButton(["知识卡", "卡片", "读卡"], timeout: 1) || tapCell(0) {
                snap("learn-cards-\(subj)")
                app.swipeLeft(); app.swipeLeft(); usleep(500_000)
                snap("learn-cards-swiped-\(subj)")
            }
            alive("textbook subject \(subj)")
            back(5)
        }
    }

    func skip_PracticeReveal() {
        section("课本"); back(4)
        guard tapCell(1) else { return }   // second subject (Maths) has textbook practice
        tapCell(0); tapCell(0)
        for _ in 0..<6 { if app.buttons["显示答案"].exists { break }; if !tapCell(1) { break } }
        if tapButton(["显示答案"]) { snap("practice-revealed") }
        alive("practice reveal")
    }

    func skip_Quizzes() {
        for subj in 0..<3 {
            section("测验"); back(4)
            guard tapCell(subj) else { continue }
            snap("quiz-home-\(subj)")
            if subj == 2 {
                // 中文: custom range with nothing selected (regression)
                if app.buttons["全部取消"].exists { app.buttons["全部取消"].tap() }
                snap("quiz-zh-none-selected")
                alive("zh custom 0 selected")
                if app.buttons["全選"].exists { app.buttons["全選"].tap() }
            }
            if tapButton(["开始", "開始", "开始做题"], timeout: 2) || tapCell(0) {
                sleep(1); snap("quiz-running-\(subj)")
                // answer a few MC questions
                for _ in 0..<3 {
                    let opt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A' OR label BEGINSWITH 'B'")).firstMatch
                    if opt.exists && opt.isHittable { opt.tap(); usleep(400_000) }
                    _ = tapButton(["下一题", "下一題"], timeout: 1)
                }
                if tapButton(["交卷"], timeout: 2) {
                    _ = tapButton(["交卷"], timeout: 2)   // confirm dialog
                    sleep(1); snap("quiz-result-\(subj)")
                }
                alive("quiz \(subj)")
                _ = tapButton(["完成", "关闭", "Done"], timeout: 2)
            }
            back(5)
        }
    }

    func test05_DailyPlanSettings() {
        section("每日练习")
        if tapButton(["开始做题", "继续做题", "回看答案"], timeout: 3) { snap("daily-open"); alive("daily"); back(2) }
        section("备考计划")
        if tapButton(["添加考试"], timeout: 3) {
            snap("plan-new")
            for c in app.switches.allElementsBoundByIndex.prefix(3) where c.isHittable { c.tap() }
            snap("plan-new-filled"); alive("plan create")
            _ = tapButton(["取消", "完成", "保存"], timeout: 2)
        }
        section("设置")
        for i in 0..<6 {
            if tapCell(i) { snap("settings-\(i)"); alive("settings \(i)"); back() }
        }
    }

    /// Regression: DeepSeek sheet → pin → unpin → close → 课本 still works.
    func skip_DeepSeekPanel() {
        section("课本"); back(4)
        tapCell(0); tapCell(0); tapCell(0)
        let ds = app.buttons["问 DeepSeek"]
        guard ds.waitForExistence(timeout: 5) else { tapCell(0); return snap("ds-no-button") }
        ds.tap(); sleep(2); snap("ds-sheet")
        alive("ds open")
        if isPad {
            if tapButton(["选项"], timeout: 2), tapButton(["固定到侧边"], timeout: 2) {
                sleep(1); snap("ds-pinned"); alive("ds pinned")
                XCTAssertTrue(app.buttons["问 DeepSeek"].exists, "screen gone after pin")
                // page change while pinned
                app.swipeLeft(); usleep(600_000); snap("ds-pinned-swiped")
                if tapButton(["选项"], timeout: 2), tapButton(["改为弹出窗口"], timeout: 2) { sleep(1); snap("ds-unpinned-sheet") }
            }
        }
        _ = tapButton(["完成"], timeout: 2)
        sleep(1)
        section("课本"); back(5)
        XCTAssertTrue(tapCell(0), "Can't open 课本 after using DeepSeek panel")
        snap("ds-after-learn"); alive("after ds")
    }

    func test07_CompactPortrait() {
        // On iPhone runs this exercises the tab bar; on iPad, a compact multitasking width isn't available in XCUITest.
        XCUIDevice.shared.orientation = .portrait
        sleep(1); snap("portrait")
        for t in ["课本", "测验", "更多"] where app.tabBars.buttons[t].exists {
            app.tabBars.buttons[t].tap(); sleep(1); snap("tab-\(t)"); alive("tab \(t)")
        }
    }
}
