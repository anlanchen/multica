import Foundation
import XCTest
@testable import MulticaCore

private typealias S = AutopilotsSchedule
private let TZ = "Asia/Shanghai"

private func every(_ interval: Int = 1, _ unit: S.Unit = .hours, window: (String, String)? = nil, minute: Int = 0) -> S.TimePattern {
    .every(S.Every(interval: interval, unit: unit, window: window.map { S.Window(from: $0.0, to: $0.1) }, minute: minute))
}

private func everyValue(_ interval: Int = 1, _ unit: S.Unit = .hours, window: (String, String)? = nil, minute: Int = 0) -> S.Every {
    S.Every(interval: interval, unit: unit, window: window.map { S.Window(from: $0.0, to: $0.1) }, minute: minute)
}

final class AutopilotsCronMappingTests: XCTestCase {
    private func structured(_ expr: String, file: StaticString = #filePath, line: UInt = #line) -> S.Config {
        let p = S.parseCron(expr, timezone: TZ)
        XCTAssertNil(p.raw, "expected \(expr.debugDescription) to be structurable", file: file, line: line)
        return p
    }

    func testFixedDailyTime() {
        let p = structured("0 9 * * *")
        XCTAssertEqual(p.time, .at("09:00"))
        XCTAssertEqual(p.days, .every)
        XCTAssertEqual(p.timezone, TZ)
        XCTAssertEqual(structured("05 09 * * *").time, .at("09:05"))
        XCTAssertEqual(structured("  0  9  *  *  *  ").time, .at("09:00"))
    }

    func testWeekdayPreset() {
        let p = structured("30 18 * * 1-5")
        XCTAssertEqual(p.time, .at("18:30"))
        XCTAssertEqual(p.days, .weekly([1, 2, 3, 4, 5]))
    }

    func testStrayCommas() {
        for expr in ["0, 9 * * *", ",0 9 * * *", "0 9, * * *", "0 ,9 * * *"] {
            XCTAssertEqual(structured(expr).time, .at("09:00"), expr)
        }
        XCTAssertEqual(structured("0 9 15, * *").days, .monthly(15))
    }

    func testQuestionMarkIsWildcard() {
        for expr in ["? 10 * * *", "0 ? * * *", "0 9 ? * 1-5", "0 9 15 * ?"] {
            XCTAssertNil(structured(expr).raw, expr)
        }
        let p = structured("? 10 * * *")
        XCTAssertEqual(p.time, every(1, .minutes, window: ("10:00", "10:59")))
        XCTAssertEqual(S.cronFields(p), "* 10 * * *")
    }

    func testWildcardUnreadUpperEnd() {
        let cases = [
            ("0 *-19 * * *", "0 * * * *"),
            ("0 ?-19 * * *", "0 * * * *"),
            ("0 *-19/2 * * *", "0 */2 * * *"),
            ("*-30/10 9 * * *", "*/10 9 * * *"),
            ("0 *-abc * * *", "0 * * * *"),
            ("0 *-10-20 * * *", "0 * * * *"),
            ("0 9 * * ?-5", "0 9 * * *"),
            ("0 9 *-15 * *", "0 9 * * *"),
        ]
        for (expr, canonical) in cases {
            XCTAssertEqual(S.cronFields(structured(expr)), canonical, expr)
        }
        XCTAssertEqual(S.parseCron("0 9-? * * *", timezone: TZ).raw, "0 9-? * * *")
    }

    func testWildcardListCollapse() {
        let cases = [
            ("0,* 9 * * *", "* 9 * * *"),
            ("*,*/2 9 * * *", "* 9 * * *"),
            ("?,15 9 * * *", "* 9 * * *"),
            ("0,*-30 9 * * *", "* 9 * * *"),
            ("0 9,* * * *", "0 * * * *"),
            ("0 9 1,* * *", "0 9 * * *"),
            ("0 9 * 1,* *", "0 9 * * *"),
            ("0 9 * JAN,* *", "0 9 * * *"),
            ("0 9 * * 1,*", "0 9 * * *"),
        ]
        for (expr, canonical) in cases {
            XCTAssertEqual(S.cronFields(structured(expr)), canonical, expr)
        }
        for expr in ["*,abc 9 * * *", "*,60 9 * * *", "0 9 *,32 * *", "0 9 * FOO,* *"] {
            XCTAssertEqual(S.parseCron(expr, timezone: TZ).raw, expr)
        }
    }

    func testDegenerateRangesCollapse() {
        let cases = [
            ("*/65 * * * *", "0 * * * *"),
            ("0 */24 * * *", "0 0 * * *"),
            ("0 10-20/30 * * *", "0 10 * * *"),
            ("0 9 */40 * *", "0 9 1 * *"),
            ("5-5 9 * * *", "5 9 * * *"),
            ("*/100 * * * *", "0 * * * *"),
        ]
        for (expr, canonical) in cases {
            XCTAssertEqual(S.cronFields(structured(expr)), canonical, expr)
        }
    }

    func testHourWindowWhoseStepOutrunsIt() {
        let p = structured("0 9-19/23 * * *")
        XCTAssertEqual(p.time, every(23, .hours, window: ("09:00", "19:00")))
        XCTAssertEqual(S.cronFields(p), "0 9-19/23 * * *")

        let q = structured("*/65 10-20 14 * *")
        XCTAssertEqual(q.days, .monthly(14))
        XCTAssertEqual(q.time, every(1, .hours, window: ("10:00", "20:00")))
        XCTAssertEqual(S.cronFields(q), "0 10-20 14 * *")
    }

    func testHourlyIntervals() {
        for (expr, interval, minute) in [("0 * * * *", 1, 0), ("15 * * * *", 1, 15), ("0 */2 * * *", 2, 0), ("15 */3 * * *", 3, 15)] {
            XCTAssertEqual(structured(expr).time, every(interval, .hours, minute: minute), expr)
        }
    }

    func testHourRangeSpanningDayIsAllDay() {
        let cases: [(String, S.Unit, Int, Int)] = [
            ("0 0-23 * * *", .hours, 1, 0), ("0 0-23/3 * * *", .hours, 3, 0), ("15 0-23/2 * * *", .hours, 2, 15),
            ("*/30 0-23 * * *", .minutes, 30, 0), ("*/30 0-23/1 * * *", .minutes, 30, 0),
        ]
        for (expr, unit, interval, minute) in cases {
            XCTAssertEqual(structured(expr).time, every(interval, unit, minute: minute), expr)
        }
    }

    func testHourWindows() {
        let cases = [("0 9-21 * * *", 1, "09:00", "21:00", 0), ("30 9-21 * * *", 1, "09:30", "21:30", 30), ("0 9-21/2 * * *", 2, "09:00", "21:00", 0)]
        for (expr, interval, from, to, minute) in cases {
            XCTAssertEqual(structured(expr).time, every(interval, .hours, window: (from, to), minute: minute), expr)
        }
    }

    func testBareHourWithStepRunsToMax() {
        let cases: [(String, Int, (String, String)?, Int, String)] = [
            ("0 9/2 * * *", 2, ("09:00", "23:00"), 0, "0 9-23/2 * * *"),
            ("30 9/1 * * *", 1, ("09:30", "23:30"), 30, "30 9-23 * * *"),
            ("0 0/2 * * *", 2, nil, 0, "0 */2 * * *"),
            ("0 ?/2 * * *", 2, nil, 0, "0 */2 * * *"),
        ]
        for (expr, interval, window, minute, back) in cases {
            let p = structured(expr)
            XCTAssertEqual(p.time, every(interval, .hours, window: window, minute: minute), expr)
            XCTAssertEqual(S.cronFields(p), back, expr)
        }
    }

