import XCTest
@testable import StepTrackerProCore

/// The pedometer's settled hours, kept between processes: a background wake
/// in a new process must count the same day as the process before it, and
/// ask the pedometer only for the hours still moving.
final class HourCacheTests: XCTestCase {
    let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let day = "2026-09-14"
    let m: Int64 = 60_000
    let h: Int64 = 3_600_000
    let boot: Int64 = 1_789_000_000_000
    var t0: Int64 { clock.startOfDayMs(day) }

    /// A pedometer holding [walks] - (start minute, minutes, steps a minute) -
    /// that counts every interval it is asked for.
    final class Pedometer {
        let t0: Int64
        let walks: [(Int, Int, Int)]
        var asked = 0

        init(t0: Int64, walks: [(Int, Int, Int)]) {
            self.t0 = t0
            self.walks = walks
        }

        func steps(_ intervals: [(Int64, Int64)]) -> [Int?] {
            asked += intervals.count
            return intervals.map { from, to in
                walks.reduce(0) { sum, w in
                    let start = t0 + Int64(w.0) * 60_000
                    let end = start + Int64(w.1) * 60_000
                    let overlap = max(0, min(end, to) - max(start, from))
                    return sum + Int(Int64(w.2) * overlap / 60_000)
                }
            }
        }
    }

    /// A day of walks: 07:12, 09:30, 12:40, 14:10 and 17:05.
    var walks: [(Int, Int, Int)] {
        [(7 * 60 + 12, 34, 104), (9 * 60 + 30, 20, 118), (12 * 60 + 40, 18, 96), (14 * 60 + 10, 25, 101), (17 * 60 + 5, 50, 112)]
    }

    func count(_ cache: inout HourCache, _ pedometer: Pedometer, at now: Int64, from: Int64? = nil) -> [WindowCount]? {
        let window = (from ?? t0, now)
        let totals = pedometer.steps([window]).map { $0 ?? 0 }
        return cache.count(windows: [window], totals: totals, clock: clock, now: now,
                           keepAfter: clock.startOfDayMs(clock.minusDays(day, 1)), query: pedometer.steps)
    }

    func build(_ counts: [WindowCount]?) -> DayCount? {
        counts.map { DayCounting.build(windows: $0, activity: [:], charging: [], activityTags: true) }
    }

    func testAWakeInANewProcessAsksOnlyForTheHoursStillMoving() {
        let now = t0 + 18 * h + 30 * m
        // The last process counted the day at 18:00 and kept what had settled.
        var first = HourCache(bootTimeMs: boot)
        XCTAssertNotNil(count(&first, Pedometer(t0: t0, walks: walks), at: t0 + 18 * h))
        // A wake at 18:30 in a new process, with nothing but the file.
        var stored = HourCache.decoded(first.encoded())!
        let warm = Pedometer(t0: t0, walks: walks)
        let fromFile = count(&stored, warm, at: now)
        // The same wake without the file: every hour since midnight, and
        // sixty minutes of each hour with steps.
        var empty = HourCache(bootTimeMs: boot)
        let cold = Pedometer(t0: t0, walks: walks)
        let fromScratch = count(&empty, cold, at: now)

        XCTAssertEqual(build(fromFile), build(fromScratch), "the same day, minute for minute")
        XCTAssertEqual(build(fromFile)?.deviceSteps, 34 * 104 + 20 * 118 + 18 * 96 + 25 * 101 + 50 * 112)
        // Settled by 18:30: every hour ending by 16:30. Still moving: 16-17,
        // 17-18 (the evening walk) and 18-18:30.
        XCTAssertEqual(warm.asked, 1 + 3 + 60, "the window, three hours, the minutes of the one with steps")
        XCTAssertEqual(cold.asked, 1 + 19 + 5 * 60, "the window, nineteen hours, the minutes of all five walks")
    }

    func testAKeptHourReadsBackExactly() {
        var cache = HourCache(bootTimeMs: boot)
        // A window starting inside an hour, and an hour with no steps at all.
        let counts = count(&cache, Pedometer(t0: t0, walks: walks), at: t0 + 20 * h, from: t0 + 7 * h + 20 * m)!
        let read = HourCache.decoded(cache.encoded())!
        XCTAssertEqual(read.bootTimeMs, boot)
        XCTAssertEqual(read.count, cache.count)
        for hour in counts[0].hours where HourCache.isSettled(endMs: hour.endMs, now: t0 + 20 * h) {
            XCTAssertEqual(read.hour(from: hour.startMs, to: hour.endMs), hour)
        }
        XCTAssertEqual(read.hour(from: t0 + 7 * h + 20 * m, to: t0 + 8 * h)?.minutes.count, 40)
        XCTAssertEqual(read.hour(from: t0 + 10 * h, to: t0 + 11 * h)?.minutes, [])
    }

