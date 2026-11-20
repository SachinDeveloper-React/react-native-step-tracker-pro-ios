import Foundation

/// The port of Android's `StepTrackerConfig`: every key the JS API has, kept
/// whether iOS uses it or not, so `updateConfig()` / `getConfig()` round-trip
/// exactly as on Android. Defaults, clamping (`sanitised`), patching
/// (`merging`) and the shape `getConfig()` returns (`jsObject`) are line for
/// line Android's.
struct StepTrackerConfig: Equatable {
    var heightCm: Double = 170
    var weightKg: Double = 70
    var strideLengthM: Double = 0
    var sex: String = "unspecified"
    var dailyGoal: Int = 10_000
    var weeklyGoal: Int = 70_000
    var monthlyGoal: Int = 300_000
    var calorieCoefficient: Double = 0.57
    var historyRetentionDays: Int = 35
    var notificationTitle: String?
    var notificationText: String?
    var notificationIcon: String?
    var notificationChannelName: String?
    var notificationActions: Bool = true
    var notificationLockScreen: String = "private"
    var notificationDistanceUnit: String = "km"
    var notificationThrottleMs: Int64 = 1_000
    var eventThrottleMs: Int64 = 500
    var persistEveryNSteps: Int = 10
    var healthConnectEnabled: Bool = true
    var healthConnectSyncIntervalMinutes: Int = 15
    var healthConnectReadEnabled: Bool = true
    var healthConnectWriteEnabled: Bool = true
    var healthConnectBackgroundRead: Bool = false
    var healthConnectHistoryRead: Bool = false
    var healthConnectIgnoreManualEntries: Bool = false
    var healthConnectReadActiveCalories: Bool = false
    var healthConnectReadTypes: [String] = StepTrackerConfig.defaultReadTypes
    var healthConnectReadTypesExplicit: Bool = false
    var healthConnectWriteExplicit: Bool = false
    var healthConnectReadVitals: [String] = []
    var healthConnectWriteGranularity: String = "day"
    var stepSource: String = "auto"
    var preferredStepSourcePackage: String?
    var wearableTrust: String = "metadata"
    var wearableAllowlist: [String] = []
    var privacyPolicyUrl: String?
    var remoteSyncUrl: String?
    var remoteSyncHeaders: [String: String] = [:]
    var remoteSyncAllowHttp: Bool = false
    var remoteSyncPayload: String = "totals"
    var remoteSyncAuth: String = "headers"
    var autoStartOnBoot: Bool = true
    var gapRecovery: String = "split"
    var gapRecoveryMaxSteps: Int = 20_000
    var watchdogEnabled: Bool = true
    var accelerometerFallback: Bool = true
    var accelerometerWakeLock: Bool = true
    var accelerometerThreshold: Double = 0.9
    var motionSamplingEnabled: Bool = false
    var motionWindowSeconds: Int = 10
    var motionIntervalMinutes: Int = 5
    var motionWindowRetention: Int = 288
    var fraudDetectionEnabled: Bool = false
    var fraudMode: String = "flag"
    var fraudMaxCadenceSpm: Int = IntegrityRules.defaultMaxCadenceSpm
    var fraudSteadyCadenceMinutes: Int = IntegrityRules.defaultSteadyMinutes
    var fraudMaxContinuousMinutes: Int = IntegrityRules.defaultMaxContinuousMinutes
    var fraudMaxDailySteps: Int = IntegrityRules.defaultMaxDailySteps
    var fraudFlagWhileCharging: Bool = true
    var fraudActivityRecognition: Bool = false
    var motionGateEnabled: Bool = false
    var motionGateWindowSeconds: Int = 3
    var motionGateStillVariance: Double = 0.02
    var motionGateMinPeakRatio: Double = 0.12
    var motionGateMaxZeroCrossingRate: Double = 9
    var motionGateEngageSeconds: Int = 2

    static let defaultReadTypes = ["steps", "distance", "totalCalories"]
    static let readTypeOrder = ["steps", "distance", "totalCalories"]
    static let vitalOrder = ["heartRate", "restingHeartRate", "oxygenSaturation", "respiratoryRate",
                             "bloodPressure", "bodyTemperature", "bloodGlucose"]

    var integrityMode: IntegrityMode { IntegrityMode(rawValue: fraudMode) ?? .flag }

    var excludeSuspect: Bool { fraudDetectionEnabled && integrityMode == .exclude }

