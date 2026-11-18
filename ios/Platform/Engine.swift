import CoreMotion
import Foundation
import HealthKit

/// Owns every piece of state, on one serial queue. HealthKit and CoreMotion
/// callbacks hop onto it; nothing on it waits for the main thread except
/// short UIKit reads, and the main thread never waits for it.
final class Engine {
    static let shared = Engine()

    let queue = DispatchQueue(label: "com.steptrackerpro.ios.engine", qos: .userInitiated)
    let motion = MotionSource()
    let health = HealthSource()
    private(set) var store: Store!
    var state = EngineState()
    var config = StepTrackerConfig()
    var events: [IntegrityEvent] = []
    var emitter: ((String, JSON) -> Void)?
    var emitterOwner: ObjectIdentifier?
    /// Uptime of the last weekly/monthly goal check: once a minute is plenty.
    var lastPeriodGoalCheck: Int64 = -1_000_000
    private var booted = false

    // Caches, in memory only.
    var hourCache: [String: BucketCount] = [:]
    var lastFull: (date: String, at: Int64, record: DayRecord)?
    var sourceCache: [String: (at: Int64, list: [StepSource])] = [:]
    var grantCache: (at: Int64, value: Grants)?
    var charging = false
    /// What an Apple device's samples said it was, for sources known only by totals.
    var learnedKinds: [String: StepSourceKind] = [:]
    var currentActivity: ActivitySample?
    var lastEventUptime: Int64 = -1_000_000
    var trailingQueued = false
    var liveDate: String?
    var midnightTimer: DispatchSourceTimer?
    var lastStatusFingerprint: String?

    struct Grants: Equatable {
        /// The sheet was answered.
        var requested: Bool
        var steps: Bool
        var distance: Bool
    }

    var clock: DayClock { DayClock() }
    var metrics: MetricsCalculator { MetricsCalculator(config: config) }
    var nowMs: Int64 { DeviceInfo.nowMs() }
    var uptimeMs: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    // ---- start-up --------------------------------------------------------------------------

    static let installMarker = "com.steptrackerpro.ios.installed"

    /// On the queue, before anything else touches state.
    func bootIfNeeded() {
        guard !booted else { return }
        booted = true
        store = Store()
        // Keychain items survive an uninstall; this package's files and
        // defaults do not. A missing marker with no state file is a fresh
        // install: what an earlier install left in the Keychain goes. Not
        // judged before the first unlock, when the defaults cannot be read.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Engine.installMarker) && !store.stateExists && DeviceInfo.protectedDataAvailable {
            Attestation.wipeLeftovers()
        }
        if DeviceInfo.protectedDataAvailable || store.stateExists { defaults.set(true, forKey: Engine.installMarker) }

