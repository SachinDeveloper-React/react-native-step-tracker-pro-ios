import XCTest
@testable import StepTrackerProCore

/// An iOS snapshot built from fixtures has an Android snapshot's key set,
/// all the way down, for the same options - so a server parses and scores
/// both with one parser.
final class SnapshotTests: XCTestCase {
    /// An Android 2.11 snapshot for `include: ['minutes', 'motionWindows',
    /// 'healthConnectRecords']`, a nonce, signed - its key set, from
    /// StepTrackerCore.verificationSnapshot and the maps it is made of.
    static let android = #"""
    {"schemaVersion":2,"libraryVersion":"2.11.0","platform":"android","date":"2026-09-14","deviceSteps":1,
     "recoveredSteps":0,"gatedSteps":0,"sensor":"step_counter","coverageStartAt":0,"countFrom":null,
     "sources":[{"packageName":"p","appName":"a","kind":"watch","steps":1,"distance":0,"calories":0,"lastRecordAt":0,
       "isSelf":false,"isWearable":true,"isPlatform":false,"manualSteps":0,"unknownMethodSteps":0,
       "recordingMethods":{"active":0,"automatic":1,"manual":0,"unknown":0},"trustedWearable":true,
       "lateWrittenSteps":0,"hourlySteps":[1],"activeCalories":-1,"distanceSource":"none"}],
     "sourcesStatus":"read",
     "resolved":{"date":"d","steps":1,"kind":"self","packageName":null,"appName":"This device","deviceSteps":1,
       "externalSteps":0,"usedExternal":false,"merged":false,"baselineSteps":0,"manualStepsExcluded":0,
       "suspectStepsExcluded":0,"distanceSource":"derived"},
     "otherDevicesSteps":0,
     "capabilities":{"hasStepCounter":true,"hasStepDetector":true,"manufacturer":"m","model":"m","sdkInt":35,"osVersion":"15"},
     "health":{"recoveryCount":0,"lastRecoveryReason":null,"batteryOptimizationEnabled":false,"aggressiveOem":false},
     "clock":{"wallClockMs":1,"bootId":1,"timezone":"UTC","utcOffsetMinutes":0},
     "suspectSteps":0,
     "integrity":{"date":"d","enabled":true,"mode":"flag","deviceSteps":1,"suspectSteps":0,
       "flags":[{"type":"cadence","severity":"strong","from":1,"to":2,"steps":1,"evidence":{}}],
       "events":[{"at":1,"type":"reboot","detail":{}}],
       "minutes":{"count":1,"timedSteps":1,"untimedSteps":0,"chargingSteps":0,"stillSteps":0,"vehicleSteps":0},
       "evaluatedAt":1,
       "rules":{"maxCadenceSpm":200,"steadyCadenceMinutes":30,"maxContinuousMinutes":180,"maxDailySteps":50000,"flagWhileCharging":true},
       "charging":false,
       "activityRecognition":{"requested":false,"available":false,"status":"not_requested","current":"unknown"},
       "device":{"emulator":false,"testKeysBuild":false,"suBinary":false,"adbEnabled":false,"developerOptions":false,
         "appDebuggable":false,"stepCounter":{"name":"n","vendor":"v","version":1,"wakeUp":true}},
       "motionGate":{"enabled":false,"holding":false,"verdict":"unknown","gatedSteps":0,
         "activityRecognition":{"available":false,"status":"not_requested","error":null,"activity":"unknown"},
         "rules":{"windowSeconds":3,"stillVariance":0.02,"minPeakRatio":0.12,"maxZeroCrossingRate":9,"engageSeconds":2}}},
     "include":["minutes","motionWindows","healthConnectRecords"],
     "minutesStatus":"enabled",
     "minutes":[{"minuteStart":1,"steps":1,"untimedSteps":0,"chargingSteps":0,"stillSteps":0,"vehicleSteps":0}],
     "motionWindowsStatus":"disabled","motionWindows":[],
     "healthConnectRecords":{"status":"read","recordTypes":["steps"],
       "records":[{"recordType":"steps","id":"i","clientRecordId":null,"clientRecordVersion":0,"packageName":"p",
         "recordingMethod":"automatic","device":{"type":"watch","manufacturer":null,"model":null},"startTime":1,"endTime":2,
         "startZoneOffsetSeconds":null,"endZoneOffsetSeconds":null,"lastModifiedTime":1,"count":1}],
       "truncated":false},
     "nonce":"n","signedAt":1}
    """#

    /// Every key path, arrays reduced to their elements' keys.
    func paths(_ json: JSON, _ prefix: String = "") -> Set<String> {
        switch json {
        case let .object(pairs):
            var out = Set<String>()
            for (k, v) in pairs {
                out.insert(prefix + k)
                // Evidence is a free-form record whose keys depend on the flag.
                if k == "evidence" { continue }
                out.formUnion(paths(v, prefix + k + "."))
            }
            return out
        case let .array(values):
            return values.reduce(into: Set<String>()) { $0.formUnion(paths($1, prefix + "[].")) }
        default:
            return []
        }
    }

    func iosSnapshot() -> JSON {
        let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
        let date = "2026-09-14"
        let t0 = clock.startOfDayMs(date)
        let config = StepTrackerConfig().merging(.object([("fraudDetection", .object([("enabled", .bool(true))]))])).sanitised()
        let metrics = MetricsCalculator(config: config)
        let minutes = (0..<60).map { MinuteSample(minuteStart: t0 + 36_000_000 + Int64($0) * 60_000, steps: $0 == 5 ? 260 : 100 + ($0 * 7 % 9) - 4) }
        let device = minutes.reduce(0) { $0 + $1.totalSteps }
        let evaluation = FraudDetector.evaluate(minutes, windows: [], rules: config.integrityRules(), clock: clock)
        let watch = HealthSample(uuid: "u", kind: .steps, startMs: t0 + 36_000_000, endMs: t0 + 39_600_000, value: 9_000,
                                 bundleId: "com.apple.health.W", sourceName: "W", productType: "Watch6,1", hasDevice: true,
                                 deviceName: "Apple Watch", deviceManufacturer: "Apple Inc.", deviceModel: "Watch")
        let sources = HealthSources.build([watch], .init(dayStartMs: t0, dayEndMs: clock.endOfDayExclusiveMs(date)), clock: clock)
        let resolved = StepSourceResolver.resolve(.auto, device: metrics.totals(date: date, steps: device), sources: sources,
                                                  preferredPackage: nil, metrics: metrics, catalog: IOSCatalog.catalog)
        let integrity = IntegrityReport.build(IntegrityReportInput(
            date: date, enabled: true, mode: "flag", deviceSteps: device, flaggedSteps: evaluation.flaggedSteps,
            flags: evaluation.flags, events: [IntegrityEvent(at: t0, type: IntegrityEvent.clockChanged)], minutes: minutes,
            evaluatedAt: t0, rules: config.integrityRules(), charging: false, activityRequested: false, activityAvailable: true,
            activityStatus: "not_requested", activityCurrent: "unknown", gate: config, gatedSteps: 0, gateHolding: false,
            device: .object([("emulator", .bool(false)), ("testKeysBuild", .bool(false)), ("suBinary", .bool(false)),
                             ("adbEnabled", .bool(false)), ("developerOptions", .bool(false)), ("appDebuggable", .bool(true)),
                             ("stepCounter", .object([("name", .string("CMPedometer")), ("vendor", .string("Apple")),
                                                      ("version", .int(0)), ("wakeUp", .bool(true))]))]),
            dayStartMs: t0, dayEndExclusiveMs: clock.endOfDayExclusiveMs(date)))
        let (records, truncated) = HealthSources.recordList([watch], types: [.steps])
        let snapshot = Snapshot.build(SnapshotInput(
            date: date, deviceSteps: device, gatedSteps: 0, coverageStartAt: 0, countFrom: nil, sources: sources,
            sourcesStatus: "read", resolved: resolved.json(), otherDevicesSteps: 0,
            capabilities: Snapshot.capabilities(hasStepCounter: true, model: "iPhone15,2", osVersion: "18.1"),
            clock: Snapshot.clock(nowMs: t0, bootMs: t0 - 1, zone: clock.timeZone), suspectSteps: 260,
            integrity: integrity, include: ["healthConnectRecords", "minutes", "motionWindows"], minutesStatus: "enabled",
            minutes: minutes,
            healthRecords: .object([("status", .string("read")), ("recordTypes", .strings(["steps"])),
                                    ("records", records), ("truncated", .bool(truncated))]),
            nonce: "n"))
        return Snapshot.signedBody(snapshot, signedAt: t0).0
    }

    func testTheKeySetIsAndroids() {
        let android = JSON.parse(SnapshotTests.android)!
        let ios = iosSnapshot()
        XCTAssertEqual(paths(ios).subtracting(paths(android)), [], "keys only iOS has")
        XCTAssertEqual(paths(android).subtracting(paths(ios)), [], "keys only Android has")
        XCTAssertEqual(ios.keys, ["schemaVersion", "libraryVersion", "platform", "date", "deviceSteps", "recoveredSteps",
                                  "gatedSteps", "sensor", "coverageStartAt", "countFrom", "sources", "sourcesStatus", "resolved",
                                  "otherDevicesSteps", "capabilities", "health", "clock", "suspectSteps", "integrity", "include",
                                  "minutesStatus", "minutes", "motionWindowsStatus", "motionWindows", "healthConnectRecords",
                                  "nonce", "signedAt"], "Android's key order")
    }

    func testIOSValuesWhereTheyDiffer() {
        let s = iosSnapshot()
        XCTAssertEqual(s["platform"], .string("ios"))
        XCTAssertEqual(s["recoveredSteps"], .int(0))
        XCTAssertEqual(s["sensor"], .string("step_counter"))
        XCTAssertEqual(s["motionWindowsStatus"], .string("unsupported"))
        XCTAssertEqual(s["motionWindows"], .array([]))
        XCTAssertEqual(s["capabilities"]?["sdkInt"], .int(0))
        XCTAssertEqual(s["capabilities"]?["manufacturer"], .string("Apple"))
        XCTAssertEqual(s["health"]?["recoveryCount"], .int(0))
        XCTAssertEqual(s["resolved"]?["distanceSource"], .string("derived"))
        XCTAssertEqual(s["include"], .strings(["minutes", "motionWindows", "healthConnectRecords"]))
        // The minutes explain the count, as the server checks.
        let minuteSum = (s["minutes"]?.arrayValue ?? []).reduce(0) { $0 + ($1["steps"]?.intValue ?? 0) + ($1["untimedSteps"]?.intValue ?? 0) }
        XCTAssertEqual(minuteSum, (s["deviceSteps"]?.intValue ?? -1) - (s["gatedSteps"]?.intValue ?? -1))
        XCTAssertEqual(s["integrity"]?["suspectSteps"], .int(260))
    }

    func testTheSignedBytesAreCompactJSONWithIntegersAsIntegers() {
        let (body, bytes) = Snapshot.signedBody(.object([("a", .double(2.0)), ("b", .string("é\"\n"))]), signedAt: 5)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"a":2,"b":"é\"\n","signedAt":5}"#)
        XCTAssertEqual(body["signedAt"], .int(5))
        let block = Snapshot.signatureBlock(keyId: "k", value: Data([1, 2]), attested: true, payload: bytes)
        XCTAssertEqual(block.keys, ["keyId", "algorithm", "value", "attested", "signedPayload", "payloadSha256"])
        XCTAssertEqual(block["payloadSha256"]?.stringValue?.count, 64)
    }

    func testSPKIIsTheStandardP256Prefix() {
        let point = Data([0x04] + [UInt8](repeating: 7, count: 64))
        let spki = KeyEncoding.spki(x963: point)!
        XCTAssertEqual(spki.count, 91)
        XCTAssertEqual(KeyEncoding.keyId(spki: spki).count, 64)
        XCTAssertNil(KeyEncoding.spki(x963: Data([1, 2, 3])))
    }
}