    /// Motion activity is wanted by the gate, or by the integrity tags.
    var wantsActivity: Bool { motionGateEnabled || (fraudDetectionEnabled && fraudActivityRecognition) }

    func integrityRules() -> IntegrityRules {
        IntegrityRules(maxCadenceSpm: fraudMaxCadenceSpm, steadyCadenceMinutes: fraudSteadyCadenceMinutes,
                       maxContinuousMinutes: fraudMaxContinuousMinutes, maxDailySteps: fraudMaxDailySteps,
                       flagWhileCharging: fraudFlagWhileCharging)
    }

    // ---- clamping --------------------------------------------------------------

    func sanitised() -> StepTrackerConfig {
        var c = self
        func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
        func offOr(_ v: Int, _ f: (Int) -> Int) -> Int { v <= 0 ? 0 : f(v) }
        func finiteOr(_ v: Double, _ fallback: Double, _ f: (Double) -> Double) -> Double { v.isFinite ? f(v) : fallback }
        c.heightCm = heightCm.isFinite ? clamp(heightCm, 50, 260) : 170
        c.weightKg = weightKg.isFinite ? clamp(weightKg, 10, 400) : 70
        c.strideLengthM = strideLengthM.isFinite ? clamp(strideLengthM, 0, 3) : 0
        c.dailyGoal = max(0, dailyGoal)
        c.weeklyGoal = max(0, weeklyGoal)
        c.monthlyGoal = max(0, monthlyGoal)
        c.calorieCoefficient = calorieCoefficient.isFinite ? clamp(calorieCoefficient, 0, 10) : 0.57
        c.historyRetentionDays = max(1, historyRetentionDays)
        c.notificationThrottleMs = max(0, notificationThrottleMs)
        c.eventThrottleMs = max(0, eventThrottleMs)
        c.persistEveryNSteps = max(1, persistEveryNSteps)
        c.healthConnectSyncIntervalMinutes = max(0, healthConnectSyncIntervalMinutes)
        c.stepSource = StepSourcePolicy(rawValue: stepSource)?.rawValue ?? "auto"
        c.preferredStepSourcePackage = preferredStepSourcePackage.flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        c.wearableTrust = WearableTrust(rawValue: wearableTrust)?.rawValue ?? "metadata"
        var seen = Set<String>()
        c.wearableAllowlist = wearableAllowlist.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        c.notificationLockScreen = notificationLockScreen == "public" ? "public" : "private"
        c.notificationDistanceUnit = ["km", "mi", "auto"].contains(notificationDistanceUnit) ? notificationDistanceUnit : "km"
        // Android's ReadType.parse: known names, steps always, in a fixed order.
        var types = Set(healthConnectReadTypes.filter { StepTrackerConfig.readTypeOrder.contains($0) })
        types.insert("steps")
        c.healthConnectReadTypes = StepTrackerConfig.readTypeOrder.filter { types.contains($0) }
        let vitals = Set(healthConnectReadVitals)
        c.healthConnectReadVitals = StepTrackerConfig.vitalOrder.filter { vitals.contains($0) }
        c.healthConnectWriteGranularity = healthConnectWriteGranularity == "minute" ? "minute" : "day"
        c.privacyPolicyUrl = privacyPolicyUrl.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        c.remoteSyncPayload = remoteSyncPayload == "full" ? "full" : "totals"
        c.remoteSyncAuth = remoteSyncAuth == "signature" ? "signature" : "headers"
        c.gapRecovery = ["split", "today", "today_capped", "drop"].contains(gapRecovery) ? gapRecovery : "split"
        c.gapRecoveryMaxSteps = max(0, gapRecoveryMaxSteps)
        c.accelerometerThreshold = accelerometerThreshold.isFinite ? clamp(accelerometerThreshold, 0.3, 10) : 0.9
        c.motionWindowSeconds = clamp(motionWindowSeconds, 1, 60)
        c.motionIntervalMinutes = max(1, motionIntervalMinutes)
        c.motionWindowRetention = max(1, motionWindowRetention)
        c.fraudMode = IntegrityMode(rawValue: fraudMode)?.rawValue ?? "flag"
        c.fraudMaxCadenceSpm = offOr(fraudMaxCadenceSpm) { clamp($0, 100, 400) }
        c.fraudSteadyCadenceMinutes = offOr(fraudSteadyCadenceMinutes) { clamp($0, 5, 24 * 60) }
        c.fraudMaxContinuousMinutes = offOr(fraudMaxContinuousMinutes) { clamp($0, 30, 24 * 60) }
        c.fraudMaxDailySteps = offOr(fraudMaxDailySteps) { max($0, 1_000) }
        c.motionGateWindowSeconds = clamp(motionGateWindowSeconds, 1, 15)
        c.motionGateStillVariance = finiteOr(motionGateStillVariance, 0.02) { clamp($0, 0, 1) }
        c.motionGateMinPeakRatio = finiteOr(motionGateMinPeakRatio, 0.12) { clamp($0, 0, 0.9) }
        c.motionGateMaxZeroCrossingRate = finiteOr(motionGateMaxZeroCrossingRate, 9) { clamp($0, 1, 100) }
        c.motionGateEngageSeconds = clamp(motionGateEngageSeconds, 0, 120)
        return c
    }

