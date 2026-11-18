import XCTest
@testable import StepTrackerProCore

/// The motion gate on iOS against the activity-driven scenarios of Android's
/// VehicleGateTest. Android's gate is fed live Activity Recognition
/// transitions and accelerometer samples; iOS judges minutes from
/// CMMotionActivity history, and has no accelerometer to ask - so the
/// scenarios that rest on the accelerometer (a confirmed walk mid-ride,
/// stillness ending a ride, rough roads, pedalling) have no iOS equivalent.
/// Each one here is the same story told in minutes.
final class ActivityGateTests: XCTestCase {
    let base: Int64 = 1_767_225_600_000 // 2026-01-01T00:00Z
    let minute: Int64 = 60_000

    func minutes(_ from: Int, _ to: Int) -> [Int64] { (from..<to).map { base + Int64($0) * minute } }

    func act(_ atMinute: Double, automotive: Bool = false, cycling: Bool = false, walking: Bool = false,
             running: Bool = false, stationary: Bool = false, confidence: Int = 2) -> ActivitySample {
        ActivitySample(startMs: base + Int64(atMinute * 60_000), stationary: stationary, walking: walking, running: running,
                       automotive: automotive, cycling: cycling, unknown: false, confidence: confidence)
    }

    func gated(_ acts: [ActivitySample], _ range: (Int, Int), enabled: Bool = true) -> [Int] {
        let result = ActivityGate.classify(minutes: minutes(range.0, range.1), activities: acts,
                                           untilMs: base + Int64(range.1) * minute, gateEnabled: enabled)
        return minutes(range.0, range.1).enumerated().filter { result[$0.element]?.gated == true }.map { $0.offset + range.0 }
    }

    func testNothingIsHeldUntilAVehicleIsReported() {
        XCTAssertEqual(gated([act(0, walking: true), act(10, stationary: true)], (0, 20)), [])
        XCTAssertEqual(gated([], (0, 20)), [])
    }

    func testAReportedVehicleOrBicycleHoldsTheMinutesItCovers() {
        XCTAssertEqual(gated([act(0, walking: true), act(5, automotive: true)], (0, 10)), [5, 6, 7, 8, 9])
        XCTAssertEqual(gated([act(5, cycling: true)], (0, 10)), [5, 6, 7, 8, 9])
    }

    func testTheGateOffHoldsNothingButStillTags() {
        let r = ActivityGate.classify(minutes: minutes(0, 10), activities: [act(5, automotive: true)], untilMs: base + 10 * minute, gateEnabled: false)
        XCTAssertEqual(r.values.filter(\.gated).count, 0)
        XCTAssertEqual(r.values.filter(\.vehicle).count, 5)
    }

    func testALowConfidenceVehicleTagsButDoesNotHold() {
        let r = ActivityGate.classify(minutes: minutes(0, 10), activities: [act(5, automotive: true, confidence: 0)],
                                      untilMs: base + 10 * minute, gateEnabled: true)
        XCTAssertEqual(r.values.filter(\.gated).count, 0)
        XCTAssertEqual(r.values.filter(\.vehicle).count, 5)
    }

    func testABusReclassifiedAsABicycleIsOneRide() {
        XCTAssertEqual(gated([act(0, automotive: true), act(4, cycling: true)], (0, 8)), Array(0..<8))
    }

    func testStepsBeforeTheRideAreCounted() {
        // The minute the ride began in is shared with the walk to the seat:
        // it was walked as much as ridden, and walking wins a minute.
        XCTAssertEqual(gated([act(0, walking: true), act(3.5, automotive: true)], (0, 6)), [4, 5])
    }

    func testWalkingReportedLateGivesBackTheWalkAwayFromTheRide() {
        // Off the bus at minute 20, "walking" reported at 21: the minute and a
        // half before the report is the walk away from the stop.
        XCTAssertEqual(gated([act(0, automotive: true), act(21, walking: true)], (0, 25)), Array(0..<19))
    }

    func testRunningEndsARideAsWalkingDoes() {
        XCTAssertEqual(gated([act(0, automotive: true), act(21, running: true)], (0, 25)), Array(0..<19))
    }

    func testWalkingSoonAfterAnEndOnStillClaimsTheRest() {
        XCTAssertEqual(gated([act(0, automotive: true), act(20, stationary: true), act(20.5, walking: true)], (0, 25)), Array(0..<18))
    }

