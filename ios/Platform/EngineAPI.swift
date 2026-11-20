import CoreMotion
import CryptoKit
import Foundation
import HealthKit
import UIKit

typealias Done = (Result<JSON, BridgeError>) -> Void

extension Engine {
    /// Every spec method, by name. Runs on the queue; [done] may be called
    /// later for the few that wait on the user or on Apple's servers.
    func handle(_ method: String, _ a: [JSON], _ done: @escaping Done) {
        func ok(_ value: JSON) { done(.success(value)) }
        func str(_ i: Int) -> String { a.count > i ? (a[i].stringValue ?? "") : "" }
        func num(_ i: Int) -> Double { a.count > i ? (a[i].doubleValue ?? .nan) : .nan }
        func obj(_ i: Int) -> JSON { a.count > i ? a[i] : .object([]) }
        do {
            switch method {
            // ---- lifecycle
            case "initialize": ok(try initialize(obj(0)))
            case "updateConfig": ok(try updateConfig(obj(0)))
            case "getConfig": ok(config.jsObject())
            case "startTracking": ok(try startTracking())
            case "pauseTracking": ok(try pauseTracking())
            case "resumeTracking": ok(try resumeTracking())
            case "stopTracking": ok(stopTracking())
            case "getTrackingState": ok(.object([("state", .string(state.trackingState.rawValue)), ("source", .string(sensorName))]))
            case "isTracking": ok(.bool(state.trackingState == .running))
            case "getTrackingHealth": ok(trackingHealth())
            // ---- reads
            case "getTodaySteps": ok(todayJSON(mode: .display))
            case "setOtherDevicesSteps": ok(try setOtherDevicesSteps(str(0), num(1)))
            case "setCountFrom": ok(try setCountFrom(num(0)))
            case "getStepsForDate": ok(try dayJSON(try date(str(0))))
            case "getYesterdaySteps": ok(try dayJSON(clock.minusDays(clock.today(), 1)))
            case "getStatsForRange": ok(try stats(try date(str(0)), try date(str(1)), goal: nil).json())
            case "getWeeklyStats": ok(try windowStats(obj(0), rolling: 7, goal: config.weeklyGoal) { self.clock.calendarWeek(offset: $0) })
            case "getMonthlyStats": ok(try windowStats(obj(0), rolling: 30, goal: config.monthlyGoal) { self.clock.calendarMonth(offset: $0) })
            case "getYearlyStats": ok(try windowStats(obj(0), rolling: 365, goal: nil) { self.clock.calendarYear(offset: $0) })
            case "getHistory": ok(try history(try date(str(0)), try date(str(1))))
            case "getVerificationSnapshot": try verificationSnapshot(try date(str(0)), obj(1), done)
            case "getMotionWindows": ok(.object([("windows", .array([]))]))
            // ---- integrity
            case "getIntegrityReport": ok(integrityReport(try date(str(0))))
            case "getIntegrityEvents":
                let (s, e) = (try date(str(0)), try date(str(1)))
                ok(.object([("events", .array(events(from: clock.startOfDayMs(s), to: clock.endOfDayMs(e)).map { $0.json() }))]))
            case "getStepMinutes": ok(.object([("minutes", .array(stepMinutes(try date(str(0)), try date(str(1))).map { $0.json() }))]))
            case "attestDevice": try attestDevice(str(0), done)
            case "hasAttestationKey": ok(.bool(signingKey() != nil && state.keyCreatedBy == "attestDevice"))
            case "getAttestationKeyInfo": ok(describeKey() ?? .null)
            case "requestIntegrityToken": try requestIntegrityToken(obj(0), done)
            case "prepareIntegrity": ok(.bool(true))
            // ---- writes
            case "resetToday": ok(.bool(resetToday()))
            case "clearHistory": ok(.bool(clearHistory()))
            case "pruneHistory": ok(.int(pruneHistory(num(0))))
            // ---- permissions
            case "checkPermissions": ok(permissionStatus())
            case "requestPermissions": try requestPermissions(done)
            case "getDeviceCapabilities": ok(capabilities())
            case "openAppSettings": DeviceInfo.open(URL(string: UIApplication.openSettingsURLString)) { opened in done(.success(.bool(opened))) }
            // ---- battery: nothing to exempt on iOS
            case "isBatteryOptimizationEnabled", "requestDisableBatteryOptimization",
                 "openBatteryOptimizationSettings", "openManufacturerAutoStartSettings": ok(.bool(false))
            case "getBackgroundRestrictionStatus": ok(backgroundStatus())
            // ---- Apple Health, in Health Connect's shapes
            case "getHealthConnectStatus": ok(healthStatus(fresh: true))
            case "requestHealthConnectPermissions": try requestHealthPermissions(done)
            case "openHealthConnectSettings":
                DeviceInfo.open(URL(string: "x-apple-health://")) { opened in
                    if opened { return done(.success(.bool(true))) }
                    DeviceInfo.open(URL(string: UIApplication.openSettingsURLString)) { done(.success(.bool($0))) }
                }
            case "installHealthConnect", "revokeHealthConnectPermissions", "writeHealthConnectSteps": ok(.bool(false))
            case "readHealthConnectSteps": ok(try readHealthSteps(str(0), str(1)))
            case "syncWithHealthConnect": ok(syncWithHealth())
            case "getHealthConnectRecords": ok(try healthRecords(str(0), str(1), obj(2)))
            case "getHealthConnectChangesToken": ok(.string(try changesToken(obj(0))))
            case "getHealthConnectChanges": ok(try changes(str(0)))
            case "readHealthConnectVitals": ok(try vitals(obj(2)))
            case "deleteHealthConnectData":
                let (s, e) = (try date(str(0)), try date(str(1)))
                guard s <= e else { throw BridgeError.invalid("startDate must be on or before endDate") }
                // Nothing was ever written, so nothing is deleted.
                ok(.object([("startDate", .string(s)), ("endDate", .string(e)), ("recordTypes", .array([]))]))
            // ---- step sources
            case "getStepSources": ok(try stepSources(try date(str(0)), try date(str(1))))
            case "getCurrentStepSource":
                let r = resolve(deviceDay(clock.today(), quick: true), mode: .display)
                ok(r.json().setting("policy", .string(policy.rawValue)).setting("preferredPackage", .optional(preferredSource)))
            case "setPreferredStepSource":
                let pkg = a.first?.stringValue?.trimmingCharacters(in: .whitespaces)
                state.preferredStepSource = (pkg?.isEmpty ?? true) ? nil : pkg
                state.continuity = nil
                sourceCache.removeAll()
                saveState()
                ok(resolveToday(deviceDay(clock.today(), quick: true), mode: .display).json())
            case "getInstalledCompanionApps": ok(.object([("apps", .array([]))]))
            // ---- remote sync: not in this version
            case "getPendingSyncCount": ok(.int(0))
            case "getSyncStatus": ok(.object([("remote", .object([
                ("configured", .bool(false)), ("pendingRecords", .int(0)), ("lastAttemptAt", .int(0)), ("lastSuccessAt", .int(0)),
                ("consecutiveFailures", .int(0)), ("lastFailure", .null), ("authFailed", .bool(false)),
            ]))]))
            case "syncNow": ok(.object([("results", .array([]))]))
            default: throw BridgeError(code: "E_UNKNOWN", message: "\(method) is not implemented on iOS")
            }
        } catch let error as BridgeError {
            done(.failure(error))
        } catch {
            done(.failure(BridgeError(code: "E_UNKNOWN", message: error.localizedDescription)))
        }
    }