    // ---- patching ----------------------------------------------------------------

    /// Android's `mergeConfig`: only the keys present (and not null) move.
    /// `fraudDetection`, `motionSampling` and `motionGate` are patched key by key.
    func merging(_ patch: JSON) -> StepTrackerConfig {
        var c = self
        let p = ConfigPatch(patch)
        c.heightCm = p.double("height") ?? heightCm
        c.weightKg = p.double("weight") ?? weightKg
        c.strideLengthM = p.double("strideLength") ?? strideLengthM
        c.sex = p.string("sex") ?? sex
        c.dailyGoal = p.int("dailyGoal") ?? dailyGoal
        c.weeklyGoal = p.int("weeklyGoal") ?? weeklyGoal
        c.monthlyGoal = p.int("monthlyGoal") ?? monthlyGoal
        c.calorieCoefficient = p.double("calorieCoefficient") ?? calorieCoefficient
        c.historyRetentionDays = p.int("historyRetentionDays") ?? historyRetentionDays
        c.notificationTitle = p.string("notificationTitle") ?? notificationTitle
        c.notificationText = p.string("notificationText") ?? notificationText
        c.notificationIcon = p.string("notificationIcon") ?? notificationIcon
        c.notificationChannelName = p.string("notificationChannelName") ?? notificationChannelName
        c.notificationActions = p.bool("notificationActions") ?? notificationActions
        c.notificationLockScreen = p.string("notificationLockScreen") ?? notificationLockScreen
        c.notificationDistanceUnit = p.string("notificationDistanceUnit") ?? notificationDistanceUnit
        c.notificationThrottleMs = p.int64("notificationThrottleMs") ?? notificationThrottleMs
        c.eventThrottleMs = p.int64("eventThrottleMs") ?? eventThrottleMs
        c.persistEveryNSteps = p.int("persistEveryNSteps") ?? persistEveryNSteps
        c.healthConnectEnabled = p.bool("healthConnectEnabled") ?? healthConnectEnabled
        c.healthConnectSyncIntervalMinutes = p.int("healthConnectSyncIntervalMinutes") ?? healthConnectSyncIntervalMinutes
        c.healthConnectReadEnabled = p.bool("healthConnectReadEnabled") ?? healthConnectReadEnabled
        c.healthConnectWriteEnabled = p.bool("healthConnectWriteEnabled") ?? healthConnectWriteEnabled
        c.healthConnectWriteExplicit = healthConnectWriteExplicit || p.has("healthConnectWriteEnabled")
        c.healthConnectReadTypesExplicit = healthConnectReadTypesExplicit || p.has("healthConnectReadTypes")
        c.healthConnectBackgroundRead = p.bool("healthConnectBackgroundRead") ?? healthConnectBackgroundRead
        c.healthConnectHistoryRead = p.bool("healthConnectHistoryRead") ?? healthConnectHistoryRead
        c.healthConnectIgnoreManualEntries = p.bool("healthConnectIgnoreManualEntries") ?? healthConnectIgnoreManualEntries
        c.healthConnectReadActiveCalories = p.bool("healthConnectReadActiveCalories") ?? healthConnectReadActiveCalories
        c.healthConnectReadTypes = p.strings("healthConnectReadTypes") ?? healthConnectReadTypes
        c.healthConnectWriteGranularity = p.string("healthConnectWriteGranularity") ?? healthConnectWriteGranularity
        c.healthConnectReadVitals = p.strings("healthConnectReadVitals") ?? healthConnectReadVitals
        c.stepSource = p.string("stepSource") ?? stepSource
        c.preferredStepSourcePackage = p.string("preferredStepSourcePackage") ?? preferredStepSourcePackage
        c.wearableTrust = p.string("wearableTrust") ?? wearableTrust
        if p.has("wearableAllowlist") { c.wearableAllowlist = p.strings("wearableAllowlist") ?? [] }
        c.privacyPolicyUrl = p.string("privacyPolicyUrl") ?? privacyPolicyUrl
        c.remoteSyncUrl = p.string("remoteSyncUrl") ?? remoteSyncUrl
        if p.present("remoteSyncHeaders") { c.remoteSyncHeaders = p.stringMap("remoteSyncHeaders") }
        c.remoteSyncAllowHttp = p.bool("remoteSyncAllowHttp") ?? remoteSyncAllowHttp
        c.remoteSyncPayload = p.string("remoteSyncPayload") ?? remoteSyncPayload
        c.remoteSyncAuth = p.string("remoteSyncAuth") ?? remoteSyncAuth
        c.autoStartOnBoot = p.bool("autoStartOnBoot") ?? autoStartOnBoot
        c.gapRecovery = p.string("gapRecovery") ?? gapRecovery
        c.gapRecoveryMaxSteps = p.int("gapRecoveryMaxSteps") ?? gapRecoveryMaxSteps
        c.watchdogEnabled = p.bool("watchdogEnabled") ?? watchdogEnabled
        c.accelerometerFallback = p.bool("accelerometerFallback") ?? accelerometerFallback
        c.accelerometerWakeLock = p.bool("accelerometerWakeLock") ?? accelerometerWakeLock
        c.accelerometerThreshold = p.double("accelerometerThreshold") ?? accelerometerThreshold
        if let m = p.nested("motionSampling") {
            c.motionSamplingEnabled = m.bool("enabled") ?? motionSamplingEnabled
            c.motionWindowSeconds = m.int("windowSeconds") ?? motionWindowSeconds
            c.motionIntervalMinutes = m.int("intervalMinutes") ?? motionIntervalMinutes
        }
        c.motionWindowRetention = p.int("motionWindowRetention") ?? motionWindowRetention
        if let f = p.nested("fraudDetection") {
            c.fraudDetectionEnabled = f.bool("enabled") ?? fraudDetectionEnabled
            c.fraudMode = f.string("mode") ?? fraudMode
            c.fraudMaxCadenceSpm = f.int("maxCadenceSpm") ?? fraudMaxCadenceSpm
            c.fraudSteadyCadenceMinutes = f.int("steadyCadenceMinutes") ?? fraudSteadyCadenceMinutes
            c.fraudMaxContinuousMinutes = f.int("maxContinuousMinutes") ?? fraudMaxContinuousMinutes
            c.fraudMaxDailySteps = f.int("maxDailySteps") ?? fraudMaxDailySteps
            c.fraudFlagWhileCharging = f.bool("flagWhileCharging") ?? fraudFlagWhileCharging
            c.fraudActivityRecognition = f.bool("activityRecognition") ?? fraudActivityRecognition
        }
        if let g = p.nested("motionGate") {
            c.motionGateEnabled = g.bool("enabled") ?? motionGateEnabled
            c.motionGateWindowSeconds = g.int("windowSeconds") ?? motionGateWindowSeconds
            c.motionGateStillVariance = g.double("stillVariance") ?? motionGateStillVariance
            c.motionGateMinPeakRatio = g.double("minPeakRatio") ?? motionGateMinPeakRatio
            c.motionGateMaxZeroCrossingRate = g.double("maxZeroCrossingRate") ?? motionGateMaxZeroCrossingRate
            c.motionGateEngageSeconds = g.int("engageSeconds") ?? motionGateEngageSeconds
        }
        return c
    }

