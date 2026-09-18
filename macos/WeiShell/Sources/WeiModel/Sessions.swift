import Foundation

/// When a session was last used, at the grain a row can carry.
///
/// The section heading above the row already says *which* day-bucket it is in, so this is the finer
/// reading of the same fact: the time of day for today, a date for the rest. A per-row "3 hours ago" would
/// be a column of figures to read rather than a list to scan — and it is also a string that goes stale
/// while the window stands still, which is the one thing a value computed at draw time cannot be.
///
/// The clock and the calendar are parameters for the reason the section rules take them: "what does this
/// row say on the 3rd of the month" is a question with an answer, and `Date()` is not.
public func sessionAgeText(modified: Int64, now: Date, calendar: Calendar) -> String {
    let date = Date(timeIntervalSince1970: Double(modified) / 1000)
    if calendar.isDate(date, inSameDayAs: now) {
        return formatter(calendar: calendar, template: "jm").string(from: date)
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return formatter(calendar: calendar, template: "MMMd").string(from: date)
    }
    return formatter(calendar: calendar, template: "yMMMd").string(from: date)
}

/// One `DateFormatter` for one pattern, built from a template so the order and the separators are the
/// locale's rather than this file's.
///
/// **Cached, and the cache is why the window stopped stuttering.** `DateFormatter()` is expensive — measured:
/// about 0.13 ms each on this machine, and this function was called *per row, per redraw*, with a table view
/// asking a hundred times a second while the reader dragged a column divider. Dragging the sidebar is a
/// resize of the whole split, so every row redraws on every frame: thirty rows × one formatter each was
/// ~4 ms of formatting per frame, which is a quarter of a 60 Hz budget spent before anything is drawn.
///
/// Keyed by the calendar's identifier and locale rather than by the `Calendar` itself, because `Calendar` is
/// a value with no stable identity and the ones that matter here are the current one and the Chinese one a
/// test uses. Two calendars that format the same way share an entry, which is the point.
private let formatterCache = FormatterCache()

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: DateFormatter] = [:]

    func formatter(calendar: Calendar, template: String) -> DateFormatter {
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "")|\(template)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key] { return existing }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        entries[key] = formatter
        return formatter
    }
}

private func formatter(calendar: Calendar, template: String) -> DateFormatter {
    formatterCache.formatter(calendar: calendar, template: template)
}

/// One headed block of the session list: a time bucket, or a project.
///
/// Deliberately not called `Section`: that name is `SwiftUI`'s, and shadowing it in a file that draws
/// lists is how "every `Section("…")` stopped being a view" happened here once already. See
/// `docs/macos-pitfalls.md`.
public struct SessionSection: Identifiable, Equatable {
    /// Stable, and never the title: two projects can be called `upstream`, and two sections sharing one
    /// identity would be one section as far as `ForEach` is concerned — the failure `row_id` exists to
    /// prevent, one layer up.
    public let id: String
    public let title: String
    public let rows: [SessionRow]

