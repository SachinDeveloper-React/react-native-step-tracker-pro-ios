# react-native-step-tracker-pro-ios

The iOS implementation of
[`react-native-step-tracker-pro`](https://www.npmjs.com/package/react-native-step-tracker-pro).
Install it next to that package and the same JavaScript counts steps on an
iPhone: the same API, return shapes and events, and the same signed day
snapshot (schema version 2), so a server verifies iOS snapshots with the code
it already has for Android and adds one App Attest check.

This package has no JavaScript API of its own. It registers the native
`StepTrackerPro` TurboModule on iOS; you keep importing
`react-native-step-tracker-pro`.

| Android | iOS |
|---|---|
| Hardware step counter in a foreground service | CMPedometer: the motion coprocessor counts all the time, app running or not |
| Health Connect sources | Apple Health sources |
| Activity Recognition | CMMotionActivity history |
| Keystore key + key attestation | Secure Enclave key + App Attest |
| Play Integrity token | App Attest assertion |

What differs, method by method and field by field, is in
[docs/IOS_DIFFERENCES.md](docs/IOS_DIFFERENCES.md).

## Requirements

- iOS 15.1 or later.
- React Native 0.77 or later, **New Architecture** (the default since 0.76).
  Verified on 0.87.1.
- `react-native-step-tracker-pro` 2.11.0 or later - the release that looks
  for a registered native module instead of assuming Android.

## Install

```sh
npm install react-native-step-tracker-pro react-native-step-tracker-pro-ios
cd ios && pod install
```

Autolinking adds the pod. The app's `AppDelegate` needs no change: the module
registers Apple Health's background observers itself as launch finishes.

### Xcode capabilities

In the app target's **Signing & Capabilities**:

1. **HealthKit**, with **Background Delivery** ticked. This adds
   `com.apple.developer.healthkit` and
   `com.apple.developer.healthkit.background-delivery`. Leave Clinical
   Health Records off.
2. **App Attest**. This adds `com.apple.developer.devicecheck.appattest-environment`;
   set it to `development` for builds you run from Xcode and `production` for
   TestFlight and the App Store (Xcode archives keep what you set, so most
   apps set `production` and test against Apple's production service).

Your provisioning profile must include both capabilities (enable them for the
App ID in the developer portal if Xcode does not do it for you).

### Info.plist

```xml
<key>NSMotionUsageDescription</key>
<string>Counts your steps with the iPhone's motion coprocessor.</string>
<key>NSHealthShareUsageDescription</key>
<string>Reads your steps and walking distance from Apple Health to show your daily activity.</string>
```

iOS terminates an app that asks for Motion & Fitness or Apple Health without
these. This package checks first and rejects instead: `requestPermissions()`
and `startTracking()` with `E_PERMISSION_DENIED`, the Apple Health calls with
`E_HEALTH_CONNECT_NOT_DECLARED`, each naming the missing key.
`NSHealthUpdateUsageDescription` is **not** needed: this package never writes
to Apple Health.

## Use

Exactly as on Android:

```ts
import StepTracker, { isSupported } from 'react-native-step-tracker-pro';

if (isSupported()) {
  await StepTracker.initialize({ dailyGoal: 8000, healthConnectReadTypes: ['steps', 'distance'] });
  await StepTracker.requestPermissions();          // Motion & Fitness
  await StepTracker.enableHealthConnect();         // Apple Health's sheet
  await StepTracker.startTracking();
  StepTracker.addListener('stepsChanged', (s) => console.log(s.steps));
}
```

`HealthConnectStatus.provider` is `'healthkit'` on iOS, so an app can say
"Apple Health" where it says "Health Connect".

### Signed snapshots and attestation

```ts
const attestation = await StepTracker.attestDevice(challengeFromServer);
// attestation.appAttest: { keyId, attestationObject, clientData, environment } | null
const signed = await StepTracker.getSignedSnapshot(date, { nonce, include: ['minutes'] });
const { token } = await StepTracker.requestIntegrityToken({ requestHash: signed.payloadSha256 });
// token: an App Attest assertion; provider: 'app_attest'. No cloudProjectNumber on iOS.
```

The signature is the same as Android's (DER ECDSA P-256 over the UTF-8
`signedPayload`, `SHA256withECDSA`), so the verifier you have works. What a
server adds for iOS - verifying the App Attest attestation once and the
assertion per request - is in
[docs/SERVER_VERIFICATION_IOS.md](docs/SERVER_VERIFICATION_IOS.md), with a
Node reference implementation in `scripts/app-attest.mjs` and
`scripts/verify-signature.mjs`.

## How counting works

- **This phone's count** (`deviceSteps`) is CMPedometer's, for the stretches
  tracking was running: steps taken while tracking was paused or stopped,
  before `setCountFrom()`'s instant or before a `resetToday()` are not
  counted. Because the coprocessor keeps counting with the app dead, there is
  no gap recovery and `recoveredSteps` is always 0.
- **Minutes** come from CMPedometer history, queried by hour and then by
  minute for hours with steps, and fitted so that
  `sum(minutes) == deviceSteps - gatedSteps` always holds - the check a server
  makes. CMPedometer remembers 7 days; each day is kept on the device the
  first time it is computed after it closes. An older day never computed
  falls back to this iPhone's own samples in Apple Health.
- **The motion gate** holds steps taken in minutes CMMotionActivity reports
  as a vehicle or a bicycle (medium or high confidence, no walking or running)
  as `gatedSteps`, and gives back the minute and a half before a reported walk
  away from the ride, as Android's gate does.
- **Apple Health sources** are read per source (bundle id): this iPhone
  (`kind: 'phone'`, `isPlatform`), an Apple Watch (`kind: 'watch'`, trusted),
  and every other app, with manual entries counted apart. The resolver is
  Android's, unchanged.
- **Calories** always come from the package's step formula, never from Apple
  Health's energy, so the same walk reads the same on both platforms.

## Background

Apple Health wakes the app at most hourly when new steps arrive (Background
Delivery entitlement, Background App Refresh on). On a wake the package
recomputes today and the recent days, keeps them, and emits `stepsChanged`,
`stepSourceChanged` and `historyBackfilled` to any JavaScript that is
running. With the phone locked, Apple Health cannot be read: the last values
read are served with `sourcesStatus: 'failed'`, and everything is read again
when the phone is unlocked. Nothing crashes.

## Privacy

Reads `stepCount` and `distanceWalkingRunning` only. Never writes to Apple
Health, never reads energy. No data leaves the device unless your app sends
it. See [docs/APP_STORE.md](docs/APP_STORE.md) for the review notes and the
privacy label.

## Example

`example/` is one screen: permissions, today's count, its minutes, the Apple
Health sources and a signed snapshot, which it sends to
`node scripts/verify-server.mjs` to be verified the way a server would.

```sh
cd example && npm install && cd ios && pod install && cd ..
node ../scripts/verify-server.mjs &   # optional: verifies what the app signs
npx react-native run-ios
```

## Development

```sh
npm test            # spec-copy check, verifier tests (node), and `swift test`
swift test          # the pure Swift logic, with Android's test vectors
```

## License

MIT