    func testHoursStillMovingAreNeverKept() {
        var cache = HourCache(bootTimeMs: boot)
        let now = t0 + 17 * h + 30 * m
        XCTAssertNotNil(count(&cache, Pedometer(t0: t0, walks: walks), at: now))
        XCTAssertNotNil(cache.hour(from: t0 + 14 * h, to: t0 + 15 * h))
        XCTAssertNil(cache.hour(from: t0 + 15 * h, to: t0 + 16 * h), "ends 1.5 hours before now")
        XCTAssertNil(cache.hour(from: t0 + 17 * h, to: now))
    }

    func testOnlyTodayAndYesterdayAreKept() {
        var cache = HourCache(bootTimeMs: boot)
        let pedometer = Pedometer(t0: t0, walks: walks)
        // keepAfter is yesterday's start: a day counted from three days back keeps nothing.
        let old = clock.startOfDayMs(clock.minusDays(day, 3))
        _ = cache.count(windows: [(old, old + 24 * h)], totals: [0], clock: clock, now: t0 + 12 * h,
                        keepAfter: clock.startOfDayMs(clock.minusDays(day, 1)), query: pedometer.steps)
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.unsaved)

        XCTAssertNotNil(count(&cache, pedometer, at: t0 + 12 * h))
        XCTAssertEqual(cache.count, 10)
        // Past midnight, yesterday's hours stay until the day after.
        cache.prune(endingBy: t0)
        XCTAssertEqual(cache.count, 10)
        cache.prune(endingBy: t0 + 24 * h)
        XCTAssertEqual(cache.count, 0)
    }

    func testARebootOrAClockEditForgetsEveryHour() {
        var cache = HourCache(bootTimeMs: boot)
        XCTAssertNotNil(count(&cache, Pedometer(t0: t0, walks: walks), at: t0 + 18 * h))
        cache.markSaved()
        let kept = cache.count
        cache.check(bootTimeMs: boot + 2_000)
        XCTAssertEqual(cache.count, kept, "the clock's own small corrections keep it")
        XCTAssertFalse(cache.unsaved)
        // The clock set two hours ahead moves kern.boottime with it: an hour
        // settled now would hold steps not yet taken.
        cache.check(bootTimeMs: boot + 2 * h)
        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(cache.unsaved)
        XCTAssertEqual(cache.bootTimeMs, boot + 2 * h)
    }

    func testAFailedQueryCountsNothingButKeepsWhatItAlreadyHad() {
        var cache = HourCache(bootTimeMs: boot)
        var calls = 0
        let pedometer = Pedometer(t0: t0, walks: walks)
        // The hour totals answer; the first minute query does not.
        let counts = cache.count(windows: [(t0, t0 + 12 * h)], totals: [0], clock: clock, now: t0 + 12 * h,
                                 keepAfter: t0 - 24 * h) { intervals in
            calls += 1
            return calls == 1 ? pedometer.steps(intervals) : intervals.map { _ in nil }
        }
        XCTAssertNil(counts)
        // The seven hours before the first walk had no steps to ask minutes
        // for, and were kept before the failure.
        XCTAssertEqual(cache.count, 7)
    }

    func testAFileThisVersionCannotReadIsIgnored() {
        XCTAssertNil(HourCache.decoded(Data("not json".utf8)))
        XCTAssertNil(HourCache.decoded(Data(#"{"version":2,"bootTimeMs":1,"hours":[]}"#.utf8)))
        // An hour whose minutes do not fit its stretch is left out; the rest stay.
        let text = #"{"version":1,"bootTimeMs":5,"hours":[{"startMs":0,"endMs":3600000,"total":10,"minutes":[10]},{"startMs":3600000,"endMs":7200000,"total":0,"minutes":[]}]}"#
        let read = HourCache.decoded(Data(text.utf8))
        XCTAssertEqual(read?.count, 1)
        XCTAssertEqual(read?.hour(from: 3_600_000, to: 7_200_000)?.total, 0)
    }

    func testOnlyAChangeNeedsWriting() {
        var cache = HourCache(bootTimeMs: boot)
        XCTAssertFalse(cache.unsaved)
        cache.check(bootTimeMs: boot + 5 * h)
        XCTAssertFalse(cache.unsaved, "nothing was kept to forget")
        cache.keep(BucketCount(startMs: t0, endMs: t0 + h, total: 0))
        XCTAssertTrue(cache.unsaved)
        cache.markSaved()
        cache.prune(endingBy: t0)
        XCTAssertFalse(cache.unsaved)
        cache.removeAll()
        XCTAssertTrue(cache.unsaved)
    }
}
