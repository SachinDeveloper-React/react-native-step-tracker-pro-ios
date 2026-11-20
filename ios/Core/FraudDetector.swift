import Foundation

/// What happens to steps a strong flag covers.
enum IntegrityMode: String {
    case flag, exclude
}

/// The thresholds a day is judged by; 0 turns a check off.
struct IntegrityRules: Equatable {
    static let defaultMaxCadenceSpm = 200
    static let defaultSteadyMinutes = 30
    static let defaultMaxContinuousMinutes = 180
    static let defaultMaxDailySteps = 50_000

    var maxCadenceSpm = IntegrityRules.defaultMaxCadenceSpm
    var steadyCadenceMinutes = IntegrityRules.defaultSteadyMinutes
    var maxContinuousMinutes = IntegrityRules.defaultMaxContinuousMinutes
    var maxDailySteps = IntegrityRules.defaultMaxDailySteps
    var flagWhileCharging = true

    func json() -> JSON {
        .object([
            ("maxCadenceSpm", .int(maxCadenceSpm)),
            ("steadyCadenceMinutes", .int(steadyCadenceMinutes)),
            ("maxContinuousMinutes", .int(maxContinuousMinutes)),
            ("maxDailySteps", .int(maxDailySteps)),
            ("flagWhileCharging", .bool(flagWhileCharging)),
        ])
    }
}

enum FlagSeverity: String {
    case strong, weak
}

/// One stretch of the day the detector found implausible.
struct IntegrityFlag: Equatable {
    static let cadence = "cadence"
    static let steadyCadence = "steady_cadence"
    static let continuous = "continuous"
    static let charging = "charging"
    static let inVehicle = "in_vehicle"
    static let activityStill = "activity_still"
    static let night = "night"
    static let shake = "shake"
    static let swing = "swing"
    static let dailyVolume = "daily_volume"

    var type: String
    var severity: FlagSeverity
    var from: Int64
    var to: Int64
    var steps: Int
    /// Ordered, so the signed evidence reads as Android's does.
    var evidence: [(String, JSON)] = []

    static func == (a: IntegrityFlag, b: IntegrityFlag) -> Bool {
        a.type == b.type && a.severity == b.severity && a.from == b.from && a.to == b.to
            && a.steps == b.steps && JSON.object(a.evidence) == JSON.object(b.evidence)
    }

    /// Stable across re-evaluations, so an event fires once per flag.
    var key: String { "\(type)@\(from)" }

    func evidenceValue(_ key: String) -> JSON? { evidence.first(where: { $0.0 == key })?.1 }

    func json() -> JSON {
        .object([
            ("type", .string(type)),
            ("severity", .string(severity.rawValue)),
            ("from", .int(from)),
            ("to", .int(to)),
            ("steps", .int(steps)),
            ("evidence", .object(evidence)),
        ])
    }

    init(type: String, severity: FlagSeverity, from: Int64, to: Int64, steps: Int, evidence: [(String, JSON)] = []) {
        self.type = type
        self.severity = severity
        self.from = from
        self.to = to
        self.steps = steps
        self.evidence = evidence
    }

    init?(json: JSON) {
        guard let type = json["type"]?.stringValue else { return nil }
        self.type = type
        severity = FlagSeverity(rawValue: json["severity"]?.stringValue ?? "") ?? .weak
        from = json["from"]?.int64Value ?? 0
        to = json["to"]?.int64Value ?? 0
        steps = json["steps"]?.intValue ?? 0
        if case let .object(pairs)? = json["evidence"] { evidence = pairs } else { evidence = [] }
    }
}

/// One window of accelerometer features. iOS records none - an app gets no
/// background accelerometer - but the detector keeps Android's rules for
/// them, so its verdict on the same inputs is the same.
struct MotionFeatures {
    var startedAt: Int64
    var durationMs: Int64
    var sampleCount: Int
    var dominantFrequencyHz: Double
    var variance: Double
    var zeroCrossingRate: Double
    var peakRatio: Double
    var stepsDuringWindow: Int
}

