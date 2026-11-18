import Foundation

/// Everything one day's verification snapshot is made of, gathered by the
/// engine, so the shape itself - key order, nulls, which keys appear when -
/// is built and tested without a device.
struct SnapshotInput {
    var date: String
    var deviceSteps: Int
    var gatedSteps: Int
    var coverageStartAt: Int64
    var countFrom: Int64?
    var sources: [StepSource]
    var sourcesStatus: String
    var resolved: JSON
    var otherDevicesSteps: Int
    var capabilities: JSON
    var clock: JSON
    var suspectSteps: Int
    var integrity: JSON
    var include: [String] = []
    var minutesStatus: String?
    var minutes: [MinuteSample]?
    var healthRecords: JSON?
    var nonce: String?
}

enum Snapshot {
    static let schemaVersion = 2
    static let parts = ["minutes", "motionWindows", "healthConnectRecords"]

    /// The snapshot, key for key in Android's order, with iOS's values.
    static func build(_ i: SnapshotInput) -> JSON {
        var pairs: [(String, JSON)] = [
            ("schemaVersion", .int(schemaVersion)),
            ("libraryVersion", .string(LibraryVersion.current)),
            ("platform", .string("ios")),
            ("date", .string(i.date)),
            ("deviceSteps", .int(i.deviceSteps)),
            // The pedometer counts with the app dead: nothing is ever recovered.
            ("recoveredSteps", .int(0)),
            ("gatedSteps", .int(i.gatedSteps)),
            ("sensor", .string("step_counter")),
            ("coverageStartAt", .int(i.coverageStartAt)),
            ("countFrom", .optional(i.countFrom)),
            ("sources", .array(i.sources.map { $0.json() })),
            ("sourcesStatus", .string(i.sourcesStatus)),
            ("resolved", i.resolved),
            ("otherDevicesSteps", .int(i.otherDevicesSteps)),
            ("capabilities", i.capabilities),
            ("health", .object([
                ("recoveryCount", .int(0)),
                ("lastRecoveryReason", .null),
                ("batteryOptimizationEnabled", .bool(false)),
                ("aggressiveOem", .bool(false)),
            ])),
            ("clock", i.clock),
            ("suspectSteps", .int(i.suspectSteps)),
            ("integrity", i.integrity),
        ]
        let include = parts.filter { i.include.contains($0) }
        if !include.isEmpty { pairs.append(("include", .strings(include))) }
        if include.contains("minutes") {
            pairs.append(("minutesStatus", .string(i.minutesStatus ?? "disabled")))
            pairs.append(("minutes", .array((i.minutes ?? []).map { $0.json() })))
        }
        if include.contains("motionWindows") {
            // No background accelerometer on iOS: never any windows.
            pairs.append(("motionWindowsStatus", .string("unsupported")))
            pairs.append(("motionWindows", .array([])))
        }
        if include.contains("healthConnectRecords") {
            pairs.append(("healthConnectRecords", i.healthRecords ?? .null))
        }
        if let nonce = i.nonce { pairs.append(("nonce", .string(nonce))) }
        return .object(pairs)
    }

    /// The signed body - the snapshot with `signedAt` - and its exact bytes.
    static func signedBody(_ snapshot: JSON, signedAt: Int64) -> (JSON, Data) {
        let body = snapshot.setting("signedAt", .int(signedAt))
        return (body, Data(body.serialized().utf8))
    }

    /// The `signature` block, as Android orders it.
    static func signatureBlock(keyId: String, value: Data, attested: Bool, payload: Data) -> JSON {
        .object([
            ("keyId", .string(keyId)),
            ("algorithm", .string("SHA256withECDSA")),
            ("value", .string(value.base64EncodedString())),
            ("attested", .bool(attested)),
            ("signedPayload", .string(String(decoding: payload, as: UTF8.self))),
            ("payloadSha256", .string(KeyEncoding.hex(KeyEncoding.sha256(payload)))),
        ])
    }

    /// `capabilities` inside the snapshot.
    static func capabilities(hasStepCounter: Bool, model: String, osVersion: String) -> JSON {
        .object([
            ("hasStepCounter", .bool(hasStepCounter)),
            ("hasStepDetector", .bool(false)),
            ("manufacturer", .string("Apple")),
            ("model", .string(model)),
            ("sdkInt", .int(0)),
            ("osVersion", .string(osVersion)),
        ])
    }