    /// The keys that matter to an integrity verdict and changed - Android
    /// logs them as `config_changed`.
    func integrityChanges(from previous: StepTrackerConfig) -> [String] {
        var keys: [String] = []
        if previous.fraudDetectionEnabled != fraudDetectionEnabled { keys.append("fraudDetection.enabled") }
        if previous.fraudMode != fraudMode { keys.append("fraudDetection.mode") }
        if previous.integrityRules() != integrityRules() { keys.append("fraudDetection.rules") }
        if previous.fraudActivityRecognition != fraudActivityRecognition { keys.append("fraudDetection.activityRecognition") }
        if previous.motionGateEnabled != motionGateEnabled { keys.append("motionGate.enabled") }
        if previous.stepSource != stepSource { keys.append("stepSource") }
        if previous.healthConnectIgnoreManualEntries != healthConnectIgnoreManualEntries { keys.append("healthConnectIgnoreManualEntries") }
        if previous.wearableTrust != wearableTrust { keys.append("wearableTrust") }
        return keys
    }

    /// The Apple Health types read on iOS: steps, and distance when asked
    /// for. Calories never are.
    var healthReadKinds: [HealthSample.Kind] {
        healthConnectReadTypes.contains("distance") ? [.steps, .distance] : [.steps]
    }

