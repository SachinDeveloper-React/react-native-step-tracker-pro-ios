import Foundation

/// A rejection with a stable code, as react-native-step-tracker-pro maps them.
struct BridgeError: Error {
    let code: String
    let message: String
    var details: [String: Any]?

    static func invalid(_ message: String) -> BridgeError { BridgeError(code: "E_INVALID_CONFIG", message: message) }
}

/// Everything this package keeps between launches, apart from config, days
/// and the event log.
struct EngineState: Codable {
    var trackingState = TrackingState.idle
    /// When tracking ran; steps outside them are not this phone's count.
    var spans: [TrackingSpan] = []
    /// The first `startTracking()` ever: the install day's coverage start.
    var firstStartAt: Int64 = 0
    var countFromAt: Int64 = 0
    /// `resetToday()`: day -> the instant that day was started over from.
    var resetAt: [String: Int64] = [:]
    /// `clearHistory()`: days before this one are gone.
    var clearedBefore: String?
    var otherDevices: [String: Int] = [:]
    var preferredStepSource: String?
    var continuity: StepContinuity.Baseline?
    var goals: [String: String] = [:]
    var lastResolvedSource: String?
    var lastPedometerAt: Int64 = 0
    /// Spans the package saw the phone plugged in: [start, end], end 0 while open.
    var chargingSpans: [[Int64]] = []
    var lastDate: String?
    var lastTimeZone: String?
    /// Wall clock minus uptime at the last look, to measure a clock edit.
    var lastBootOffsetMs: Int64 = 0
    var reportedFlags: [String: [String]] = [:]
    var lastResolvedSteps: [String: Int] = [:]
    var healthFingerprint: String?
    var healthDenials = 0
    var healthRequested = false
    // The signing key's record; the key itself is in the Keychain.
    var keyCreatedAt: Int64 = 0
    var keyCreatedBy: String?
    var keyAttested = false
    var keySecurityLevel: String?
    var appAttestKeyId: String?
    var appAttestObject: String?
    var appAttestClientData: String?
    var appAttestEnvironment: String?
    /// This iPhone's own source in Apple Health, learned by matching the
    /// pedometer - see `HealthSources.identifyThisPhone`.
    var thisPhoneBundle: String?

    init() {}

    /// Every field optional on the way in, so a file an earlier version
    /// wrote - or a later one, with keys this one does not know - still
    /// loads. A failed decode would start from nothing: tracking state,
    /// spans, countFrom and the key's record, gone with an app update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        trackingState = v(.trackingState, .idle)
        spans = v(.spans, [])
        firstStartAt = v(.firstStartAt, 0)
        countFromAt = v(.countFromAt, 0)
        resetAt = v(.resetAt, [:])
        clearedBefore = v(.clearedBefore, nil)
        otherDevices = v(.otherDevices, [:])
        preferredStepSource = v(.preferredStepSource, nil)
        continuity = v(.continuity, nil)
        goals = v(.goals, [:])
        lastResolvedSource = v(.lastResolvedSource, nil)
        lastPedometerAt = v(.lastPedometerAt, 0)
        chargingSpans = v(.chargingSpans, [])
        lastDate = v(.lastDate, nil)
        lastTimeZone = v(.lastTimeZone, nil)
        lastBootOffsetMs = v(.lastBootOffsetMs, 0)
        reportedFlags = v(.reportedFlags, [:])
        lastResolvedSteps = v(.lastResolvedSteps, [:])
        healthFingerprint = v(.healthFingerprint, nil)
        healthDenials = v(.healthDenials, 0)
        healthRequested = v(.healthRequested, false)
        keyCreatedAt = v(.keyCreatedAt, 0)
        keyCreatedBy = v(.keyCreatedBy, nil)
        keyAttested = v(.keyAttested, false)
        keySecurityLevel = v(.keySecurityLevel, nil)
        appAttestKeyId = v(.appAttestKeyId, nil)
        appAttestObject = v(.appAttestObject, nil)
        appAttestClientData = v(.appAttestClientData, nil)
        appAttestEnvironment = v(.appAttestEnvironment, nil)
        thisPhoneBundle = v(.thisPhoneBundle, nil)
    }
}

