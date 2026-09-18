import XCTest

@testable import WeiModel

/// The middle column: what it lists, and how it heads what it lists.
///
/// The clock and the calendar are parameters rather than "now", which is the whole reason these rules are
/// testable: "what does the list look like on the 3rd of the month" is a question with an answer, and
/// `Date()` is not.
final class SessionSectionsTests: XCTestCase {
    /// A fixed calendar, so a month name is a string rather than a locale's opinion.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// 2026-07-03 12:00 UTC.
    private var now: Date = Date(timeIntervalSince1970: 1_783_080_000)

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> SessionRow {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        let date = calendar.date(from: components)!
        return row(Date(timeIntervalSince1970: date.timeIntervalSince1970), "session \(year)-\(month)-\(day)")
    }

    private func row(_ date: Date, _ label: String, modifiedOverride: Int64? = nil) -> SessionRow {
        SessionRow(
            path: "/store/\(label).jsonl",
            shortID: label,
            label: label,
            modified: modifiedOverride ?? Int64(date.timeIntervalSince1970 * 1000),
            current: false,
            running: false
        )
    }

    private func group(_ cwd: String, _ label: String, _ rows: [SessionRow]) -> SessionGroup {
        SessionGroup(cwd: cwd, label: label, current: false, sessions: rows)
    }

    /// The everyday view: this afternoon, yesterday, the week, the month, and then by month — descending.
    func testSessionsAreBucketedByRecency() {
        let sections = timeSections(
            rows: [
                at(2026, 7, 3),  // today
                at(2026, 7, 3, 9),
                at(2026, 7, 2),  // yesterday, one calendar day back
                at(2026, 6, 30),  // six days back: inside the week
                at(2026, 6, 20),  // inside 30 days, outside 7
                at(2026, 6, 4),
                at(2026, 5, 30),  // outside it: its own month
                at(2026, 5, 2),
                at(2025, 11, 9),  // and an older year
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(
            sections.map(\.title),
            ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "May", "November 2025"]
        )
        XCTAssertEqual(sections.map(\.rows.count), [2, 1, 1, 2, 2, 1])
    }

    /// The four boundaries themselves, because "previous 7 days" is exactly the kind of rule that is off
    /// by one: the day itself is *in* and the day after it out, every boundary sits on the start of a
    /// calendar day rather than on a rolling 24 hours, and midnight this morning is still Today.
    func testTheBoundariesAreInclusive() {
        let start = calendar.startOfDay(for: now)
        let midnight = start
        let yesterday = calendar.date(byAdding: .day, value: -1, to: start)!
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: start)!
        let eightDaysAgo = calendar.date(byAdding: .day, value: -8, to: start)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: start)!
        let thirtyOneDaysAgo = calendar.date(byAdding: .day, value: -31, to: start)!