    func date(_ key: String) throws -> String {
        guard key.count == 10, clock.isValid(key) else { throw BridgeError.invalid("Dates must be yyyy-MM-dd") }
        return key
    }

    // ---- lifecycle ---------------------------------------------------------------------------------

    func applyConfig(_ next: StepTrackerConfig) {
        let previous = config
        config = next.sanitised()
        store.saveConfig(config.storeObject())
        if previous.remoteSyncHeaders != config.remoteSyncHeaders { Attestation.saveHeaders(config.remoteSyncHeaders) }
        let changed = config.integrityChanges(from: previous)
        if !changed.isEmpty {
            // Turning detection off is the one change logged while it is off.
            log(IntegrityEvent.configChanged, .object([("keys", .strings(changed))]),
                force: previous.fraudDetectionEnabled && !config.fraudDetectionEnabled)
        }
        if previous.motionGateEnabled != config.motionGateEnabled {
            log(IntegrityEvent.motionGate, .object([("enabled", .bool(config.motionGateEnabled))]))
        }
        if previous != config {
            lastFull = nil
            sourceCache.removeAll()
            grantCache = nil
        }
    }

    func initialize(_ patch: JSON) throws -> JSON {
        applyConfig(config.merging(patch))
        observeHealthIfGranted()
        startLiveIfNeeded()
        return todayJSON(mode: .cachedOnly)
    }

    func updateConfig(_ patch: JSON) throws -> JSON {
        let previous = config
        applyConfig(config.merging(patch))
        // Apple Health turned on or off, or other types read: the observers
        // follow now, not at the next launch or foreground.
        if config.observedHealthKinds != previous.observedHealthKinds { observeHealthIfGranted() }
        return config.jsObject()
    }

    func emitTrackingState(_ reason: String? = nil) {
        var pairs: [(String, JSON)] = [("state", .string(state.trackingState.rawValue)), ("source", .string(sensorName))]
        if let reason { pairs.append(("reason", .string(reason))) }
        emit("trackingStateChanged", .object(pairs))
    }

    func startTracking() throws -> JSON {
        guard DeviceInfo.hasInfoKey("NSMotionUsageDescription") else {
            throw BridgeError(code: "E_PERMISSION_DENIED", message: "NSMotionUsageDescription is missing from the app's Info.plist; the pedometer cannot be used without it.")
        }
        guard motion.authorized else {
            throw BridgeError(code: "E_PERMISSION_DENIED", message: "Motion & Fitness must be allowed before tracking can start")
        }
        guard motion.pedometerAvailable else { throw BridgeError(code: "E_NO_SENSOR", message: "No step counter on this device") }
        if state.trackingState != .running {
            let now = nowMs
            if state.trackingState == .paused || state.trackingState == .stopped || state.trackingState == .idle {
                closeSpan(at: now)
                state.spans.append(TrackingSpan(start: now, end: nil))
            }
            if state.firstStartAt == 0 { state.firstStartAt = now }
            state.trackingState = .running
            lastFull = nil
            saveState()
            emitTrackingState()
        }
        startLiveIfNeeded()
        return todayJSON(mode: .cachedOnly)
    }

