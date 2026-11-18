# Device checklist

What only a real iPhone can confirm. Run the example app (`example/`) on a
device with the HealthKit (Background Delivery) and App Attest capabilities,
and `node scripts/verify-server.mjs` on a Mac on the same network (set
`VERIFY_URL` in `example/App.tsx` to the Mac's address). Record the results
here before a release.

| # | Check | How | Pass when | Result |
|---|---|---|---|---|
| 1 | Every call resolves | Launch the example; read **Checks** | All resolve, or reject with a documented code (`startTracking` before Motion & Fitness, `requestIntegrityToken` before attesting) | |
| 2 | A 500-step walk matches the Health app | Start tracking, walk 500 counted steps, compare `deviceSteps` with the Health app's steps for this iPhone over the same minutes | Within 2% | |
| 3 | Minutes explain the count | **Sign today** after a walk; the verifier's `minutesExplainCount` | `true`, and the per-hour residual absorbed by the fit is a few steps at most (log `hours` against `minutes` in a debug build to measure) | |
| 4 | A car or bus ride is gated | Ride 15+ minutes with the gate on, phone in a pocket or bag; walk away at the end | `gatedSteps` > 0, the walk away counted, `integrity.motionGate.gatedSteps` matches | |
| 5 | A watch walk with the phone on a desk resolves to the watch | Leave the phone, walk with an Apple Watch, let it sync | `stepSource.kind === 'watch'`, `usedExternal`, the Watch's number | |
| 6 | A manual entry stays out | Add 5,000 steps by hand in the Health app; `healthConnectIgnoreManualEntries: true` | It appears in `manualSteps` of source `com.apple.Health` and not in `resolved` (`manualStepsExcluded`) | |
| 7 | A locked background wake does not crash | Lock the phone, walk with an Apple Watch or another app writing steps, wait for an hourly delivery | No crash in Xcode's device log; on unlock the day is complete | |
| 8 | Reinstall forgets the key | Attest, delete the app, reinstall | `hasAttestationKey()` is false | Simulator: pass |
| 9 | Attestation verifies on the server | **Attest**, post `DeviceAttestation` to `verifyAttestation()` with your team id and bundle id | Verified; `requestIntegrityToken()` then verifies with `verifyAssertion()` and the counter rises | |
| 10 | Simulator | Run on a simulator | No crash; `attestDevice()` gives `attested: false`, `appAttest: null`; `requestIntegrityToken()` rejects `E_INTEGRITY_UNAVAILABLE` | Pass (iOS 26.5 simulator, RN 0.87.1) |
| 11 | Health grant inference | Deny steps on Apple Health's sheet on a phone with steps this week | `stepsGranted: false`, `shouldOpenSettings: true` | |
| 12 | Midnight | Leave the app open across midnight | `dayChanged` with the closed day's steps; yesterday final and unchanged afterwards | |
