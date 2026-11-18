import XCTest
@testable import StepTrackerProCore

/// Android's StepTimelineTest, CountFromTest, OtherDevicesTest and
/// HourlyStepsTest, input for input.
final class StepTimelineTests: XCTestCase {
    let t0: Int64 = 1_757_800_800_000
    typealias Share = MinuteAttribution.Share

    func testADeltaInsideOneMinuteLandsOnThatMinute() {
        XCTAssertEqual(MinuteAttribution.attribute(t0 + 1_000, t0 + 1_600, 1), [Share(minuteStart: t0, timed: 1, untimed: 0)])
    }

    func testADeltaStraddlingAMinuteBoundaryIsSplitByOverlap() {
        let shares = MinuteAttribution.attribute(t0 + 30_000, t0 + 70_000, 40)
        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(shares[0].timed, 30)
        XCTAssertEqual(shares[1].timed, 10)
        XCTAssertEqual(shares[1].minuteStart, t0 + 60_000)
        XCTAssertEqual(shares.reduce(0) { $0 + $1.timed }, 40)
    }

    func testRoundingNeverLosesOrInventsAStep() {
        for steps in 1...50 {
            let shares = MinuteAttribution.attribute(t0 + 59_999, t0 + 60_001 + Int64(steps) * 7, steps)
            XCTAssertEqual(shares.reduce(0) { $0 + $1.timed + $1.untimed }, steps)
        }
    }

    func testAFewStepsAfterALongRestAreTimedAtArrival() {
        XCTAssertEqual(MinuteAttribution.attribute(t0 - 3_600_000, t0 + 5_000, 3), [Share(minuteStart: t0, timed: 3, untimed: 0)])
    }

    func testALumpAfterASilenceIsParkedUntimed() {
        XCTAssertEqual(MinuteAttribution.attribute(t0 - 1_800_000, t0 + 5_000, 2_400), [Share(minuteStart: t0, timed: 0, untimed: 2_400)])
    }

    func testAnUntimedSampleParksUntimedAtArrival() {
        XCTAssertEqual(MinuteAttribution.attribute(t0 + 500, t0 + 1_000, 1, timed: false), [Share(minuteStart: t0, timed: 0, untimed: 1)])
        XCTAssertEqual(MinuteAttribution.attribute(t0 + 30_000, t0 + 70_000, 30, timed: false),
                       [Share(minuteStart: t0 + 60_000, timed: 0, untimed: 30)])
    }

    func testNoPreviousSampleOrABackwardClockKeepsOnlyTheArrival() {
        XCTAssertEqual(MinuteAttribution.attribute(0, t0 + 1, 5), [Share(minuteStart: t0, timed: 5, untimed: 0)])
        XCTAssertEqual(MinuteAttribution.attribute(t0 + 9_000, t0 + 1, 90), [Share(minuteStart: t0, timed: 0, untimed: 90)])
        XCTAssertTrue(MinuteAttribution.attribute(t0, t0 + 1, 0).isEmpty)
    }

    func testTheTimelineTagsChargingAndActivityAndDrainsOnce() {
        let timeline = StepTimeline()
        timeline.record(t0 + 1_000, t0 + 2_000, 2, charging: true, activity: .unknown)
        timeline.record(t0 + 2_000, t0 + 3_000, 3, charging: false, activity: .inVehicle)
        timeline.record(t0 + 61_000, t0 + 62_000, 4, charging: false, activity: .still)
        let drained = timeline.drain()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained[0], MinuteSample(minuteStart: t0, steps: 5, untimedSteps: 0, chargingSteps: 2, stillSteps: 0, vehicleSteps: 3))
        XCTAssertEqual(drained[1], MinuteSample(minuteStart: t0 + 60_000, steps: 4, untimedSteps: 0, chargingSteps: 0, stillSteps: 4, vehicleSteps: 0))
        XCTAssertTrue(timeline.drain().isEmpty)
    }

    func testTheTimelineKeepsAnUntimedSampleUntimed() {
        let timeline = StepTimeline()
        timeline.record(t0 + 1_000, t0 + 2_000, 2, charging: true, activity: .unknown)
        timeline.record(t0 + 2_000, t0 + 2_001, 3, charging: true, activity: .unknown, timed: false)
        XCTAssertEqual(timeline.drain(), [MinuteSample(minuteStart: t0, steps: 2, untimedSteps: 3, chargingSteps: 5)])
    }

    func testThePendingBufferIsBounded() {
        let timeline = StepTimeline()
        for i in 0..<(StepTimeline.maxPendingMinutes + 10) {
            let at = t0 + Int64(i) * 60_000
            timeline.record(at, at + 500, 1, charging: false, activity: .unknown)
        }
        let drained = timeline.drain()
        XCTAssertEqual(drained.count, StepTimeline.maxPendingMinutes)
        XCTAssertEqual(drained.first?.minuteStart, t0 + 10 * 60_000)
    }
}

final class CountFromTests: XCTestCase {
    let signIn: Int64 = 1_791_100_000_000
    let minute: Int64 = 60_000