    func closeSpan(at: Int64) {
        if let last = state.spans.indices.last, state.spans[last].end == nil { state.spans[last].end = at }
        let cutoff = clock.startOfDayMs(clock.minusDays(clock.today(), max(config.historyRetentionDays, Engine.pedometerDays) + 1))
        state.spans = TrackingSpans.pruned(state.spans, before: cutoff)
    }

    func pauseTracking() throws -> JSON {
        guard state.trackingState == .running || state.trackingState == .paused else {
            throw BridgeError(code: "E_NOT_TRACKING", message: "Tracking is not running")
        }
        if state.trackingState == .running {
            closeSpan(at: nowMs)
            state.trackingState = .paused
            lastFull = nil
            saveState()
            motion.stopLive()
            emitTrackingState()
        }
        return todayJSON(mode: .cachedOnly)
    }

    func resumeTracking() throws -> JSON {
        guard state.trackingState == .running || state.trackingState == .paused else {
            throw BridgeError(code: "E_NOT_TRACKING", message: "Tracking is not running")
        }
        if state.trackingState == .paused {
            state.spans.append(TrackingSpan(start: nowMs, end: nil))
            state.trackingState = .running
            lastFull = nil
            saveState()
            emitTrackingState()
            startLiveIfNeeded()
        }
        return todayJSON(mode: .cachedOnly)
    }

    func stopTracking() -> JSON {
        closeSpan(at: nowMs)
        let changed = state.trackingState != .stopped
        state.trackingState = .stopped
        lastFull = nil
        saveState()
        motion.stopLive()
        if changed { emitTrackingState("stopped") }
        return todayJSON(mode: .cachedOnly)
    }

    func trackingHealth() -> JSON {
        let now = nowMs
        let beat = state.lastPedometerAt
        return .object([
            ("serviceAlive", .bool(state.trackingState == .running)),
            ("shouldBeRunning", .bool(state.trackingState == .running || state.trackingState == .paused)),
            ("lastHeartbeatAt", .int(beat)),
            ("heartbeatAgeMs", .int(beat > 0 && now >= beat ? now - beat : -1)),
            ("lastSensorEventAt", .int(beat)),
            ("lastRecoveryAt", .int(0)),
            ("lastRecoveryReason", .null),
            ("recoveryCount", .int(0)),
            ("looksDead", .bool(false)),
            ("batteryOptimizationEnabled", .bool(false)),
            ("aggressiveOem", .bool(false)),
            ("manufacturer", .string("Apple")),
        ])
    }

    // ---- reads ---------------------------------------------------------------------------------------

    func setOtherDevicesSteps(_ day: String, _ steps: Double) throws -> JSON {
        let date = try date(day)
        guard steps.isFinite, steps >= 0, steps <= Double(OtherDevices.maxSteps), steps == steps.rounded(.down) else {
            throw BridgeError.invalid("steps must be a whole number from 0 to \(OtherDevices.maxSteps)")
        }
        var next = state.otherDevices
        if steps > 0 { next[date] = Int(steps) } else { next.removeValue(forKey: date) }
        state.otherDevices = OtherDevices.kept(next, today: clock.today(), clock: clock)
        saveState()
        if date == clock.today() { emitSteps(force: true) }
        return todayJSON(mode: .cachedOnly)
    }

    /// Counts nothing before [at]. The pedometer times every step, so unlike
    /// Android - which cannot tell its counted steps apart and starts today
    /// over at the call - iOS counts exactly from [at], and today is never
    /// restarted.
    func setCountFrom(_ at: Double) throws -> JSON {
        let earliest: Double = 946_684_800_000
        let latest = Double(nowMs) + 366 * 86_400_000
        guard at == 0 || (at == at.rounded(.down) && at >= earliest && at <= latest) else {
            throw BridgeError.invalid("at must be epoch milliseconds, no more than a year ahead, or null to clear it")
        }
        let next = Int64(at)
        let previous = state.countFromAt
        guard next != previous else { return todayJSON(mode: .cachedOnly) }
        state.countFromAt = next
        state.continuity = nil
        sourceCache.removeAll()
        lastFull = nil
        saveState()
        log(IntegrityEvent.countFrom, .object([("countFrom", .optional(next > 0 ? next : nil)),
                                               ("previous", .optional(previous > 0 ? previous : nil)),
                                               ("restartedToday", .bool(false))]))
        emitSteps(force: true)
        return todayJSON(mode: .cachedOnly)
    }

    func dayJSON(_ date: String) throws -> JSON {
        let resolution = resolve(deviceDay(date, quick: true), mode: .display)
        return resolution.totals.json(stepSource: resolution.json())
    }