    func testWalkingLongAfterAnEndOnStillClaimsNothing() {
        XCTAssertEqual(gated([act(0, automotive: true), act(20, stationary: true), act(30, walking: true)], (0, 35)), Array(0..<20))
    }

    func testARedLightIsStillTheRide() {
        // iOS reports a car at a light as automotive and stationary at once.
        XCTAssertEqual(gated([act(0, automotive: true), act(3, automotive: true, stationary: true), act(5, automotive: true)], (0, 8)), Array(0..<8))
    }

    func testNoRideIsHeldForMoreThanTwelveHoursOnOneReport() {
        let held = gated([act(0, automotive: true)], (0, 13 * 60))
        XCTAssertEqual(held.count, 12 * 60 + 1)
        XCTAssertEqual(held.last, 12 * 60)
    }

    func testStillIsTaggedOnlyWithoutAVehicle() {
        let r = ActivityGate.classify(minutes: minutes(0, 4), activities: [act(0, stationary: true), act(2, automotive: true, stationary: true)],
                                      untilMs: base + 4 * minute, gateEnabled: false)
        XCTAssertEqual(r[base]?.still, true)
        XCTAssertEqual(r[base + 2 * minute]?.still ?? false, false)
        XCTAssertEqual(r[base + 2 * minute]?.vehicle, true)
    }
}

final class DayCountingTests: XCTestCase {
    let h: Int64 = 3_600_000
    let m: Int64 = 60_000
    let t0: Int64 = 1_789_344_000_000 // 2026-09-14T00:00Z

    func hour(_ start: Int64, _ total: Int, minutes: [Int]) -> BucketCount {
        BucketCount(startMs: start, endMs: start + h, total: total,
                    minutes: minutes.enumerated().map { BucketCount(startMs: start + Int64($0.offset) * m, endMs: start + Int64($0.offset + 1) * m, total: $0.element) })
    }

    func testFitAlwaysAddsBackUp() {
        XCTAssertEqual(DayCounting.fit(10, [3, 3, 4]), [3, 3, 4])
        XCTAssertEqual(DayCounting.fit(11, [3, 3, 4])?.reduce(0, +), 11)
        XCTAssertEqual(DayCounting.fit(9, [3, 3, 4])?.reduce(0, +), 9)
        XCTAssertNil(DayCounting.fit(5, [0, 0]))
        for target in 0...200 {
            XCTAssertEqual(DayCounting.fit(target, [17, 1, 0, 99, 3])?.reduce(0, +), target)
        }
    }

    func testMinutesExplainTheDayExactly() {
        // The day's query says 1,003; the hours say 1,000; the minutes 998.
        let window = WindowCount(startMs: t0 + 9 * h, endMs: t0 + 11 * h, total: 1_003,
                                 hours: [hour(t0 + 9 * h, 600, minutes: [100, 100, 100, 99, 99, 100]),
                                         hour(t0 + 10 * h, 400, minutes: [200, 200])])
        let day = DayCounting.build(windows: [window], activity: [:], charging: [], activityTags: true)
        XCTAssertEqual(day.deviceSteps, 1_003)
        XCTAssertEqual(day.gatedSteps, 0)
        XCTAssertEqual(day.minutes.reduce(0) { $0 + $1.totalSteps }, 1_003)
        XCTAssertTrue(day.minutes.allSatisfy { $0.untimedSteps == 0 })
    }

    func testGatedMinutesLeaveTheMinutesAndStayInTheCount() {
        let window = WindowCount(startMs: t0, endMs: t0 + h, total: 300, hours: [hour(t0, 300, minutes: [100, 100, 100])])
        let activity = [t0 + m: MinuteActivity(gated: true, vehicle: false, still: false)]
        let day = DayCounting.build(windows: [window], activity: activity, charging: [], activityTags: true)
        XCTAssertEqual(day.deviceSteps, 300)
        XCTAssertEqual(day.gatedSteps, 100)
        XCTAssertEqual(day.minutes.map(\.minuteStart), [t0, t0 + 2 * m])
        XCTAssertEqual(day.minutes.reduce(0) { $0 + $1.totalSteps }, day.deviceSteps - day.gatedSteps)
    }