    func testDegenerateHourWindowsStayWindows() {
        let cases = [("0 9-9 * * *", 1, "09:00", "09:00"), ("0 9-9/3 * * *", 3, "09:00", "09:00"),
                     ("0 9-11/5 * * *", 5, "09:00", "11:00"), ("0 9-21/23 * * *", 23, "09:00", "21:00")]
        for (expr, interval, from, to) in cases {
            XCTAssertEqual(structured(expr).time, every(interval, .hours, window: (from, to)), expr)
        }
        let minuteCases = [("*/5 9-9/3 * * *", 5, "09:00", "09:59"), ("*/10 9-21/23 * * *", 10, "09:00", "09:59"), ("*/10 9-9 * * *", 10, "09:00", "09:59")]
        for (expr, interval, from, to) in minuteCases {
            XCTAssertEqual(structured(expr).time, every(interval, .minutes, window: (from, to)), expr)
        }
        for (expr, time) in [("0 9-9/24 * * *", "09:00"), ("0 9-21/30 * * *", "09:00"), ("0 */24 * * *", "00:00")] {
            XCTAssertEqual(structured(expr).time, .at(time), expr)
        }
    }

    func testDowStepWiderThanWeek() {
        for (expr, days) in [("0 9 * * */100", [0]), ("0 9 * * 1-5/60", [1]), ("0 9 * * MON-FRI/60", [1]), ("0 9 * * */7", [0])] {
            XCTAssertEqual(structured(expr).days, .weekly(days), expr)
        }
    }

    func testCompoundExpression() {
        let p = structured("0 9-21/2 * * 2-4")
        XCTAssertEqual(p.time, every(2, .hours, window: ("09:00", "21:00")))
        XCTAssertEqual(p.days, .weekly([2, 3, 4]))
    }

    func testMinuteIntervals() {
        let cases: [(String, Int, (String, String)?)] = [
            ("* * * * *", 1, nil), ("*/10 * * * *", 10, nil), ("0/5 * * * *", 5, nil),
            ("*/10 9-18 * * *", 10, ("09:00", "18:59")), ("* 9 * * *", 1, ("09:00", "09:59")), ("*/15 9 * * *", 15, ("09:00", "09:59")),
        ]
        for (expr, interval, window) in cases {
            XCTAssertEqual(structured(expr).time, every(interval, .minutes, window: window), expr)
        }
    }

    func testMonthly() {
        let cases: [(String, S.TimePattern, Int)] = [
            ("30 10 15 * *", .at("10:30"), 15), ("0 9 1 * *", .at("09:00"), 1), ("0 9 31 * *", .at("09:00"), 31),
            ("*/10 * 15 * *", every(10, .minutes), 15),
        ]
        for (expr, time, dom) in cases {
            let p = structured(expr)
            XCTAssertEqual(p.time, time, expr)
            XCTAssertEqual(p.days, .monthly(dom), expr)
        }
    }

    func testDowExpansion() {
        let cases: [(String, [Int])] = [
            ("0 9 * * 0", [0]), ("0 9 * * 6", [6]), ("0 9 * * 1,3,5", [1, 3, 5]), ("0 9 * * 5,1,5", [1, 5]),
            ("0 9 * * 0-6", [0, 1, 2, 3, 4, 5, 6]), ("0 9 * * MON", [1]), ("0 9 * * SUN", [0]), ("0 9 * * SAT", [6]),
            ("0 9 * * mon-fri", [1, 2, 3, 4, 5]), ("0 9 * * MON,WED", [1, 3]), ("0 9 * * */2", [0, 2, 4, 6]),
            ("0 9 * * 1-5/2", [1, 3, 5]), ("0 9 * * 1/2", [1, 3, 5]), ("0 9 * * MON/2", [1, 3, 5]), ("0 9 * * */7", [0]),
            ("0 9 * * 1,3-5", [1, 3, 4, 5]), ("0 9 * * 1-5,", [1, 2, 3, 4, 5]), ("0 9 * * 1,,5", [1, 5]), ("0 9 * * ,1,5", [1, 5]),
        ]
        for (expr, days) in cases {
            XCTAssertEqual(structured(expr).days, .weekly(days), expr)
        }
    }

    func testAdvancedFallbackPreservesRaw() {
        let cases = [
            "0-30 9 * * *", "0,30 9 * * *", "15/5 * * * *", "60 9 * * *", "-5 9 * * *", "99999999999999999999 9 * * *",
            "0 9,12,15 * * *", "0 24 * * *", "0 21-9 * * *", "*/10 */2 * * *", "* */2 * * *", "*/10 9-18/2 * * *",
            "?/2 ?/2 * * ?/2", "0 9 1,15 * *", "0 9 1-15 * *", "0 9 */2 * *", "0 9 0 * *", "0 9 32 * *", "0 9 15 * 1",
            "0 9 * 6 *", "0 9 * JAN *", "0 9 * * 7", "0 9 * * 5-1", "0 9 * *", "0 0 9 * * *", "not a cron", "", "   ",
            "@daily", "@every 1h", "0 9 L * *", "0 9 * * 5L", "0 9 * * 1#2", "0 9 15W * *",
        ]
        for expr in cases {
            let p = S.parseCron(expr, timezone: TZ)
            XCTAssertEqual(p.raw, expr, expr.debugDescription)
            XCTAssertEqual(p.timezone, TZ)
        }
    }

    func testCronFieldsSerialization() {
        let base = S.defaultConfig(timezone: TZ)
        func cfg(_ time: S.TimePattern, _ days: S.DayPattern) -> S.Config {
            var c = base
            c.time = time
            c.days = days
            return c
        }
        let cases: [(S.Config, String)] = [
            (cfg(.at("09:00"), .every), "0 9 * * *"),
            (cfg(.at("18:30"), .weekly([1, 2, 3, 4, 5])), "30 18 * * 1-5"),
            (cfg(.at("09:00"), .weekly([1, 3, 5])), "0 9 * * 1,3,5"),
            (cfg(.at("09:00"), .weekly([0, 1, 2, 4])), "0 9 * * 0-2,4"),
            (cfg(every(2, .hours, window: ("09:00", "21:00")), .weekly([2, 3, 4])), "0 9-21/2 * * 2-4"),
            (cfg(every(1, .hours, minute: 15), .every), "15 * * * *"),
            (cfg(every(3, .hours), .every), "0 */3 * * *"),
            (cfg(every(1, .hours, window: ("09:30", "21:30"), minute: 30), .every), "30 9-21 * * *"),
            (cfg(every(10, .minutes, window: ("09:00", "18:59")), .every), "*/10 9-18 * * *"),
            (cfg(every(15, .minutes, window: ("09:00", "09:59")), .every), "*/15 9 * * *"),
            (cfg(every(1, .minutes), .every), "* * * * *"),
            (cfg(.at("10:30"), .monthly(15)), "30 10 15 * *"),
            (cfg(every(2, .hours), .monthly(15)), "0 */2 15 * *"),
            (cfg(every(2, .hours, window: ("09:30", "21:30"), minute: 30), .monthly(15)), "30 9-21/2 15 * *"),
            (cfg(every(10, .minutes, window: ("09:00", "18:59")), .monthly(1)), "*/10 9-18 1 * *"),
            (cfg(.at("09:00"), .weekly([0, 1, 2, 3, 4, 5, 6])), "0 9 * * 0-6"),
        ]
        for (config, expected) in cases {
            XCTAssertEqual(S.cronFields(config), expected)
        }
        var raw = base
        raw.raw = "0 9 1,15 * *"
        XCTAssertEqual(S.cronFields(raw), "0 9 1,15 * *")
        XCTAssertEqual(S.cronFields(cfg(.at("09:00"), .weekly([]))), "0 9 * * 1")
    }

    static let canonical = [
        "0 9 * * *", "30 18 * * 1-5", "15 * * * *", "0 */2 * * *", "30 9-21 * * *", "0 9-21/2 * * 2-4",
        "*/10 9-18 * * 1-5", "*/15 9 * * *", "30 10 15 * *", "* * * * *", "0 9 * * 1,3,5", "0 9 * * 0-2,4",
        "0 */2 15 * *", "30 9-21/2 15 * *", "*/10 9-18 1 * *", "0 9 * * 0-6", "0 9-9 * * *", "0 9-9/3 * * *", "59 23 * * *",
    ]

