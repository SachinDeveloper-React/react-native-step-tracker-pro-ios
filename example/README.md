# Example

One screen against the real module: permissions, today's count, its minutes,
Apple Health sources, and a signed snapshot that is verified the way a server
would verify it. On launch it also calls every method the reference
integration uses once and shows which resolved (**Checks**).

```sh
npm install          # react-native-step-tracker-pro must be 2.11.0 or later
cd ios && pod install && cd ..
node ../scripts/verify-server.mjs &    # optional: the development verifier
npx react-native run-ios               # or open ios/StepTrackerProExample.xcworkspace
```

On a device: set your team in Xcode (the target already has the HealthKit with
Background Delivery and App Attest entitlements), and set `VERIFY_URL` in
`App.tsx` to your Mac's address so the phone can reach the verifier.

`react-native.config.js` links `react-native-step-tracker-pro-ios` from this
repository's root. Until `react-native-step-tracker-pro@2.11.0` is on npm,
install it from a local checkout: `npm pack` there, then
`npm install --no-save <path to the .tgz>` here.
