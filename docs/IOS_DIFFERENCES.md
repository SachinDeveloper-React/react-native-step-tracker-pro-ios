# What differs on iOS

Everything not listed here behaves as on Android: same method, same shape,
same meaning. Every difference below comes from something iOS does not have
or does differently; none adds a required field or method. Where iOS cannot
produce a value, it returns a neutral one rather than inventing data.

## Counting

| Topic | Android | iOS | Why |
|---|---|---|---|
| This phone's count | Hardware step counter, read by a foreground service | CMPedometer history | The motion coprocessor counts with the app dead; there is no service and no notification. |
| `recoveredSteps` | Steps credited by gap recovery | Always `0` | Nothing is ever missed, so nothing is recovered. `gapRecovery` and `gapRecoveryMaxSteps` are stored and ignored. |
| Steps while paused or stopped | Not counted | Not counted: the spans are kept and cut out of the pedometer's history | Same contract, done after the fact. |
| Install day | Coverage starts at the first reading | Coverage starts at the first `startTracking()`; nothing before it counts | The pedometer has a week of history; counting it would credit steps from before the app was used. |
| `setCountFrom(at)` with `at` earlier today | Today starts over at the call (it cannot tell which counted steps came before `at`); `count_from` logs `restartedToday: true` | Counts exactly from `at`; today is never restarted; `restartedToday: false` | The pedometer timestamps every step. |
| `resetToday()` | Zeroes today's counter | Today counts from the call on | Same result; the pedometer's own total cannot be zeroed, so the reset is a floor. |
| `clearHistory()` | Deletes every stored day | Deletes every stored day before today, and no day before today is computed again | Otherwise the pedometer's week of history would bring cleared days back. |
| Minutes (`StepMinute`) | Live sensor deltas placed on minutes | CMPedometer queried per hour, then per minute for hours with steps, fitted to the day's single query by largest remainder | So `sum(minutes) == deviceSteps - gatedSteps` holds by construction. See below. |
| `untimedSteps` | Lumps whose timing is unknown | `0`, except an hour the pedometer counts steps in but cannot place in any minute: those are parked untimed at its first minute | The one case where timing is truly unknown. |
| Days older than 7 | Stored | Stored if computed before; otherwise rebuilt from this iPhone's own samples in Apple Health (bundle `com.apple.health.*`, product type `iPhone*`, not user-entered), all tags `0`, with an integrity event `sensor_changed` `{ from: 'pedometer', to: 'healthkit' }` | CMPedometer and CMMotionActivity keep 7 days. |
| `sensor` / `source` | `step_counter`, `step_detector`, `accelerometer` | `step_counter` (`none` without a pedometer, e.g. the simulator) | |
| Live `stepsChanged` | Every sensor event | Live pedometer updates while the app is in the foreground and tracking; after every background recomputation | iOS gives no live updates in the background. |

**Which minute source shipped.** CMPedometer per-minute queries (the
prompt's first choice). Each day is queried once per counting window (the
figure reported), once per clock hour, and once per minute of every hour with
steps; hours that ended more than two hours ago are cached, so today costs
about two hours of minute queries per full recomputation. The hour totals are
fitted to the window total, and each hour's minutes to the hour, so rounding
between overlapping queries never breaks the sum. **To measure on a device**
(see [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md)): the residual the fit absorbs
per hour. If it proves large or unstable, the fallback is Apple Health's
1-minute statistics from this iPhone's own source, which is already
implemented for days past the pedometer's week.

## The motion gate and tags