    static let normalizing: [(String, String)] = [
        ("05 09 * * *", "5 9 * * *"), ("0/5 * * * *", "*/5 * * * *"), ("*/10 */1 * * *", "*/10 * * * *"),
        ("*/10 0-23/1 * * *", "*/10 * * * *"), ("*/10 0-23 * * *", "*/10 * * * *"), ("0 0-23 * * *", "0 * * * *"),
        ("0 0-23/3 * * *", "0 */3 * * *"), ("15 0-23/2 * * 1-5", "15 */2 * * 1-5"), ("*/10 9-18/1 * * *", "*/10 9-18 * * *"),
        ("0 9-21/1 * * *", "0 9-21 * * *"), ("0 9 * * 5,1,5", "0 9 * * 1,5"), ("0 9 * * MON-FRI", "0 9 * * 1-5"),
        ("0 9 * * sun-sat", "0 9 * * 0-6"), ("0 9 * * 1-5,", "0 9 * * 1-5"), ("0 9 * * 1,,5", "0 9 * * 1,5"),
        ("0, 9 * * *", "0 9 * * *"), ("0 9, * * *", "0 9 * * *"), ("0 9 15, * *", "0 9 15 * *"), (",0 ,9 * * *", "0 9 * * *"),
        ("009 09 * * *", "9 9 * * *"), ("+30 14 * * *", "30 14 * * *"), ("00/05 9-18 * * *", "*/5 9-18 * * *"),
        ("0 09-021/02 * * *", "0 9-21/2 * * *"), ("0 9 015 * *", "0 9 15 * *"), ("0 9 * * 001", "0 9 * * 1"),
        ("0 9 * * MON-05", "0 9 * * 1-5"), ("0 9 * * */2", "0 9 * * 0,2,4,6"), ("0 9/2 * * *", "0 9-23/2 * * *"),
        ("0 ?/2 * * *", "0 */2 * * *"), ("0 9-9/24 * * *", "0 9 * * *"),
    ]

    func testBidirectionalInvariants() {
        for expr in Self.canonical {
            XCTAssertEqual(S.cronFields(S.parseCron(expr, timezone: TZ)), expr)
        }
        for (expr, normalized) in Self.normalizing {
            XCTAssertEqual(S.cronFields(S.parseCron(expr, timezone: TZ)), normalized, expr)
        }
        for expr in Self.canonical + Self.normalizing.map(\.0) {
            let once = S.parseCron(expr, timezone: TZ)
            XCTAssertEqual(S.parseCron(S.toCron(once), timezone: TZ), once, expr)
        }
        let adv = S.parseCron("0 9 1,15 * *", timezone: TZ)
        XCTAssertEqual(adv.raw, "0 9 1,15 * *")
        XCTAssertEqual(S.parseCron(S.toCron(adv), timezone: TZ), adv)
    }

    func testEditorConfigsSurviveRoundTrip() {
        let base = S.defaultConfig(timezone: TZ)
        let times: [S.TimePattern] = [
            every(3, .hours, window: ("09:00", "09:00")),
            every(2, .hours, window: ("22:30", "22:30"), minute: 30),
            every(10, .minutes, window: ("09:00", "09:59")),
            every(1, .hours, window: ("00:00", "22:00")),
            every(3, .hours, minute: 15),
        ]
        for time in times {
            var c = base
            c.time = time
            XCTAssertEqual(S.parseCron(S.toCron(c), timezone: TZ), c)
        }
    }

    func testToCronWireExpression() {
        var base = S.defaultConfig(timezone: TZ)
        XCTAssertEqual(S.toCron(base), "TZ=Asia/Shanghai 0 9 * * *")
        var raw = base
        raw.raw = "0 9 1,15 * *"
        XCTAssertEqual(S.toCron(raw), "TZ=Asia/Shanghai 0 9 1,15 * *")
        XCTAssertEqual(S.parseCron(S.toCron(base), timezone: "Test/Sentinel"), base)
        for r in ["TZ=Local 0 9 * * *", "CRON_TZ=Bogus/Zone 0 9 * * *", "TZ=UTC"] {
            var c = base
            c.raw = r
            XCTAssertEqual(S.toCron(c), r)
        }
        base.timezone = ""
        XCTAssertEqual(S.toCron(base), "0 9 * * *")
        base.timezone = "Bad Zone"
        XCTAssertEqual(S.toCron(base), "0 9 * * *")
    }

    func testTimezonePrefixExtraction() {
        let p = S.parseCron("TZ=Asia/Tokyo 0 9 * * *", timezone: TZ)
        XCTAssertNil(p.raw)
        XCTAssertEqual(p.timezone, "Asia/Tokyo")
        XCTAssertEqual(p.time, .at("09:00"))
        XCTAssertEqual(S.toCron(p), "TZ=Asia/Tokyo 0 9 * * *")

        let q = S.parseCron("CRON_TZ=America/New_York 30 */3 * * 1-5", timezone: TZ)
        XCTAssertNil(q.raw)
        XCTAssertEqual(q.timezone, "America/New_York")
        XCTAssertEqual(S.toCron(q), "TZ=America/New_York 30 */3 * * 1-5")

        XCTAssertEqual(S.parseCron("TZ= 0 9 * * *", timezone: TZ).timezone, "UTC")
        XCTAssertEqual(S.parseCron("TZ=asia/shanghai 0 9 * * *", timezone: "UTC").timezone, "Asia/Shanghai")
        XCTAssertEqual(S.parseCron("CRON_TZ=UTC 0 9 * * *", timezone: "Asia/Tokyo").timezone, "UTC")

        let adv = S.parseCron("TZ=Asia/Tokyo ?/2 ?/2 * * ?/2", timezone: TZ)
        XCTAssertEqual(adv.raw, "?/2 ?/2 * * ?/2")
        XCTAssertEqual(adv.timezone, "Asia/Tokyo")

        for expr in ["TZ=Local 0 9 * * *", "TZ=Bogus/Zone 0 9 * * *", "TZ=UTC\t 0 9 * * *", "TZ=UTC", "CRON_TZ=Asia/Tokyo",
                     "TZ=", "TZ=UTC ", "TZ=UTC TZ=UTC 0 9 * * *", "TZ=UTC CRON_TZ=Asia/Tokyo 0 9 * * *", "tz=UTC 0 9 * * *",
                     " TZ=UTC 0 9 * * *"] {
            let c = S.parseCron(expr, timezone: TZ)
            XCTAssertEqual(c.raw, expr, expr.debugDescription)
            XCTAssertEqual(c.timezone, TZ, expr.debugDescription)
        }
    }
}

// MARK: - Grammar corpus against a reference robfig/cron v3 parser

private struct RefBounds {
    let min: Int
    let max: Int
    var names: [String: Int]? = nil
}

private struct RefField {
    var values: Set<Int>
    var star: Bool
}

private struct RefSpec {
    var minute, hour, dom, month, dow: RefField
    var tz: String?
    var tzValid: Bool
    var body: String
}

private enum Reference {
    static let minute = RefBounds(min: 0, max: 59)
    static let hour = RefBounds(min: 0, max: 23)
    static let dom = RefBounds(min: 1, max: 31)
    static let month = RefBounds(min: 1, max: 12, names: ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                                           "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12])
    static let dow = RefBounds(min: 0, max: 6, names: ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6])

    static let tzVerdicts: [String: Bool] = ["UTC": true, "Asia/Tokyo": true, "Asia/Shanghai": true, "Local": true,
                                             "Bogus/Zone": false, "A=B": false, "UTC\t": false]

    struct SyntaxError: Error {}

    static func atoi(_ s: Substring) -> Int? {
        var t = s
        if t.first == "+" { t = t.dropFirst() }
        guard !t.isEmpty, t.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(t) ?? Int.max
    }

    static func parseIntOrName(_ token: Substring, _ b: RefBounds) throws -> Int {
        if let n = b.names?[token.lowercased()] { return n }
        guard let v = atoi(token) else { throw SyntaxError() }
        return v
    }

