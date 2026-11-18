import XCTest
@testable import StepTrackerProCore

/// Android's StepSourceResolverTest, input for input. The resolver is the
/// same code on both platforms; only the catalog differs (package names on
/// Android, bundle ids on iOS), so these tests run it against Android's
/// catalog to keep the vectors identical. The two Android-only cases - its
/// `classify()` of package names - have iOS equivalents in HealthSourcesTests.
final class StepSourceResolverTests: XCTestCase {
    let metrics = MetricsCalculator(config: StepTrackerConfig().sanitised())
    let date = "2026-09-09"

    /// The wearable entries of Android's StepSourceCatalog.
    static let androidWearables: Set<String> = [
        "com.google.android.wearable.app", "com.google.android.apps.wearable.health",
        "com.samsung.android.wear.shealth", "com.samsung.android.app.watchmanager", "com.fitbit.FitbitMobile",
        "com.garmin.android.apps.connectmobile", "com.huawei.health", "com.hihonor.health", "com.mi.health",
        "com.xiaomi.wearable", "com.zepp.life", "com.huami.midong", "com.huami.watch.hmwatchmanager",
        "com.heytap.health", "com.oneplus.health.international", "com.ouraring.oura", "com.whoop.android",
        "fi.polar.polarflow", "com.stt.android.suunto", "com.withings.wiscale2", "com.yf.smart.coros.dist",
    ]
    let android = SourceCatalog { androidWearables.contains($0.packageName) }

    func device(_ steps: Int) -> DayTotals { metrics.totals(date: date, steps: steps) }

    func source(_ pkg: String, _ steps: Int, _ kind: StepSourceKind, distance: Double = 0, calories: Double = 0,
                isSelf: Bool = false, stepsBeforeCoverage: Int = -1, manualSteps: Int = -1,
                manualStepsBeforeCoverage: Int = -1) -> StepSource {
        StepSource(packageName: pkg, appName: pkg, kind: kind, steps: steps, distance: distance, calories: calories,
                   lastRecordAt: 0, isSelf: isSelf, stepsBeforeCoverage: stepsBeforeCoverage, manualSteps: manualSteps,
                   unknownMethodSteps: manualSteps >= 0 ? 0 : -1,
                   recordingMethods: manualSteps >= 0 ? RecordingMethods(active: 0, automatic: steps - manualSteps, manual: manualSteps, unknown: 0) : nil,
                   manualStepsBeforeCoverage: manualStepsBeforeCoverage,
                   isPlatform: pkg == "android" || pkg.hasPrefix("com.android.healthconnect.phone."))
    }

    func resolve(_ policy: StepSourcePolicy, _ device: DayTotals, _ sources: [StepSource], preferred: String? = nil,
                 ignoreManualEntries: Bool = false, reliable: Bool = true, trust: WearableTrust = .metadata,
                 allowlist: Set<String> = []) -> StepSourceResolver.Resolution {
        StepSourceResolver.resolve(policy, device: device, sources: sources, preferredPackage: preferred, metrics: metrics,
                                   deviceCoverageReliable: reliable, ignoreManualEntries: ignoreManualEntries,
                                   wearableTrust: trust, wearableAllowlist: allowlist, catalog: android,
                                   measuredDistance: DistanceSource.healthConnect)
    }

    let fitbit = "com.fitbit.FitbitMobile"
    let garmin = "com.garmin.android.apps.connectmobile"
    let samsungHealth = "com.sec.android.app.shealth"
    let fit = "com.google.android.apps.fitness"

    func testNeverSumsThePhoneAndAWatch() {
        let r = resolve(.auto, device(7_800), [source(fitbit, 8_000, .watch)])
        XCTAssertEqual(r.totals.steps, 8_000)
        XCTAssertTrue(r.usedExternal)
    }

