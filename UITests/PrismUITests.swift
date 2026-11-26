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

    // MARK: tests
    func test01_Sections() {
        snap("launch")
        for s in ["每日练习", "课本", "真题", "测验", "备考计划", "工具", "进度", "设置"] {
            section(s); snap("section-\(s)")
        }
        section("课本"); XCTAssertTrue(app.state == .runningForeground)
    }

    func test02_TextbookDeep() {
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

    func test03_PracticeReveal() {
        section("课本"); back(4)
        guard tapCell(1) else { return }   // second subject (Maths) has textbook practice
        tapCell(0); tapCell(0)
        for _ in 0..<6 { if app.buttons["显示答案"].exists { break }; if !tapCell(1) { break } }
        if tapButton(["显示答案"]) { snap("practice-revealed") }
        alive("practice reveal")
    }

    func test04_Quizzes() {
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
    func test06_DeepSeekPanel() {
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