    func testARecordBeforeCountFromCountsNothingOneAfterCountsWhole() {
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn - 20 * minute, endMs: signIn - 10 * minute, floorMs: signIn), 0)
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn - 10 * minute, endMs: signIn, floorMs: signIn), 0)
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn, endMs: signIn + 10 * minute, floorMs: signIn), 800)
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn + minute, endMs: signIn + 2 * minute, floorMs: signIn), 800)
    }

    func testARecordAcrossCountFromCountsItsShareAfterIt() {
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn - 5 * minute, endMs: signIn + 5 * minute, floorMs: signIn), 400)
        XCTAssertEqual(CountFrom.shareAfter(2_000.0, startMs: signIn - minute, endMs: signIn + 3 * minute, floorMs: signIn), 1_500, accuracy: 0.001)
        XCTAssertEqual(CountFrom.startAfter(signIn - 5 * minute, floorMs: signIn), signIn)
        XCTAssertEqual(CountFrom.startAfter(signIn + minute, floorMs: signIn), signIn + minute)
    }

    func testWithNoCountFromEverythingCounts() {
        XCTAssertEqual(CountFrom.shareAfter(800, startMs: signIn - 5 * minute, endMs: signIn + 5 * minute, floorMs: 0), 800)
        XCTAssertEqual(CountFrom.shareAfter(12.5, startMs: signIn - 5 * minute, endMs: signIn, floorMs: 0), 12.5)
        XCTAssertEqual(CountFrom.startAfter(signIn - 5 * minute, floorMs: 0), signIn - 5 * minute)
    }
}

final class OtherDevicesTests: XCTestCase {
    let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let today = "2026-10-04"

    func testAWeekOfDaysIsKeptAndNothingOlderOrAtZero() {
        let kept = OtherDevices.kept(["2026-10-04": 629, "2026-10-03": 0, "2026-09-27": 1_200, "2026-09-26": 800], today: today, clock: clock)
        XCTAssertEqual(kept, ["2026-09-27": 1_200, "2026-10-04": 629])
    }

    func testTomorrowIsKeptAndNothingPastIt() {
        var byDate: [String: Int] = [:]
        for i in 0..<40 { byDate[clock.minusDays("2026-10-20", i)] = i + 1 }
        let kept = OtherDevices.kept(byDate, today: today, clock: clock)
        XCTAssertEqual(kept.keys.sorted(), clock.range("2026-09-27", "2026-10-05"))
        XCTAssertEqual(kept[today], 17)
    }

    func testWhatIsKeptReadsBackAsItWasWritten() {
        let kept = ["2026-10-03": 4_120, "2026-10-04": 629]
        XCTAssertEqual(OtherDevices.decode(OtherDevices.encode(kept)), kept)
    }
}

final class HourlyStepsTests: XCTestCase {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)

    func at(_ clock: DayClock, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Int64 {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (y, m, d, h, min)
        return DayClock.ms(clock.calendar.date(from: c)!)
    }

    func testARecordInsideOneHourLandsOnThatHour() {
        var hours = [Int](repeating: 0, count: 24)
        HourlySteps.add(into: &hours, startMs: at(utc, 2026, 9, 14, 9, 10), endMs: at(utc, 2026, 9, 14, 9, 20), count: 800, clock: utc)
        XCTAssertEqual(hours[9], 800)
        XCTAssertEqual(hours.reduce(0, +), 800)
    }

    func testARecordSpanningHoursIsSplitByTime() {
        var hours = [Int](repeating: 0, count: 24)
        HourlySteps.add(into: &hours, startMs: at(utc, 2026, 9, 14, 9, 30), endMs: at(utc, 2026, 9, 14, 11, 0), count: 900, clock: utc)
        XCTAssertEqual(hours[9], 300)
        XCTAssertEqual(hours[10], 600)
        XCTAssertEqual(hours.reduce(0, +), 900)
    }

    func testWhateverRunsPastMidnightStaysOnTheDayItStarted() {
        var hours = [Int](repeating: 0, count: 24)
        HourlySteps.add(into: &hours, startMs: at(utc, 2026, 9, 14, 23, 30), endMs: at(utc, 2026, 9, 15, 0, 30), count: 100, clock: utc)
        XCTAssertEqual(hours[23], 100)
        XCTAssertEqual(hours.reduce(0, +), 100)
    }

    func testAnInstantRecordLandsOnItsHour() {
        var hours = [Int](repeating: 0, count: 24)
        let t = at(utc, 2026, 9, 14, 7, 5)
        HourlySteps.add(into: &hours, startMs: t, endMs: t, count: 12, clock: utc)
        XCTAssertEqual(hours[7], 12)
    }

    func testADaylightSavingDayStillSumsToTheRecord() {
        let london = DayClock(timeZone: TimeZone(identifier: "Europe/London")!)
        var hours = [Int](repeating: 0, count: 24)
        HourlySteps.add(into: &hours, startMs: at(london, 2026, 3, 29, 0), endMs: at(london, 2026, 3, 29, 4), count: 3_000, clock: london)
        XCTAssertEqual(hours.reduce(0, +), 3_000)
        XCTAssertEqual(hours[1], 0)
        XCTAssertEqual(hours[0], 1_000)
    }

    func testRoundingNeverLosesAStep() {
        for count in 1...60 {
            var hours = [Int](repeating: 0, count: 24)
            HourlySteps.add(into: &hours, startMs: at(utc, 2026, 9, 14, 5, 59), endMs: at(utc, 2026, 9, 14, 8, 1), count: count, clock: utc)
            XCTAssertEqual(hours.reduce(0, +), count)
        }
    }
}