    func testAnHourThePedometerCannotPlaceIsParkedUntimed() {
        let window = WindowCount(startMs: t0, endMs: t0 + h, total: 50, hours: [hour(t0, 50, minutes: [0, 0])])
        let day = DayCounting.build(windows: [window], activity: [:], charging: [], activityTags: true)
        XCTAssertEqual(day.minutes, [MinuteSample(minuteStart: t0, steps: 0, untimedSteps: 50)])
    }

    func testTagsFollowChargingAndActivity() {
        let window = WindowCount(startMs: t0, endMs: t0 + h, total: 90, hours: [hour(t0, 90, minutes: [30, 30, 30])])
        let activity = [t0: MinuteActivity(gated: false, vehicle: true, still: false),
                        t0 + 2 * m: MinuteActivity(gated: false, vehicle: false, still: true)]
        let day = DayCounting.build(windows: [window], activity: activity, charging: [(t0 + m, t0 + 2 * m)], activityTags: true)
        XCTAssertEqual(day.minutes.map(\.vehicleSteps), [30, 0, 0])
        XCTAssertEqual(day.minutes.map(\.chargingSteps), [0, 30, 0])
        XCTAssertEqual(day.minutes.map(\.stillSteps), [0, 0, 30])
        let untagged = DayCounting.build(windows: [window], activity: activity, charging: [], activityTags: false)
        XCTAssertEqual(untagged.minutes.map { $0.vehicleSteps + $0.stillSteps }, [0, 0, 0])
    }

    func testTrackingSpansCutTheDay() {
        let spans = [TrackingSpan(start: t0 + h, end: t0 + 2 * h), TrackingSpan(start: t0 + 3 * h, end: nil)]
        let windows = TrackingSpans.windows(spans, from: t0, to: t0 + 5 * h)
        XCTAssertEqual(windows.map(\.0), [t0 + h, t0 + 3 * h])
        XCTAssertEqual(windows.map(\.1), [t0 + 2 * h, t0 + 5 * h])
        XCTAssertTrue(TrackingSpans.windows([], from: t0, to: t0 + h).isEmpty)
        let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(TrackingSpans.hours(from: t0 + 30 * m, to: t0 + 2 * h, clock: clock).count, 2)
        XCTAssertEqual(TrackingSpans.minutes(from: t0 + 30_000, to: t0 + 2 * m).count, 2)
    }
}

final class HealthSourcesTests: XCTestCase {
    let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let day = "2026-09-14"
    let t0: Int64 = 1_789_344_000_000
    let h: Int64 = 3_600_000

    func sample(_ bundle: String, _ start: Int64, _ end: Int64, _ value: Double, kind: HealthSample.Kind = .steps,
                product: String? = nil, device: String? = nil, manual: Bool = false) -> HealthSample {
        HealthSample(uuid: UUID().uuidString, kind: kind, startMs: start, endMs: end, value: value, bundleId: bundle,
                     sourceName: bundle, productType: product, hasDevice: device != nil, deviceName: device,
                     deviceManufacturer: device == nil ? nil : "Maker", deviceModel: device, userEntered: manual)
    }

    var options: HealthSources.Options {
        HealthSources.Options(dayStartMs: clock.startOfDayMs(day), dayEndMs: clock.endOfDayExclusiveMs(day))
    }

