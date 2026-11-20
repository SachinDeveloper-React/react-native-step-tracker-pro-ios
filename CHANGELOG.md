# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-18

From research into how iOS actually records steps - Apple's documentation
and what others measured - and how reward apps handle it. The findings, with
sources, and the decision each led to are in
[docs/RESEARCH.md](docs/RESEARCH.md).

### Changed

- **`steady_cadence` and `continuous` are weak flags on iOS**, with
  `evidence.minuteData: 'averaged'`. The iPhone keeps step history in
  records of 6-10 minutes, so each minute is an average: a steady treadmill
  walk read as a swing gadget, and a hike whose short rests were averaged
  away ran past the continuous limit - both strong, both taking real steps
  out under `mode: 'exclude'`. They stay in `flags` as evidence; `cadence`,
  `charging`, `in_vehicle` and `daily_volume` stay strong.
- **`auto` merges this phone with a worn watch, hour by hour.** A morning
  walked with only the watch and an evening with only the phone each count -
  the larger of the two in each hour, never the sum - so the number matches
  the Health app instead of keeping one of them. A pin and the exact
  policies are unchanged; untrusted apps and manual entries never ride along.
- **A day settles two hours after midnight**, not ten minutes: the record
  that ends a day can land late, and its last walk was lost.

### Fixed

- **Apple Health background delivery could stop.** HealthKit hands a
  background launch's update to the observer queries that exist as launch
  finishes, and stops waking an app that misses three. They were registered
  a moment later on the engine's queue; now synchronously, on the main
  thread, from the settings the previous run kept. The launch and the engine
  register through one lock, each deciding and acting in one step, and the
  engine's types - from the current config and grant - replace the launch's,
  whichever thread gets there first: a type added since the last run is
  observed, one removed is stopped, and with Apple Health turned off nothing
  is.
- **A background wake counted today again, minute by minute.** The
  pedometer's settled hours were cached in memory only, so a wake in a new
  process asked again for every hour since midnight - sixty queries for each
  hour with steps. They are now kept on disk for today and yesterday, for
  one boot and one setting of the clock, and a wake asks the pedometer only
  for the hours still moving, the last two or three. Yesterday's hours also
  survive midnight, while it is still being counted.
- **A failed `attestDevice()` took the working key with it.** The install's
  key was deleted before App Attest answered, and a failure then deleted the
  new key too: with Apple's service down, an attested install was left with
  no key, no App Attest key and `hasAttestationKey()` false. The new key now
  waits in a second Keychain slot and replaces the install's key only once
  attested. Until then, and after any failure, snapshots are signed with the
  install's key and `requestIntegrityToken()` answers with its App Attest
  key, as before the call. A call overtaken by a later one rejects with
  `E_INTEGRITY_FAILED` (`retryable: false`); the later one stands.
- **The ten-second answer to a background delivery waited behind the work
  it was meant to bound.** It was scheduled on the same serial queue; it now
  has its own timer.
- A minute of more than 500 steps - a lump the pedometer could not place -
  is kept untimed rather than judged as a cadence.
- **A day left half-counted when it aged out of the pedometer's week kept
  the half.** A day last computed while it was still open - the app used at
  6 pm, then not opened, and not woken by Apple Health, for over a week -
  kept its 6 pm count for good. It now takes this iPhone's own samples in
  Apple Health when they hold more of the day.
- **A launch before the first unlock after a reboot could wipe what was
  kept.** This package's files cannot be read until then. An app iOS started
  earlier - a VoIP push, a location event - ran on a blank state and saved
  it over them once the phone was unlocked: tracking state, spans,
  countFrom, the event log and the key's record lost, and today counted
  from zero. The engine now starts at the unlock; calls and Apple Health's
  deliveries made before it wait, and are answered then, in the order
  asked, on what was kept.
- **A refused Apple Health read could settle a day at zero for good.** Apple
  Health answers a refused read with no data rather than an error, so a day
  past the pedometer's week was stored as 0 and never asked again, even
  after the user allowed Apple Health. A zero or a failed read now never
  settles a day.
- **Two iPhones on one Apple Account were both "This iPhone"**, and a day
  rebuilt from Apple Health summed both - a walk both phones carried counted
  twice. This phone's source is now learned by matching the pedometer, the
  other is called "iPhone", and a rebuilt day uses one iPhone only.
- **An update could have reset everything stored.** A stored file missing a
  field a new version added failed to decode, and the package started over:
  tracking state, spans, countFrom and the key's record gone, stored days
  lost. Every field now decodes leniently.
- The example app's launch check no longer starts, stops or resets
  tracking: on a phone being tested it changed the count being measured.

### Added

- iOS 27's limited Apple Health history: `historyReadGranted` is false when
  the user allowed only a recent window, and nothing before it is read.
- `docs/RESEARCH.md`, and a scenario test suite that walks real days -
  treadmill, hike, bus ride, watch and phone, aged-out days - through the
  whole pipeline with the iPhone's averaged records modelled.

## [1.0.1] - 2026-11-18

The same code as 1.0.0. Its snapshots report `libraryVersion: '1.0.0'`:
`npm version` moved package.json alone. From 1.1.0 it also writes
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

[1.1.0]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.1.0
[1.0.1]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.0.1
[1.0.0]: https://github.com/SachinDeveloper-React/react-native-step-tracker-pro-ios/releases/tag/v1.0.0