/// One day of this phone's own count, as computed and kept.
struct DayRecord: Codable {
    var date: String
    var deviceSteps: Int
    var gatedSteps: Int
    var minutes: [MinuteSample]
    /// `pedometer`, or `healthkit` for the fallback.
    var sensor: String
    var computedAt: Int64
    /// Computed after the day closed: never computed again.
    var final: Bool
    var flagsJSON: String?
    var flaggedSteps: Int = 0
    var evaluatedAt: Int64 = 0
    /// The day's Apple Health sources as last read, for a locked phone.
    var sourcesJSON: String?

    init(date: String, deviceSteps: Int, gatedSteps: Int, minutes: [MinuteSample], sensor: String,
         computedAt: Int64, final: Bool) {
        self.date = date
        self.deviceSteps = deviceSteps
        self.gatedSteps = gatedSteps
        self.minutes = minutes
        self.sensor = sensor
        self.computedAt = computedAt
        self.final = final
    }

    /// Lenient, like `EngineState`: a stored day that fails to decode is a
    /// day lost once it is past the pedometer's week.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        date = try c.decode(String.self, forKey: .date)
        deviceSteps = v(.deviceSteps, 0)
        gatedSteps = v(.gatedSteps, 0)
        minutes = v(.minutes, [])
        sensor = v(.sensor, "pedometer")
        computedAt = v(.computedAt, 0)
        final = v(.final, false)
        flagsJSON = v(.flagsJSON, nil)
        flaggedSteps = v(.flaggedSteps, 0)
        evaluatedAt = v(.evaluatedAt, 0)
        sourcesJSON = v(.sourcesJSON, nil)
    }

    var flags: [IntegrityFlag] {
        guard let text = flagsJSON, let json = JSON.parse(text)?.arrayValue else { return [] }
        return json.compactMap(IntegrityFlag.init(json:))
    }

    var count: DayCount { DayCount(deviceSteps: deviceSteps, gatedSteps: gatedSteps, minutes: minutes) }
}

/// Files in Application Support, protected until the first unlock after a
/// boot - so a background wake on a locked phone can still read and write
/// them - and kept out of backups, like Android's keystore-bound state.
final class Store {
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("StepTrackerPro", isDirectory: true)
        ensure(root)
        ensure(root.appendingPathComponent("days", isDirectory: true))
    }

    private func ensure(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    var stateExists: Bool { FileManager.default.fileExists(atPath: url("state.json").path) }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func write(_ data: Data, _ name: String) {
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    // ---- state and config ------------------------------------------------------

    func loadState() -> EngineState? { read("state.json").flatMap { try? decoder.decode(EngineState.self, from: $0) } }

    func saveState(_ state: EngineState) {
        if let data = try? encoder.encode(state) { write(data, "state.json") }
    }

    func loadConfig() -> JSON? { read("config.json").flatMap(JSON.parse) }

    func saveConfig(_ json: JSON) { write(Data(json.serialized().utf8), "config.json") }

    // ---- days ------------------------------------------------------------------------

    func day(_ date: String) -> DayRecord? {
        read("days/\(date).json").flatMap { try? decoder.decode(DayRecord.self, from: $0) }
    }

    func saveDay(_ record: DayRecord) {
        if let data = try? encoder.encode(record) { write(data, "days/\(record.date).json") }
    }

    func storedDates() -> [String] {
        let dir = root.appendingPathComponent("days")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    @discardableResult
    func deleteDay(_ date: String) -> Bool {
        (try? FileManager.default.removeItem(at: url("days/\(date).json"))) != nil
    }

    // ---- the pedometer's settled hours ------------------------------------------------

    func loadHourCache() -> HourCache? { read("hours.json").flatMap(HourCache.decoded) }

    func saveHourCache(_ cache: HourCache) { write(cache.encoded(), "hours.json") }

    // ---- events ----------------------------------------------------------------------

    func events() -> [IntegrityEvent] {
        guard let data = read("events.json"), let json = JSON.parse(data)?.arrayValue else { return [] }
        return json.compactMap(IntegrityEvent.init(json:))
    }

    func saveEvents(_ events: [IntegrityEvent]) {
        write(Data(JSON.array(events.map { $0.json() }).serialized().utf8), "events.json")
    }

    func wipe() {
        try? FileManager.default.removeItem(at: root)
        ensure(root)
        ensure(root.appendingPathComponent("days", isDirectory: true))
    }
}