        let sections = timeSections(
            rows: [
                row(midnight, "midnight"),
                row(yesterday, "yesterday"),
                row(sevenDaysAgo, "seven"),
                row(eightDaysAgo, "eight"),
                row(thirtyDaysAgo, "thirty"),
                row(thirtyOneDaysAgo, "thirty-one"),
            ],
            now: now,
            calendar: calendar
        )
        // The order the rows arrive in is the order they are kept in, and the headings are what place them:
        // midnight is Today, one day back is Yesterday, seven days back is still the week while eight is out,
        // and 30 days back is still the month while 31 is a month name.
        XCTAssertEqual(
            sections.map(\.title),
            ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "June"]
        )
        XCTAssertEqual(sections[0].rows.map(\.label), ["midnight"])
        XCTAssertEqual(sections[1].rows.map(\.label), ["yesterday"])
        XCTAssertEqual(sections[2].rows.map(\.label), ["seven"])
        // Two rows in one bucket, in arrival order: eight days back and thirty days back share a heading
        // because there is nothing between them — the week is the *last* seven days, not a sliding one.
        XCTAssertEqual(sections[3].rows.map(\.label), ["eight", "thirty"])
        XCTAssertEqual(sections[4].rows.map(\.label), ["thirty-one"])
    }

    /// Rows arrive newest first and the sections keep that order without a sort — including when one row
    /// is out of order, which joins its own month rather than starting a second section with the same
    /// title.
    func testOutOfOrderRowsJoinTheBucketTheyBelongTo() {
        let sections = timeSections(
            rows: [at(2026, 7, 3), at(2026, 5, 30), at(2026, 5, 2), at(2026, 6, 1)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.title), ["Today", "May", "June"])
        XCTAssertEqual(sections[1].rows.count, 2)
        XCTAssertEqual(sections[1].rows.map(\.label), ["session 2026-5-30", "session 2026-5-2"])
    }

    /// An empty list is no sections at all, not one empty section: the view draws "no sessions" from an
    /// empty list, and an empty heading would be a heading for nothing.
    func testNoSessionsIsNoSections() {
        XCTAssertTrue(timeSections(rows: [], now: now, calendar: calendar).isEmpty)
    }

    /// Nothing typed: the workspace being browsed, by time. Its sibling is not listed.
    func testBrowsingShowsOneWorkspace() {
        let sections = sessionSections(
            groups: [
                group("/src/pi", "pi", [at(2026, 7, 3)]),
                group("/src/other", "other", [at(2026, 7, 2)]),
            ],
            browsing: "/src/pi",
            query: "",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.title), ["Today"])
        XCTAssertEqual(sections[0].rows.map(\.label), ["session 2026-7-3"])
    }

    /// A workspace that is not in the list — just deleted, or never sent — is no sections rather than a
    /// crash, which is what the reader sees as "no sessions" for a moment.
    func testBrowsingAWorkspaceThatIsNotThereIsEmpty() {
        let sections = sessionSections(
            groups: [group("/src/pi", "pi", [at(2026, 7, 3)])],
            browsing: "/src/gone",
            query: "",
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(sections.isEmpty)
    }

    /// Searching reaches every workspace, and the heading becomes the project — because a result has to
    /// say where it came from.
    ///
    /// The two rules are both visible here: `/src/upstream` matches the query as a *path*, so all of its sessions
    /// are kept; `/work/other` does not, so only the session whose name matches survives, and the project
    /// with nothing matching is not listed.
    func testSearchingCrossesWorkspacesAndHeadsByProject() {
        let sections = sessionSections(
            groups: [
                group("/src/pi", "pi", [at(2026, 7, 3), row(now, "unrelated")]),
                group("/work/other", "other", [row(now, "pi follow-up"), row(now, "nothing to do with it")]),
                group("/work/quiet", "quiet", [row(now, "elsewhere")]),
            ],
            browsing: "/src/pi",
            query: "pi",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.title), ["pi", "other"])
        XCTAssertEqual(sections[0].rows.map(\.label), ["session 2026-7-3", "unrelated"])
        XCTAssertEqual(sections[1].rows.map(\.label), ["pi follow-up"])
    }

    /// A project's *name* is not a reason to keep all of its sessions. The distinction matters because the
    /// two rules look alike and behave nothing alike: typing a project's name should find the conversations
    /// about it, not dump the project.
    func testMatchingAProjectNameDoesNotKeepEverything() {
        let sections = sessionSections(
            groups: [group("/work/different", "pi", [row(now, "pi work"), row(now, "unrelated")])],
            browsing: "/work/different",
            query: "pi",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.title), ["pi"])
        XCTAssertEqual(sections[0].rows.map(\.label), ["pi work"])
    }

    /// A directory that matches keeps all of its sessions: typing a path asks for that project, not for
    /// the sessions whose names happen to contain the same letters.
    func testAPathMatchKeepsTheWholeProject() {
        let sections = sessionSections(
            groups: [
                group("/src/pi", "pi", [row(now, "first"), row(now, "second")]),
            ],
            browsing: "/src/pi",
            query: "/src/pi",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].rows.count, 2)
    }

    /// Case does not matter, and whitespace is not a query: a search field holding a space is an empty
    /// field, not a search for everything with a space in it.
    func testSearchIgnoresCaseAndSurroundingSpace() {
        let groups = [group("/src/pi", "pi", [row(now, "Fix the Parser")])]
        let hits = sessionSections(
            groups: groups, browsing: "/src/pi", query: "  parser ", now: now, calendar: calendar
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].rows.count, 1)

        let whitespaceOnly = sessionSections(
            groups: groups, browsing: "/src/pi", query: "   ", now: now, calendar: calendar
        )
        // Falls back to the everyday view rather than matching everything: the workspace's own rows.
        XCTAssertEqual(whitespaceOnly.map(\.title), ["Today"])
    }

    /// One identity per section, and it is not the title — two projects called `upstream` are two sections.
    func testSectionsHaveDistinctIdentities() {
        let sections = sessionSections(
            groups: [
                group("/one/pi", "pi", [row(now, "a")]),
                group("/two/pi", "pi", [row(now, "a")]),
            ],
            browsing: "/one/pi",
            query: "a",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.title), ["pi", "pi"])
        XCTAssertEqual(Set(sections.map(\.id)).count, 2)
    }
}