    public init(id: String, title: String, rows: [SessionRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// What the middle column shows, and how it is headed.
///
/// Two modes, and the mode is decided by the search field rather than by a control of its own:
///
/// - **Nothing typed**: the sessions of the workspace being browsed, headed by *when* they were last
///   used. The everyday view, and time is the right axis for it — a project's conversations are otherwise
///   an undifferentiated wall of first lines.
/// - **Something typed**: matches from *every* workspace, headed by the project they belong to. The header
///   changes because the question changed: a result has to say where it came from, or finding a session in
///   another project leaves you opening rows you cannot place.
///
/// The rules are here rather than in the view for the reason `WeiModel` is apart from the runtime: this is
/// arithmetic on values, and it is the part that can be wrong in a way a test can see.
public func sessionSections(
    groups: [SessionGroup],
    browsing: String,
    query: String,
    now: Date,
    calendar: Calendar
) -> [SessionSection] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard trimmed.isEmpty else {
        return searchSections(groups: groups, query: trimmed)
    }
    guard let group = groups.first(where: { $0.cwd == browsing }) else { return [] }
    return timeSections(rows: group.sessions, now: now, calendar: calendar)
}

/// The everyday view: one project's sessions, bucketed by recency.
///
/// Five buckets, fine where a list is long and coarse where it is short: **Today / Yesterday / Previous
/// 7 Days / Previous 30 Days**, then a month at a time. The first four are Notes' grain, and the reason a
/// list of documents needs any bucketing at all is the same here — a session used this afternoon and one
/// used in June do not belong under one heading.
///
/// **Why the two extra buckets.** The old rule was Today / Previous 30 Days / a month, and the middle
/// bucket was doing the work of three: a project worked in daily showed "Previous 30 Days" over thirty
/// rows, so the heading said nothing about the part of the list a reader is in most of the time. Splitting
/// it puts yesterday and the last week back in reach — the sessions anyone actually returns to — while the
/// month floor stays coarse, because a per-row "3 hours ago" is a column of figures to read rather than a
/// list to scan. Finer than a week is not worth a heading: "Previous 2 Days" over two rows is a rule the
/// reader has to work out, and a heading has to be cheaper to read than the rows under it.
///
/// All four boundaries are **closed at the start of the calendar day**, not a rolling 24 hours — see the
/// tests, because "previous 7 days" is exactly the kind of rule that is off by one.
public func timeSections(
    rows: [SessionRow],
    now: Date,
    calendar: Calendar
) -> [SessionSection] {
    guard !rows.isEmpty else { return [] }
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
    let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today
    // Two formatters rather than one per row: a month heading is the same string for every session in that
    // month, and `DateFormatter` is the expensive part of this.
    let monthOnly = monthFormatter(calendar: calendar, withYear: false)
    let monthAndYear = monthFormatter(calendar: calendar, withYear: true)

    // Collected in the order they are *met*. The rows arrive newest first, so the sections come out
    // descending without sorting them; a row whose timestamp is out of order joins the bucket it belongs
    // to rather than starting a second one with the same title.
    var order: [String] = []
    var titles: [String: String] = [:]
    var contents: [String: [SessionRow]] = [:]
    for row in rows {
        let date = Date(timeIntervalSince1970: Double(row.modified) / 1000)
        let id: String
        var title = ""
        if date >= today {
            id = "today"
            title = "Today"
        } else if date >= yesterday {
            id = "yesterday"
            title = "Yesterday"
        } else if date >= sevenDaysAgo {
            id = "week"
            title = "Previous 7 Days"
        } else if date >= thirtyDaysAgo {
            id = "recent"
            title = "Previous 30 Days"
        } else {
            let year = calendar.component(.year, from: date)
            let month = calendar.component(.month, from: date)
            id = "month-\(year)-\(month)"
            let sameYear = year == calendar.component(.year, from: today)
            title = (sameYear ? monthOnly : monthAndYear).string(from: date)
        }
        if titles[id] == nil {
            order.append(id)
            titles[id] = title
        }
        contents[id, default: []].append(row)
    }
    return order.map {
        SessionSection(id: $0, title: titles[$0] ?? "", rows: contents[$0] ?? [])
    }
}

/// A month's name, standalone ("June" rather than "June 2026"), with the year for months that are not
/// this year's — "June" alone in a list reaching back two years is a heading with two meanings.
private func monthFormatter(calendar: Calendar, withYear: Bool) -> DateFormatter {
    // Through the same cache as the rows, for the same reason: a heading is drawn as often as a row.
    formatter(calendar: calendar, template: withYear ? "LLLL yyyy" : "LLLL")
}

/// The search view: matches from every workspace, headed by project.
///
/// Two rules, and which one applies is about what was typed:
///
/// - A **directory** that matches keeps all of that project's sessions. A reader who types a path is
///   asking for the project, not for the sessions whose names happen to contain the same letters — which
///   is also how someone who half-remembers a project finds everything in it.
/// - Otherwise the *sessions* are filtered, and a project with no matching session is not listed at all.
///
/// Deliberately not "the project's label keeps everything": that reads as a convenience and behaves as a
/// surprise — typing a project's name would dump every conversation in it whether or not any of them had
/// anything to do with the search. The path rule covers the real case, because a project's name is
/// normally a piece of its path.
private func searchSections(groups: [SessionGroup], query: String) -> [SessionSection] {
    var out: [SessionSection] = []
    for group in groups {
        let hits: [SessionRow]
        if group.cwd.localizedCaseInsensitiveContains(query) {
            hits = group.sessions
        } else {
            hits = group.sessions.filter { $0.label.localizedCaseInsensitiveContains(query) }
        }
        guard !hits.isEmpty else { continue }
        out.append(SessionSection(id: "cwd:\(group.cwd)", title: group.label, rows: hits))
    }
    return out
}