    func testDevicePolicyIgnoresTheStore() {
        let r = resolve(.device, device(500), [source(fitbit, 20_000, .watch)])
        XCTAssertEqual(r.totals.steps, 500)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.kind, .selfSource)
    }

    func testAutoKeepsThePhoneWhenItCountedMore() {
        let r = resolve(.auto, device(9_000), [source(fitbit, 3_000, .watch)])
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.externalSteps, 3_000)
    }

    func testWearablePolicyPrefersTheWatchEvenWhenLower() {
        let r = resolve(.wearable, device(9_000), [source(fitbit, 3_000, .watch)])
        XCTAssertEqual(r.totals.steps, 3_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertEqual(r.deviceSteps, 9_000)
    }

    func testWearablePolicyFallsBackWhenOnlyPhoneAppsPublished() {
        let r = resolve(.wearable, device(9_000), [source("cc.pacer.androidapp", 12_000, .phone)])
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertFalse(r.usedExternal)
    }

    func testHealthConnectPolicyTakesTheBestExternalSource() {
        let r = resolve(.healthConnect, device(9_000), [source("cc.pacer.androidapp", 12_000, .phone)])
        XCTAssertEqual(r.totals.steps, 12_000)
        XCTAssertTrue(r.usedExternal)
    }

    func testOurOwnMirrorIsNeverExternal() {
        let r = resolve(.auto, device(6_000), [source("com.example.app", 4_000, .phone, isSelf: true)])
        XCTAssertEqual(r.totals.steps, 6_000)
        XCTAssertFalse(r.usedExternal)
    }

    func testAPinnedPackageWinsOverAHigherOne() {
        let r = resolve(.auto, device(1_000), [source(fitbit, 11_000, .watch), source(garmin, 4_000, .watch)], preferred: garmin)
        XCTAssertEqual(r.totals.steps, 4_000)
        XCTAssertEqual(r.sourcePackage, garmin)
    }

    func testAPinNamingASourceWithNoDataFallsBack() {
        let r = resolve(.auto, device(1_000), [source(fitbit, 11_000, .watch)], preferred: garmin)
        XCTAssertEqual(r.totals.steps, 1_000)
        XCTAssertFalse(r.usedExternal)
    }

    func testDistanceIsDerivedWhenTheWatchGaveNone() {
        let r = resolve(.wearable, device(0), [source(fitbit, 10_000, .watch)])
        XCTAssertEqual(r.totals.distance, metrics.distance(10_000), accuracy: 0.001)
        XCTAssertEqual(r.totals.calories, metrics.calories(10_000), accuracy: 0.001)
    }

    func testAWatchsOwnDistanceIsKept() {
        let r = resolve(.wearable, device(0), [source(fitbit, 10_000, .watch, distance: 7_500, calories: 410)])
        XCTAssertEqual(r.totals.distance, 7_500, accuracy: 0.001)
        XCTAssertEqual(r.totals.calories, 410, accuracy: 0.001)
    }

    func testNoDataLeavesThePhoneUntouched() {
        let r = resolve(.auto, device(5_432), [])
        XCTAssertEqual(r.totals.steps, 5_432)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.externalSteps, 0)
    }

    func testTiesGoToThePhone() {
        XCTAssertFalse(resolve(.auto, device(5_000), [source(fitbit, 5_000, .watch)]).usedExternal)
    }

    func testAnUnknownPolicyResolvesToAuto() {
        XCTAssertEqual(StepSourcePolicy.from("nonsense"), .auto)
        XCTAssertEqual(StepSourcePolicy.from(nil), .auto)
        XCTAssertEqual(StepSourcePolicy.from("device"), .device)
    }

    func testThePlatformCountIsNeverAWearable() {
        let platform = source("android", 6_000, .phone)
        XCTAssertFalse(resolve(.wearable, device(500), [platform]).usedExternal)
        XCTAssertTrue(platform.isPlatform)
    }

    func testAnAppInstalledAt1500TakesThePhoneSideStepsFromBefore() {
        let r = resolve(.auto, device(10), [source(samsungHealth, 6_000, .app, stepsBeforeCoverage: 5_990)])
        XCTAssertEqual(r.totals.steps, 6_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(r.baselineSteps, 5_990)
        XCTAssertEqual(r.sourcePackage, samsungHealth)
    }

    func testAPhoneSideAppCannotPullACoveredDayUp() {
        let r = resolve(.auto, device(8_000), [source("com.example.aggregator", 16_000, .app, stepsBeforeCoverage: 0)])
        XCTAssertEqual(r.totals.steps, 8_000)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.externalSteps, 16_000)
    }

    func testAPhoneSideAlgorithmCountingHighDoesNotCreep() {
        XCTAssertEqual(resolve(.auto, device(8_000), [source(samsungHealth, 8_400, .app, stepsBeforeCoverage: 0)]).totals.steps, 8_000)
    }

    func testAWatchMayBeAheadAtAnyTime() {
        let r = resolve(.auto, device(8_000), [source(fitbit, 9_000, .watch, stepsBeforeCoverage: 0)])
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertFalse(r.merged)
    }

    func testAPinnedPhoneSideSourceIsTrustedLikeAWatch() {
        let r = resolve(.auto, device(8_000), [source(samsungHealth, 8_400, .app, stepsBeforeCoverage: 0)], preferred: samsungHealth)
        XCTAssertEqual(r.totals.steps, 8_400)
        XCTAssertTrue(r.usedExternal)
    }

    func testOnAPastDayAPhoneSideSourceOnlyFillsAnEmptyDay() {
        let platform = source("android", 7_000, .phone)
        XCTAssertEqual(resolve(.auto, device(0), [platform]).totals.steps, 7_000)
        XCTAssertEqual(resolve(.auto, device(6_500), [platform]).totals.steps, 6_500)
    }

    func testOnAnUnreliableCounterAPhoneSideAppIsTrusted() {
        let r = resolve(.auto, device(8_000), [source(samsungHealth, 8_400, .app, stepsBeforeCoverage: 0)], reliable: false)
        XCTAssertEqual(r.totals.steps, 8_400)
        XCTAssertTrue(r.usedExternal)
    }

    func testWearableAndHealthConnectPoliciesAreExact() {
        let r = resolve(.healthConnect, device(8_000), [source(samsungHealth, 4_000, .app, stepsBeforeCoverage: 0)])
        XCTAssertEqual(r.totals.steps, 4_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertFalse(r.merged)
    }

    func testATypedInSourceWinsWithTheFlagOffAndLosesWithItOn() {
        let typed = source("com.example.faker", 20_000, .watch, manualSteps: 20_000)
        let off = resolve(.auto, device(4_000), [typed])
        XCTAssertEqual(off.totals.steps, 20_000)
        XCTAssertTrue(off.usedExternal)
        XCTAssertEqual(off.manualStepsExcluded, 0)
        let on = resolve(.auto, device(4_000), [typed], ignoreManualEntries: true)
        XCTAssertEqual(on.totals.steps, 4_000)
        XCTAssertFalse(on.usedExternal)
        XCTAssertEqual(on.kind, .selfSource)
        XCTAssertEqual(on.manualStepsExcluded, 20_000)
        XCTAssertEqual(on.externalSteps, 0)
    }

    func testAMixedSourceIsReducedByItsManualShare() {
        let r = resolve(.auto, device(6_000), [source(fitbit, 12_000, .watch, manualSteps: 5_000)], ignoreManualEntries: true)
        XCTAssertEqual(r.totals.steps, 7_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertEqual(r.externalSteps, 7_000)
        XCTAssertEqual(r.manualStepsExcluded, 5_000)
        XCTAssertEqual(r.totals.distance, metrics.distance(7_000), accuracy: 0.001)
    }

    func testTheFlagOffLeavesAMixedSourceAlone() {
        let r = resolve(.auto, device(6_000), [source(fitbit, 12_000, .watch, distance: 9_000, manualSteps: 5_000)])
        XCTAssertEqual(r.totals.steps, 12_000)
        XCTAssertEqual(r.externalSteps, 12_000)
        XCTAssertEqual(r.totals.distance, 9_000, accuracy: 0.001)
        XCTAssertEqual(r.manualStepsExcluded, 0)
    }

    func testAPinCannotSmuggleAManualEntryIn() {
        let r = resolve(.auto, device(4_000), [source("com.example.faker", 20_000, .app, manualSteps: 20_000)],
                        preferred: "com.example.faker", ignoreManualEntries: true)
        XCTAssertEqual(r.totals.steps, 4_000)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.manualStepsExcluded, 20_000)
    }

    func testATypedInMorningDoesNotSurviveAsPreCoverage() {
        let r = resolve(.auto, device(10), [source(samsungHealth, 8_000, .app, stepsBeforeCoverage: 8_000, manualSteps: 6_000, manualStepsBeforeCoverage: 6_000)],
                        ignoreManualEntries: true)
        XCTAssertEqual(r.totals.steps, 2_010)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(r.baselineSteps, 2_000)
        XCTAssertEqual(r.manualStepsExcluded, 6_000)
    }

    func testAnUnknownManualSplitIsTakenConservatively() {
        let r = resolve(.auto, device(10), [source(samsungHealth, 8_000, .app, stepsBeforeCoverage: 3_000, manualSteps: 6_000)],
                        ignoreManualEntries: true)
        XCTAssertEqual(r.totals.steps, 10)
        XCTAssertFalse(r.usedExternal)
    }

    func testWearableAndHealthConnectAlsoCompeteOnCountedSteps() {
        let none = resolve(.wearable, device(4_000), [source(fitbit, 20_000, .watch, manualSteps: 20_000)], ignoreManualEntries: true)
        XCTAssertEqual(none.totals.steps, 4_000)
        XCTAssertFalse(none.usedExternal)
        XCTAssertEqual(none.manualStepsExcluded, 20_000)
        let some = resolve(.healthConnect, device(9_000), [source(fitbit, 12_000, .watch, manualSteps: 5_000)], ignoreManualEntries: true)
        XCTAssertEqual(some.totals.steps, 7_000)
        XCTAssertTrue(some.usedExternal)
        XCTAssertEqual(some.manualStepsExcluded, 5_000)
    }

    func testASourceWithNoMethodSplitIsLeftAlone() {
        let r = resolve(.auto, device(7_800), [source(fitbit, 8_000, .watch)], ignoreManualEntries: true)
        XCTAssertEqual(r.totals.steps, 8_000)
        XCTAssertEqual(r.manualStepsExcluded, 0)
    }

    func testExcludingManualKeepsWhatWasRemoved() {
        let reduced = source(fitbit, 12_000, .watch, distance: 9_000, stepsBeforeCoverage: 4_000, manualSteps: 5_000,
                             manualStepsBeforeCoverage: 1_000).excludingManual()
        XCTAssertEqual(reduced.steps, 7_000)
        XCTAssertEqual(reduced.stepsBeforeCoverage, 3_000)
        XCTAssertEqual(reduced.manualSteps, 5_000)
        XCTAssertEqual(reduced.distance, 0)
        let clean = source(fitbit, 8_000, .watch, manualSteps: 0)
        XCTAssertEqual(clean.excludingManual(), clean)
    }

    func testDefaultArgumentsReproduceTheOldResolution() {
        let watch = source(fitbit, 8_000, .watch, distance: 6_100, manualSteps: 3_000)
        let samsung = source(samsungHealth, 6_000, .app, stepsBeforeCoverage: 150, manualSteps: 100)
        for policy in StepSourcePolicy.allCases {
            let r = StepSourceResolver.resolve(policy, device: device(7_800), sources: [watch, samsung], preferredPackage: nil, metrics: metrics)
            XCTAssertEqual(r.totals.steps, policy == .device ? 7_800 : 8_000, "\(policy)")
            XCTAssertEqual(r.manualStepsExcluded, 0)
            if policy != .device {
                XCTAssertEqual(r.externalSteps, 8_000)
                XCTAssertEqual(r.totals.distance, 6_100, accuracy: 0.001)
            }
        }
    }

    func testATrustedWatchIsNotShutOutByAnUntrustedAppWithMore() {
        let r = resolve(.auto, device(5_000), [source(fit, 9_000, .app, stepsBeforeCoverage: 0), source(fitbit, 8_000, .watch, stepsBeforeCoverage: 0)])
        XCTAssertEqual(r.totals.steps, 8_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertFalse(r.merged)
        XCTAssertEqual(r.sourcePackage, fitbit)
        XCTAssertEqual(r.externalSteps, 8_000)
    }

    func testUnderCatalogTrustAKnownRelayBeatsAnUnlistedWatch() {
        let r = resolve(.auto, device(4_000), [source("com.example.faker", 20_000, .watch, stepsBeforeCoverage: 0),
                                              source("com.samsung.android.app.watchmanager", 7_000, .watch, stepsBeforeCoverage: 0)],
                        trust: .catalog)
        XCTAssertEqual(r.totals.steps, 7_000)
        XCTAssertEqual(r.sourcePackage, "com.samsung.android.app.watchmanager")
        XCTAssertFalse(r.merged)
    }

    func testTheSourceAllowedTheLargerLeadAnswers() {
        let r = resolve(.auto, device(7_800), [source(fitbit, 8_000, .watch), source(samsungHealth, 6_000, .app, stepsBeforeCoverage: 5_990)])
        XCTAssertEqual(r.totals.steps, 13_790)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(r.baselineSteps, 5_990)
        XCTAssertEqual(r.sourcePackage, samsungHealth)
        XCTAssertEqual(r.totals.distance, metrics.distance(13_790), accuracy: 0.001)
    }

    func testAnEqualLeadGoesToTheTrustedSource() {
        let r = resolve(.auto, device(0), [source("android", 6_000, .phone), source(fitbit, 6_000, .watch, distance: 4_400)])
        XCTAssertEqual(r.totals.steps, 6_000)
        XCTAssertEqual(r.sourcePackage, fitbit)
        XCTAssertFalse(r.merged)
        XCTAssertEqual(r.totals.distance, 4_400, accuracy: 0.001)
    }

    func testWithNoSourceAheadThePhoneAnswers() {
        let r = resolve(.auto, device(9_000), [source(fitbit, 3_000, .watch), source(fit, 12_000, .app, stepsBeforeCoverage: 0)])
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertFalse(r.usedExternal)
        XCTAssertEqual(r.externalSteps, 12_000)
    }

    func testWearableAndHealthConnectStillTakeTheMostSteps() {
        let sources = [source(fit, 9_000, .app, stepsBeforeCoverage: 0), source(fitbit, 8_000, .watch), source(garmin, 7_000, .watch)]
        XCTAssertEqual(resolve(.healthConnect, device(5_000), sources).totals.steps, 9_000)
        XCTAssertEqual(resolve(.wearable, device(5_000), sources).totals.steps, 8_000)
    }

    func testAnUnknownWatchStampWinsUnderMetadataTrust() {
        let r = resolve(.auto, device(4_000), [source("com.example.faker", 20_000, .watch, stepsBeforeCoverage: 500)], trust: .metadata)
        XCTAssertEqual(r.totals.steps, 20_000)
        XCTAssertTrue(r.usedExternal)
        XCTAssertFalse(r.merged)
        XCTAssertEqual(r.kind, .watch)
    }

    func testTheSamePackageIsBoundByCoverageUnderCatalogTrust() {
        let r = resolve(.auto, device(4_000), [source("com.example.faker", 20_000, .watch, stepsBeforeCoverage: 500)], trust: .catalog)
        XCTAssertEqual(r.totals.steps, 4_500)
        XCTAssertTrue(r.merged)
        XCTAssertEqual(r.baselineSteps, 500)
        XCTAssertEqual(r.kind, .watch)
        XCTAssertEqual(r.externalSteps, 20_000)
    }

    func testAnAllowlistedPackageIsTrustedUnderCatalogTrust() {
        let band = source("com.example.newband", 9_000, .fitnessBand, stepsBeforeCoverage: 0)
        let without = resolve(.auto, device(8_000), [band], trust: .catalog)
        XCTAssertEqual(without.totals.steps, 8_000)
        XCTAssertFalse(without.usedExternal)
        let with = resolve(.auto, device(8_000), [band], trust: .catalog, allowlist: ["com.example.newband"])
        XCTAssertEqual(with.totals.steps, 9_000)
        XCTAssertTrue(with.usedExternal)
        XCTAssertFalse(with.merged)
    }

    func testACataloguedCompanionIsTrustedWithoutAnAllowlist() {
        let r = resolve(.auto, device(8_000), [source(fitbit, 9_000, .watch, stepsBeforeCoverage: 0)], trust: .catalog)
        XCTAssertEqual(r.totals.steps, 9_000)
        XCTAssertTrue(r.usedExternal)
    }

    func testAPinStillTrustsItsSourceUnderCatalogTrust() {
        let r = resolve(.auto, device(4_000), [source("com.example.faker", 20_000, .watch, stepsBeforeCoverage: 500)],
                        preferred: "com.example.faker", trust: .catalog)
        XCTAssertEqual(r.totals.steps, 20_000)
    }

    func testTrustedWearableIsStampedFromTheSameRule() {
        let sources = [source("com.example.faker", 20_000, .watch), source(fitbit, 9_000, .watch),
                       source(samsungHealth, 6_000, .app), source("android", 6_000, .phone)]
        XCTAssertEqual(StepSourceTrust.stamp(sources, trust: .metadata, allowlist: [], catalog: android).map(\.trustedWearable), [true, true, false, false])
        let catalog = StepSourceTrust.stamp(sources, trust: .catalog, allowlist: [], catalog: android)
        XCTAssertEqual(catalog.map(\.trustedWearable), [false, true, false, false])
        XCTAssertEqual(catalog[0].kind, .watch)
        XCTAssertTrue(catalog[0].isWearable)
        XCTAssertTrue(StepSourceTrust.stamp(sources, trust: .catalog, allowlist: ["com.example.faker"], catalog: android)[0].trustedWearable)
        XCTAssertFalse(StepSourceTrust.stamp([sources[3]], trust: .catalog, allowlist: ["android"], catalog: android)[0].trustedWearable)
        XCTAssertEqual(WearableTrust.from("nonsense"), .metadata)
        XCTAssertEqual(WearableTrust.from("catalog"), .catalog)
    }
}