    func stats(_ start: String, _ end: String, goal: Int?) throws -> RangeStats {
        guard start <= end else { throw BridgeError.invalid("startDate (\(start)) must be on or before endDate (\(end))") }
        let c = clock
        let today = c.today()
        let read = shouldConsultHealth() ? prefetchSources(start, min(end, today)) : HealthRead.notConsulted
        let days = c.range(start, end).map { date -> DayTotals in
            if date > today { return metrics.totals(date: date, steps: 0) }
            let record = deviceDay(date, quick: true)
            var totals = resolve(record, mode: .display).totals
            totals.suspectSteps = suspect(record)
            return totals
        }
        var result = RangeStats.of(start: start, end: end, days: days, goal: goal, today: today, clock: c)
        result.healthConnect = read
        return result
    }

    /// Reads a range's sources in as few queries as cover it into the cache:
    /// samples for up to 35 days, per-day totals by source past that -
    /// Android's aggregate path, with no per-sample detail.
    func prefetchSources(_ start: String, _ end: String) -> String {
        guard start <= end else { return HealthRead.read }
        let c = clock
        let from = c.startOfDayMs(start)
        let to = min(c.endOfDayExclusiveMs(end), nowMs)
        let dates = c.range(start, end).filter { sourceCache[$0] == nil || nowMs - sourceCache[$0]!.at > 30_000 }
        guard !dates.isEmpty, to > from else { return HealthRead.read }
        let g = grants()
        let today = c.today()
        if dates.count <= 35 {
            var samples: [HealthSample] = []
            for kind in readKinds where kind == .steps || g.distance {
                switch health.samples(kind, from: c.startOfDayMs(dates.first!), to: to) {
                case let .success(s): samples += s
                case let .failure(e): if case .timedOut = e { return HealthRead.timedOut } else { return HealthRead.failed }
                }
            }
            for date in dates {
                let options = HealthSources.Options(dayStartMs: c.startOfDayMs(date), dayEndMs: c.endOfDayExclusiveMs(date),
                                                    coverageStartMs: date == today ? coverageStart(date) : 0,
                                                    countFromMs: state.countFromAt, distanceRead: g.distance,
                                                    thisPhone: state.thisPhoneBundle)
                sourceCache[date] = (nowMs, stampTrust(HealthSources.build(samples, options, clock: c)))
            }
            return HealthRead.read
        }
        switch health.dailySourceTotals(.steps, from: max(from, state.countFromAt), to: to, clock: c) {
        case let .success(byDay):
            var distance: [String: [String: Double]] = [:]
            if g.distance, case let .success(d) = health.dailySourceTotals(.distance, from: max(from, state.countFromAt), to: to, clock: c) {
                for (date, rows) in d { distance[date] = Dictionary(rows.map { ($0.0, $0.2) }, uniquingKeysWith: +) }
            }
            for date in dates {
                let rows = byDay[date] ?? []
                sourceCache[date] = (nowMs, stampTrust(rows.filter { $0.2 >= 0.5 }.map { id, name, steps in
                    aggregateSource(id, name, steps, distance[date]?[id] ?? 0, distanceRead: g.distance)
                }))
            }
            return HealthRead.read
        case let .failure(e):
            if case .timedOut = e { return HealthRead.timedOut }
            return HealthRead.failed
        }
    }

    /// A source known only by its totals - Android's aggregate rows: every
    /// per-record figure `-1`. An Apple device's kind is what its samples
    /// said when last read.
    func aggregateSource(_ id: String, _ name: String, _ steps: Double, _ meters: Double, distanceRead: Bool) -> StepSource {
        let apple = id.hasPrefix(HealthOrigin.applePrefix)
        let kind = learnedKinds[id] ?? (apple ? .unknown : .app)
        let appName = kind == .watch && apple ? HealthOrigin.watchName
            : (kind == .phone && apple ? (state.thisPhoneBundle == nil || state.thisPhoneBundle == id ? HealthOrigin.iPhoneName : HealthOrigin.otherPhoneName) : name)
        return StepSource(packageName: id, appName: appName, kind: kind, steps: Int(steps.rounded()), distance: meters,
                          calories: 0, lastRecordAt: 0, isSelf: false, hourlySteps: HourlySteps.unknown, activeCalories: 0,
                          distanceSource: !distanceRead ? DistanceSource.notRead : (meters > 0 ? DistanceSource.healthKit : DistanceSource.none),
                          isPlatform: apple)
    }

    func windowStats(_ options: JSON, rolling: Int, goal: Int?, calendar: (Int) -> (String, String)) throws -> JSON {
        let mode = options["mode"]?.stringValue ?? "calendar"
        let offset = options["offset"]?.intValue ?? 0
        let (s, e) = mode == "rolling" ? clock.rolling(rolling) : calendar(offset)
        return try stats(s, e, goal: goal).json()
    }

    /// Stored days as they are - Android's `getHistory()` rows.
    func history(_ start: String, _ end: String) throws -> JSON {
        guard start <= end else { throw BridgeError.invalid("startDate must be on or before endDate") }
        let c = clock
        let today = c.today()
        var records: [JSON] = []
        for date in c.range(start, end) where date <= today && !isGone(date) {
            let record = date == today ? deviceDay(date, quick: true) : (store.day(date) ?? deviceDay(date))
            guard record.deviceSteps > 0 || store.day(date) != nil else { continue }
            let s = suspect(record)
            let day = record.gatedSteps > 0 ? adjusted(rawTotals(record), suspect: s, excluded: 0) : {
                var d = rawTotals(record)
                d.suspectSteps = s
                return d
            }()
            records.append(.object([
                ("date", .string(day.date)), ("steps", .int(day.steps)), ("distance", .double(day.distance)),
                ("calories", .double(day.calories)), ("synced", .bool(false)), ("syncedRemote", .bool(false)),
                ("recoveredSteps", .int(0)), ("suspectSteps", .int(day.suspectSteps)),
            ]))
        }
        return .object([("records", .array(records))])
    }