    func testAppleSourcesAreClassifiedByProductType() {
        let phone = sample("com.apple.health.AAAA", t0 + h, t0 + h + 60_000, 100, product: "iPhone15,2", device: "iPhone")
        let watch = sample("com.apple.health.BBBB", t0 + h, t0 + h + 60_000, 120, product: "Watch6,1", device: "Watch")
        let typed = sample("com.apple.Health", t0 + 2 * h, t0 + 2 * h + 60_000, 5_000, manual: true)
        let band = sample("com.example.band", t0 + h, t0 + 2 * h, 900, device: "Example Band 2")
        let app = sample("com.example.pedometer", t0 + h, t0 + 2 * h, 700)
        let sources = HealthSources.build([phone, watch, typed, band, app], options, clock: clock)
        let byId = Dictionary(uniqueKeysWithValues: sources.map { ($0.packageName, $0) })

        XCTAssertEqual(byId["com.apple.health.AAAA"]?.kind, .phone)
        XCTAssertEqual(byId["com.apple.health.AAAA"]?.isPlatform, true)
        XCTAssertEqual(byId["com.apple.health.AAAA"]?.appName, "This iPhone")
        XCTAssertEqual(byId["com.apple.health.BBBB"]?.kind, .watch)
        XCTAssertEqual(byId["com.apple.health.BBBB"]?.isPlatform, true)
        XCTAssertEqual(byId["com.apple.Health"]?.manualSteps, 5_000)
        XCTAssertEqual(byId["com.apple.Health"]?.isPlatform, false)
        XCTAssertEqual(byId["com.example.band"]?.kind, .fitnessBand)
        XCTAssertEqual(byId["com.example.pedometer"]?.kind, .app)
        XCTAssertEqual(byId["com.example.pedometer"]?.unknownMethodSteps, 700)
        XCTAssertTrue(sources.allSatisfy { $0.calories == 0 && $0.activeCalories == 0 && !$0.isSelf && $0.lateWrittenSteps == -1 })
        XCTAssertTrue(sources.allSatisfy { $0.hourlySteps.reduce(0, +) == $0.steps })

        // Apple Watch is trusted under both rules; the iPhone under neither.
        let catalog = StepSourceTrust.stamp(sources, trust: .catalog, allowlist: [], catalog: IOSCatalog.catalog)
        XCTAssertEqual(catalog.first { $0.packageName == "com.apple.health.BBBB" }?.trustedWearable, true)
        XCTAssertEqual(catalog.first { $0.packageName == "com.apple.health.AAAA" }?.trustedWearable, false)
        XCTAssertEqual(catalog.first { $0.packageName == "com.example.band" }?.trustedWearable, false)
        let metadata = StepSourceTrust.stamp(sources, trust: .metadata, allowlist: [], catalog: IOSCatalog.catalog)
        XCTAssertEqual(metadata.first { $0.packageName == "com.example.band" }?.trustedWearable, true)
    }

    func testAManualEntryIsKeptOutOfResolutionWithTheFlagOn() {
        let typed = sample("com.apple.Health", t0 + 2 * h, t0 + 2 * h + 60_000, 20_000, manual: true)
        let metrics = MetricsCalculator(config: StepTrackerConfig())
        let sources = HealthSources.build([typed], options, clock: clock)
        let r = StepSourceResolver.resolve(.auto, device: metrics.totals(date: day, steps: 4_000), sources: sources,
                                           preferredPackage: nil, metrics: metrics, ignoreManualEntries: true, catalog: IOSCatalog.catalog)
        XCTAssertEqual(r.totals.steps, 4_000)
        XCTAssertEqual(r.manualStepsExcluded, 20_000)
    }

    func testAWatchWalkWithThePhoneOnADeskResolvesToTheWatch() {
        let watch = sample("com.apple.health.BBBB", t0 + 9 * h, t0 + 10 * h, 4_200, product: "Watch6,1", device: "Watch")
        let distance = sample("com.apple.health.BBBB", t0 + 9 * h, t0 + 10 * h, 3_100, kind: .distance, product: "Watch6,1", device: "Watch")
        let metrics = MetricsCalculator(config: StepTrackerConfig())
        let sources = HealthSources.build([watch, distance], options, clock: clock)
        let r = StepSourceResolver.resolve(.auto, device: metrics.totals(date: day, steps: 40), sources: sources,
                                           preferredPackage: nil, metrics: metrics, catalog: IOSCatalog.catalog)
        XCTAssertEqual(r.totals.steps, 4_200)
        XCTAssertEqual(r.kind, .watch)
        XCTAssertEqual(r.distanceSource, "healthkit")
        XCTAssertEqual(r.totals.distance, 3_100, accuracy: 0.01)
        // Calories are the package's formula, never Apple Health's energy.
        XCTAssertEqual(r.totals.calories, metrics.calories(4_200), accuracy: 0.001)
    }

    func testCountFromAndMidnightCutSamplesByTime() {
        var o = options
        o.countFromMs = t0 + 10 * h + 30 * 60_000
        let walk = sample("com.example.pedometer", t0 + 10 * h, t0 + 11 * h, 1_000)
        let overnight = sample("com.example.pedometer", t0 - h, t0 + h, 400)
        XCTAssertEqual(HealthSources.build([walk], o, clock: clock).first?.steps, 500)
        XCTAssertEqual(HealthSources.build([overnight], options, clock: clock).first?.steps, 200)
    }

