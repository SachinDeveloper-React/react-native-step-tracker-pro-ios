import XCTest
@testable import StepTrackerProCore

/// Real days, end to end through the pure pipeline: pedometer history ->
/// minutes -> gate -> integrity -> Apple Health sources -> resolution.
///
/// The pedometer is modelled the way iPhones store steps: in records of 6
/// to 10 minutes, each returned as its average when asked minute by minute
/// (exported Health data shows records "at least 6 minutes and ideally 10"
/// since iOS 10). Every scenario names what a user would see go wrong.
final class ScenarioTests: XCTestCase {
    let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let day = "2026-09-14"
    let m: Int64 = 60_000
    let h: Int64 = 3_600_000
    var t0: Int64 { clock.startOfDayMs(day) }
    let rules = IntegrityRules()

    // ---- the iPhone's records ----------------------------------------------------------------

    struct Record { let start: Int64; let end: Int64; let steps: Int }

    /// Records of [length] minutes at [spm], from [startMinute] for [minutes].
    func walk(at startMinute: Int, minutes: Int, spm: [Int], length: Int = 10) -> [Record] {
        var out: [Record] = []
        var minute = startMinute
        var i = 0
        while minute < startMinute + minutes {
            let len = min(length, startMinute + minutes - minute)
            let rate = spm[i % spm.count]
            out.append(Record(start: t0 + Int64(minute) * m, end: t0 + Int64(minute + len) * m, steps: rate * len))
            minute += len
            i += 1
        }
        return out
    }

    /// What the pedometer answers for [from, to): each record's share by time.
    func query(_ records: [Record], _ from: Int64, _ to: Int64) -> Int {
        Int(records.reduce(0.0) { sum, r in
            let overlap = max(0, min(r.end, to) - max(r.start, from))
            return sum + Double(r.steps) * Double(overlap) / Double(r.end - r.start)
        }.rounded())
    }

    /// The engine's queries - window, hours, minutes of hours with steps.
    func windows(_ records: [Record], from: Int64? = nil, to: Int64? = nil) -> [WindowCount] {
        let start = from ?? t0
        let end = to ?? clock.endOfDayExclusiveMs(day)
        let hours = TrackingSpans.hours(from: start, to: end, clock: clock).map { span -> BucketCount in
            var bucket = BucketCount(startMs: span.0, endMs: span.1, total: query(records, span.0, span.1))
            if bucket.total > 0 {
                bucket.minutes = TrackingSpans.minutes(from: span.0, to: span.1).map {
                    BucketCount(startMs: $0.0, endMs: $0.1, total: query(records, $0.0, $0.1))
                }
            }
            return bucket
        }
        return [WindowCount(startMs: start, endMs: end, total: query(records, start, end), hours: hours)]
    }

    func count(_ records: [Record], activity: [Int64: MinuteActivity] = [:]) -> DayCount {
        DayCounting.build(windows: windows(records), activity: activity, charging: [], activityTags: true)
    }

    func judge(_ day: DayCount) -> DayEvaluation {
        FraudDetector.evaluate(day.minutes, windows: [], rules: rules, clock: clock, resolution: .averaged)
    }

    func suspect(_ day: DayCount) -> Int {
        FraudDetector.suspectSteps(flaggedSteps: judge(day).flaggedSteps, deviceSteps: day.deviceSteps, rules: rules)
    }

    // ---- this phone's count -------------------------------------------------------------------

    func testAnOrdinaryWalkIsCountedWholeAndExplainedByItsMinutes() {
        let records = walk(at: 9 * 60, minutes: 34, spm: [104, 117, 96, 111])
        let day = count(records)
        XCTAssertEqual(day.deviceSteps, records.reduce(0) { $0 + $1.steps })
        XCTAssertEqual(day.minutes.reduce(0) { $0 + $1.totalSteps }, day.deviceSteps - day.gatedSteps)
        XCTAssertEqual(suspect(day), 0)
    }