    static func clock(nowMs: Int64, bootMs: Int64, zone: TimeZone) -> JSON {
        .object([
            ("wallClockMs", .int(nowMs)),
            ("bootId", .int(bootMs)),
            ("timezone", .string(zone.identifier)),
            ("utcOffsetMinutes", .int(zone.secondsFromGMT(for: DayClock.date(nowMs)) / 60)),
        ])
    }
}

/// Everything the integrity report is made of - the port of Android's
/// `IntegrityMonitor.report` plus the core's `motionGate` block.
struct IntegrityReportInput {
    var date: String
    var enabled: Bool
    var mode: String
    var deviceSteps: Int
    var flaggedSteps: Int
    var flags: [IntegrityFlag]
    var events: [IntegrityEvent]
    var minutes: [MinuteSample]
    var evaluatedAt: Int64
    var rules: IntegrityRules
    var charging: Bool
    var activityRequested: Bool
    var activityAvailable: Bool
    var activityStatus: String
    var activityCurrent: String
    var gate: StepTrackerConfig
    var gatedSteps: Int
    var gateHolding: Bool
    var device: JSON
    var dayStartMs: Int64
    var dayEndExclusiveMs: Int64
}

enum IntegrityReport {
    static func build(_ i: IntegrityReportInput) -> JSON {
        var flags = i.flags.filter { $0.type != IntegrityFlag.dailyVolume }
        if i.enabled, let volume = FraudDetector.dailyVolumeFlag(
            flaggedSteps: i.flaggedSteps, deviceSteps: i.deviceSteps, rules: i.rules,
            dayStart: i.dayStartMs, dayEnd: i.dayEndExclusiveMs) {
            flags.append(volume)
        }
        flags = flags.enumerated().sorted { a, b in
            a.element.from != b.element.from ? a.element.from < b.element.from
                : (a.element.type != b.element.type ? a.element.type < b.element.type : a.offset < b.offset)
        }.map(\.element)
        let m = i.enabled ? i.minutes : []
        func sum(_ f: (MinuteSample) -> Int) -> JSON { .int(m.reduce(0) { $0 + f($1) }) }
        return .object([
            ("date", .string(i.date)),
            ("enabled", .bool(i.enabled)),
            ("mode", .string(i.mode)),
            ("deviceSteps", .int(i.deviceSteps)),
            ("suspectSteps", .int(i.enabled ? FraudDetector.suspectSteps(flaggedSteps: i.flaggedSteps, deviceSteps: i.deviceSteps, rules: i.rules) : 0)),
            ("flags", .array(i.enabled ? flags.map { $0.json() } : [])),
            ("events", .array(i.enabled ? i.events.map { $0.json() } : [])),
            ("minutes", .object([
                ("count", .int(m.count)),
                ("timedSteps", sum(\.steps)),
                ("untimedSteps", sum(\.untimedSteps)),
                ("chargingSteps", sum(\.chargingSteps)),
                ("stillSteps", sum(\.stillSteps)),
                ("vehicleSteps", sum(\.vehicleSteps)),
            ])),
            ("evaluatedAt", .int(i.enabled ? i.evaluatedAt : 0)),
            ("rules", i.rules.json()),
            ("charging", .bool(i.charging)),
            ("activityRecognition", .object([
                ("requested", .bool(i.activityRequested)),
                ("available", .bool(i.activityAvailable)),
                ("status", .string(i.activityStatus)),
                ("current", .string(i.activityCurrent)),
            ])),
            ("device", i.device),
            ("motionGate", .object([
                ("enabled", .bool(i.gate.motionGateEnabled)),
                ("holding", .bool(i.gateHolding)),
                // No accelerometer is watched on iOS.
                ("verdict", .string("unknown")),
                ("gatedSteps", .int(i.gatedSteps)),
                ("activityRecognition", .object([
                    ("available", .bool(i.activityAvailable)),
                    ("status", .string(i.gate.motionGateEnabled ? i.activityStatus : "not_requested")),
                    ("error", .null),
                    ("activity", .string(i.activityCurrent)),
                ])),
                ("rules", .object([
                    ("windowSeconds", .int(i.gate.motionGateWindowSeconds)),
                    ("stillVariance", .double(i.gate.motionGateStillVariance)),
                    ("minPeakRatio", .double(i.gate.motionGateMinPeakRatio)),
                    ("maxZeroCrossingRate", .double(i.gate.motionGateMaxZeroCrossingRate)),
                    ("engageSeconds", .int(i.gate.motionGateEngageSeconds)),
                ])),
            ])),
        ])
    }
}