    func stepMinutes(_ start: String, _ end: String) -> [MinuteSample] {
        guard config.fraudDetectionEnabled, start <= end else { return [] }
        return clock.range(start, end).flatMap { deviceDay($0).minutes }
    }

    // ---- integrity -------------------------------------------------------------------------------------

    var activityStatus: String {
        guard config.wantsActivity else { return "not_requested" }
        guard motion.activityAvailable else { return "unavailable" }
        return motion.authorized ? "registered" : "no_permission"
    }

    func integrityReport(_ date: String, record given: DayRecord? = nil) -> JSON {
        let c = clock
        let today = date == c.today()
        let record = given ?? deviceDay(date)
        let flags = record.flags
        return IntegrityReport.build(IntegrityReportInput(
            date: date, enabled: config.fraudDetectionEnabled, mode: config.fraudMode, deviceSteps: record.deviceSteps,
            flaggedSteps: record.flaggedSteps, flags: flags,
            events: events(from: c.startOfDayMs(date), to: c.endOfDayMs(date)), minutes: record.minutes,
            evaluatedAt: record.evaluatedAt, rules: config.integrityRules(), charging: today && charging,
            activityRequested: config.fraudDetectionEnabled && config.fraudActivityRecognition,
            activityAvailable: motion.activityAvailable, activityStatus: activityStatus,
            activityCurrent: today ? (currentActivity?.state ?? .unknown).rawValue : "unknown",
            gate: config, gatedSteps: record.gatedSteps,
            gateHolding: today && config.motionGateEnabled && (currentActivity?.vehicle ?? false) && (currentActivity?.confidence ?? 0) >= 1,
            device: DeviceInfo.signals(pedometerAvailable: motion.pedometerAvailable),
            dayStartMs: c.startOfDayMs(date), dayEndExclusiveMs: c.endOfDayExclusiveMs(date)))
    }

    // ---- writes ------------------------------------------------------------------------------------------

    func resetToday() -> Bool {
        let today = clock.today()
        state.resetAt[today] = nowMs
        state.resetAt = state.resetAt.filter { $0.key >= clock.minusDays(today, Engine.pedometerDays) }
        state.otherDevices.removeValue(forKey: today)
        state.continuity = nil
        state.reportedFlags.removeValue(forKey: today)
        var goals = GoalRules(values: state.goals)
        goals.reset()
        state.goals = goals.values
        sourceCache.removeAll()
        lastFull = nil
        saveState()
        events.removeAll { clock.key(ms: $0.at) == today && $0.type != IntegrityEvent.resetToday }
        log(IntegrityEvent.resetToday, .object([("date", .string(today))]))
        store.deleteDay(today)
        emitSteps(force: true)
        return true
    }

    func clearHistory() -> Bool {
        let today = clock.today()
        for date in store.storedDates() where date < today { store.deleteDay(date) }
        state.clearedBefore = today
        let shownToday = (state.otherDevices[today] ?? 0) > 0
        state.otherDevices = [:]
        state.lastResolvedSteps = [:]
        saveState()
        log(IntegrityEvent.historyCleared)
        if shownToday { emitSteps(force: true) }
        return true
    }

    func pruneHistory(_ days: Double) -> Int {
        let keep = clock.minusDays(clock.today(), max(1, days.isFinite ? Int(days) : 1))
        var removed = 0
        for date in store.storedDates() where date < keep {
            if store.deleteDay(date) { removed += 1 }
        }
        return removed
    }

    // ---- permissions ----------------------------------------------------------------------------------

    func permissionStatus() -> JSON {
        let motionOk = motion.authorized
        return .object([
            ("activityRecognition", .bool(motionOk)), ("postNotifications", .bool(true)),
            ("foregroundServiceHealth", .bool(true)), ("allGranted", .bool(motionOk)),
        ])
    }