    func testRecordsCarryTheHealthConnectShape() {
        var s = sample("com.apple.health.AAAA", t0, t0 + 60_000, 42, product: "iPhone15,2", device: "iPhone")
        s.syncIdentifier = "sync-1"
        s.syncVersion = 3
        s.timeZoneName = "Asia/Kolkata"
        let record = HealthSources.record(s)
        XCTAssertEqual(record.keys, ["recordType", "id", "clientRecordId", "clientRecordVersion", "packageName",
                                     "recordingMethod", "device", "startTime", "endTime", "startZoneOffsetSeconds",
                                     "endZoneOffsetSeconds", "lastModifiedTime", "count"])
        XCTAssertEqual(record["recordingMethod"], .string("automatic"))
        XCTAssertEqual(record["startZoneOffsetSeconds"], .int(19_800))
        XCTAssertEqual(record["device"]?["type"], .string("phone"))
        XCTAssertEqual(record["count"], .int(42))
        XCTAssertEqual(HealthSources.record(sample("x", t0, t0, 1, manual: true))["recordingMethod"], .string("manual"))
        XCTAssertEqual(HealthSources.record(sample("x", t0, t0, 1))["recordingMethod"], .string("unknown"))
    }

    func testTheFallbackMinutesAreThisIPhonesOnly() {
        let phone = sample("com.apple.health.AAAA", t0 + h, t0 + h + 120_000, 200, product: "iPhone15,2", device: "iPhone")
        let watch = sample("com.apple.health.BBBB", t0 + h, t0 + h + 60_000, 120, product: "Watch6,1", device: "Watch")
        let minutes = HealthSources.iPhoneMinutes([phone, watch], windows: [(t0, t0 + 24 * h)])
        XCTAssertEqual(minutes.values.reduce(0, +), 200)
        XCTAssertEqual(DayCounting.fromHealthMinutes(minutes).deviceSteps, 200)
    }
}

final class ConfigTests: XCTestCase {
    func testAPatchMovesOnlyItsKeysAndNestedGroupsKeyByKey() {
        let base = StepTrackerConfig().merging(.object([("fraudDetection", .object([("enabled", .bool(true)), ("maxCadenceSpm", .int(250))]))]))
        let patched = base.merging(.object([("fraudDetection", .object([("mode", .string("exclude"))])), ("height", .double(181.5))])).sanitised()
        XCTAssertTrue(patched.fraudDetectionEnabled)
        XCTAssertEqual(patched.fraudMaxCadenceSpm, 250)
        XCTAssertEqual(patched.fraudMode, "exclude")
        XCTAssertEqual(patched.heightCm, 181.5)
        XCTAssertEqual(patched.weightKg, 70)
    }

    func testClampingFollowsAndroid() {
        let c = StepTrackerConfig().merging(.object([
            ("height", .int(10)), ("fraudDetection", .object([("maxCadenceSpm", .int(50)), ("maxDailySteps", .int(0))])),
            ("healthConnectReadTypes", .strings(["distance", "nonsense"])), ("stepSource", .string("nope")),
        ])).sanitised()
        XCTAssertEqual(c.heightCm, 50)
        XCTAssertEqual(c.fraudMaxCadenceSpm, 100)
        XCTAssertEqual(c.fraudMaxDailySteps, 0)
        XCTAssertEqual(c.healthConnectReadTypes, ["steps", "distance"])
        XCTAssertEqual(c.stepSource, "auto")
    }

    func testStoredConfigRoundTripsKeysIOSDoesNotUse() {
        let c = StepTrackerConfig().merging(.object([
            ("notificationTitle", .string("{steps}")), ("gapRecovery", .string("drop")), ("accelerometerThreshold", .double(1.5)),
            ("healthConnectWriteGranularity", .string("minute")), ("preferredStepSourcePackage", .string("com.example")),
        ])).sanitised()
        let back = StepTrackerConfig.fromStore(JSON.parse(c.storeObject().serialized())!)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.jsObject(), c.jsObject())
        XCTAssertEqual(c.jsObject().keys.count, 43)
    }
}
