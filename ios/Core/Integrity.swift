import CryptoKit
import Foundation

/// Something that happened that a server judging a day wants to see next to
/// the numbers - Android's `IntegrityEvent`.
struct IntegrityEvent: Equatable {
    static let clockChanged = "clock_changed"
    static let timezoneChanged = "timezone_changed"
    static let resetToday = "reset_today"
    static let countFrom = "count_from"
    static let historyCleared = "history_cleared"
    static let configChanged = "config_changed"
    static let sensorChanged = "sensor_changed"
    static let chargingStarted = "charging_started"
    static let chargingStopped = "charging_stopped"
    static let activityChanged = "activity_changed"
    static let motionGate = "motion_gate"
    static let deviceAttested = "device_attested"

    var at: Int64
    var type: String
    var detail: JSON = .object([])

    func json() -> JSON { .object([("at", .int(at)), ("type", .string(type)), ("detail", detail)]) }

    init(at: Int64, type: String, detail: JSON = .object([])) {
        self.at = at
        self.type = type
        self.detail = detail
    }

    init?(json: JSON) {
        guard let type = json["type"]?.stringValue, let at = json["at"]?.int64Value else { return nil }
        self.at = at
        self.type = type
        detail = json["detail"] ?? .object([])
    }
}

/// Fires each goal at most once per period - the port of Android's
/// `GoalTracker`, over any key-value store.
struct GoalRules {
    static let daily = "daily"
    static let weekly = "weekly"
    static let monthly = "monthly"

    struct Reached: Equatable {
        var type: String
        var goal: Int
        var steps: Int
        var periodKey: String
    }

    /// `fired_<type>` -> period key, `fired_goal_<type>` -> goal, `bucket_<type>` -> percent.
    var values: [String: String] = [:]

    mutating func check(_ type: String, periodKey: String, steps: Int, goal: Int) -> Reached? {
        guard goal > 0, steps >= goal else { return nil }
        if values["fired_\(type)"] == periodKey {
            let celebrated = Int(values["fired_goal_\(type)"] ?? "") ?? Int.max
            if goal <= celebrated { return nil }
        }
        values["fired_\(type)"] = periodKey
        values["fired_goal_\(type)"] = String(goal)
        return Reached(type: type, goal: goal, steps: steps, periodKey: periodKey)
    }

    func alreadyFired(_ type: String, periodKey: String) -> Bool { values["fired_\(type)"] == periodKey }

    /// Emits progress only when the whole-percent bucket changes.
    mutating func progressBucketChanged(_ type: String, percent: Int) -> Bool {
        if values["bucket_\(type)"] == String(percent) { return false }
        values["bucket_\(type)"] = String(percent)
        return true
    }

    /// Rearms today's goal; the weekly and monthly markers stand.
    mutating func reset() {
        values.removeValue(forKey: "fired_\(GoalRules.daily)")
        values.removeValue(forKey: "fired_goal_\(GoalRules.daily)")
        values.removeValue(forKey: "bucket_\(GoalRules.daily)")
    }
}

/// What the app says the user's other devices counted, by day - Android's
/// `StepStateStore` rules.
enum OtherDevices {
    static let days = 7
    static let maxSteps = 1_000_000

    /// No day at zero, and only from a week before today to the day after.
    static func kept(_ byDate: [String: Int], today: String, clock: DayClock) -> [String: Int] {
        let first = clock.minusDays(today, days)
        let last = clock.minusDays(today, -1)
        return byDate.filter { $0.value > 0 && $0.key >= first && $0.key <= last }
    }

    static func encode(_ owed: [String: Int]) -> String {
        owed.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    static func decode(_ text: String?) -> [String: Int] {
        guard let text, !text.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 10, let steps = Int(parts[1]), steps > 0 else { continue }
            out[String(parts[0]), default: 0] += steps
        }
        return out
    }
}

/// The P-256 key shapes Android's Keystore and a server agree on.
enum KeyEncoding {
    /// The DER prefix of a P-256 SubjectPublicKeyInfo: SEQUENCE { SEQUENCE {
    /// id-ecPublicKey, prime256v1 }, BIT STRING } - 26 bytes, followed by
    /// the 65-byte uncompressed X9.63 point.
    static let p256SpkiHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    static func spki(x963 point: Data) -> Data? {
        guard point.count == 65, point.first == 0x04 else { return nil }
        return Data(p256SpkiHeader) + point
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Lowercase hex SHA-256 of the SPKI DER - the id Android files a key under.
    static func keyId(spki: Data) -> String { hex(sha256(spki)) }
}