        state = store.loadState() ?? EngineState()
        if let stored = store.loadConfig() { config = StepTrackerConfig.fromStore(stored) }
        config.remoteSyncHeaders = Attestation.loadHeaders()
        events = store.events()
        if state.lastBootOffsetMs == 0 { state.lastBootOffsetMs = DeviceInfo.bootOffsetMs }
        if state.lastTimeZone == nil { state.lastTimeZone = TimeZone.current.identifier }
        if state.lastDate == nil { state.lastDate = clock.today() }
        saveState()
        Lifecycle.install(self)
    }

    func saveState() { store.saveState(state) }

    func emit(_ name: String, _ payload: JSON) {
        emitter?(name, payload)
    }

    // ---- integrity events ---------------------------------------------------------------------

    func log(_ type: String, _ detail: JSON = .object([]), force: Bool = false) {
        guard force || config.fraudDetectionEnabled else { return }
        events.append(IntegrityEvent(at: nowMs, type: type, detail: detail))
        let cutoff = clock.startOfDayMs(clock.minusDays(clock.today(), config.historyRetentionDays))
        events.removeAll { $0.at < cutoff }
        store.saveEvents(events)
    }

    func events(from: Int64, to: Int64) -> [IntegrityEvent] { events.filter { $0.at >= from && $0.at <= to } }

    // ---- counting ----------------------------------------------------------------------------------

    /// A day too old for retention, or before `clearHistory()`, is gone.
    func isGone(_ date: String) -> Bool {
        let today = clock.today()
        if let cleared = state.clearedBefore, date < cleared { return true }
        return date < clock.minusDays(today, config.historyRetentionDays)
    }

    /// The stretches of [date] this phone counted: tracking spans, cut by
    /// countFrom and by a `resetToday()`.
    func countingWindows(_ date: String, until: Int64) -> [(Int64, Int64)] {
        let c = clock
        var floor = c.startOfDayMs(date)
        if state.countFromAt > 0 { floor = max(floor, state.countFromAt) }
        if let reset = state.resetAt[date] { floor = max(floor, reset) }
        return TrackingSpans.windows(state.spans, from: floor, to: min(c.endOfDayExclusiveMs(date), until))
    }

    /// Where today's coverage began, when not at midnight: the first
    /// `startTracking()` on the install day, a countFrom, a reset.
    func coverageStart(_ date: String) -> Int64 {
        let c = clock
        let start = c.startOfDayMs(date)
        var coverage = start
        if state.firstStartAt > 0 && c.key(ms: state.firstStartAt) == date { coverage = max(coverage, state.firstStartAt) }
        if state.countFromAt > 0 && c.key(ms: state.countFromAt) == date { coverage = max(coverage, state.countFromAt) }
        if let reset = state.resetAt[date] { coverage = max(coverage, reset) }
        return coverage > start ? coverage : 0
    }

    static let closeGraceMs: Int64 = 10 * 60_000
    static let pedometerDays = 7

    func emptyRecord(_ date: String) -> DayRecord {
        DayRecord(date: date, deviceSteps: 0, gatedSteps: 0, minutes: [], sensor: "pedometer", computedAt: nowMs, final: false)
    }

    /// This phone's own count for [date]: a closed day as first computed
    /// after it closed, an open one recomputed from the pedometer, an old
    /// one never computed from Apple Health's record of this iPhone.
    func deviceDay(_ date: String, quick: Bool = false) -> DayRecord {
        let c = clock
        let now = nowMs
        let today = c.today()
        if date > today || isGone(date) { return emptyRecord(date) }
        let stored = store.day(date)
        if let stored, stored.final { return stored }
        let reach = c.startOfDayMs(c.minusDays(today, Engine.pedometerDays - 1))
        let dayStart = c.startOfDayMs(date)
        if dayStart >= reach && motion.pedometerAvailable && motion.authorized {
            if quick, date == today, let last = lastFull, last.date == date, now - last.at < 60_000 {
                return quickToday(last.record)
            }
            if let record = pedometerDay(date, previous: stored) {
                return record
            }
            return stored ?? emptyRecord(date)
        }
        if let stored { return stored }
        if dayStart < reach { return healthFallbackDay(date) ?? emptyRecord(date) }
        return emptyRecord(date)
    }

    /// The last full count with a fresh total: the minutes and the gate's
    /// verdict from up to a minute ago, the total as of now.
    private func quickToday(_ last: DayRecord) -> DayRecord {
        let windows = countingWindows(last.date, until: nowMs)
        let totals = motion.steps(windows)
        guard !totals.contains(where: { $0 == nil }) else { return last }
        var record = last
        record.deviceSteps = totals.reduce(0) { $0 + ($1 ?? 0) }
        // New steps since the full count are not in a minute yet; they are
        // in the count, and the next full count places them.
        return record
    }

    func pedometerDay(_ date: String, previous: DayRecord?) -> DayRecord? {
        let c = clock
        let now = nowMs
        let dayEnd = c.endOfDayExclusiveMs(date)
        let windows = countingWindows(date, until: now)
        let totals = motion.steps(windows)
        if totals.contains(where: { $0 == nil }) { return nil }
        var counts: [WindowCount] = []
        let settled = now - 2 * DayClock.hourMs
        for (i, w) in windows.enumerated() {
            let hourSpans = TrackingSpans.hours(from: w.0, to: w.1, clock: c)
            var hours = [BucketCount?](repeating: nil, count: hourSpans.count)
            var needed: [Int] = []
            for (j, h) in hourSpans.enumerated() {
                if h.1 <= settled, let cached = hourCache["\(h.0)-\(h.1)"] { hours[j] = cached } else { needed.append(j) }
            }
            let hourTotals = motion.steps(needed.map { hourSpans[$0] })
            if hourTotals.contains(where: { $0 == nil }) { return nil }
            for (k, j) in needed.enumerated() {
                let h = hourSpans[j]
                var bucket = BucketCount(startMs: h.0, endMs: h.1, total: hourTotals[k] ?? 0)
                if bucket.total > 0 {
                    let minuteSpans = TrackingSpans.minutes(from: h.0, to: h.1)
                    let minuteTotals = motion.steps(minuteSpans)
                    if minuteTotals.contains(where: { $0 == nil }) { return nil }
                    bucket.minutes = zip(minuteSpans, minuteTotals).map { BucketCount(startMs: $0.0, endMs: $0.1, total: $1 ?? 0) }
                }
                if h.1 <= settled { hourCache["\(h.0)-\(h.1)"] = bucket }
                hours[j] = bucket
            }
            counts.append(WindowCount(startMs: w.0, endMs: w.1, total: totals[i] ?? 0, hours: hours.compactMap { $0 }))
        }
        let count = DayCounting.build(windows: counts, activity: activityFor(date, counts: counts, until: min(dayEnd, now)),
                                      charging: chargingSpans(until: now),
                                      activityTags: config.fraudDetectionEnabled && config.fraudActivityRecognition)
        var record = DayRecord(date: date, deviceSteps: count.deviceSteps, gatedSteps: count.gatedSteps, minutes: count.minutes,
                               sensor: "pedometer", computedAt: now, final: now >= dayEnd + Engine.closeGraceMs)
        record.sourcesJSON = previous?.sourcesJSON
        evaluate(&record)
        if !isGone(date) { store.saveDay(record) }
        if date == c.today() { lastFull = (date, now, record) }
        return record
    }

    /// The motion coprocessor's verdict per minute with steps, when the gate
    /// or the integrity tags want it.
    private func activityFor(_ date: String, counts: [WindowCount], until: Int64) -> [Int64: MinuteActivity] {
        guard config.wantsActivity, motion.activityAvailable, motion.authorized else { return [:] }
        var minutes: [Int64] = []
        for w in counts {
            for h in w.hours where h.total > 0 {
                minutes += h.minutes.filter { $0.total > 0 }.map { DayClock.minuteOf($0.startMs) }
            }
        }
        guard !minutes.isEmpty else { return [:] }
        let from = clock.startOfDayMs(date) - ActivityGate.vehicleMaxMs
        guard let acts = motion.activities(from: from, to: until) else { return [:] }
        if date == clock.today() { noteActivity(acts.last(where: { $0.informative })) }
        return ActivityGate.classify(minutes: minutes, activities: acts, untilMs: until, gateEnabled: config.motionGateEnabled)
    }

    func noteActivity(_ latest: ActivitySample?) {
        let previous = currentActivity?.state ?? .unknown
        currentActivity = latest
        let now = latest?.state ?? .unknown
        if now != previous && config.fraudActivityRecognition {
            log(IntegrityEvent.activityChanged, .object([("activity", .string(now.rawValue))]))
        }
    }

    func chargingSpans(until: Int64) -> [(Int64, Int64)] {
        state.chargingSpans.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1] == 0 ? until : pair[1])
        }
    }

    /// The fallback for a day older than the pedometer remembers that was
    /// never computed: this iPhone's own samples in Apple Health, untagged.
    func healthFallbackDay(_ date: String) -> DayRecord? {
        let c = clock
        let windows = countingWindows(date, until: nowMs)
        guard !windows.isEmpty else {
            var record = emptyRecord(date)
            record.final = true
            store.saveDay(record)
            return record
        }
        guard health.available, HealthSource.missingDeclaration == nil,
              case let .success(samples) = health.samples(.steps, from: c.startOfDayMs(date), to: c.endOfDayExclusiveMs(date)) else {
            return nil
        }
        let count = DayCounting.fromHealthMinutes(HealthSources.iPhoneMinutes(samples, windows: windows))
        var record = DayRecord(date: date, deviceSteps: count.deviceSteps, gatedSteps: 0, minutes: count.minutes,
                               sensor: "healthkit", computedAt: nowMs, final: true)
        evaluate(&record)
        store.saveDay(record)
        log(IntegrityEvent.sensorChanged, .object([("from", .string("pedometer")), ("to", .string("healthkit")), ("date", .string(date))]))
        return record
    }

    /// Judges the day, stores the verdict, and announces flags not seen before.
    func evaluate(_ record: inout DayRecord) {
        guard config.fraudDetectionEnabled else {
            record.flagsJSON = nil
            record.flaggedSteps = 0
            record.evaluatedAt = 0
            return
        }
        let c = clock
        let rules = config.integrityRules()
        let evaluation = FraudDetector.evaluate(record.minutes, windows: [], rules: rules, clock: c)
        var flags = evaluation.flags
        if let volume = FraudDetector.dailyVolumeFlag(flaggedSteps: evaluation.flaggedSteps, deviceSteps: record.deviceSteps, rules: rules,
                                                      dayStart: c.startOfDayMs(record.date), dayEnd: c.endOfDayExclusiveMs(record.date)) {
            flags.append(volume)
        }
        record.flagsJSON = JSON.array(flags.map { $0.json() }).serialized()
        record.flaggedSteps = evaluation.flaggedSteps
        record.evaluatedAt = nowMs
        let known = Set(state.reportedFlags[record.date] ?? [])
        let fresh = flags.filter { !known.contains($0.key) }
        guard !fresh.isEmpty else { return }
        state.reportedFlags[record.date] = Array(known.union(fresh.map(\.key))).sorted()
        let keep = clock.minusDays(clock.today(), Engine.pedometerDays + 1)
        state.reportedFlags = state.reportedFlags.filter { $0.key >= keep }
        saveState()
        emit("suspiciousActivity", .object([
            ("date", .string(record.date)),
            ("flags", .array(fresh.map { $0.json() })),
            ("deviceSteps", .int(record.deviceSteps)),
            ("suspectSteps", .int(FraudDetector.suspectSteps(flaggedSteps: record.flaggedSteps, deviceSteps: record.deviceSteps, rules: rules))),
            ("mode", .string(config.fraudMode)),
        ]))
    }

    // ---- integrity arithmetic ------------------------------------------------------------------

    func suspect(_ record: DayRecord) -> Int {
        guard config.fraudDetectionEnabled else { return 0 }
        return FraudDetector.suspectSteps(flaggedSteps: record.flaggedSteps, deviceSteps: record.deviceSteps, rules: config.integrityRules())
    }

    /// Android's `adjusted`: the gate's steps always out, flagged ones under exclude.
    func adjusted(_ day: DayTotals, suspect: Int, excluded: Int) -> DayTotals {
        let gated = min(max(day.gatedSteps, 0), day.steps)
        let out = min(max(excluded, 0) + gated, day.steps)
        var copy = day
        copy.suspectSteps = suspect
        guard out > 0 else { return copy }
        let kept = day.steps - out
        copy.steps = kept
        copy.distance = metrics.distance(kept)
        copy.calories = metrics.calories(kept)
        copy.recoveredSteps = min(day.recoveredSteps, kept)
        copy.gatedSteps = gated
        return copy
    }

    func rawTotals(_ record: DayRecord) -> DayTotals {
        metrics.totals(date: record.date, steps: record.deviceSteps, gatedSteps: record.gatedSteps)
    }

    // ---- Apple Health ---------------------------------------------------------------------------

    var readKinds: [HealthSample.Kind] {
        config.healthConnectReadTypes.contains("distance") ? [.steps, .distance] : [.steps]
    }

    /// What Apple Health lets this app read. HealthKit never says whether a
    /// read was refused, so: the sheet must have been answered; then a
    /// type counts as granted unless this iPhone's pedometer has data for
    /// the last week while Apple Health returns none from any source -
    /// which is what a refused read looks like.
    func grants(fresh: Bool = false) -> Grants {
        if !fresh, let cached = grantCache, nowMs - cached.at < 5 * 60_000 { return cached.value }
        var value = Grants(requested: false, steps: false, distance: false)
        if health.available, HealthSource.missingDeclaration == nil, health.requestStatus(readKinds) == .unnecessary {
            value.requested = true
            let recent = motion.authorized ? motion.recentTotals() : nil
            value.steps = !(health.hasRecentSample(.steps) == false && (recent?.steps ?? 0) > 0)
            if readKinds.contains(.distance) {
                value.distance = value.steps && !(health.hasRecentSample(.distance) == false && (recent?.distance ?? 0) > 0)
            }
        }
        grantCache = (nowMs, value)
        return value
    }

    var policy: StepSourcePolicy { StepSourcePolicy.from(config.stepSource) }

    var preferredSource: String? { config.preferredStepSourcePackage ?? state.preferredStepSource }

    func shouldConsultHealth() -> Bool {
        guard config.healthConnectEnabled, config.healthConnectReadEnabled, policy != .device, health.available,
              HealthSource.missingDeclaration == nil else { return false }
        return grants().steps
    }

    enum SourceMode { case cachedOnly, display, evidence }

    /// One day's Apple Health sources and how the read went.
    func sources(_ date: String, mode: SourceMode) -> (list: [StepSource], status: String) {
        guard shouldConsultHealth() else { return ([], HealthRead.notConsulted) }
        let c = clock
        let today = c.today()
        let ttl: Int64 = date == today ? 30_000 : 600_000
        if mode != .evidence, let cached = sourceCache[date], mode == .cachedOnly || nowMs - cached.at < ttl {
            return (cached.list, HealthRead.read)
        }
        if mode == .cachedOnly { return ([], HealthRead.read) }
        let start = c.startOfDayMs(date)
        let end = min(c.endOfDayExclusiveMs(date), nowMs)
        guard end > start else { return ([], HealthRead.read) }
        var samples: [HealthSample] = []
        var failure: HealthSource.ReadError?
        let g = grants()
        for kind in readKinds where kind == .steps || g.distance {
            switch health.samples(kind, from: start, to: end) {
            case let .success(list): samples += list
            case let .failure(error): failure = error
            }
            if failure != nil { break }
        }
        if let failure {
            let status: String
            if case .timedOut = failure { status = HealthRead.timedOut } else { status = HealthRead.failed }
            // A locked phone: what was read last, for a number on screen -
            // never for evidence, which says it failed.
            if mode == .display, let stored = store.day(date)?.sourcesJSON, let list = Engine.decodeSources(stored) {
                return (list, status)
            }
            return ([], status)
        }
        let options = HealthSources.Options(dayStartMs: start, dayEndMs: c.endOfDayExclusiveMs(date),
                                            coverageStartMs: date == today ? coverageStart(date) : 0,
                                            countFromMs: state.countFromAt, distanceRead: g.distance)
        let list = stampTrust(HealthSources.build(samples, options, clock: c))
        for source in list where source.isPlatform { learnedKinds[source.packageName] = source.kind }
        sourceCache[date] = (nowMs, list)
        if !isGone(date), var record = store.day(date) {
            record.sourcesJSON = JSON.array(list.map { $0.json() }).serialized()
            store.saveDay(record)
        }
        return (list, HealthRead.read)
    }

    func stampTrust(_ list: [StepSource]) -> [StepSource] {
        StepSourceTrust.stamp(list, trust: WearableTrust.from(config.wearableTrust), allowlist: Set(config.wearableAllowlist),
                              catalog: IOSCatalog.catalog)
    }

    static func decodeSources(_ text: String) -> [StepSource]? {
        guard let array = JSON.parse(text)?.arrayValue else { return nil }
        return array.compactMap { j -> StepSource? in
            guard let pkg = j["packageName"]?.stringValue else { return nil }
            var methods: RecordingMethods?
            if let m = j["recordingMethods"], !m.isNull {
                methods = RecordingMethods(active: m["active"]?.intValue ?? 0, automatic: m["automatic"]?.intValue ?? 0,
                                           manual: m["manual"]?.intValue ?? 0, unknown: m["unknown"]?.intValue ?? 0)
            }
            return StepSource(packageName: pkg, appName: j["appName"]?.stringValue ?? pkg,
                              kind: StepSourceKind(rawValue: j["kind"]?.stringValue ?? "") ?? .unknown,
                              steps: j["steps"]?.intValue ?? 0, distance: j["distance"]?.doubleValue ?? 0, calories: 0,
                              lastRecordAt: j["lastRecordAt"]?.int64Value ?? 0, isSelf: false,
                              manualSteps: j["manualSteps"]?.intValue ?? -1, unknownMethodSteps: j["unknownMethodSteps"]?.intValue ?? -1,
                              recordingMethods: methods, trustedWearable: j["trustedWearable"]?.boolValue,
                              hourlySteps: j["hourlySteps"]?.arrayValue?.compactMap(\.intValue) ?? HourlySteps.unknown,
                              activeCalories: 0, distanceSource: j["distanceSource"]?.stringValue ?? DistanceSource.none,
                              isPlatform: j["isPlatform"]?.boolValue ?? false)
        }
    }

    // ---- resolution ----------------------------------------------------------------------------------

    func resolve(_ record: DayRecord, mode: SourceMode) -> StepSourceResolver.Resolution {
        let suspect = suspect(record)
        let excluded = config.excludeSuspect ? suspect : 0
        let device = adjusted(rawTotals(record), suspect: suspect, excluded: excluded)
        let today = record.date == clock.today()
        var resolution: StepSourceResolver.Resolution
        if !shouldConsultHealth() {
            resolution = StepSourceResolver.resolve(.device, device: device, sources: [], preferredPackage: nil, metrics: metrics)
            if policy == .auto && today { resolution = StepContinuity.apply(resolution, baseline: state.continuity, metrics: metrics) }
        } else {
            let list = sources(record.date, mode: mode).list
            resolution = StepSourceResolver.resolve(
                policy, device: device, sources: list, preferredPackage: preferredSource, metrics: metrics,
                deviceCoverageReliable: true, ignoreManualEntries: config.healthConnectIgnoreManualEntries,
                wearableTrust: WearableTrust.from(config.wearableTrust), wearableAllowlist: Set(config.wearableAllowlist),
                catalog: IOSCatalog.catalog, measuredDistance: DistanceSource.healthKit)
            if policy == .auto && today {
                if mode != .cachedOnly {
                    let observed = StepContinuity.observe(state.continuity, raw: resolution, date: record.date, now: nowMs)
                    if observed != state.continuity {
                        state.continuity = observed
                        saveState()
                    }
                }
                resolution = StepContinuity.apply(resolution, baseline: state.continuity, metrics: metrics)
            }
        }
        if suspect != 0 || excluded != 0 {
            resolution.totals.suspectSteps = suspect
            resolution.suspectStepsExcluded = excluded
        }
        return resolution
    }

    /// Today's resolution, telling JS when the winner changed.
    func resolveToday(_ record: DayRecord, mode: SourceMode) -> StepSourceResolver.Resolution {
        let resolution = resolve(record, mode: mode)
        let key = resolution.sourcePackage ?? "self"
        if state.lastResolvedSource != key {
            let first = state.lastResolvedSource == nil
            state.lastResolvedSource = key
            saveState()
            if !first || resolution.usedExternal { emit("stepSourceChanged", resolution.json()) }
        }
        return resolution
    }

    // ---- what is shown ------------------------------------------------------------------------------

    var sensorName: String { motion.pedometerAvailable ? "step_counter" : "none" }

    func baseSnapshot(_ record: DayRecord) -> StepSnapshot {
        let goal = config.dailyGoal
        let steps = record.deviceSteps
        return StepSnapshot(date: record.date, steps: steps, distance: metrics.distance(steps), calories: metrics.calories(steps),
                            dailyGoal: goal, goalProgress: metrics.goalProgress(steps, goal: goal),
                            goalReached: goal > 0 && steps >= goal, state: state.trackingState, source: sensorName,
                            timestamp: state.lastPedometerAt, recoveredSteps: 0, suspectSteps: suspect(record),
                            gatedSteps: record.gatedSteps)
    }

    /// Android's `displaySnapshot`: the winner's numbers, other devices on top.
    func display(_ base: StepSnapshot, _ resolution: StepSourceResolver.Resolution) -> StepSnapshot {
        let totals = resolution.totals
        var shown = base
        if resolution.usedExternal || totals.steps != base.steps {
            shown.steps = totals.steps
            shown.distance = totals.distance
            shown.calories = totals.calories
            shown.goalProgress = metrics.goalProgress(totals.steps, goal: base.dailyGoal)
            shown.goalReached = base.dailyGoal > 0 && totals.steps >= base.dailyGoal
        }
        shown.suspectSteps = totals.suspectSteps
        let other = state.otherDevices[base.date] ?? 0
        guard other > 0 else { return shown }
        let steps = shown.steps + other
        shown.steps = steps
        shown.distance += metrics.distance(other)
        shown.calories += metrics.calories(other)
        shown.goalProgress = metrics.goalProgress(steps, goal: base.dailyGoal)
        shown.goalReached = base.dailyGoal > 0 && steps >= base.dailyGoal
        shown.otherDevicesSteps = other
        return shown
    }

    /// Today as JS sees it.
    func todayJSON(mode: SourceMode, quick: Bool = true) -> JSON {
        let record = deviceDay(clock.today(), quick: quick)
        let resolution = mode == .cachedOnly ? resolve(record, mode: mode) : resolveToday(record, mode: mode)
        let shown = display(baseSnapshot(record), resolution)
        followGoals(shown)
        return shown.json(stepSource: resolution.json())
    }

    func followGoals(_ shown: StepSnapshot) {
        var goals = GoalRules(values: state.goals)
        var changed = false
        let percent = metrics.goalPercent(shown.steps, goal: config.dailyGoal)
        if goals.progressBucketChanged(GoalRules.daily, percent: percent) {
            changed = true
            emit("goalProgressChanged", .object([
                ("type", .string(GoalRules.daily)), ("goal", .int(config.dailyGoal)), ("steps", .int(shown.steps)),
                ("progress", .double(Rounding.round(shown.goalProgress, 4))), ("date", .string(shown.date)),
            ]))
        }
        if let reached = goals.check(GoalRules.daily, periodKey: shown.date, steps: shown.steps, goal: config.dailyGoal) {
            changed = true
            emitGoal(reached, date: shown.date)
        }
        let c = clock
        // Summing the week and the month reads every stored day in them; the
        // hot path runs every few hundred ms while walking, so at most once a
        // minute - Android checks only when it commits.
        let checkPeriods = uptimeMs - lastPeriodGoalCheck >= 60_000
        if checkPeriods { lastPeriodGoalCheck = uptimeMs }
        for (type, window, goal) in [(GoalRules.weekly, c.calendarWeek(), config.weeklyGoal),
                                     (GoalRules.monthly, c.calendarMonth(), config.monthlyGoal)] where checkPeriods && goal > 0 {
            if goals.alreadyFired(type, periodKey: window.0) { continue }
            var sum = shown.steps - shown.otherDevicesSteps
            for date in c.range(window.0, window.1) where date < shown.date {
                if let stored = store.day(date) { sum += max(0, stored.deviceSteps - stored.gatedSteps) }
            }
            if let reached = goals.check(type, periodKey: window.0, steps: sum, goal: goal) {
                changed = true
                emitGoal(reached, date: shown.date)
            }
        }
        if changed {
            state.goals = goals.values
            saveState()
        }
    }

    private func emitGoal(_ reached: GoalRules.Reached, date: String) {
        emit("goalReached", .object([
            ("type", .string(reached.type)), ("goal", .int(reached.goal)), ("steps", .int(reached.steps)),
            ("date", .string(date)), ("timestamp", .int(nowMs)),
        ]))
    }

    /// Emits `stepsChanged`, throttled by `eventThrottleMs`, with a trailing
    /// event so JS never sits on a stale count after the user stops.
    func emitSteps(force: Bool = false) {
        let now = uptimeMs
        let throttle = config.eventThrottleMs
        if force || now - lastEventUptime >= throttle {
            lastEventUptime = now
            emit("stepsChanged", todayJSON(mode: .cachedOnly))
        } else if !trailingQueued {
            trailingQueued = true
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(throttle - (now - lastEventUptime)))) { [weak self] in
                guard let self else { return }
                self.trailingQueued = false
                self.lastEventUptime = self.uptimeMs
                self.emit("stepsChanged", self.todayJSON(mode: .cachedOnly))
            }
        }
    }
}
