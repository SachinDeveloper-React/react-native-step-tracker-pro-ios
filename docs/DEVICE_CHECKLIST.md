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
| 13 | Minute resolution | After a 30-minute walk, read today's minutes (`getStepMinutes`) | Runs of near-equal minutes up to ~10 long, as the research predicts; no minute over 500. Note the record lengths you see | |
| 14 | Watch morning, phone evening | Walk with only the Watch, later with only the phone | `getTodaySteps().steps` within 2% of the Health app's total; `stepSource.merged` true | |
| 15 | Treadmill | 30+ minutes at a fixed belt speed, `fraudDetection.mode: 'exclude'` | No steps taken out; any `steady_cadence` flag is weak with `minuteData: 'averaged'` | |
| 16 | Background delivery | Leave the app in the background (do not swipe it away: iOS may not wake an app the user force-quit), walk an hour with Apple Health access | The day updates without opening the app (check `computedAt` / events on the next launch) | |
| 17 | Limited history (iOS 27) | Allow Apple Health "recent data only" | `historyReadGranted: false`; days before the window are not read | |
| 18 | A background wake reuses the settled hours | Walk in the morning; stop the app from Xcode (not a swipe); let an hourly Apple Health delivery wake it in the afternoon | `hours.json` (download the container in Xcode) lists the morning's hours; the woken day matches the count on the next launch | |
| 19 | A failed attestation keeps the key | **Attest** online; then turn on Airplane Mode and **Attest** again | Rejects `E_INTEGRITY_FAILED` (note `details.playError`; expected `APP_ATTEST_SERVER_UNAVAILABLE`, `retryable: true`); `getAttestationKeyInfo()` unchanged - same `keyId`, `attested: true`; **Sign today** verifies against the key on file; `requestIntegrityToken()` still verifies | |
| 20 | Attesting again replaces the key | **Attest** twice | A new `keyId` each time, info and signatures follow it, one signing key left in the Keychain | Simulator: pass (iOS 26.5, unattested path; key rows counted in the simulator's keychain database) |