    /// The bug the averaged mode fixes: a steady treadmill pace, stored as
    /// 10-minute averages, reads as a machine minute by minute.
    func testATreadmillWalkIsNotTakenForAMachine() {
        let records = walk(at: 7 * 60, minutes: 45, spm: [119, 120, 119, 120, 119])
        let day = count(records)
        let exact = FraudDetector.evaluate(day.minutes, windows: [], rules: rules, clock: clock, resolution: .exact)
        XCTAssertEqual(exact.flags.first { $0.type == IntegrityFlag.steadyCadence }?.severity, .strong,
                       "judged as exact minutes, the averages look like a machine")
        let averaged = judge(day)
        let steady = averaged.flags.first { $0.type == IntegrityFlag.steadyCadence }
        XCTAssertEqual(steady?.severity, .weak)
        XCTAssertEqual(steady?.evidenceValue("minuteData"), .string("averaged"))
        XCTAssertEqual(suspect(day), 0, "nothing is taken out, under exclude mode either")
    }

    func testAHikeWhoseShortRestsWereAveragedAwayIsNotCutAtThreeHours() {
        // 200 minutes in 10-minute records; the 2-minute rests inside them
        // only lower each record's average.
        let records = walk(at: 6 * 60, minutes: 200, spm: [88, 95, 79, 101])
        let day = count(records)
        let flag = judge(day).flags.first { $0.type == IntegrityFlag.continuous }
        XCTAssertEqual(flag?.severity, .weak)
        XCTAssertEqual(suspect(day), 0)
    }

    func testASwingGadgetStillLeavesEvidenceAndTheDailyCapStillHolds() {
        // Six hours a day for a week's worth of steps in one day.
        let records = walk(at: 0, minutes: 24 * 60 - 1, spm: [110])
        let day = count(records)
        let evaluation = judge(day)
        XCTAssertTrue(evaluation.flags.contains { $0.type == IntegrityFlag.steadyCadence })
        XCTAssertTrue(evaluation.flags.contains { $0.type == IntegrityFlag.continuous })
        XCTAssertEqual(suspect(day), day.deviceSteps - rules.maxDailySteps, "the cap is strong on every platform")
    }

    func testAShakenPhoneIsStillCaughtByCadence() {
        // Ten minutes at 260 a minute survive any averaging.
        let records = walk(at: 22 * 60, minutes: 10, spm: [260])
        let day = count(records)
        XCTAssertEqual(judge(day).flags.first { $0.type == IntegrityFlag.cadence }?.severity, .strong)
        XCTAssertEqual(suspect(day), 2_600)
    }

    func testALumpThePedometerCouldNotPlaceIsCountedNotJudged() {
        // A whole record landing in one minute: 1,100 steps.
        let records = [Record(start: t0 + 10 * h, end: t0 + 10 * h + m, steps: 1_100)]
        let day = count(records)
        XCTAssertEqual(day.deviceSteps, 1_100)
        XCTAssertEqual(day.minutes, [MinuteSample(minuteStart: t0 + 10 * h, steps: 0, untimedSteps: 1_100)])
        XCTAssertFalse(judge(day).flags.contains { $0.type == IntegrityFlag.cadence })
    }

    func testABusRideIsHeldAndTheWalkAwayGivenBack() {
        // 08:00-08:30 on a bus, off at 08:30, "walking" reported 08:31.
        let bus = walk(at: 8 * 60, minutes: 30, spm: [22])
        let walkHome = walk(at: 8 * 60 + 30, minutes: 10, spm: [105])
        let acts = [ActivitySample(startMs: t0 + 8 * h, automotive: true, confidence: 2),
                    ActivitySample(startMs: t0 + 8 * h + 31 * m, walking: true, confidence: 2)]
        let minutes = (0..<(24 * 60)).map { t0 + Int64($0) * m }
        let activity = ActivityGate.classify(minutes: minutes, activities: acts, untilMs: t0 + 9 * h, gateEnabled: true)
        let day = count(bus + walkHome, activity: activity)
        XCTAssertEqual(day.deviceSteps, 30 * 22 + 10 * 105, "held steps stay in the raw count")
        XCTAssertEqual(day.gatedSteps, 29 * 22, "the ride, less the minute and a half before the walk")
        XCTAssertEqual(day.minutes.reduce(0) { $0 + $1.totalSteps }, day.deviceSteps - day.gatedSteps)
    }