    /// The types an observer query is wanted for: those read, and none with
    /// Apple Health or its reads turned off.
    var observedHealthKinds: [HealthSample.Kind] {
        healthConnectEnabled && healthConnectReadEnabled ? healthReadKinds : []
    }

    // ---- shapes ------------------------------------------------------------------

    /// What `getConfig()` and `updateConfig()` resolve with: Android's `configToMap`.
    func jsObject() -> JSON {
        .object([
            ("height", .double(heightCm)),
            ("weight", .double(weightKg)),
            ("strideLength", .double(strideLengthM)),
            ("sex", .string(sex)),
            ("dailyGoal", .int(dailyGoal)),
            ("weeklyGoal", .int(weeklyGoal)),
            ("monthlyGoal", .int(monthlyGoal)),
            ("calorieCoefficient", .double(calorieCoefficient)),
            ("historyRetentionDays", .int(historyRetentionDays)),
            ("notificationActions", .bool(notificationActions)),
            ("notificationLockScreen", .string(notificationLockScreen)),
            ("notificationDistanceUnit", .string(notificationDistanceUnit)),
            ("healthConnectEnabled", .bool(healthConnectEnabled)),
            ("healthConnectSyncIntervalMinutes", .int(healthConnectSyncIntervalMinutes)),
            ("healthConnectReadEnabled", .bool(healthConnectReadEnabled)),
            ("healthConnectWriteEnabled", .bool(healthConnectWriteEnabled)),
            ("healthConnectBackgroundRead", .bool(healthConnectBackgroundRead)),
            ("healthConnectHistoryRead", .bool(healthConnectHistoryRead)),
            ("healthConnectIgnoreManualEntries", .bool(healthConnectIgnoreManualEntries)),
            ("healthConnectReadActiveCalories", .bool(healthConnectReadActiveCalories)),
            ("healthConnectReadTypes", .strings(healthConnectReadTypes)),
            ("healthConnectReadVitals", .strings(healthConnectReadVitals)),
            ("healthConnectWriteGranularity", .string(healthConnectWriteGranularity)),
            ("stepSource", .string(stepSource)),
            ("preferredStepSourcePackage", .optional(preferredStepSourcePackage)),
            ("wearableTrust", .string(wearableTrust)),
            ("wearableAllowlist", .strings(wearableAllowlist)),
            ("privacyPolicyUrl", .optional(privacyPolicyUrl)),
            ("remoteSyncUrl", .optional(remoteSyncUrl)),
            ("remoteSyncAllowHttp", .bool(remoteSyncAllowHttp)),
            ("remoteSyncPayload", .string(remoteSyncPayload)),
            ("remoteSyncAuth", .string(remoteSyncAuth)),
            ("autoStartOnBoot", .bool(autoStartOnBoot)),
            ("gapRecovery", .string(gapRecovery)),
            ("gapRecoveryMaxSteps", .int(gapRecoveryMaxSteps)),
            ("watchdogEnabled", .bool(watchdogEnabled)),
            ("accelerometerFallback", .bool(accelerometerFallback)),
            ("accelerometerWakeLock", .bool(accelerometerWakeLock)),
            ("accelerometerThreshold", .double(accelerometerThreshold)),
            ("motionSampling", .object([
                ("enabled", .bool(motionSamplingEnabled)),
                ("windowSeconds", .int(motionWindowSeconds)),
                ("intervalMinutes", .int(motionIntervalMinutes)),
            ])),
            ("motionWindowRetention", .int(motionWindowRetention)),
            ("fraudDetection", .object([
                ("enabled", .bool(fraudDetectionEnabled)),
                ("mode", .string(fraudMode)),
                ("maxCadenceSpm", .int(fraudMaxCadenceSpm)),
                ("steadyCadenceMinutes", .int(fraudSteadyCadenceMinutes)),
                ("maxContinuousMinutes", .int(fraudMaxContinuousMinutes)),
                ("maxDailySteps", .int(fraudMaxDailySteps)),
                ("flagWhileCharging", .bool(fraudFlagWhileCharging)),
                ("activityRecognition", .bool(fraudActivityRecognition)),
            ])),
            ("motionGate", .object([
                ("enabled", .bool(motionGateEnabled)),
                ("windowSeconds", .int(motionGateWindowSeconds)),
                ("stillVariance", .double(motionGateStillVariance)),
                ("minPeakRatio", .double(motionGateMinPeakRatio)),
                ("maxZeroCrossingRate", .double(motionGateMaxZeroCrossingRate)),
                ("engageSeconds", .int(motionGateEngageSeconds)),
            ])),
        ])
    }

