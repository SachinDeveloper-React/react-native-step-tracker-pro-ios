import XCTest
@testable import StepTrackerProCore

/// Android's FraudDetectorTest, input for input and assertion for assertion.
final class FraudDetectorTests: XCTestCase {
    let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let rules = IntegrityRules()
    let minute: Int64 = 60_000
    /// 2026-09-14T10:00Z and 01:00Z.
    let morning: Int64 = 1_789_380_000_000
    let night: Int64 = 1_789_347_600_000

    func minutes(_ start: Int64, _ counts: [Int], tag: (Int, MinuteSample, Int) -> MinuteSample = { _, m, _ in m }) -> [MinuteSample] {
        counts.enumerated().map { i, c in tag(i, MinuteSample(minuteStart: start + Int64(i) * minute, steps: c), c) }
    }

    /// The same 64-bit LCG as the Kotlin test, wrapping and unsigned-shifted.
    func humanWalk(_ n: Int, base: Int = 110, seed: Int64 = 3) -> [Int] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let shifted = Int64(bitPattern: UInt64(bitPattern: s) >> 33)
            return base + Int(shifted % 9) - 4
        }
    }

    func evaluate(_ m: [MinuteSample], _ w: [MotionFeatures] = [], _ r: IntegrityRules? = nil) -> DayEvaluation {
        FraudDetector.evaluate(m, windows: w, rules: r ?? rules, clock: clock)
    }

    func testFixturesAreTheKotlinInstants() {
        XCTAssertEqual(clock.key(ms: morning), "2026-09-14")
        XCTAssertEqual(clock.hour(ofMs: morning), 10)
        XCTAssertEqual(clock.hour(ofMs: night), 1)
    }

    func testAnOrdinaryWalkRaisesNothing() {
        let result = evaluate(minutes(morning, humanWalk(60)))
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(result.flaggedSteps, 0)
    }

    func testATreadmillSessionIsLeftAlone() {
        let counts = (0..<45).map { 118 + ($0 * 7 % 4) }
        XCTAssertFalse(evaluate(minutes(morning, counts)).flags.contains { $0.type == IntegrityFlag.steadyCadence })
    }

    func testASwingGadgetIsSteadyCadence() {
        let counts = (0..<90).map { $0 % 2 == 0 ? 110 : 111 }
        let result = evaluate(minutes(morning, counts))
        let flags = result.flags.filter { $0.type == IntegrityFlag.steadyCadence }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].severity, .strong)
        XCTAssertEqual(flags[0].evidenceValue("minutes"), .int(90))
        XCTAssertEqual(result.flaggedSteps, counts.reduce(0, +))
    }

    func testASteadyStretchShorterThanTheRuleIsNotAMachine() {
        let counts = humanWalk(20, base: 130) + Array(repeating: 110, count: 29) + humanWalk(20, base: 130, seed: 9)
        XCTAssertFalse(evaluate(minutes(morning, counts)).flags.contains { $0.type == IntegrityFlag.steadyCadence })
    }

    func testMinutesFasterThanAnyoneAreFlaggedARunIsNot() {
        XCTAssertFalse(evaluate(minutes(morning, Array(repeating: 172, count: 30))).flags.contains { $0.type == IntegrityFlag.cadence })
        let result = evaluate(minutes(morning, [110, 260, 280, 115]))
        let flags = result.flags.filter { $0.type == IntegrityFlag.cadence }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].from, morning + minute)
        XCTAssertEqual(flags[0].to, morning + 3 * minute)
        XCTAssertEqual(flags[0].evidenceValue("peakSpm"), .int(280))
        XCTAssertEqual(result.flaggedSteps, 540)
    }

    func testUntimedLumpsNeverCount() {
        let result = evaluate([MinuteSample(minuteStart: morning, steps: 0, untimedSteps: 5_000)])
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(result.flaggedSteps, 0)
    }

    func testWalkingPastTheContinuousLimitFlagsOnlyTheExcess() {
        let counts = humanWalk(200)
        let result = evaluate(minutes(morning, counts))
        let flags = result.flags.filter { $0.type == IntegrityFlag.continuous }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].from, morning + 180 * minute)
        XCTAssertEqual(flags[0].steps, counts.dropFirst(180).reduce(0, +))
        XCTAssertEqual(result.flaggedSteps, flags[0].steps)
    }

    func testAPauseResetsTheContinuousClock() {
        let counts = humanWalk(120) + [12] + humanWalk(120, seed: 5)
        XCTAssertFalse(evaluate(minutes(morning, counts)).flags.contains { $0.type == IntegrityFlag.continuous })
    }

    func testChargingStepsAreFlaggedAndOnlyThose() {
        let m = minutes(morning, Array(repeating: 100, count: 10)) { i, s, c in
            var s = s
            if (3...5).contains(i) { s.chargingSteps = c }
            return s
        }
        let result = evaluate(m)
        let flags = result.flags.filter { $0.type == IntegrityFlag.charging }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].steps, 300)
        XCTAssertEqual(result.flaggedSteps, 300)
        var off = rules
        off.flagWhileCharging = false
        XCTAssertEqual(evaluate(m, [], off).flaggedSteps, 0)
    }

    func testACarRideIsStrongABusStopIsWeak() {
        let vehicle: (Int, MinuteSample, Int) -> MinuteSample = { _, s, c in var s = s; s.vehicleSteps = c; return s }
        let strong = evaluate(minutes(morning, Array(repeating: 30, count: 6), tag: vehicle))
        XCTAssertEqual(strong.flags.first { $0.type == IntegrityFlag.inVehicle }?.severity, .strong)
        XCTAssertEqual(strong.flaggedSteps, 180)
        let weak = evaluate(minutes(morning, [30], tag: vehicle))
        XCTAssertEqual(weak.flags.count, 1)
        XCTAssertEqual(weak.flags[0].severity, .weak)
        XCTAssertEqual(weak.flaggedSteps, 0)
    }

    func testALongWalkInTheSmallHoursIsNotedNotCounted() {
        let result = evaluate(minutes(night, humanWalk(40)))
        let flags = result.flags.filter { $0.type == IntegrityFlag.night }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].severity, .weak)
        XCTAssertEqual(result.flaggedSteps, 0)
    }

    func window(_ at: Int64, _ hz: Double, _ variance: Double, _ peak: Double, steps: Int = 20) -> MotionFeatures {
        MotionFeatures(startedAt: at, durationMs: 10_000, sampleCount: 250, dominantFrequencyHz: hz, variance: variance,
                       zeroCrossingRate: hz * 2, peakRatio: peak, stepsDuringWindow: steps)
    }

    func testAShakenWindowCondemnsItsMinuteARunsDoesNot() {
        let m = minutes(morning, [120, 150, 120])
        let result = evaluate(m, [window(morning + minute + 5_000, 4.0, 31.9, 0.5)])
        let flags = result.flags.filter { $0.type == IntegrityFlag.shake }
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags[0].severity, .strong)
        XCTAssertEqual(flags[0].steps, 150)
        XCTAssertEqual(result.flaggedSteps, 150)
        XCTAssertNil(FraudDetector.classifyWindow(window(morning + minute + 5_000, 5.5, 25.0, 0.19)))
        XCTAssertNil(FraudDetector.classifyWindow(window(morning, 4.0, 31.9, 0.5, steps: 0)))
    }

    func testAPureToneAtWalkingPaceIsAWeakSwing() {
        let result = evaluate(minutes(morning, [110]), [window(morning + 1_000, 1.8, 12.0, 0.5)])
        XCTAssertEqual(result.flags.count, 1)
        XCTAssertEqual(result.flags[0].type, IntegrityFlag.swing)
        XCTAssertEqual(result.flags[0].severity, .weak)
        XCTAssertEqual(result.flaggedSteps, 0)
    }

    func testAMinuteCoveredBySeveralFlagsIsCountedOnce() {
        let m = minutes(morning, [260]) { _, s, c in var s = s; s.chargingSteps = c; return s }
        let result = evaluate(m)
        XCTAssertEqual(result.flags.count, 2)
        XCTAssertEqual(result.flaggedSteps, 260)
    }

    func testTheDailyCapTakesTheExcessOfWhatIsLeft() {
        XCTAssertEqual(FraudDetector.suspectSteps(flaggedSteps: 0, deviceSteps: 49_000, rules: rules), 0)
        XCTAssertEqual(FraudDetector.suspectSteps(flaggedSteps: 0, deviceSteps: 60_000, rules: rules), 10_000)
        XCTAssertEqual(FraudDetector.suspectSteps(flaggedSteps: 8_000, deviceSteps: 60_000, rules: rules), 10_000)
        var off = rules
        off.maxDailySteps = 0
        XCTAssertEqual(FraudDetector.suspectSteps(flaggedSteps: 0, deviceSteps: 90_000, rules: off), 0)
        XCTAssertEqual(FraudDetector.suspectSteps(flaggedSteps: 900, deviceSteps: 500, rules: rules), 500)
        let flag = FraudDetector.dailyVolumeFlag(flaggedSteps: 8_000, deviceSteps: 60_000, rules: rules, dayStart: 0, dayEnd: 1)
        XCTAssertEqual(flag?.type, IntegrityFlag.dailyVolume)
        XCTAssertEqual(flag?.steps, 2_000)
        XCTAssertNil(FraudDetector.dailyVolumeFlag(flaggedSteps: 0, deviceSteps: 10_000, rules: rules, dayStart: 0, dayEnd: 1))
    }

    func testACheckSetToZeroIsOff() {
        let off = IntegrityRules(maxCadenceSpm: 0, steadyCadenceMinutes: 0, maxContinuousMinutes: 0, maxDailySteps: 0, flagWhileCharging: false)
        let m = minutes(morning, Array(repeating: 300, count: 300)) { _, s, c in var s = s; s.chargingSteps = c; return s }
        XCTAssertEqual(evaluate(m, [], off).flaggedSteps, 0)
        XCTAssertFalse(evaluate(m, [], off).flags.contains { $0.severity == .strong })
    }

    func testFlagsSurviveAJSONRoundTripForStorage() {
        let flags = evaluate(minutes(morning, Array(repeating: 110, count: 40))).flags
        XCTAssertFalse(flags.isEmpty)
        let text = JSON.array(flags.map { $0.json() }).serialized()
        let back = (JSON.parse(text)?.arrayValue ?? []).compactMap(IntegrityFlag.init(json:))
        XCTAssertEqual(flags.map(\.key), back.map(\.key))
        XCTAssertEqual(flags.map(\.steps), back.map(\.steps))
        XCTAssertEqual(flags[0].evidenceValue("minutes"), back[0].evidenceValue("minutes"))
        XCTAssertNil(JSON.parse("not json"))
    }
}
