# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-11-18

### Fixed

- **A day left half-counted when it aged out of the pedometer's week kept
  the half.** A day last computed while it was still open - the app used at
  6 pm, then not opened, and not woken by Apple Health, for over a week -
  kept its 6 pm count for good. It now takes this iPhone's own samples in
  Apple Health when they hold more of the day.
- **A refused Apple Health read could settle a day at zero for good.** Apple
  Health answers a refused read with no data rather than an error, so a day
  past the pedometer's week was stored as 0 and never asked again, even
  after the user allowed Apple Health. A zero or a failed read now never
  settles a day.
- The example app's launch check no longer starts, stops or resets
  tracking: on a phone being tested it changed the count being measured.

## [1.0.1] - 2026-11-18

The same code as 1.0.0. Its snapshots report `libraryVersion: '1.0.0'`:
`npm version` moved package.json alone. From 1.0.2 it also writes
`ios/Core/LibraryVersion.swift`, and `npm publish` refuses a mismatch.

## [1.0.0] - 2026-11-18

The first release: the iOS implementation of `react-native-step-tracker-pro`
(2.11.0 or later). Install both, run `pod install`, and the same JavaScript
counts steps on an iPhone. What differs from Android is in
[docs/IOS_DIFFERENCES.md](docs/IOS_DIFFERENCES.md).

### Added

- A `StepTrackerPro` TurboModule implementing the Android package's codegen
  spec, method for method; typed events through the generated emitters.
  New Architecture, iOS 15.1+, React Native 0.77+ (verified on 0.87.1).
- This phone's count from CMPedometer, cut by tracking spans, countFrom and
  resets; per-minute buckets that always sum to `deviceSteps - gatedSteps`;
  days kept on the device past the pedometer's 7-day history, with this
  iPhone's own Apple Health samples as the fallback for older days.
- The motion gate and still/vehicle tags from CMMotionActivity history, with
  Android's walk-away and twelve-hour rules.
- The integrity checks ported from Android with its test vectors (`shake`
  and `swing` need motion windows and never fire); `chargingSteps` from
  battery state the package saw.
- Apple Health sources per bundle id - this iPhone, Apple Watch, other apps -
  with manual entries, recording methods, hourly splits and distance;
  Android's resolver and continuity unchanged; records and change anchors in
  Health Connect's shapes. Reads `stepCount` and `distanceWalkingRunning`
  only; never writes; never reads energy.
- The signed snapshot, schema version 2, with Android's keys and
  `platform: 'ios'`, signed by a Secure Enclave P-256 key; `attestDevice()`
  binds the key to the install with App Attest; `requestIntegrityToken()`
  returns an App Attest assertion.
- Observer queries and hourly background delivery registered at launch;
  `stepsChanged`, `dayChanged`, `historyBackfilled`, `stepSourceChanged`,
  `healthConnectStatusChanged`, `goalReached`, `goalProgressChanged`,
  `suspiciousActivity` and `error` events; a locked phone never crashes.
- Crash guards for `NSMotionUsageDescription`, `NSHealthShareUsageDescription`
  and the HealthKit entitlements; a privacy manifest for the required-reason
  APIs used.
- `scripts/verify-signature.mjs`, `scripts/app-attest.mjs` and
  `scripts/verify-server.mjs`: server-side verification in Node, documented in
  [docs/SERVER_VERIFICATION_IOS.md](docs/SERVER_VERIFICATION_IOS.md).
- An example app.

[1.0.2]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.0.2
[1.0.1]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.0.1
[1.0.0]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.0.0