| Topic | Android | iOS |
|---|---|---|
| Detector | Activity Recognition transitions, live | CMMotionActivity history, judged per minute |
| A vehicle minute | Steps arriving while AR said in a vehicle or on a bicycle | A minute covered by an activity with `automotive` or `cycling` at medium or high confidence, and nothing covering it says `walking` or `running` |
| Giving held steps back | Walking reported after a ride gives back the last 90 s; walking within 60 s of a ride ending on "still" claims what is left; the accelerometer can confirm a walk | The same two activity rules, per minute (minutes overlapping the 90 s before the walk). No accelerometer: a walk inside a ride is only seen when the coprocessor reports it |
| A ride's limits | 12 h on one report; 30 min of stillness; 3 min of confirmed walking | 12 h on one report. The other two rest on the accelerometer and do not exist |
| `vehicleSteps` | Steps tagged while AR said vehicle (only when `fraudDetection.activityRecognition`) | Vehicle-minute steps that were not gated (gate off, or low confidence); also only with `fraudDetection.activityRecognition` |
| `stillSteps` | Steps tagged while AR said still | Steps in minutes covered by `stationary` at medium or high confidence with no walking, running or vehicle |
| `motionGate.verdict` | The accelerometer's verdict during a ride | Always `'unknown'`: iOS gives no background accelerometer |
| `motionGate.holding` | A ride is being held now | The latest activity is a vehicle at medium or high confidence and the gate is on |
| `activityRecognition.status` | Play Services registration | `'not_requested'` (neither the gate nor the tags want it), `'unavailable'` (no motion coprocessor), `'no_permission'` (Motion & Fitness not allowed), `'registered'`; never `'pending'` or `'failed'`. `error` is always null |
| `chargingSteps` | Steps counted while plugged in | Steps in minutes that overlap a span the package itself saw the phone plugged in (UIDevice battery notifications while the process was alive); otherwise `0` |

`VehicleGateTest.kt`'s accelerometer scenarios have no iOS equivalent; its
activity-driven scenarios are ported as minute-level tests in
`ios/Tests/StepTrackerProCoreTests/IOSLogicTests.swift`.

## Integrity

- Rules, thresholds, `suspectSteps` and `mode: 'flag' | 'exclude'` are
  Android's, ported with its test vectors. `shake` and `swing` never fire:
  they need motion windows.
- Minutes are listed (and judged) only while `fraudDetection.enabled`, as on
  Android: `minutesStatus: 'disabled'` returns `[]`. Turning detection on
  mid-day judges the whole day, since the pedometer's history is there.
- Events logged: `clock_changed` (`jumpMs`, from wall clock minus uptime),
  `timezone_changed`, `reset_today`, `count_from`, `history_cleared`,
  `config_changed`, `sensor_changed` (the Apple Health fallback),
  `charging_started` / `charging_stopped`, `activity_changed`, `motion_gate`
  (enabled/disabled only), `device_attested`. Never: `reboot`,
  `service_recovered`.
- `integrity.device`: `emulator` = the simulator; `suBinary` = cheap jailbreak
  indicators (Cydia, Sileo, Zebra, MobileSubstrate, `/var/jb`, `/etc/apt`,
  `sshd`, `bash`, tweak-injection libraries loaded into the process, a write
  outside the sandbox succeeding) - no private API, and all of it can be
  hidden; `appDebuggable` = a debugger attached, or the app signed with
  `get-task-allow`; `testKeysBuild`, `adbEnabled`, `developerOptions` =
  `false`; `stepCounter` = `{ name: 'CMPedometer', vendor: 'Apple', version: 0, wakeUp: true }`
  (null without a pedometer).

## Apple Health in Health Connect's shapes