    func requestPermissions(_ done: @escaping Done) throws {
        guard DeviceInfo.hasInfoKey("NSMotionUsageDescription") else {
            throw BridgeError(code: "E_PERMISSION_DENIED", message: "NSMotionUsageDescription is missing from the app's Info.plist; asking for Motion & Fitness would terminate the app.")
        }
        guard motion.authorization == .notDetermined, motion.pedometerAvailable else { return done(.success(permissionStatus())) }
        motion.requestAuthorization { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.startLiveIfNeeded()
                done(.success(self.permissionStatus()))
            }
        }
    }

    func capabilities() -> JSON {
        let counter = motion.pedometerAvailable
        return .object([
            ("hasStepCounter", .bool(counter)), ("hasStepDetector", .bool(false)), ("hasAccelerometer", .bool(true)),
            ("hasWakeUpAccelerometer", .bool(false)), ("supported", .bool(counter)),
            ("bestSensor", .string(counter ? "step_counter" : "none")), ("sdkInt", .int(0)),
            ("manufacturer", .string("Apple")), ("model", .string(DeviceInfo.model)),
            ("platform", .string("ios")), ("osVersion", .string(DeviceInfo.osVersion)),
        ])
    }

    func backgroundStatus() -> JSON {
        .object([
            ("manufacturer", .string("Apple")), ("brand", .string("Apple")), ("aggressiveOem", .bool(false)),
            ("batteryOptimizationEnabled", .bool(false)), ("directPromptAvailable", .bool(false)),
            ("autoStartSettingsAvailable", .bool(false)), ("autoStartTarget", .null),
            ("backgroundStartNeedsExemption", .bool(false)), ("backgroundRefresh", .string(DeviceInfo.backgroundRefresh)),
        ])
    }

    // ---- Apple Health ---------------------------------------------------------------------------------

    static let permissionNames: [HealthSample.Kind: String] = [
        .steps: HKQuantityTypeIdentifier.stepCount.rawValue,
        .distance: HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
    ]

    func healthStatus(fresh: Bool = false) -> JSON {
        let available = health.available
        let g = available ? grants(fresh: fresh) : Grants(requested: false, steps: false, distance: false)
        let readOn = config.healthConnectReadEnabled
        let kinds = readKinds
        let grantedKinds = kinds.filter { $0 == .steps ? g.steps : g.distance }
        let grantedNames = grantedKinds.map { Engine.permissionNames[$0]! }
        let missing = readOn ? kinds.filter { !grantedKinds.contains($0) }.map { Engine.permissionNames[$0]! } : []
        var undeclared: [String] = []
        if !DeviceInfo.hasInfoKey("NSHealthShareUsageDescription") { undeclared.append("NSHealthShareUsageDescription") }
        if DeviceInfo.hasEntitlement("com.apple.developer.healthkit") == false { undeclared.append("com.apple.developer.healthkit") }
        if DeviceInfo.hasEntitlement("com.apple.developer.healthkit.background-delivery") == false {
            undeclared.append("com.apple.developer.healthkit.background-delivery")
        }
        let canRead = readOn && grantedKinds.count == kinds.count && g.steps
        let anyRead = g.steps
        return .object([
            ("provider", .string("healthkit")),
            ("available", .bool(available)),
            ("availability", .string(available ? "available" : "not_supported")),
            ("requiresUpdate", .bool(false)),
            ("installable", .bool(false)),
            ("granted", .bool(readOn && canRead)),
            ("canRead", .bool(canRead)),
            ("canReadSteps", .bool(g.steps)),
            ("grantedReadTypes", .strings(grantedKinds.map(\.rawValue))),
            ("canWriteSteps", .bool(false)),
            ("grantedWriteTypes", .array([])),
            ("canWrite", .bool(false)),
            ("readRequired", .bool(readOn)),
            ("writeRequired", .bool(false)),
            ("backgroundReadGranted", .bool(anyRead)),
            // Full history, unless the user allowed only a recent window (iOS 27+).
            ("historyReadGranted", .bool(anyRead && g.stepsReadableFrom == nil)),
            ("grantedPermissions", .strings(grantedNames)),
            ("missingPermissions", .strings(missing)),
            ("undeclaredPermissions", .strings(undeclared)),
            ("stepsGranted", .bool(!readOn || g.steps)),
            ("denialCount", .int(state.healthDenials)),
            ("shouldOpenSettings", .bool(readOn && g.requested && !g.steps)),
            ("backgroundReadAvailable", .bool(anyRead)),
            ("historyReadAvailable", .bool(anyRead)),
            ("grantedVitals", .array([])),
            ("workProfile", .bool(false)),
        ])
    }

    func requestHealthPermissions(_ done: @escaping Done) throws {
        guard health.available else {
            throw BridgeError(code: "E_HEALTH_CONNECT_UNAVAILABLE", message: "Apple Health is not available on this device")
        }
        if let missing = HealthSource.missingDeclaration { throw BridgeError(code: "E_HEALTH_CONNECT_NOT_DECLARED", message: missing) }
        guard config.healthConnectReadEnabled else { return done(.success(healthStatus(fresh: true))) }
        health.requestAuthorization(readKinds) { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if let error = error as? HKError, error.code == .errorAuthorizationDenied || error.code == .errorUserCanceled {
                    // Fall through: the status says what happened.
                } else if let error {
                    let text = error.localizedDescription
                    if text.lowercased().contains("entitlement") {
                        return done(.failure(BridgeError(code: "E_HEALTH_CONNECT_NOT_DECLARED", message: text)))
                    }
                    return done(.failure(BridgeError(code: "E_UNKNOWN", message: text)))
                }
                self.grantCache = nil
                self.sourceCache.removeAll()
                let g = self.grants(fresh: true)
                if g.requested && !g.steps { self.state.healthDenials += 1 }
                self.state.healthRequested = true
                let status = self.healthStatus()
                self.state.healthFingerprint = status.serialized()
                self.saveState()
                self.observeHealthIfGranted()
                self.emit("healthConnectStatusChanged", status)
                done(.success(status))
            }
        }
    }

    func requireHealthRead(_ kinds: [HealthSample.Kind]) throws {
        guard health.available else { throw BridgeError(code: "E_HEALTH_CONNECT_UNAVAILABLE", message: "Apple Health is not available on this device") }
        if let missing = HealthSource.missingDeclaration { throw BridgeError(code: "E_HEALTH_CONNECT_NOT_DECLARED", message: missing) }
        let g = grants()
        let refused = kinds.filter { $0 == .steps ? !g.steps : !g.distance }
        if !refused.isEmpty {
            throw BridgeError(code: "E_HEALTH_CONNECT_DENIED",
                              message: "Apple Health read permission is not granted: " + refused.map { Engine.permissionNames[$0]! }.joined(separator: ", "))
        }
    }

    func instant(_ iso: String) throws -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return DayClock.ms(d) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return DayClock.ms(d) }
        throw BridgeError.invalid("Instants must be ISO-8601 with a zone, e.g. '2026-09-01T00:00:00Z'")
    }

    func recordKinds(_ options: JSON) throws -> [HealthSample.Kind] {
        guard let names = options["recordTypes"]?.arrayValue?.compactMap(\.stringValue) else { return [.steps] }
        let kinds = names.compactMap(HealthSample.Kind.init(rawValue:))
        guard !kinds.isEmpty, kinds.count == names.count else { throw BridgeError.invalid("recordTypes takes steps and distance") }
        return HealthSample.Kind.allOrdered.filter { kinds.contains($0) }
    }

    func readFailure(_ error: HealthSource.ReadError) -> BridgeError {
        switch error {
        case .timedOut: return BridgeError(code: "E_UNKNOWN", message: "Apple Health did not answer in time")
        case let .failed(e):
            if HealthSource.isLockedError(e) {
                return BridgeError(code: "E_HEALTH_CONNECT_UNAVAILABLE", message: "Apple Health cannot be read while the phone is locked")
            }
            return BridgeError(code: "E_UNKNOWN", message: e?.localizedDescription ?? "Apple Health read failed")
        }
    }

    func healthRecords(_ startIso: String, _ endIso: String, _ options: JSON) throws -> JSON {
        let kinds = try recordKinds(options)
        let (start, end) = (try instant(startIso), try instant(endIso))
        try requireHealthRead(kinds)
        var samples: [HealthSample] = []
        for kind in kinds {
            switch health.samples(kind, from: start, to: end, limit: HealthSources.maxRecordsPerType + 1) {
            case let .success(list): samples += list
            case let .failure(error): throw readFailure(error)
            }
        }
        let (records, truncated) = HealthSources.recordList(samples, types: kinds)
        return .object([("records", records), ("truncated", .bool(truncated))])
    }

    func readHealthSteps(_ startIso: String, _ endIso: String) throws -> JSON {
        var (start, end) = (try instant(startIso), try instant(endIso))
        try requireHealthRead([.steps])
        let c = clock
        if state.countFromAt > 0 { start = max(start, state.countFromAt) }
        guard end > start else { return .object([("totalSteps", .int(0)), ("records", .array([]))]) }
        let steps: [String: Double]
        switch health.dailyTotals(.steps, from: start, to: end, clock: c) {
        case let .success(v): steps = v
        case let .failure(e): throw readFailure(e)
        }
        var distance: [String: Double] = [:]
        if grants().distance, case let .success(v) = health.dailyTotals(.distance, from: start, to: end, clock: c) { distance = v }
        let records = steps.keys.sorted().compactMap { date -> JSON? in
            let count = Int((steps[date] ?? 0).rounded())
            guard count > 0 else { return nil }
            let meters = distance[date] ?? 0
            return .object([
                ("date", .string(date)), ("steps", .int(count)),
                ("distance", .double(meters > 0 ? meters : metrics.distance(count))),
                // Calories are always the package's formula, never Apple Health's energy.
                ("calories", .double(metrics.calories(count))),
                ("synced", .bool(true)), ("syncedRemote", .bool(false)), ("recoveredSteps", .int(0)), ("suspectSteps", .int(0)),
            ])
        }
        let total = records.reduce(0) { $0 + ($1["steps"]?.intValue ?? 0) }
        return .object([("totalSteps", .int(total)), ("records", .array(records))])
    }

    func syncWithHealth() -> JSON {
        sourceCache.removeAll()
        let (_, status) = sources(clock.today(), mode: .evidence)
        let ok = status == HealthRead.read || status == HealthRead.notConsulted
        return .object([
            ("target", .string("health_connect")), ("syncedRecords", .int(0)), ("failedRecords", .int(0)), ("skippedRecords", .int(0)),
            ("success", .bool(ok)), ("error", ok ? .null : .string("Apple Health read \(status)")),
            ("retryable", .bool(!ok)), ("rateLimited", .bool(false)),
        ])
    }

    /// A change cursor: each type's `HKQueryAnchor`, archived, as base64 JSON.
    func changesToken(_ options: JSON) throws -> String {
        let kinds = try recordKinds(options)
        try requireHealthRead(kinds)
        var anchors: [(String, JSON)] = []
        let now = DayClock.date(nowMs)
        for kind in kinds {
            // Nothing from before now: the anchor is where the store stands.
            let predicate = HKQuery.predicateForSamples(withStart: now, end: nil, options: .strictStartDate)
            switch health.anchored(kind, anchor: nil, predicate: predicate, limit: 1) {
            case let .success(r): anchors.append((kind.rawValue, .optional(HealthSource.archive(r.anchor))))
            case let .failure(e): throw readFailure(e)
            }
        }
        return Data(JSON.object([("v", .int(1)), ("anchors", .object(anchors))]).serialized().utf8).base64EncodedString()
    }

    func changes(_ token: String) throws -> JSON {
        guard let data = Data(base64Encoded: token), let json = JSON.parse(data), case let .object(pairs)? = json["anchors"] else {
            // Not a token this package made: say so the way an expired one does.
            return .object([("tokenExpired", .bool(true)), ("upserted", .array([])), ("deletedIds", .array([])),
                            ("nextToken", .null), ("hasMore", .bool(false))])
        }
        try requireHealthRead([.steps])
        var upserted: [HealthSample] = []
        var deleted: [String] = []
        var next: [(String, JSON)] = []
        var more = false
        let limit = 1_000
        for (name, value) in pairs {
            guard let kind = HealthSample.Kind(rawValue: name) else { continue }
            let anchor = value.stringValue.flatMap(HealthSource.unarchive)
            switch health.anchored(kind, anchor: anchor, predicate: nil, limit: limit) {
            case let .success(r):
                upserted += r.samples
                deleted += r.deleted
                if r.samples.count + r.deleted.count >= limit { more = true }
                next.append((name, .optional(HealthSource.archive(r.anchor) ?? value.stringValue)))
            case let .failure(e): throw readFailure(e)
            }
        }
        upserted.sort { $0.startMs < $1.startMs }
        let nextToken = Data(JSON.object([("v", .int(1)), ("anchors", .object(next))]).serialized().utf8).base64EncodedString()
        return .object([
            ("tokenExpired", .bool(false)), ("upserted", .array(upserted.map(HealthSources.record))),
            ("deletedIds", .strings(deleted)), ("nextToken", .string(nextToken)), ("hasMore", .bool(more)),
        ])
    }

    func vitals(_ options: JSON) throws -> JSON {
        let names = options["types"]?.arrayValue?.compactMap(\.stringValue) ?? config.healthConnectReadVitals
        let known = StepTrackerConfig.vitalOrder
        guard !names.isEmpty, names.allSatisfy(known.contains) else {
            throw BridgeError.invalid("types takes " + known.joined(separator: ", ") + " - pass some, or list them in healthConnectReadVitals")
        }
        // No vitals on iOS in this version: every type asked for is not granted.
        return .object([("vitals", .array([])), ("notGranted", .strings(known.filter(names.contains)))])
    }

    func stepSources(_ start: String, _ end: String) throws -> JSON {
        guard start <= end else { throw BridgeError.invalid("startDate must be on or before endDate") }
        guard config.healthConnectEnabled, config.healthConnectReadEnabled, health.available,
              HealthSource.missingDeclaration == nil, grants().steps else {
            return .object([("sources", .array([])), ("hasWearable", .bool(false)), ("healthConnect", .string(HealthRead.notConsulted))])
        }
        let c = clock
        let from = c.startOfDayMs(start)
        let to = min(c.endOfDayExclusiveMs(end), nowMs)
        var list: [StepSource] = []
        var status = HealthRead.read
        if c.daysBetween(start, end) <= 35 {
            var samples: [HealthSample] = []
            for kind in readKinds where kind == .steps || grants().distance {
                switch health.samples(kind, from: from, to: to) {
                case let .success(s): samples += s
                case let .failure(e): if case .timedOut = e { status = HealthRead.timedOut } else { status = HealthRead.failed }
                }
            }
            if status == HealthRead.read {
                let today = c.today()
                let options = HealthSources.Options(dayStartMs: from, dayEndMs: c.endOfDayExclusiveMs(end),
                                                    coverageStartMs: start == today && end == today ? coverageStart(today) : 0,
                                                    countFromMs: state.countFromAt, distanceRead: grants().distance,
                                                    thisPhone: state.thisPhoneBundle)
                list = stampTrust(HealthSources.build(samples, options, clock: c))
            }
        } else {
            // Long ranges as Android's aggregate path: totals per source, no per-sample detail.
            switch health.sourceTotals(.steps, from: max(from, state.countFromAt), to: to) {
            case let .success(rows):
                var distance: [String: Double] = [:]
                if grants().distance, case let .success(d) = health.sourceTotals(.distance, from: max(from, state.countFromAt), to: to) {
                    for (id, _, v) in d { distance[id] = v }
                }
                list = stampTrust(rows.filter { $0.2 >= 0.5 }.map { id, name, steps in
                    aggregateSource(id, name, steps, distance[id] ?? 0, distanceRead: grants().distance)
                }.sorted { $0.steps > $1.steps })
            case let .failure(e):
                if case .timedOut = e { status = HealthRead.timedOut } else { status = HealthRead.failed }
            }
        }
        return .object([
            ("sources", .array(list.map { $0.json() })),
            ("hasWearable", .bool(list.contains { !$0.isSelf && $0.isWearable })),
            ("healthConnect", .string(status)),
        ])
    }
}

extension HealthSample.Kind {
    static let allOrdered: [HealthSample.Kind] = [.steps, .distance]
}