/// How the minutes being judged were measured.
enum MinuteResolution {
    /// Each minute's steps were counted in that minute: Android's sensor
    /// events, timed to the second.
    case exact
    /// Each minute is its share of a record that covers several - iOS
    /// history. The iPhone stores steps in records of 6 to 10 minutes, so a
    /// walk's minutes come back as that record's average: the minute-to-
    /// minute drift that tells a person from a machine, and the short rests
    /// that break a walk, are averaged away.
    case averaged
}

struct DayEvaluation {
    var flags: [IntegrityFlag]
    var flaggedSteps: Int
}

/// Judges a day of this device's own steps - the port of Android's
/// `FraudDetector`, rule for rule and threshold for threshold. Pure:
/// minutes, windows and rules in, flags out.
enum FraudDetector {
    static let activeMinuteSteps = 40
    static let steadyMaxDeltaSpm = 1
    private static let tagGapMinutes = 1
    static let vehicleStrongMinutes = 3
    static let nightMinRunMinutes = 30
    static let nightEndHour = 5
    static let shakeMinHz = 3.3
    static let shakeMinVariance = 20.0
    static let shakeMinPeakRatio = 0.25
    static let swingMinHz = 0.8
    static let swingMaxHz = 2.6
    static let swingMinPeakRatio = 0.42
    private static let minute = MinuteAttribution.minuteMs

    /// @param resolution `.averaged` on iOS: the two rules that read the
    ///   minute-to-minute shape of a walk - `steady_cadence` and
    ///   `continuous` - become weak, evidence for a server rather than
    ///   suspect steps, since averaged minutes make every steady walker
    ///   look like a machine and erase the pauses that end a run.
    static func evaluate(_ minutes: [MinuteSample], windows: [MotionFeatures], rules: IntegrityRules, clock: DayClock,
                         resolution: MinuteResolution = .exact) -> DayEvaluation {
        let sorted = minutes.filter { $0.totalSteps > 0 }.sorted { $0.minuteStart < $1.minuteStart }
        var byMinute: [Int64: MinuteSample] = [:]
        for m in sorted { byMinute[m.minuteStart] = m }
        var flags: [IntegrityFlag] = []
        var whole = Set<Int64>()
        var strongVehicle = Set<Int64>()

        cadence(sorted, rules, &flags, &whole)
        steady(sorted, rules, resolution, &flags, &whole)
        continuous(sorted, rules, resolution, &flags, &whole)
        if rules.flagWhileCharging {
            for run in tagged(sorted, { $0.chargingSteps }) {
                flags.append(tagFlag(IntegrityFlag.charging, .strong, run) { $0.chargingSteps })
            }
        }
        for run in tagged(sorted, { $0.vehicleSteps }) {
            let strong = spanMinutes(run) >= vehicleStrongMinutes
            if strong { run.forEach { strongVehicle.insert($0.minuteStart) } }
            flags.append(tagFlag(IntegrityFlag.inVehicle, strong ? .strong : .weak, run) { $0.vehicleSteps })
        }
        for run in tagged(sorted, { $0.stillSteps }) {
            flags.append(tagFlag(IntegrityFlag.activityStill, .weak, run) { $0.stillSteps })
        }
        night(sorted, clock, &flags)
        motionWindows(windows, byMinute, &flags, &whole)

        var flagged = 0
        for m in sorted {
            var suspect = whole.contains(m.minuteStart) ? m.steps : 0
            if rules.flagWhileCharging { suspect = max(suspect, m.chargingSteps) }
            if strongVehicle.contains(m.minuteStart) { suspect = max(suspect, m.vehicleSteps) }
            flagged += min(suspect, m.totalSteps)
        }
        let ordered = flags.enumerated().sorted { a, b in
            if a.element.from != b.element.from { return a.element.from < b.element.from }
            if a.element.type != b.element.type { return a.element.type < b.element.type }
            return a.offset < b.offset
        }.map(\.element)
        return DayEvaluation(flags: ordered, flaggedSteps: flagged)
    }

    /// Strong minute flags plus whatever the rest of the day exceeds the cap by.
    static func suspectSteps(flaggedSteps: Int, deviceSteps: Int, rules: IntegrityRules) -> Int {
        let device = max(0, deviceSteps)
        let flagged = min(max(flaggedSteps, 0), device)
        let excess = rules.maxDailySteps > 0 ? max(0, device - flagged - rules.maxDailySteps) : 0
        return flagged + excess
    }