    static func getRange(_ expr: Substring, _ b: RefBounds) throws -> RefField {
        let parts = expr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw SyntaxError() }
        let rangeStr = parts[0]
        guard !rangeStr.isEmpty else { throw SyntaxError() }
        var step = 1
        if parts.count == 2 {
            guard let s = atoi(parts[1]) else { throw SyntaxError() }
            guard s != 0 else { throw SyntaxError() }
            step = s
        }
        let ends = rangeStr.split(separator: "-", omittingEmptySubsequences: false)
        let star = ends[0] == "*" || ends[0] == "?"
        let low: Int
        let high: Int
        if star {
            low = b.min
            high = b.max
        } else {
            guard ends.count <= 2 else { throw SyntaxError() }
            low = try parseIntOrName(ends[0], b)
            if ends.count == 2 {
                high = try parseIntOrName(ends[1], b)
            } else {
                high = parts.count == 2 ? b.max : low
            }
        }
        guard low >= b.min, high <= b.max, low <= high else { throw SyntaxError() }
        var values = Set<Int>()
        var v = low
        while v <= high {
            values.insert(v)
            let (next, overflow) = v.addingReportingOverflow(step)
            if overflow { break }
            v = next
        }
        return RefField(values: values, star: star && step == 1)
    }

    static func parseField(_ expr: String, _ b: RefBounds) throws -> RefField {
        var values = Set<Int>()
        var star = false
        for part in expr.split(separator: ",", omittingEmptySubsequences: false) where !part.isEmpty {
            let f = try getRange(part, b)
            values.formUnion(f.values)
            if f.star { star = true }
        }
        return RefField(values: values, star: star)
    }

    enum Prefix {
        case none
        case reject
        case some(tz: String, tzValid: Bool, rest: String)
    }

    static func prefix(_ expr: String) -> Prefix {
        guard expr.hasPrefix("TZ=") || expr.hasPrefix("CRON_TZ=") else { return .none }
        guard let space = expr.firstIndex(of: " "), let eq = expr.firstIndex(of: "=") else { return .reject }
        let name = String(expr[expr.index(after: eq)..<space])
        let tz = name.isEmpty ? "UTC" : name
        guard let valid = tzVerdicts[tz] else {
            XCTFail("corpus uses unpinned timezone \(name.debugDescription)")
            return .reject
        }
        return .some(tz: tz, tzValid: valid, rest: String(expr[space...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parse(_ expr: String) -> RefSpec? {
        let p = prefix(expr)
        var body = expr
        var tz: String?
        var tzValid = true
        switch p {
        case .reject: return nil
        case .none: break
        case .some(let t, let v, let rest):
            body = rest
            tz = t
            tzValid = v
        }
        let parts = body.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 5 else { return nil }
        do {
            return RefSpec(minute: try parseField(parts[0], minute), hour: try parseField(parts[1], hour),
                           dom: try parseField(parts[2], dom), month: try parseField(parts[3], month),
                           dow: try parseField(parts[4], dow), tz: tz, tzValid: tzValid,
                           body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }

    static func extractedForEcho(_ expr: String) -> (tz: String, rest: String)? {
        guard case .some(let tz, _, let rest) = prefix(expr), !rest.isEmpty else { return nil }
        if rest.hasPrefix("TZ=") || rest.hasPrefix("CRON_TZ=") { return nil }
        guard let canonical = S.canonicalZone(tz) else { return nil }
        return (canonical, rest)
    }

    static func dayMatches(_ s: RefSpec, _ dom: Int, _ dow: Int) -> Bool {
        let domHit = s.dom.values.contains(dom)
        let dowHit = s.dow.values.contains(dow)
        return s.dom.star || s.dow.star ? domHit && dowHit : domHit || dowHit
    }

    static func sameSchedule(_ a: RefSpec, _ b: RefSpec) -> Bool {
        guard a.minute.values == b.minute.values, a.hour.values == b.hour.values, a.month.values == b.month.values else { return false }
        for dom in 1...31 {
            for dow in 0...6 where dayMatches(a, dom, dow) != dayMatches(b, dom, dow) {
                return false
            }
        }
        return true
    }
}

private func fullMatch(_ pattern: String, _ s: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return false }
    return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

private func lastMatchGroup(_ pattern: String, _ s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

final class AutopilotsCronGrammarTests: XCTestCase {
    static let minuteTokens = [
        "*", "?", "0", "5", "30", "59", "60", "-5", "*/1", "*/5", "*/59", "*/60", "*/0", "?/5", "0/5", "15/5", "59/5",
        "0-30", "0-30/10", "30-0", "0-59", "0,30", "0,15,30,45", "0-10,30", "0-30/10,45",
        "0,30,", ",0,30", "1,,5", ",", "0,", ",0", "30,", "0,*", "*,*/2", "?,15", "0,*-30", "*,60", "*,abc",
        "09", "009", "00", "+30", "030-045", "00/05", "*/05", "*/+5", "99999999999999999999", "+",
        "*-30", "?-30", "*-30/10", "?-30/10", "*-99", "*-abc", "*-10-20", "9-?", "5-5", "", "*/", "0//5", "0--30", "abc",
    ]
    static let hourTokens = [
        "*", "?", "0", "9", "23", "24", "-1", "*/1", "*/2", "*/23", "*/24", "*/0", "0/2", "9/2", "23/2", "9/1", "?/2",
        "*-19", "?-19", "*-19/2", "?-19/2", "*-19/23", "9-19/23", "9-21", "9-21/2", "9-21/1", "21-9", "0-23", "0-23/1", "9-9",
        "9-9/3", "9-9/24", "9-11/5", "9-21/23", "9-21/30", "9,12,15", "9-12,18", "0-23/6", "9,12,", "9,,12", "9,", ",9", "0,",
        "9,*", "*,*/2", "09", "021", "+9", "09-021/02", "", "*/", "9//2", "abc",
    ]
    static let domTokens = [
        "*", "?", "1", "15", "31", "0", "32", "*/2", "?/2", "1/2", "1-15", "1-15/2", "15-1", "*-15", "?-15", "*-15/2", "?/40",
        "1,15", "1-7,15", "1,15,", "1,,15", "15,", ",15", "1,*", "*,32", "L", "15W", "015", "01", "+15", "", "abc",
    ]
    static let monthTokens = [
        "*", "?", "1", "6", "12", "0", "13", "JAN", "jan", "DEC", "FOO", "*/2", "?/2", "1-6", "1-6/2", "1,6", "6-1", "1,6,",
        "1,,6", "6,", ",6", "1,*", "JAN,*", "FOO,*", "*-6", "?-6", "*-6/2", "JAN-JUN/2", "06", "012", "+6", "", "abc",
    ]
    static let dowTokens = [
        "*", "?", "0", "1", "6", "7", "-1", "SUN", "sun", "SAT", "MON", "FOO", "*/2", "*/7", "?/2", "1/2", "MON/2", "0/3",
        "*-5", "?-5", "*-5/2", "?-5/2", "SUN-SAT/2", "*/100", "1-5/60", "MON-FRI/60", "1-5", "MON-FRI", "mon-fri", "sun-sat",
        "0-6", "5-1", "1-5/2", "1-1", "1,3,5", "MON,WED", "5,1,5", "1,3-5", "0-2,4", "1-5,", ",1,5", "1,,5", ",", "1,", ",1", "5,",
        "1,*", "MON,*", "*/2,*/3", "*,7", "001", "01", "+1", "+0", "MON-05", "0-06/02", "1#2", "5L", "", "abc",
    ]
    static let dayBranches = ["* * *", "* * 1-5", "* * 0", "* * 6", "1 * *", "15 * *", "31 * *", "15 * 1"]
    static let timeBranches = ["0 9", "30 14", "0 *", "15 *", "0 */2", "30 */3", "0 9-21", "30 9-21", "0 9-21/2", "* *",
                               "*/10 *", "*/10 9-18", "*/15 9"]

    static let corpus: [String] = {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ e: String) { if seen.insert(e).inserted { out.append(e) } }
        for m in minuteTokens { for h in hourTokens { for d in dayBranches { add("\(m) \(h) \(d)") } } }
        for dom in domTokens { for dow in dowTokens { for t in timeBranches { add("\(t) \(dom) * \(dow)") } } }
        for mo in monthTokens {
            for t in timeBranches { add("\(t) * \(mo) *") }
            add("0 9 15 \(mo) *")
            add("0 9 * \(mo) 1-5")
        }
        for e in ["", "   ", "0 9 * *", "0 9 * * * *", "0 0 9 * * *", "@daily", "@hourly", "@every 1h", "@reboot",
                  "not a cron", "0 9 * * 1 # comment", "  0  9  *  *  *  "] { add(e) }
        let prefixes = ["TZ=UTC", "CRON_TZ=Asia/Tokyo", "TZ=Local", "TZ=", "TZ=Bogus/Zone", "TZ=A=B", "tz=UTC", "TZ=UTC\t"]
        let bodies = ["0 9 * * *", "30 */3 * * 1-5", "0 9 1,15 * *", "?/2 ?/2 * * ?/2", "not a cron", "0 9 * *", "", "@daily"]
        for p in prefixes { for b in bodies { add("\(p) \(b)") } }
        for e in ["TZ=UTC", "CRON_TZ=Asia/Tokyo", "TZ=", "TZ=UTC ", "TZ=UTC   ", "TZ=UTC TZ=UTC 0 9 * * *",
                  "TZ=UTC CRON_TZ=Asia/Tokyo 0 9 * * *", " TZ=UTC 0 9 * * *"] { add(e) }
        return out
    }()

    private struct Exclusion: Sendable {
        let why: String
        let holds: @Sendable (RefSpec, [String]) -> Bool
    }

    private static func wildcardQ(_ f: String) -> String {
        f.hasPrefix("?") && (f.count == 1 || f.dropFirst().first == "/") ? "*" + f.dropFirst() : f
    }

    private static let exclusions: [Exclusion] = [
        Exclusion(why: "a field that selects no value at all") { s, _ in
            [s.minute, s.hour, s.dom, s.month, s.dow].contains { $0.values.isEmpty }
        },
        Exclusion(why: "minute is a list, a range, or an anchored step") { _, f in
            let m = wildcardQ(f[0])
            if m == "*" || fullMatch(#"\d{1,2}"#, m) { return false }
            return !fullMatch(#"(\*|0)/\d{1,2}"#, m)
        },
        Exclusion(why: "hour is a list") { _, f in
            let h = wildcardQ(f[1])
            return !(h == "*" || fullMatch(#"\d{1,2}"#, h) || fullMatch(#"\d{1,2}-\d{1,2}(/\d{1,2})?"#, h)
                     || fullMatch(#"\*/\d{1,2}"#, h) || fullMatch(#"\d{1,2}/\d{1,2}"#, h))
        },
        Exclusion(why: "a minute step and an hour step at once") { _, f in
            let m = wildcardQ(f[0])
            let minuteStepped = m == "*" || fullMatch(#"(\*|0)/\d{1,2}"#, m)
            guard let step = lastMatchGroup(#"/(\d{1,2})$"#, f[1]) else { return false }
            return minuteStepped && Int(step) != 1
        },
        Exclusion(why: "day-of-month is anything but a single day") { _, f in
            !(f[2] == "*" || fullMatch(#"\d{1,2}"#, f[2]))
        },
        Exclusion(why: "a pinned day-of-month beside a restricted day-of-week") { _, f in f[2] != "*" && f[4] != "*" },
        Exclusion(why: "month is pinned") { _, f in f[3] != "*" },
        Exclusion(why: "an embedded timezone the picker cannot offer") { s, _ in
            s.tz != nil && S.canonicalZone(s.tz!) == nil
        },
    ]

    private static func meaningfulFields(_ body: String, _ spec: RefSpec) -> [String] {
        let fields = [spec.minute, spec.hour, spec.dom, spec.month, spec.dow]
        let raw = body.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return raw.enumerated().map { i, field in
            let parsed = fields[i]
            if parsed.star { return "*" }
            if parsed.values.count == 1 { return String(parsed.values.first!) }
            return field.split(separator: ",").filter { !$0.isEmpty }.map { part -> String in
                var out = ""
                var digits = ""
                func flush() {
                    if !digits.isEmpty {
                        let t = digits.hasPrefix("+") ? String(digits.dropFirst()) : digits
                        out += Int(t).map(String.init) ?? digits
                        digits = ""
                    }
                }
                for c in part {
                    if ("0"..."9").contains(c) || (c == "+" && digits.isEmpty) {
                        digits.append(c)
                    } else {
                        if digits == "+" { out += "+"; digits = "" }
                        flush()
                        out.append(c)
                    }
                }
                if digits == "+" { out += "+"; digits = "" }
                flush()
                return out
            }.joined(separator: ",")
        }
    }

    func testCorpusCoversEveryTokenForm() {
        let corpus = Self.corpus
        XCTAssertGreaterThan(corpus.count, 10_000)
        XCTAssertGreaterThan(corpus.filter { Reference.parse($0) != nil }.count, 3000)
        XCTAssertGreaterThan(corpus.filter { Reference.parse($0) == nil }.count, 3000)
        for e in ["0 */2 15 * *", "*/10 9-18 15 * *", "0 9-21/2 * * 1-5", "009 9 * * *", "0 9 * * +1", "*-30 9 * * *",
                  "0 *-19 * * *", "0 9 *-15 * *", "0 9 * *-6 *", "0 9 * * ?-5", "0,* 9 * * *", "0 9,* * * *", "0 9 1,* * *",
                  "0 9 * 1,* *", "0 9 * * 1,*", "*,abc 9 * * *", "TZ=UTC 0 9 * * *", "CRON_TZ=Asia/Tokyo 30 */3 * * 1-5",
                  "TZ=Bogus/Zone 0 9 * * *", "TZ=UTC", "tz=UTC 0 9 * * *"] {
            XCTAssertTrue(corpus.contains(e), e)
        }
    }

    func testReferenceReadsPrefixAndWildcardLowEnd() {
        XCTAssertEqual(Reference.parse("TZ=UTC 0 9 * * *")?.tz, "UTC")
        XCTAssertEqual(Reference.parse("CRON_TZ=Asia/Tokyo 0 9 * * *")?.tz, "Asia/Tokyo")
        XCTAssertEqual(Reference.parse("TZ= 0 9 * * *")?.tz, "UTC")
        XCTAssertEqual(Reference.parse("TZ=Bogus/Zone 0 9 * * *")?.tzValid, false)
        for e in ["TZ=UTC", "CRON_TZ=Asia/Tokyo", "TZ=", "tz=UTC 0 9 * * *", " TZ=UTC 0 9 * * *", "TZ=UTC TZ=UTC 0 9 * * *"] {
            XCTAssertNil(Reference.parse(e), e)
        }
        XCTAssertEqual(Reference.parse("0 *-19 * * *")?.hour.values.count, 24)
        XCTAssertEqual(Reference.parse("0 ?-19 * * *")?.hour.star, true)
        XCTAssertEqual(Reference.parse("0 *-19-25 * * *")?.hour.values.count, 24)
        XCTAssertEqual(Reference.parse("0 *-19/2 * * *")?.hour.values.sorted(), Array(stride(from: 0, through: 22, by: 2)))
        XCTAssertNil(Reference.parse("0 9-? * * *"))
    }

    /// Every invariant of upstream's grammar suite, in one pass over the corpus.
    func testEditorAgainstReference() {
        var wronglyAccepted: [String] = []
        var wrongTz: [String] = []
        var outOfDomain: [String] = []
        var drifted: [String] = []
        var mangled: [String] = []
        var unstable: [String] = []
        var unexplained: [String] = []
        func validTime(_ t: String) -> Bool { fullMatch(#"([01]\d|2[0-3]):[0-5]\d"#, t) }

        for expr in Self.corpus {
            let spec = Reference.parse(expr)
            let config = S.parseCron(expr, timezone: "UTC")
            let sentinel = S.parseCron(expr, timezone: "Test/Sentinel")
            let echo = Reference.extractedForEcho(expr)

            if spec == nil && config.raw == nil { wronglyAccepted.append(expr) }
            if sentinel.timezone != (echo?.tz ?? "Test/Sentinel") { wrongTz.append(expr) }
            if sentinel.raw != nil {
                let expectedRaw = echo?.rest ?? expr
                if sentinel.raw != expectedRaw || S.cronFields(sentinel) != expectedRaw { mangled.append(expr) }
            }
            let twice = S.parseCron(S.toCron(config), timezone: config.timezone)
            if twice != config { unstable.append(expr) }

            if config.raw == nil {
                switch config.time {
                case .at(let t):
                    if !validTime(t) { outOfDomain.append("\(expr): at-time") }
                case .every(let e):
                    if e.interval < 1 || e.interval > e.unit.maxInterval { outOfDomain.append("\(expr): interval") }
                    if e.minute < 0 || e.minute > 59 { outOfDomain.append("\(expr): minute") }
                    if let w = e.window, !validTime(w.from) || !validTime(w.to) { outOfDomain.append("\(expr): window") }
                }
                switch config.days {
                case .weekly(let d):
                    if d.isEmpty || d.contains(where: { $0 < 0 || $0 > 6 }) || Array(Set(d)).sorted() != d { outOfDomain.append("\(expr): days") }
                case .monthly(let dom):
                    if dom < 1 || dom > 31 { outOfDomain.append("\(expr): dom") }
                case .every: break
                }
                let after = Reference.parse(S.toCron(config))
                if let before = spec, let after {
                    if !Reference.sameSchedule(before, after) || config.timezone != (before.tz ?? "UTC") { drifted.append(expr) }
                } else {
                    drifted.append(expr)
                }
            } else if let spec, spec.tzValid {
                let fields = Self.meaningfulFields(spec.body, spec)
                if !Self.exclusions.contains(where: { $0.holds(spec, fields) }) { unexplained.append(expr) }
            }
        }
        XCTAssertEqual(wronglyAccepted, [], "structured expressions the server cannot parse")
        XCTAssertEqual(wrongTz, [], "embedded zone not carried in the config")
        XCTAssertEqual(outOfDomain, [], "configs outside the model's domain")
        XCTAssertEqual(drifted, [], "round-trips that changed the schedule's meaning")
        XCTAssertEqual(mangled, [], "advanced expressions not handed back verbatim")
        XCTAssertEqual(unstable, [], "second pass changed something")
        XCTAssertEqual(unexplained, [], "valid expressions sent to advanced-only without a documented reason")
    }
}

// MARK: - Describe

final class AutopilotsDescribeTests: XCTestCase {
    private func l10n(_ lang: String) -> L10n {
        let l = L10n()
        l.setLanguage(lang)
        return l
    }

    func testEnglish() {
        let l = l10n("en")
        let cases = [
            ("0 9 * * *", "At 09:00 · Every day"),
            ("30 18 * * 1-5", "At 18:30 · Mon–Fri"),
            ("0 9 * * 1,3,5", "At 09:00 · Mon, Wed, Fri"),
            ("15 * * * *", "Every hour at :15 · Every day"),
            ("0 */2 * * *", "Every 2 hours at :00 · Every day"),
            ("0 9-21/2 * * 2-4", "Every 2 hours · 09:00–21:00 · Tue–Thu"),
            ("30 9-21 * * *", "Every hour · 09:30–21:30 · Every day"),
            ("*/10 9-18 * * 1-5", "Every 10 minutes · 09:00–18:59 · Mon–Fri"),
            ("* * * * *", "Every minute · Every day"),
            ("30 10 15 * *", "At 10:30 · Day 15 of the month"),
        ]
        for (expr, expected) in cases {
            XCTAssertEqual(S.describe(S.parseCron(expr, timezone: "UTC"), l10n: l), expected, expr)
        }
        XCTAssertNil(S.describe(S.parseCron("0 9 1,15 * *", timezone: "UTC"), l10n: l))
        var raw = S.defaultConfig(timezone: "UTC")
        raw.raw = "@daily"
        XCTAssertNil(S.describe(raw, l10n: l))
        for expr in ["0 9-21/2 * * 2-4", "15 * * * *", "30 10 15 * *"] {
            XCTAssertFalse(S.describe(S.parseCron(expr, timezone: "UTC"), l10n: l)?.contains("{{") ?? true)
        }
    }

    func testChinese() {
        let l = l10n("zh-Hans")
        let cases = [
            ("0 9 * * *", "09:00 · 每天"),
            ("0 9-21/2 * * 2-4", "每 2 小时 · 09:00–21:00 · 周二至周四"),
            ("0 9 * * 1,3,5", "09:00 · 周一、周三、周五"),
            ("30 10 15 * *", "10:30 · 每月 15 日"),
        ]
        for (expr, expected) in cases {
            XCTAssertEqual(S.describe(S.parseCron(expr, timezone: "UTC"), l10n: l), expected, expr)
        }
    }

    func testCountdown() {
        let l = l10n("en")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(S.countdown(to: now.addingTimeInterval(30), now: now, l10n: l), "<1m")
        XCTAssertEqual(S.countdown(to: now.addingTimeInterval(5 * 60), now: now, l10n: l), "5m")
        XCTAssertEqual(S.countdown(to: now.addingTimeInterval(2 * 3600 + 7 * 60), now: now, l10n: l), "2h 7m")
        XCTAssertEqual(S.countdown(to: now.addingTimeInterval(86400 + 3600 + 60), now: now, l10n: l), "1d 1h 1m")
    }
}

// MARK: - Transitions

final class AutopilotsTransitionTests: XCTestCase {
    func testIsFullDay() {
        let cases = [("00:00", "23:59", true), ("00:30", "23:30", true), ("00:00", "23:00", true), ("09:00", "21:00", false),
                     ("00:00", "22:59", false), ("01:00", "23:59", false), ("22:00", "22:00", false), ("00:59", "23:00", true)]
        for (from, to, expected) in cases {
            XCTAssertEqual(S.isFullDay(S.Window(from: from, to: to)), expected, "\(from)–\(to)")
        }
    }

    func testDisplayWindow() {
        let w = S.Window(from: "09:00", to: "21:00")
        XCTAssertEqual(S.displayWindow(S.Every(window: w)), w)
        XCTAssertEqual(S.displayWindow(everyValue(1, .hours, minute: 30)), S.Window(from: "00:30", to: "23:30"))
        XCTAssertEqual(S.displayWindow(everyValue(1, .minutes, minute: 30)), S.Window(from: "00:00", to: "23:59"))
    }

    func testTimeAnchor() {
        XCTAssertEqual(S.timeAnchor(of: .at("14:30")), "14:30")
        XCTAssertEqual(S.timeAnchor(of: every(1, .minutes, window: ("14:00", "14:59"), minute: 30)), "14:30")
        XCTAssertEqual(S.timeAnchor(of: every(1, .hours, window: ("14:30", "21:30"), minute: 30)), "14:30")
        XCTAssertNil(S.timeAnchor(of: every(minute: 30)))
    }

    func testDefaultAtTime() {
        XCTAssertEqual(S.defaultAtTime(.at("14:30"), anchor: "09:00"), "14:30")
        XCTAssertEqual(S.defaultAtTime(every(minute: 30), anchor: "09:00"), "09:30")
        XCTAssertEqual(S.defaultAtTime(every(window: ("14:30", "21:30"), minute: 30), anchor: "09:00"), "14:30")
        XCTAssertEqual(S.defaultAtTime(every(minute: 45), anchor: "08:15"), "08:45")
        XCTAssertEqual(S.defaultAtTime(.at("00:00"), anchor: "08:15"), "00:00")
    }

    func testDefaultEveryTime() {
        let time = everyValue(3, window: ("09:00", "21:00"))
        XCTAssertEqual(S.defaultEveryTime(.every(time), anchor: nil), time)

        let restored = S.defaultEveryTime(.at("10:00"), anchor: everyValue(3, window: ("09:00", "21:00")))
        XCTAssertEqual(restored.interval, 3)
        XCTAssertEqual(restored.unit, .hours)
        XCTAssertEqual(restored.window, S.Window(from: "10:00", to: "21:00"))

        XCTAssertEqual(S.defaultEveryTime(.at("10:15"), anchor: nil), everyValue(1, .hours, minute: 15))

        for t in ["22:00", "15:00"] {
            let w = S.Window(from: "09:00", to: "15:00")
            XCTAssertEqual(S.defaultEveryTime(.at(t), anchor: S.Every(interval: 3, window: w)).window, w, t)
        }
        XCTAssertNil(S.defaultEveryTime(.at("00:00"), anchor: everyValue(3, window: ("09:00", "23:00"))).window)
    }

    func testClampWindow() {
        XCTAssertEqual(S.clampWindow(S.Window(from: "09:00", to: "21:00"), unit: .hours, minute: 30), S.Window(from: "09:30", to: "21:30"))
        XCTAssertEqual(S.clampWindow(S.Window(from: "09:30", to: "21:30"), unit: .minutes, minute: 30), S.Window(from: "09:00", to: "21:59"))
        XCTAssertEqual(S.clampWindow(S.Window(from: "09:30", to: "21:30"), unit: .hours, minute: 0), S.Window(from: "09:00", to: "21:00"))
        XCTAssertEqual(S.clampWindow(S.Window(from: "18:00", to: "12:00"), unit: .hours, minute: 0), S.Window(from: "18:00", to: "18:00"))
        XCTAssertEqual(S.clampWindow(S.Window(from: "09:00", to: "09:00"), unit: .hours, minute: 0), S.Window(from: "09:00", to: "09:00"))
        XCTAssertEqual(S.clampWindow(S.Window(from: "00:00", to: "23:00"), unit: .hours, minute: 0), S.Window(from: "00:00", to: "23:00"))
        let start = S.Window(from: "09:30", to: "21:30")
        XCTAssertEqual(S.clampWindow(S.clampWindow(start, unit: .minutes, minute: 30), unit: .hours, minute: 30), start)
    }

    func testToggleDay() {
        XCTAssertEqual(S.toggleDay([1, 5], 3), [1, 3, 5])
        XCTAssertEqual(S.toggleDay([3], 0), [0, 3])
        XCTAssertEqual(S.toggleDay([1, 3, 5], 3), [1, 5])
        XCTAssertEqual(S.toggleDay([3], 3), [3])
    }

    func testFixedTimeIntervalRoundTrip() {
        let cases: [(String, S.Every?)] = [("14:30", everyValue(3, window: ("09:00", "21:00"))), ("14:30", nil), ("00:15", nil)]
        for (time, anchor) in cases {
            let interval = S.defaultEveryTime(.at(time), anchor: anchor)
            XCTAssertEqual(S.defaultAtTime(.every(interval), anchor: time), time)
        }
    }
}

// MARK: - Validation

final class AutopilotsValidationTests: XCTestCase {
    private func run(status: Int, json: String) async -> S.Rejection? {
        let transport = FakeTransport()
        transport.on("GET", "/api/autopilots/cron-preview", status: status, json: json)
        let api = APIClient(config: .localDevelopment, transport: transport, token: "tok")
        return await S.findRejection(api: api, config: S.parseCron("0 9 * * *", timezone: "UTC"))
    }

    func testAccepted() async {
        let r = await run(status: 200, json: #"{"next_runs":["2126-07-14T01:00:00Z"]}"#)
        XCTAssertNil(r)
    }

    func testCronRejection() async {
        let r = await run(status: 400, json: #"{"error":"parse cron: expected exactly 5 fields","code":"invalid_cron"}"#)
        XCTAssertEqual(r, S.Rejection(code: .invalidCron, detail: "parse cron: expected exactly 5 fields"))
    }

    func testTimezoneRejection() async {
        let r = await run(status: 400, json: #"{"error":"invalid timezone \"X\"","code":"invalid_timezone"}"#)
        XCTAssertEqual(r?.code, .invalidTimezone)
    }

    func testNoCodeFallsBackToCron() async {
        let r = await run(status: 400, json: #""bad request""#)
        XCTAssertEqual(r?.code, .invalidCron)
    }

    func testTransportFailureDoesNotBlock() async {
        let r = await run(status: 502, json: #"{"error":"Bad Gateway"}"#)
        XCTAssertNil(r)
    }
}

// MARK: - Run now, webhooks, list

final class AutopilotsLogicTests: XCTestCase {
    func testRunNowToastKind() {
        XCTAssertEqual(AutopilotsRunNow.toastKind("issue_created"), .success)
        XCTAssertEqual(AutopilotsRunNow.toastKind("running"), .success)
        XCTAssertEqual(AutopilotsRunNow.toastKind("skipped"), .warning)
        XCTAssertEqual(AutopilotsRunNow.toastKind("failed"), .error)
        for s in ["blocked", "deferred", "", nil] as [String?] {
            XCTAssertEqual(AutopilotsRunNow.toastKind(s), .error)
        }
    }

    func testRunNowBlockedKey() {
        let cases = [
            ("invocation_not_allowed", "run_blocked_invocation_not_allowed"), ("runtime_offline", "run_blocked_runtime_offline"),
            ("target_unavailable", "run_blocked_target_unavailable"), ("attribution_blocked", "run_blocked_attribution"),
            ("already_active", "run_blocked_already_active"), ("quota_exceeded", "run_blocked_quota_exceeded"),
            ("issue_limit_reached", "run_blocked_issue_limit_reached"), ("runtime_access_denied", "run_blocked_runtime_access_denied"),
            ("agent_runtime_required", "run_blocked_agent_runtime_required"),
        ]
        for (code, key) in cases {
            XCTAssertEqual(AutopilotsRunNow.blockedKey(code), key)
            XCTAssertNotEqual(tr("autopilots", "detail.\(key)"), "detail.\(key)", key)
        }
        XCTAssertEqual(AutopilotsRunNow.blockedKey("some_future_code"), "run_blocked_generic")
        XCTAssertEqual(AutopilotsRunNow.blockedKey(nil), "run_blocked_generic")
    }

    func testClientErrorMessage() {
        XCTAssertEqual(AutopilotsRunNow.clientErrorMessage(APIError(status: 409, message: "autopilot is not active")), "autopilot is not active")
        XCTAssertNil(AutopilotsRunNow.clientErrorMessage(APIError(status: 500, message: "pgx: constraint")))
        struct Transport: Error {}
        XCTAssertNil(AutopilotsRunNow.clientErrorMessage(Transport()))
    }

    func testAPIErrorCarriesCodes() {
        let e = APIError.from(status: 400, body: Data(#"{"error":"nope","code":"invalid_timezone","reason_code":"quota_exceeded"}"#.utf8))
        XCTAssertEqual(e.message, "nope")
        XCTAssertEqual(e.code, "invalid_timezone")
        XCTAssertEqual(e.reasonCode, "quota_exceeded")
        let plain = APIError.from(status: 500, body: Data("oops".utf8))
        XCTAssertNil(plain.code)
        XCTAssertEqual(plain.message, "Request failed with status 500")
    }

    private let trigger = AutopilotTrigger(id: "t1", autopilotId: "a1", kind: "webhook", enabled: true,
                                           webhookToken: "awt_abc", webhookPath: "/api/webhooks/autopilots/awt_abc")

    func testWebhookURL() {
        var custom = trigger
        custom.webhookUrl = "https://custom.example/api/webhooks/autopilots/awt_abc"
        XCTAssertEqual(AutopilotsWebhook.url(for: custom, apiBaseURL: nil), "https://custom.example/api/webhooks/autopilots/awt_abc")
        XCTAssertEqual(AutopilotsWebhook.url(for: trigger, apiBaseURL: "https://api.example"), "https://api.example/api/webhooks/autopilots/awt_abc")
        XCTAssertEqual(AutopilotsWebhook.url(for: trigger, apiBaseURL: "https://api.example/"), "https://api.example/api/webhooks/autopilots/awt_abc")
        XCTAssertEqual(AutopilotsWebhook.url(for: trigger, apiBaseURL: "", currentOrigin: "https://app.example"), "https://app.example/api/webhooks/autopilots/awt_abc")
        var noPath = trigger
        noPath.webhookPath = nil
        XCTAssertEqual(AutopilotsWebhook.url(for: noPath, apiBaseURL: "https://api.example"), "https://api.example/api/webhooks/autopilots/awt_abc")
        var schedule = trigger
        schedule.kind = "schedule"
        schedule.webhookToken = nil
        schedule.webhookPath = nil
        XCTAssertNil(AutopilotsWebhook.url(for: schedule, apiBaseURL: nil))
        XCTAssertEqual(AutopilotsWebhook.url(for: trigger, apiBaseURL: nil), "/api/webhooks/autopilots/awt_abc")
    }

    func testWebhookMask() {
        let masked = AutopilotsWebhook.masked("https://api.example/api/webhooks/autopilots/awt_abc")
        XCTAssertEqual(masked, "https://api.example/api/webhooks/autopilots/••••••••••••")
        XCTAssertFalse(masked.contains("awt_abc"))
        XCTAssertEqual(AutopilotsWebhook.masked("/api/webhooks/autopilots/awt_abc"), "/api/webhooks/autopilots/••••••••••••")
        XCTAssertEqual(AutopilotsWebhook.masked("https://api.example/hooks/a"),
                       AutopilotsWebhook.masked("https://api.example/hooks/" + String(repeating: "z", count: 64)))
        XCTAssertEqual(AutopilotsWebhook.masked("awt_abc"), "••••••••••••")
        XCTAssertEqual(AutopilotsWebhook.masked("https://api.example/hooks/"), "••••••••••••")
    }

    func testEventFilters() {
        XCTAssertNil(AutopilotsWebhook.makeFilter(event: "  ", actions: "a"))
        XCTAssertEqual(AutopilotsWebhook.makeFilter(event: " workflow_run ", actions: "completed, failed,,"),
                       WebhookEventFilter(event: "workflow_run", actions: ["completed", "failed"]))
        XCTAssertEqual(AutopilotsWebhook.makeFilter(event: "push", actions: ""), WebhookEventFilter(event: "push", actions: nil))
        XCTAssertEqual(AutopilotsWebhook.serialize([WebhookEventFilter(event: "push", actions: nil)]),
                       AutopilotsWebhook.serialize([WebhookEventFilter(event: "push", actions: [])]))
    }

    func testReplayRules() {
        var d = WebhookDelivery(signatureStatus: "valid", status: "dispatched")
        XCTAssertTrue(AutopilotsWebhook.canReplay(d))
        XCTAssertNil(AutopilotsWebhook.replayHintKey(d))
        d.status = "queued"
        XCTAssertFalse(AutopilotsWebhook.canReplay(d))
        XCTAssertEqual(AutopilotsWebhook.replayHintKey(d), "disabled_queued")
        d.status = "rejected"
        XCTAssertEqual(AutopilotsWebhook.replayHintKey(d), "disabled_rejected")
        d.signatureStatus = "invalid"
        XCTAssertEqual(AutopilotsWebhook.replayHintKey(d), "disabled_invalid_signature")
    }

    func testPayloadEnvelope() {
        let env = AutopilotsWebhook.envelope(["event": "push", "eventPayload": ["ref": "main"],
                                              "request": ["receivedAt": "2026-01-01T00:00:00Z", "contentType": "application/json"]])
        XCTAssertEqual(env.event, "push")
        XCTAssertEqual(env.receivedAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(env.contentType, "application/json")
        XCTAssertTrue(env.fullJSON.contains("\"ref\" : \"main\""))
        XCTAssertFalse(env.isTruncated)

        let bare = AutopilotsWebhook.envelope(["hello": "world"])
        XCTAssertNil(bare.event)
        XCTAssertTrue(bare.fullJSON.contains("hello"))

        let big = AutopilotsWebhook.envelope(["eventPayload": .string(String(repeating: "x", count: 5000))])
        XCTAssertTrue(big.isTruncated)
        XCTAssertEqual(big.displayJSON.count, AutopilotsWebhook.displayLimit)
    }

    private func autopilot(_ id: String, title: String, status: String = "active", assignee: String = "a1",
                           mode: String = "create_issue", kinds: [String] = ["schedule"], creator: String = "u1",
                           lastRun: String? = nil, nextRun: String? = nil, created: String = "2026-01-01T00:00:00Z") -> Autopilot {
        Autopilot(id: id, title: title, assigneeType: "agent", assigneeId: assignee, status: status, executionMode: mode,
                  createdByType: "member", createdById: creator, lastRunAt: lastRun, createdAt: created,
                  triggerKinds: kinds, nextRunAt: nextRun)
    }

    func testScopesAndCounts() {
        let rows = [autopilot("1", title: "A"), autopilot("2", title: "B", status: "paused"), autopilot("3", title: "C", status: "archived")]
        XCTAssertEqual(AutopilotsList.scopeCounts(rows), [.all: 2, .active: 1, .paused: 1])
        XCTAssertEqual(AutopilotsList.scopeRows(rows, scope: .all).map(\.id), ["1", "2"])
        XCTAssertEqual(AutopilotsList.scopeRows(rows, scope: .paused).map(\.id), ["2"])
    }

    func testFiltersAndSort() {
        let rows = [
            autopilot("1", title: "Beta", assignee: "a1", kinds: ["webhook"], lastRun: "2026-01-03T00:00:00Z", nextRun: "2026-02-01T00:00:00Z"),
            autopilot("2", title: "Alpha", assignee: "a2", mode: "run_only", lastRun: nil, nextRun: nil),
            autopilot("3", title: "Gamma", assignee: "a1", creator: "u2", lastRun: "2026-01-05T00:00:00Z", nextRun: "2026-01-15T00:00:00Z",
                      created: "2026-01-02T00:00:00Z"),
        ]
        var state = AutopilotsListState()
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["3", "1", "2"])
        state.toggleSort(.lastRun)
        XCTAssertEqual(state.sortDirection, .asc)
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["2", "1", "3"])
        state.toggleSort(.nextRun)
        XCTAssertEqual(state.sortDirection, .asc)
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["3", "1", "2"])
        state.sortDirection = .desc
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["1", "3", "2"])
        state.setSortField(.name)
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["2", "1", "3"])
        state.setSortField(.created)
        XCTAssertEqual(state.sortDirection, .desc)
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).first?.id, "3")

        state.toggleFilter(.assignees, "agent:a1")
        XCTAssertEqual(Set(AutopilotsList.visibleRows(rows, state: state).map(\.id)), ["1", "3"])
        state.toggleFilter(.triggerKinds, "webhook")
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["1"])
        XCTAssertEqual(state.filters.activeDimensions, 2)
        state.toggleFilter(.triggerKinds, "webhook")
        state.toggleFilter(.creators, "member:u2")
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["3"])
        state.clearFilters()
        state.toggleFilter(.modes, "run_only")
        XCTAssertEqual(AutopilotsList.visibleRows(rows, state: state).map(\.id), ["2"])

        let o = AutopilotsList.options(rows)
        XCTAssertEqual(o.assignees.map(\.value), ["agent:a1", "agent:a2"])
        XCTAssertEqual(o.assignees.first?.count, 2)
        XCTAssertEqual(o.modeCounts, ["create_issue": 2, "run_only": 1])
        XCTAssertEqual(o.triggerKindCounts, ["webhook": 1, "schedule": 2])
    }

    func testColumnsAndPersistence() throws {
        var state = AutopilotsListState()
        XCTAssertFalse(state.isVisible(.mode))
        state.toggleColumn(.mode)
        state.toggleColumn(.assignee)
        XCTAssertTrue(state.isVisible(.mode))
        XCTAssertFalse(state.isVisible(.assignee))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(AutopilotsListState.self, from: data), state)

        let legacy = Data(#"{"scope":"archived","sortField":"name","filters":{"assignees":["agent:x"]}}"#.utf8)
        let decoded = try JSONDecoder().decode(AutopilotsListState.self, from: legacy)
        XCTAssertEqual(decoded.scope, .all)
        XCTAssertEqual(decoded.sortField, .name)
        XCTAssertEqual(decoded.sortDirection, .asc)
        XCTAssertEqual(decoded.filters.assignees, ["agent:x"])
        XCTAssertEqual(decoded.filters.modes, [])
        XCTAssertEqual(decoded.hiddenColumns, AutopilotsListState.defaultHiddenColumns)
    }

    func testRunSplit() {
        let runs = [AutopilotRun(id: "1", status: "completed"), AutopilotRun(id: "2", status: "skipped"), AutopilotRun(id: "3", status: "failed")]
        let s = AutopilotsRuns.split(runs)
        XCTAssertEqual(s.visible.map(\.id), ["1", "3"])
        XCTAssertEqual(s.skipped.map(\.id), ["2"])
        XCTAssertEqual(AutopilotsRuns.taskStatus(for: "issue_created"), .queued)
        XCTAssertEqual(AutopilotsRuns.taskStatus(for: "running"), .running)
    }
}