    func testPausedTrackingAndCountFromAreCutByTime() {
        let records = walk(at: 9 * 60, minutes: 60, spm: [100], length: 6)
        // Tracking ran 09:00-09:20 and from 09:40; countFrom 09:10.
        let spans = [TrackingSpan(start: t0 + 9 * h, end: t0 + 9 * h + 20 * m), TrackingSpan(start: t0 + 9 * h + 40 * m, end: nil)]
        let cut = TrackingSpans.windows(spans, from: max(t0, t0 + 9 * h + 10 * m), to: t0 + 11 * h)
        let total = cut.reduce(0) { $0 + query(records, $1.0, $1.1) }
        XCTAssertEqual(total, 10 * 100 + 20 * 100, "09:10-09:20 and 09:40-10:00")
    }

    // ---- this phone and a watch ----------------------------------------------------------------

    let metrics = MetricsCalculator(config: StepTrackerConfig())

    func watch(_ hours: [Int: Int]) -> StepSource {
        var hourly = [Int](repeating: 0, count: 24)
        for (hour, steps) in hours { hourly[hour] = steps }
        return StepSource(packageName: "com.apple.health.W", appName: "Apple Watch", kind: .watch,
                          steps: hourly.reduce(0, +), manualSteps: 0, unknownMethodSteps: 0,
                          recordingMethods: RecordingMethods(automatic: hourly.reduce(0, +)), hourlySteps: hourly,
                          distanceSource: DistanceSource.healthKit, isPlatform: true)
    }

    func resolve(phone: [Int: Int], sources: [StepSource], policy: StepSourcePolicy = .auto,
                 pin: String? = nil, ignoreManual: Bool = false) -> StepSourceResolver.Resolution {
        var hours = [Int](repeating: 0, count: 24)
        for (hour, steps) in phone { hours[hour] = steps }
        let device = metrics.totals(date: day, steps: hours.reduce(0, +))
        let stamped = StepSourceTrust.stamp(sources, trust: .metadata, allowlist: [], catalog: IOSCatalog.catalog)
        let r = StepSourceResolver.resolve(policy, device: device, sources: stamped, preferredPackage: pin, metrics: metrics,
                                           ignoreManualEntries: ignoreManual, catalog: IOSCatalog.catalog)
        guard policy == .auto, pin == nil else { return r }
        return HourMerge.apply(r, device: device, phoneHours: hours, sources: stamped, trust: .metadata, allowlist: [],
                               catalog: IOSCatalog.catalog, ignoreManualEntries: ignoreManual, metrics: metrics)
    }

    /// The bug the merge fixes: a morning walked with only the watch and an
    /// evening with only the phone used to show one of them.
    func testAWatchMorningAndAPhoneEveningBothCount() {
        let r = resolve(phone: [18: 4_000], sources: [watch([8: 5_000])])
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(r.kind, .watch)
        XCTAssertEqual(r.deviceSteps, 4_000)
        XCTAssertEqual(r.baselineSteps, 5_000)
        XCTAssertEqual(r.totals.calories, metrics.calories(9_000), accuracy: 0.001)
    }

    func testOneWalkSeenByBothIsNeverCountedTwice() {
        let r = resolve(phone: [9: 3_900], sources: [watch([9: 4_100])])
        XCTAssertEqual(r.totals.steps, 4_100)
    }

    func testEachHourTakesWhicheverSawMore() {
        // Phone ahead at 9 (watch loose), watch ahead at 10 (phone on a desk).
        let r = resolve(phone: [9: 2_000, 10: 300], sources: [watch([9: 1_500, 10: 3_000])])
        XCTAssertEqual(r.totals.steps, 5_000)
    }