    static func dailyVolumeFlag(flaggedSteps: Int, deviceSteps: Int, rules: IntegrityRules, dayStart: Int64, dayEnd: Int64) -> IntegrityFlag? {
        let excess = suspectSteps(flaggedSteps: flaggedSteps, deviceSteps: deviceSteps, rules: rules)
            - min(max(flaggedSteps, 0), max(deviceSteps, 0))
        guard excess > 0 else { return nil }
        return IntegrityFlag(type: IntegrityFlag.dailyVolume, severity: .strong, from: dayStart, to: dayEnd, steps: excess,
                             evidence: [("deviceSteps", .int(deviceSteps)), ("limit", .int(rules.maxDailySteps))])
    }

    static func classifyWindow(_ w: MotionFeatures) -> String? {
        guard w.stepsDuringWindow > 0 else { return nil }
        if w.dominantFrequencyHz >= shakeMinHz && w.variance >= shakeMinVariance && w.peakRatio >= shakeMinPeakRatio {
            return IntegrityFlag.shake
        }
        if w.dominantFrequencyHz >= swingMinHz && w.dominantFrequencyHz <= swingMaxHz && w.peakRatio >= swingMinPeakRatio {
            return IntegrityFlag.swing
        }
        return nil
    }

    // ---- the checks ----------------------------------------------------------

    private static func cadence(_ sorted: [MinuteSample], _ rules: IntegrityRules, _ flags: inout [IntegrityFlag], _ whole: inout Set<Int64>) {
        guard rules.maxCadenceSpm > 0 else { return }
        for run in adjacentRuns(sorted.filter { $0.steps > rules.maxCadenceSpm }) {
            run.forEach { whole.insert($0.minuteStart) }
            flags.append(IntegrityFlag(
                type: IntegrityFlag.cadence, severity: .strong,
                from: run.first!.minuteStart, to: run.last!.minuteStart + minute,
                steps: run.reduce(0) { $0 + $1.steps },
                evidence: [("minutes", .int(run.count)),
                           ("peakSpm", .int(run.map(\.steps).max() ?? 0)),
                           ("limitSpm", .int(rules.maxCadenceSpm))]))
        }
    }

    private static func steady(_ sorted: [MinuteSample], _ rules: IntegrityRules, _ resolution: MinuteResolution,
                               _ flags: inout [IntegrityFlag], _ whole: inout Set<Int64>) {
        let exact = resolution == .exact
        guard rules.steadyCadenceMinutes > 0 else { return }
        for run in activeRuns(sorted) {
            var start = 0
            for i in 1...run.count {
                let breaks = i == run.count || abs(run[i].steps - run[i - 1].steps) > steadyMaxDeltaSpm
                if !breaks { continue }
                let span = Array(run[start..<i])
                if span.count >= rules.steadyCadenceMinutes {
                    if exact { span.forEach { whole.insert($0.minuteStart) } }
                    let sum = span.reduce(0) { $0 + $1.steps }
                    var evidence: [(String, JSON)] = [("minutes", .int(span.count)),
                                                      ("meanSpm", .double(round1(Double(sum) / Double(span.count)))),
                                                      ("minSpm", .int(span.map(\.steps).min() ?? 0)),
                                                      ("maxSpm", .int(span.map(\.steps).max() ?? 0))]
                    if !exact { evidence.append(("minuteData", .string("averaged"))) }
                    flags.append(IntegrityFlag(
                        type: IntegrityFlag.steadyCadence, severity: exact ? .strong : .weak,
                        from: span.first!.minuteStart, to: span.last!.minuteStart + minute, steps: sum,
                        evidence: evidence))
                }
                start = i
            }
        }
    }