/// The second line of a session row.
///
/// Same clock injection as the sections above, and for the same reason: "what does a row from this
/// afternoon say" has an answer, and a test that asked `Date()` would have a different one every day.
final class SessionAgeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// 2026-07-03 15:30 UTC.
    private var now: Date = Date(timeIntervalSince1970: 1_783_092_600)

    /// Whatever ICU put between the time and the meridiem, as an ordinary space.
    ///
    /// It is a **narrow no-break space** (U+202F) on this macOS, and it is not the space on a keyboard —
    /// writing the literal would make this test pass on one ICU version and fail on another, which is a
    /// test of the locale data rather than of the rule being asserted. The rule is "today is a time, other
    /// days are dates".
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        return Int64(calendar.date(from: components)!.timeIntervalSince1970 * 1000)
    }

    /// Today is a time: the heading above it already said "today", and the reader wants to know when.
    func testTodayIsTheTimeOfDay() {
        XCTAssertEqual(
            plain(sessionAgeText(modified: at(2026, 7, 3, 9, 5), now: now, calendar: calendar)),
            "9:05 AM"
        )
        XCTAssertEqual(
            plain(sessionAgeText(modified: at(2026, 7, 3, 0, 1), now: now, calendar: calendar)),
            "12:01 AM"
        )
    }

    /// Any other day this year is a date without the year, which the heading has already given.
    func testAnotherDayThisYearIsADate() {
        XCTAssertEqual(
            sessionAgeText(modified: at(2026, 1, 2, 8, 0), now: now, calendar: calendar),
            "Jan 2"
        )
        // Yesterday is not special-cased: "Jul 2" is shorter than "Yesterday" and says the same thing in a
        // list where every row has a date.
        XCTAssertEqual(
            sessionAgeText(modified: at(2026, 7, 2, 23, 59), now: now, calendar: calendar),
            "Jul 2"
        )
    }

    /// An older year carries it, because "Jul 2" in a list that reaches back further is a date with two
    /// possible meanings.
    func testAnOlderYearCarriesIt() {
        XCTAssertEqual(
            sessionAgeText(modified: at(2025, 7, 2, 12, 0), now: now, calendar: calendar),
            "Jul 2, 2025"
        )
    }

    /// The boundary is the calendar's day, not 24 hours: something at 00:05 this morning is today's even
    /// though it was more than fifteen hours ago by the clock, and the heading above it says so too.
    func testTheDayBoundaryIsTheCalendars() {
        let yesterdayLate = at(2026, 7, 2, 23, 55)
        let todayEarly = at(2026, 7, 3, 0, 5)
        XCTAssertEqual(plain(sessionAgeText(modified: todayEarly, now: now, calendar: calendar)), "12:05 AM")
        XCTAssertEqual(sessionAgeText(modified: yesterdayLate, now: now, calendar: calendar), "Jul 2")
    }

    /// A locale that writes dates the other way round gets its own order: the template is the locale's, not
    /// this file's.
    func testTheDateFormatFollowsTheLocale() {
        var chinese = calendar
        chinese.locale = Locale(identifier: "zh_CN")
        XCTAssertEqual(sessionAgeText(modified: at(2026, 1, 2, 8, 0), now: now, calendar: chinese), "1月2日")
        XCTAssertEqual(
            sessionAgeText(modified: at(2025, 7, 2, 12, 0), now: now, calendar: chinese),
            "2025年7月2日"
        )
    }
}