    /// Everything, for storage on device - the JS shape plus the keys
    /// `getConfig()` leaves out, as Android stores them. Headers are not
    /// here: they live in the Keychain.
    func storeObject() -> JSON {
        var obj = jsObject()
        let extra: [(String, JSON)] = [
            ("notificationTitle", .optional(notificationTitle)),
            ("notificationText", .optional(notificationText)),
            ("notificationIcon", .optional(notificationIcon)),
            ("notificationChannelName", .optional(notificationChannelName)),
            ("notificationThrottleMs", .int(notificationThrottleMs)),
            ("eventThrottleMs", .int(eventThrottleMs)),
            ("persistEveryNSteps", .int(persistEveryNSteps)),
            ("healthConnectReadTypesExplicit", .bool(healthConnectReadTypesExplicit)),
            ("healthConnectWriteExplicit", .bool(healthConnectWriteExplicit)),
        ]
        for (key, value) in extra { obj = obj.setting(key, value) }
        return obj
    }

    /// Back from `storeObject()`: the stored keys patched onto the defaults.
    static func fromStore(_ json: JSON) -> StepTrackerConfig {
        var c = StepTrackerConfig().merging(json)
        // Merging treats null as "leave alone"; stored nulls mean unset.
        if json["preferredStepSourcePackage"]?.isNull == true { c.preferredStepSourcePackage = nil }
        if json["privacyPolicyUrl"]?.isNull == true { c.privacyPolicyUrl = nil }
        if json["remoteSyncUrl"]?.isNull == true { c.remoteSyncUrl = nil }
        c.healthConnectReadTypesExplicit = json["healthConnectReadTypesExplicit"]?.boolValue ?? false
        c.healthConnectWriteExplicit = json["healthConnectWriteExplicit"]?.boolValue ?? false
        return c.sanitised()
    }
}

/// Reads a config patch the way Android's ReadableMap helpers do: a key
/// that is absent or null is "not given".
struct ConfigPatch {
    let json: JSON

    init(_ json: JSON) { self.json = json }

    func present(_ key: String) -> Bool { json[key] != nil }

    func has(_ key: String) -> Bool {
        guard let value = json[key] else { return false }
        return !value.isNull
    }

    func double(_ key: String) -> Double? { json[key]?.doubleValue }

    /// Truncated toward zero, as `ReadableMap.getInt` does.
    func int(_ key: String) -> Int? {
        guard let d = json[key]?.doubleValue, d.isFinite else { return nil }
        return Int(max(min(d, Double(Int32.max)), Double(Int32.min)).rounded(.towardZero))
    }

    func int64(_ key: String) -> Int64? {
        guard let d = json[key]?.doubleValue, d.isFinite else { return nil }
        return Int64(max(min(d, 9.0e15), -9.0e15).rounded(.towardZero))
    }

    func bool(_ key: String) -> Bool? { json[key]?.boolValue }

    func string(_ key: String) -> String? { json[key]?.stringValue }

    func strings(_ key: String) -> [String]? { json[key]?.arrayValue?.compactMap(\.stringValue) }

    func stringMap(_ key: String) -> [String: String] {
        guard case let .object(pairs)? = json[key] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in pairs { if let s = v.stringValue { out[k] = s } }
        return out
    }

    func nested(_ key: String) -> ConfigPatch? {
        guard let value = json[key], case .object = value else { return nil }
        return ConfigPatch(value)
    }
}