    private static func continuous(_ sorted: [MinuteSample], _ rules: IntegrityRules, _ resolution: MinuteResolution,
                                   _ flags: inout [IntegrityFlag], _ whole: inout Set<Int64>) {
        let limit = rules.maxContinuousMinutes
        guard limit > 0 else { return }
        let exact = resolution == .exact
        for run in activeRuns(sorted) where run.count > limit {
            let excess = Array(run[limit...])
            if exact { excess.forEach { whole.insert($0.minuteStart) } }
            var evidence: [(String, JSON)] = [("runMinutes", .int(run.count)), ("limitMinutes", .int(limit)),
                                              ("runStartedAt", .int(run.first!.minuteStart))]
            if !exact { evidence.append(("minuteData", .string("averaged"))) }
            flags.append(IntegrityFlag(
                type: IntegrityFlag.continuous, severity: exact ? .strong : .weak,
                from: excess.first!.minuteStart, to: excess.last!.minuteStart + minute,
                steps: excess.reduce(0) { $0 + $1.steps }, evidence: evidence))
        }
    }

    private static func night(_ sorted: [MinuteSample], _ clock: DayClock, _ flags: inout [IntegrityFlag]) {
        for run in activeRuns(sorted) where run.count >= nightMinRunMinutes {
            let hour = clock.hour(ofMs: run.first!.minuteStart)
            if hour >= nightEndHour { continue }
            flags.append(IntegrityFlag(
                type: IntegrityFlag.night, severity: .weak,
                from: run.first!.minuteStart, to: run.last!.minuteStart + minute,
                steps: run.reduce(0) { $0 + $1.steps },
                evidence: [("minutes", .int(run.count)), ("startHour", .int(hour))]))
        }
    }

    private static func motionWindows(_ windows: [MotionFeatures], _ byMinute: [Int64: MinuteSample], _ flags: inout [IntegrityFlag], _ whole: inout Set<Int64>) {
        for window in windows.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard let type = classifyWindow(window) else { continue }
            let end = window.startedAt + max(1, window.durationMs)
            var covered: [Int64] = []
            var m = MinuteAttribution.minuteOf(window.startedAt)
            while m < end {
                covered.append(m)
                m += minute
            }
            let minuteSteps = covered.reduce(0) { $0 + (byMinute[$1]?.steps ?? 0) }
            let strong = type == IntegrityFlag.shake
            if strong { covered.filter { byMinute[$0] != nil }.forEach { whole.insert($0) } }
            flags.append(IntegrityFlag(
                type: type, severity: strong ? .strong : .weak, from: window.startedAt, to: end,
                steps: minuteSteps > 0 ? minuteSteps : window.stepsDuringWindow,
                evidence: [("dominantFrequencyHz", .double(window.dominantFrequencyHz)),
                           ("variance", .double(round1(window.variance))),
                           ("peakRatio", .double(round3(window.peakRatio))),
                           ("zeroCrossingRate", .double(round1(window.zeroCrossingRate))),
                           ("stepsDuringWindow", .int(window.stepsDuringWindow))]))
        }
    }

    // ---- grouping --------------------------------------------------------------

    private static func adjacentRuns(_ minutes: [MinuteSample], gapMinutes: Int64 = 0) -> [[MinuteSample]] {
        var runs: [[MinuteSample]] = []
        var current: [MinuteSample] = []
        for m in minutes {
            if let last = current.last, m.minuteStart - last.minuteStart > minute * (1 + gapMinutes) {
                runs.append(current)
                current = []
            }
            current.append(m)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func activeRuns(_ sorted: [MinuteSample]) -> [[MinuteSample]] {
        adjacentRuns(sorted.filter { $0.steps >= activeMinuteSteps && $0.untimedSteps == 0 })
    }

    private static func tagged(_ sorted: [MinuteSample], _ count: (MinuteSample) -> Int) -> [[MinuteSample]] {
        adjacentRuns(sorted.filter { count($0) > 0 }, gapMinutes: Int64(tagGapMinutes))
    }

    private static func spanMinutes(_ run: [MinuteSample]) -> Int {
        Int((run.last!.minuteStart - run.first!.minuteStart) / minute) + 1
    }

    private static func tagFlag(_ type: String, _ severity: FlagSeverity, _ run: [MinuteSample], _ count: (MinuteSample) -> Int) -> IntegrityFlag {
        IntegrityFlag(type: type, severity: severity, from: run.first!.minuteStart, to: run.last!.minuteStart + minute,
                      steps: run.reduce(0) { $0 + count($1) }, evidence: [("minutes", .int(spanMinutes(run)))])
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded(.toNearestOrAwayFromZero) / 10 }
    private static func round3(_ v: Double) -> Double { (v * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }
}