    func testAPinOrAnExactPolicyIsNotMerged() {
        let sources = [watch([8: 5_000])]
        XCTAssertEqual(resolve(phone: [18: 4_000], sources: sources, pin: "com.apple.health.W").totals.steps, 5_000)
        XCTAssertEqual(resolve(phone: [18: 4_000], sources: sources, policy: .wearable).totals.steps, 5_000)
        XCTAssertEqual(resolve(phone: [18: 4_000], sources: sources, policy: .device).totals.steps, 4_000)
    }

    func testAnUntrustedAppAndAManualEntryNeverRideAlong() {
        let app = StepSource(packageName: "com.example.pedometer", appName: "Pedometer", kind: .app, steps: 6_000,
                             manualSteps: 0, hourlySteps: [Int](repeating: 250, count: 24))
        let typed = StepSource(packageName: "com.apple.Health", appName: "Health", kind: .app, steps: 20_000,
                               manualSteps: 20_000, hourlySteps: [20_000] + [Int](repeating: 0, count: 23))
        let r = resolve(phone: [10: 3_000], sources: [app, typed], ignoreManual: true)
        XCTAssertEqual(r.totals.steps, 3_000)
        XCTAssertFalse(r.merged)
    }

    func testThePhoneAloneIsUnchanged() {
        let r = resolve(phone: [10: 3_000], sources: [])
        XCTAssertEqual(r.totals.steps, 3_000)
        XCTAssertFalse(r.usedExternal)
    }

    func testPhoneHoursFollowTheCountAfterExclusions() {
        let minutes = [MinuteSample(minuteStart: t0 + 9 * h, steps: 100), MinuteSample(minuteStart: t0 + 10 * h, steps: 300)]
        XCTAssertEqual(HourMerge.phoneHours(minutes, total: 200, clock: clock)[9...10], [50, 150])
        XCTAssertEqual(HourMerge.phoneHours(minutes, total: 400, clock: clock).reduce(0, +), 400)
    }

    func testStepsSinceTheLastMinuteCountLandInTheCurrentHour() {
        // Minutes from a minute ago; 500 steps walked since, at 18:00, with
        // the watch on: they must not be spread over the morning and then
        // counted again in the watch's 18:00.
        let minutes = [MinuteSample(minuteStart: t0 + 9 * h, steps: 2_000)]
        let hours = HourMerge.phoneHours(minutes, total: 2_500, clock: clock, currentHour: 18)
        XCTAssertEqual(hours[9], 2_000)
        XCTAssertEqual(hours[18], 500)
        let r = resolve(phone: Dictionary(uniqueKeysWithValues: hours.enumerated().filter { $0.element > 0 }.map { ($0.offset, $0.element) }),
                        sources: [watch([18: 500])])
        XCTAssertEqual(r.totals.steps, 2_500, "the walk at 18:00 counted once")
    }

    // ---- days that age out and days that close ---------------------------------------------------

    func testADayLeftHalfCountedTakesAppleHealthsFullDay() {
        XCTAssertEqual(DayPolicy.agedDay(counted: 4_100, health: 9_800), .replace)
        XCTAssertEqual(DayPolicy.agedDay(counted: nil, health: 9_800), .replace)
    }

    func testARefusedOrFailedReadNeverSettlesADay() {
        XCTAssertEqual(DayPolicy.agedDay(counted: 4_100, health: 0), .keep)
        XCTAssertEqual(DayPolicy.agedDay(counted: nil, health: 0), .keep)
        XCTAssertEqual(DayPolicy.agedDay(counted: 4_100, health: nil), .keep)
    }

    func testAFullyCountedDayIsSettled() {
        XCTAssertEqual(DayPolicy.agedDay(counted: 9_800, health: 9_800), .settle)
        XCTAssertEqual(DayPolicy.agedDay(counted: 9_900, health: 9_800), .settle)
    }

