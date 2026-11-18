import Foundation

/// Every date key is `yyyy-MM-dd` in one time zone - the device's, unless a
/// test says otherwise. The port of Android's `DateKeys`: everything that
/// needs a wall-clock day goes through here, so a zone change is handled in
/// one place.
struct DayClock {
    let timeZone: TimeZone
    let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    static let minuteMs: Int64 = 60_000
    static let hourMs: Int64 = 3_600_000

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    // ---- keys --------------------------------------------------------------

    func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func key(ms: Int64) -> String { key(DayClock.date(ms)) }

    func today(now: Date = Date()) -> String { key(now) }

    /// The key's day at its first instant, or nil for a malformed key.
    func startOfDay(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        c.hour = 12
        guard let noon = calendar.date(from: c), self.key(noon) == key else { return nil }
        return calendar.startOfDay(for: noon)
    }

    func isValid(_ key: String) -> Bool { startOfDay(key) != nil }

    func startOfDayMs(_ key: String) -> Int64 {
        startOfDay(key).map(DayClock.ms) ?? 0
    }

    /// The first instant of the next day - the day's exclusive end.
    func endOfDayExclusiveMs(_ key: String) -> Int64 {
        startOfDayMs(adding(1, to: key))
    }

    /// The day's last millisecond, as Android's `endOfDayMillis`.
    func endOfDayMs(_ key: String) -> Int64 { endOfDayExclusiveMs(key) - 1 }

    func adding(_ days: Int, to key: String) -> String {
        guard let start = startOfDay(key) else { return key }
        let noon = start.addingTimeInterval(12 * 3600)
        guard let moved = calendar.date(byAdding: .day, value: days, to: noon) else { return key }
        return self.key(moved)
    }

    func minusDays(_ key: String, _ days: Int) -> String { adding(-days, to: key) }

    /// Every key from start to end, inclusive, ascending.
    func range(_ start: String, _ end: String) -> [String] {
        guard start <= end, isValid(start), isValid(end) else { return [] }
        var out: [String] = []
        var cursor = start
        while cursor <= end {
            out.append(cursor)
            cursor = adding(1, to: cursor)
            if out.count > 40_000 { break }
        }
        return out
    }

    func daysBetween(_ start: String, _ end: String) -> Int {
        guard let a = startOfDay(start), let b = startOfDay(end) else { return 0 }
        let days = calendar.dateComponents([.day], from: a.addingTimeInterval(43_200), to: b.addingTimeInterval(43_200)).day ?? 0
        return days + 1
    }

    // ---- windows -------------------------------------------------------------

    /// Monday-anchored week; `offset` 1 is last week.
    func calendarWeek(offset: Int = 0, now: Date = Date()) -> (String, String) {
        let base = adding(-7 * offset, to: today(now: now))
        guard let start = startOfDay(base) else { return (base, base) }
        let weekday = calendar.component(.weekday, from: start.addingTimeInterval(43_200))
        let sinceMonday = (weekday + 5) % 7
        let monday = adding(-sinceMonday, to: base)
        return (monday, adding(6, to: monday))
    }

    func calendarMonth(offset: Int = 0, now: Date = Date()) -> (String, String) {
        let c = calendar.dateComponents([.year, .month], from: now)
        var month = (c.year ?? 1970) * 12 + ((c.month ?? 1) - 1) - offset
        let year = month / 12
        month = month % 12 + 1
        let first = String(format: "%04d-%02d-01", year, month)
        let next = month == 12 ? String(format: "%04d-01-01", year + 1) : String(format: "%04d-%02d-01", year, month + 1)
        return (first, adding(-1, to: next))
    }

    func calendarYear(offset: Int = 0, now: Date = Date()) -> (String, String) {
        let year = (calendar.component(.year, from: now)) - offset
        return (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
    }

    /// The last `days` days ending today, inclusive.
    func rolling(_ days: Int, now: Date = Date()) -> (String, String) {
        let end = today(now: now)
        return (adding(-(days - 1), to: end), end)
    }

    // ---- instants -------------------------------------------------------------

    func hour(ofMs ms: Int64) -> Int { calendar.component(.hour, from: DayClock.date(ms)) }

    /// Seconds east of UTC at that instant.
    func offsetSeconds(atMs ms: Int64) -> Int { timeZone.secondsFromGMT(for: DayClock.date(ms)) }

    static func minuteOf(_ ms: Int64) -> Int64 {
        let q = ms / minuteMs
        return (ms % minuteMs < 0 ? q - 1 : q) * minuteMs
    }

    /// The start of the clock hour [ms] falls in, in this zone.
    func hourStart(ofMs ms: Int64) -> Int64 {
        let date = DayClock.date(ms)
        let interval = calendar.dateInterval(of: .hour, for: date)
        return interval.map { DayClock.ms($0.start) } ?? (ms - ms % DayClock.hourMs)
    }
}
