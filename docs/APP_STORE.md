# App Store review and privacy

Notes for shipping an app that uses `react-native-step-tracker-pro-ios`.

## What the package touches

| Framework | Use |
|---|---|
| CoreMotion | CMPedometer (steps, history); CMMotionActivityManager (vehicle and still minutes). Needs `NSMotionUsageDescription`. |
| HealthKit | **Reads** `HKQuantityTypeIdentifierStepCount` and `HKQuantityTypeIdentifierDistanceWalkingRunning`. **Never writes** - the share set is always empty - and **never reads energy** (no active or basal energy, no other type). Needs `NSHealthShareUsageDescription` and the HealthKit capability. |
| DeviceCheck | App Attest: attests the install's signing key and makes assertions. |
| Security / CryptoKit | A P-256 key in the Secure Enclave that signs day snapshots. |

It makes no network requests. Whatever leaves the device, your app sends.

## HealthKit review

App Review rejects HealthKit apps that request types they do not use, store
health data in iCloud, or use it for advertising. With this package:

- Request only the types you show. `healthConnectReadTypes: ['steps']` asks
  for steps alone; add `'distance'` only if your UI or server uses distance.
  `'totalCalories'` is ignored on iOS - calories are computed from steps.
- In the review notes, say which screen shows the Apple Health data and that
  the app only reads steps (and walking distance).
- The usage string should say what the data is for, e.g. *"Reads your steps
  and walking distance from Apple Health to show your daily activity and
  verify challenge results."*
- The package's own files are excluded from iCloud backup. If your app
  uploads steps to your server, say so in your privacy policy and the review
  notes.
- Your app must have a privacy policy (App Store Connect requires one for
  HealthKit apps), and must not use health data for advertising or sell it.
- Tick **Background Delivery** only if you rely on hourly background updates;
  it is optional (without it, Apple Health is read while the app runs).

## Privacy nutrition label

If your app sends step data to your server (a signed snapshot, step counts):

- **Health & Fitness → Fitness**: collected; linked to the user if your
  server ties it to an account; purpose *App Functionality* (and any other
  purpose you actually have, such as *Analytics*). Not used for tracking.

If nothing leaves the device, the data is not "collected" in App Store
Connect's sense and needs no entry.

App Attest assertions and the public key are device integrity data your
server verifies; they identify an install, not a person. Apple's guidance
treats them as part of fraud prevention (*App Functionality*). The snapshot
carries the phone model (`hw.machine`), OS version, time zone and boot time:
if you collect it, declare **Diagnostics** or **Other Data** as your use
requires.

## Required-reason APIs

The pod ships `PrivacyInfo.xcprivacy` (bundled as
`StepTrackerProIOSPrivacy.bundle`), declaring:

| Category | Reason | Use |
|---|---|---|
| User defaults | `CA92.1` | A marker that this install ran before, so Keychain items an earlier install left can be removed. Read and written by this app only. |
| System boot time | `35F9.1` | `kern.boottime` for the snapshot's `clock.bootId`, and the uptime for event throttling and to measure a wall-clock edit - elapsed time between events in the app. |

It declares no tracking and no tracking domains, and collects nothing itself.

## Motion & Fitness

`requestPermissions()` raises the Motion & Fitness prompt with a one-minute
pedometer query - CoreMotion has no request API. Ask in context, after
explaining why, as for any permission.