| Topic | iOS |
|---|---|
| `StepSource.packageName` | The source's bundle id |
| This iPhone | `kind: 'phone'`, `isPlatform: true`, `appName: 'This iPhone'` |
| Apple Watch | `kind: 'watch'`; `isWearable`, `trustedWearable` (under both trust rules) and `isPlatform` all true; `appName: 'Apple Watch'` |
| Other apps | `kind` from the samples' `HKDevice` (model or name containing watch, ring, band/tracker, strap/chest, phone), else the catalog, else `'app'` |
| Device names | Never sent: Apple's own sources are named "This iPhone" / "Apple Watch", not the user's device name |
| `wearableTrust: 'catalog'` | Trusts Apple Watch and bundle ids in the iOS catalog or `wearableAllowlist`. The built-in iOS catalog is **empty in this release**: no third-party bundle id has been verified yet (see below) |
| `manualSteps`, `recordingMethods` | `manual` = samples with `HKMetadataKeyWasUserEntered`; `automatic` = Apple's sources and samples that name a device; `unknown` = the rest; `active` = 0 |
| `unknownMethodSteps` | Third-party samples with no device |
| `lateWrittenSteps` | `-1`: Apple Health records no write time |
| `isSelf` | Always `false`: this package never writes |
| `calories`, `activeCalories` | `0`: energy is never read |
| `distanceSource` | `'healthkit'` for a source's own `distanceWalkingRunning`; `'none'` or `'not_read'` otherwise. `ResolvedStepSource.distanceSource` is `'healthkit'` or `'derived'` |
| `stepsBeforeCoverage` | Today only, when coverage started after midnight |
| A sample across midnight or `countFrom` | Counts its share inside the day, by time (Apple Health's own statistics split the same way) |
| Ranges over 35 days (`getStepSources`, stats) | Per-source totals from Apple Health's statistics; per-sample fields `-1`, as Android's aggregate path. An Apple device's kind there is what its samples said when last read, else `'unknown'` |
| Records (`HealthConnectRecord`) | `id` = sample UUID; `clientRecordId` = `HKMetadataKeySyncIdentifier`; `clientRecordVersion` = `HKMetadataKeySyncVersion` or 0; `device.type` `'watch'`, `'phone'` or `'unknown'`; zone offsets from `HKMetadataKeyTimeZone` or null; `lastModifiedTime: 0`; at most 10,000 per type with `truncated` |
| Change tokens | Each type's `HKQueryAnchor`, archived, as base64. They do not expire; a token this package did not make reads as `tokenExpired: true` |

Bundle ids that are candidates for the iOS catalog, not yet verified on a
device or in vendor documentation, so **not** in the catalog: Garmin Connect,
Fitbit, Oura, WHOOP, Polar Flow, Suunto, Withings Health Mate, COROS, Zepp,
Huawei Health, Samsung Health. Verify each by reading its `packageName` from
`getStepSources()` on a device with the companion app writing to Apple Health,
then add it to `IOSCatalog.wearableBundleIds` (or have apps pass it in
`wearableAllowlist`).

### `getHealthConnectStatus()`

- `provider: 'healthkit'`; `availability` `'available'` or `'not_supported'`
  (`HKHealthStore.isHealthDataAvailable()`); `requiresUpdate`, `installable`,
  `canWrite`, `canWriteSteps`, `writeRequired`, `workProfile` false;
  `grantedWriteTypes: []`; no `rateLimit`, no `deviceStepTracking`.
- Permission names are HealthKit identifiers:
  `HKQuantityTypeIdentifierStepCount`,
  `HKQuantityTypeIdentifierDistanceWalkingRunning`.
- `'totalCalories'` in `healthConnectReadTypes` is ignored: never requested,
  never in `grantedReadTypes`, and not part of `canRead` / `granted`.
- `backgroundReadGranted`, `backgroundReadAvailable`, `historyReadGranted`,
  `historyReadAvailable` are true once steps are readable: iOS has no
  separate grant for them.
- `undeclaredPermissions` lists a missing `NSHealthShareUsageDescription`, or
  a HealthKit / background-delivery entitlement the app's code signature does
  not carry (read from the signature; when it cannot be read, nothing is
  listed).
- `denialCount` counts sheets answered without steps.

**iOS hides read grants.** It never says whether a read was refused - a
refused read simply returns no data. So:

1. `getRequestStatusForAuthorization` must say the sheet was answered;
   otherwise nothing is granted (`stepsGranted: false`).
2. Then steps count as granted unless this iPhone's pedometer has steps in the
   last 7 days while Apple Health returns no step sample from any source over
   the same span - which is what a refused read looks like. Then
   `stepsGranted: false` and `shouldOpenSettings: true` (asking again shows
   nothing; the user changes it in Settings → Health → Data Access & Devices).
3. Distance the same way, with the pedometer's distance.

A phone with no steps at all in a week cannot be told apart and reads as
granted. The answer is cached for five minutes and refreshed after every
request and on every foreground.

## Attestation and integrity tokens

| Topic | Android | iOS |
|---|---|---|
| Key | Keystore P-256 | Secure Enclave P-256 (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no user presence); a Keychain key where there is no Secure Enclave |
| `attestDevice()` | Key attestation chain | App Attest over `SHA256(challenge + "\|" + keyId)`; `certificateChain: []`; `appAttest: { keyId, attestationObject, clientData, environment }` |
| `securityLevel` | `strongbox`, `tee`, `software` | `'secure_enclave'`, `'software'` |
| Unattested fallback | Device refuses attestation | App Attest unsupported (simulator, some devices) or `featureUnsupported`: `attested: false`, `appAttest: null` |
| Transient failure | - | `DCError.serverUnavailable` rejects `E_INTEGRITY_FAILED` with `retryable: true`, never downgrades |
| `requestIntegrityToken()` | Play Integrity token; needs `cloudProjectNumber` | App Attest assertion over `SHA256(UTF8(requestHash))`, `provider: 'app_attest'`; `cloudProjectNumber` ignored; `E_INTEGRITY_UNAVAILABLE` before an App Attest key exists |
| Error details | Play's code and name | `playErrorCode: null`, `playError: 'APP_ATTEST_<CASE>'` (`SERVER_UNAVAILABLE` retryable; `INVALID_KEY` - attest again; `INVALID_INPUT`, `FEATURE_UNSUPPORTED`, `UNKNOWN_SYSTEM_FAILURE`) |
| `prepareIntegrity()` | Warms Play up | Resolves at once |
| Reinstall | Keys go with the app | Keychain items outlive an uninstall, so the first launch of a fresh install (no UserDefaults marker, no state file) deletes this package's leftovers: `hasAttestationKey()` is false again |

The signature itself is identical: base64 DER ECDSA P-256 over the UTF-8
bytes of `signedPayload`, `algorithm: 'SHA256withECDSA'`, `keyId` = hex
SHA-256 of the SubjectPublicKeyInfo.

## The snapshot

`schemaVersion: 2`, Android's keys in Android's order, plus:

- `platform: 'ios'`; `libraryVersion` = this package's version.
- `recoveredSteps: 0`, `sensor: 'step_counter'`.
- `capabilities: { hasStepCounter, hasStepDetector: false, manufacturer: 'Apple', model: <hw.machine>, sdkInt: 0, osVersion }`.
- `health: { recoveryCount: 0, lastRecoveryReason: null, batteryOptimizationEnabled: false, aggressiveOem: false }`.
- `clock.bootId` = the boot time from `kern.boottime`, epoch ms.
- `motionWindows: []`, `motionWindowsStatus: 'unsupported'`.
- `sources: []` with `sourcesStatus: 'failed'` while the phone is locked -
  evidence never falls back on an old read. Displayed numbers do (below).

## Other methods

| Method | iOS |
|---|---|
| `checkPermissions` | `activityRecognition` = Motion & Fitness allowed; `postNotifications`, `foregroundServiceHealth` true; `allGranted` = `activityRecognition` |
| `requestPermissions` | A one-minute pedometer query raises the Motion & Fitness prompt; resolves after the answer |
| `startTracking` | `E_PERMISSION_DENIED` without Motion & Fitness, `E_NO_SENSOR` without a pedometer |
| `getTrackingHealth` | `serviceAlive` = running; `looksDead: false`; `recoveryCount: 0`; heartbeat = the last pedometer read; `manufacturer: 'Apple'` |
| `getDeviceCapabilities` | `hasStepDetector`, `hasWakeUpAccelerometer` false; `hasAccelerometer` true; `bestSensor: 'step_counter'`; `sdkInt: 0`; `platform: 'ios'`; `osVersion`; `model` = `hw.machine` |
| `getBackgroundRestrictionStatus` | Every Android flag false or null; `manufacturer`, `brand` `'Apple'`; `backgroundRefresh` from `UIApplication.backgroundRefreshStatus` |
| Battery methods | `false`, so `requestBackgroundPermissions()` resolves `'none'` |
| `openHealthConnectSettings` | Opens the Health app (`x-apple-health://`), else the app's Settings page |
| `installHealthConnect`, `revokeHealthConnectPermissions`, `writeHealthConnectSteps` | `false`. iOS has no revoke API: the user revokes in Settings → Health → Data Access & Devices |
| `readHealthConnectSteps` | Apple Health's per-day statistics across sources; calories from the step formula |
| `readHealthConnectVitals` | `{ vitals: [], notGranted: <every type asked> }`: no vitals in this version |
| `deleteHealthConnectData` | `{ startDate, endDate, recordTypes: [] }`: nothing was written |
| `syncWithHealthConnect` | Re-reads today's sources; `syncedRecords: 0` |
| `getInstalledCompanionApps` | `[]`: iOS cannot list installed apps |
| `getMotionWindows` | `[]`; `motionSampling` is stored and ignored; `motionWindow` never fires |
| `syncNow`, `getSyncStatus`, `getPendingSyncCount` | Remote sync is not in this version: `[]`, `{ remote: { configured: false, ... } }`, `0`. `remoteSyncHeaders` are kept in the Keychain, never used |
| `getHistory` | `synced` and `syncedRemote` always false |

## Events

| Event | iOS |
|---|---|
| `stepsChanged` | Live while foreground and tracking (throttled by `eventThrottleMs`); after every background recomputation |
| `dayChanged` | At local midnight while the app runs, and on clock or zone changes (with `clock_changed` / `timezone_changed` logged) |
| `historyBackfilled` | When Apple Health brings more steps for a past day (a watch syncing late); `reason: 'late'` |
| `healthConnectStatusChanged` | After a permission request, and on a foreground when the status changed |
| `error` | `E_SENSOR_UNAVAILABLE` (live updates failed), `E_HEALTH_CONNECT_NOT_DECLARED` (no background-delivery entitlement), `E_HEALTH_CONNECT_UNAVAILABLE` (background delivery refused) |
| Never | `motionWindow`, `syncCompleted`, `syncAuthFailed` |

## Background and the locked phone

- Observer queries and hourly background delivery (the most often iOS allows
  for steps) are registered from the module itself at the end of every launch,
  once Apple Health's sheet has been answered. A wake recomputes today and the
  open days, keeps them, emits events to any running JavaScript, and calls the
  completion handler within 20 seconds whatever happens.
- Locked: Apple Health cannot be read. Displayed numbers use the sources last
  read, with the read reported as `'failed'`; signed evidence carries no
  sources and `sourcesStatus: 'failed'`. Everything is read again on
  `protectedDataDidBecomeAvailable`. This package's own files are protected
  until the first unlock after a boot, and its Keychain key is usable after
  it, so a locked wake still counts and signs.

## Storage

Application Support/StepTrackerPro, file protection
`completeUntilFirstUserAuthentication`, excluded from backups (the signing key
is device-only, so state restored onto another phone would describe a key it
does not have). Days are kept for `historyRetentionDays`.

## Config

`updateConfig` / `getConfig` round-trip exactly as on Android: every key is
kept, clamped by Android's rules, whether iOS uses it or not. Keys stored and
ignored on iOS: the notification keys, `persistEveryNSteps`, `gapRecovery`,
`gapRecoveryMaxSteps`, `autoStartOnBoot`, `watchdogEnabled`,
`accelerometer*`, `motionSampling`, `motionWindowRetention`,
`healthConnectWriteEnabled`, `healthConnectWriteGranularity`,
`healthConnectSyncIntervalMinutes`, `healthConnectBackgroundRead`,
`healthConnectHistoryRead`, `healthConnectReadActiveCalories`,
`healthConnectReadVitals`, `remoteSync*`, `privacyPolicyUrl`, and the
deprecated `motionGate` thresholds.