    func testADayStaysOpenLongEnoughForItsLastRecord() {
        let end = clock.endOfDayExclusiveMs(day)
        XCTAssertFalse(DayPolicy.isSettled(computedAt: end + 10 * m, dayEndExclusive: end), "a record ending at 00:05 may land later")
        XCTAssertTrue(DayPolicy.isSettled(computedAt: end + 2 * h, dayEndExclusive: end))
    }

    // ---- two iPhones on one Apple Account ----------------------------------------------------------

    func phoneSample(_ bundle: String, _ start: Int64, _ minutes: Int64, _ steps: Double) -> HealthSample {
        HealthSample(uuid: UUID().uuidString, kind: .steps, startMs: start, endMs: start + minutes * m, value: steps,
                     bundleId: bundle, sourceName: bundle, productType: "iPhone15,2", hasDevice: true, deviceModel: "iPhone")
    }

    func testOnlyThisIPhoneIsCalledThisIPhone() {
        let mine = phoneSample("com.apple.health.MINE", t0 + 9 * h, 10, 1_000)
        let work = phoneSample("com.apple.health.WORK", t0 + 9 * h, 10, 950)
        var o = HealthSources.Options(dayStartMs: t0, dayEndMs: clock.endOfDayExclusiveMs(day))
        // Two iPhones and neither known: neither is "This iPhone".
        XCTAssertEqual(Set(HealthSources.build([mine, work], o, clock: clock).map(\.appName)), ["iPhone"])
        // One iPhone: it is this one.
        XCTAssertEqual(HealthSources.build([mine], o, clock: clock).first?.appName, "This iPhone")
        // Learned from the pedometer's count, which matches one of them.
        let sources = HealthSources.build([mine, work], o, clock: clock)
        XCTAssertNil(HealthSources.identifyThisPhone(sources, pedometerSteps: 975), "both within 10%: undecided")
        XCTAssertEqual(HealthSources.identifyThisPhone(sources, pedometerSteps: 1_600), nil)
        let far = phoneSample("com.apple.health.WORK", t0 + 9 * h, 10, 400)
        let apart = HealthSources.build([mine, far], o, clock: clock)
        XCTAssertEqual(HealthSources.identifyThisPhone(apart, pedometerSteps: 1_020), "com.apple.health.MINE")
        o.thisPhone = "com.apple.health.MINE"
        let named = Dictionary(uniqueKeysWithValues: HealthSources.build([mine, far], o, clock: clock).map { ($0.packageName, $0.appName) })
        XCTAssertEqual(named, ["com.apple.health.MINE": "This iPhone", "com.apple.health.WORK": "iPhone"])
    }

    func testTheFallbackNeverSumsTwoIPhones() {
        // Both phones carried on the same walk.
        let mine = phoneSample("com.apple.health.MINE", t0 + 9 * h, 10, 1_000)
        let work = phoneSample("com.apple.health.WORK", t0 + 9 * h, 10, 980)
        let windows = [(t0, clock.endOfDayExclusiveMs(day))]
        XCTAssertEqual(HealthSources.iPhoneMinutes([mine, work], windows: windows).values.reduce(0, +), 1_000, "the larger, not 1,980")
        XCTAssertEqual(HealthSources.iPhoneMinutes([mine, work], windows: windows, thisPhone: "com.apple.health.WORK").values.reduce(0, +), 980)
    }

    func testAWalkAcrossMidnightIsSplitByTime() {
        let sample = HealthSample(uuid: "a", kind: .steps, startMs: t0 - 5 * m, endMs: t0 + 5 * m, value: 1_000,
                                  bundleId: "com.apple.health.P", sourceName: "P", productType: "iPhone15,2",
                                  hasDevice: true, deviceModel: "iPhone")
        let options = HealthSources.Options(dayStartMs: t0, dayEndMs: clock.endOfDayExclusiveMs(day))
        XCTAssertEqual(HealthSources.build([sample], options, clock: clock).first?.steps, 500)
        XCTAssertEqual(HealthSources.iPhoneMinutes([sample], windows: [(t0, t0 + h)]).values.reduce(0, +), 500)
    }
}
