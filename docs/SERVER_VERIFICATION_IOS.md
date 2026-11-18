# Verifying iOS snapshots on a server

An iOS snapshot is signed exactly as an Android one is, so the signature
check you already run works unchanged. What iOS adds is how the server comes
to trust the signing key, and what replaces the Play Integrity token:

| Step | Android | iOS |
|---|---|---|
| Trust the install's key, once | Key attestation chain to Google's root | App Attest attestation to Apple's root, binding the signing key |
| Verify each snapshot | ECDSA over `signedPayload` | The same |
| Fresh device verdict, when wanted | Play Integrity token over `payloadSha256` | App Attest assertion over `payloadSha256` |

Tell them apart by `VerificationSnapshot.platform` (`'ios'`; absent or
`'android'` is Android) and, before a snapshot exists, by
`DeviceAttestation.appAttest` being present.

This follows Apple's [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server).
A Node reference implementation is in
[`scripts/app-attest.mjs`](../scripts/app-attest.mjs) and
[`scripts/verify-signature.mjs`](../scripts/verify-signature.mjs), using
`node:crypto` only; `test/app-attest.test.mjs` runs it against a synthetic
attestation chain.

## 1. Attestation: trust the signing key

The app asks your server for a random, single-use challenge (1-128 bytes of
UTF-8) and calls `attestDevice(challenge)`. It posts back the whole
`DeviceAttestation`:

```json
{
  "keyId": "<hex SHA-256 of publicKey>",
  "publicKey": "<base64 SPKI DER of the Secure Enclave key>",
  "algorithm": "SHA256withECDSA",
  "attested": true,
  "securityLevel": "secure_enclave",
  "certificateChain": [],
  "appAttest": {
    "keyId": "<App Attest key id, base64>",
    "attestationObject": "<base64 CBOR>",
    "clientData": "<challenge>|<keyId>",
    "environment": "production"
  }
}
```

With `appAttest` present, check:

1. **The chain.** Decode the CBOR attestation object
   (`{ fmt: 'apple-appattest', attStmt: { x5c, receipt }, authData }`).
   `x5c[0]` (the credential certificate) and `x5c[1]` (the intermediate) lead
   to the **Apple App Attestation Root CA**
   ([`scripts/Apple_App_Attestation_Root_CA.pem`](../scripts/Apple_App_Attestation_Root_CA.pem),
   from <https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem>,
   SHA-256 fingerprint `1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32`), each valid now.
2. **The nonce.** `nonce = SHA256(authData ‖ SHA256(clientData))` equals the
   credential certificate's extension `1.2.840.113635.100.8.2` (an octet
   string inside a sequence).
3. **The key.** SHA-256 of the credential certificate's public key (the
   65-byte uncompressed point) equals `appAttest.keyId` (base64), and equals
   the credential id in `authData`.
4. **The app.** `authData`'s `rpIdHash` equals `SHA256("<TeamID>.<bundleId>")`.
5. **A new key.** `authData`'s counter is 0.
6. **The environment.** The aaguid is `appattestdevelop` for `development`,
   or `appattest` followed by seven zero bytes for `production`. Accept only
   the one your build uses.
7. **The binding.** `clientData` is `"<challenge>|<keyId>"`, with the
   challenge you issued (and have not seen before) and `keyId` equal to the
   hex SHA-256 of `publicKey` - which is also `DeviceAttestation.keyId`.

Then store, against the install:

- `publicKey` and `keyId`: the signing key every snapshot names;
- the credential public key and a counter of 0: for assertions;
- `attStmt.receipt`, if you want App Attest's fraud metric later.

```js
import { verifyAttestation } from './scripts/app-attest.mjs';

const { credentialPublicKey, signingKeyId } = verifyAttestation({
  attestationObject: body.appAttest.attestationObject,
  keyId: body.appAttest.keyId,
  clientData: body.appAttest.clientData,
  challenge: issuedChallenge,
  signingPublicKey: body.publicKey,
  teamId: 'ABCDE12345',
  bundleId: 'com.example.app',
  environment: 'production',
});
```

**`appAttest: null`** means the device could not attest - a simulator, a
device App Attest does not support - and `attested: false`. That is Android's
unattested fallback: the key works, but nothing vouches for it. Decide what
it is worth exactly as you do for an unattested Android key.

**A failed `attestDevice()`** with `E_INTEGRITY_FAILED` and
`details.playError: 'APP_ATTEST_SERVER_UNAVAILABLE'` (`retryable: true`) is
Apple's service being unreachable: ask the app to try again later rather than
accepting an unattested key from a device that can attest.

## 2. Each snapshot

Unchanged from Android:

```js
import { verify } from './scripts/verify-signature.mjs';

const { ok, checks, snapshot } = verify({ publicKey: stored.publicKey, signature: body.signature });
```

- `signature.keyId` names a key you stored;
- `value` (base64 DER ECDSA) verifies over the UTF-8 bytes of
  `signedPayload` with that key - `SHA256withECDSA`;
- `payloadSha256` is the hex SHA-256 of those bytes;
- parse `signedPayload` and trust only that.

Then score the day as you do for Android. What to expect from iOS values:

- `recoveredSteps` is always 0 and `sensor` is `'step_counter'`.
- `minutes` (with `minutesStatus: 'enabled'`) sum exactly to
  `deviceSteps - gatedSteps`.
- `motionWindows` is always `[]` with `motionWindowsStatus: 'unsupported'`.
- `sources` are Apple Health's: `packageName` is a bundle id; this iPhone is
  `kind: 'phone'` with `isPlatform: true`, an Apple Watch `kind: 'watch'` with
  `isPlatform: true`. `lateWrittenSteps` is `-1`; `calories` and
  `activeCalories` are 0.
- `healthConnectRecords.records[].lastModifiedTime` is 0.
- `capabilities.sdkInt` is 0; use `capabilities.osVersion`.
- `clock.bootId` is the boot time from `kern.boottime`: constant for one boot
  unless the wall clock is edited, as on Android.

See [IOS_DIFFERENCES.md](IOS_DIFFERENCES.md) for every field.

## 3. Assertions: a fresh verdict

When your server wants proof that a request comes from the genuine app on a
genuine device now - not only that it is signed by a key it trusted once -
it asks the app for an integrity token bound to the snapshot:

```ts
const { token, provider } = await StepTracker.requestIntegrityToken({ requestHash: signed.payloadSha256 });
// provider === 'app_attest'; no cloudProjectNumber on iOS
```

Check:

1. Decode the CBOR assertion: `{ signature, authenticatorData }`.
2. `nonce = SHA256(authenticatorData ‖ SHA256(UTF8(requestHash)))`, where
   `requestHash` is the `payloadSha256` you computed yourself from the
   `signedPayload` you verified.
3. `signature` is a valid ECDSA (SHA-256) signature over `nonce` under the
   credential public key you stored at attestation.
4. `authenticatorData`'s `rpIdHash` equals `SHA256("<TeamID>.<bundleId>")`.
5. Its counter is strictly greater than the one you stored; store the new one.
   An equal or lower counter is a replayed assertion.

```js
import { verifyAssertion } from './scripts/app-attest.mjs';

const { counter } = verifyAssertion({
  token, requestHash: computedPayloadSha256,
  credentialPublicKey: stored.credentialPublicKey,
  teamId: 'ABCDE12345', bundleId: 'com.example.app',
  previousCounter: stored.counter,
});
stored.counter = counter;
```

Errors the app may report instead of a token:

| `code` | `details.playError` | Meaning |
|---|---|---|
| `E_INTEGRITY_UNAVAILABLE` | - | No App Attest key: the install never attested on a supporting device |
| `E_INTEGRITY_FAILED` | `APP_ATTEST_SERVER_UNAVAILABLE` | Retry later (`retryable: true`) |
| `E_INTEGRITY_FAILED` | `APP_ATTEST_INVALID_KEY` | The key is gone (a restore, a reset): call `attestDevice()` again |
| `E_INTEGRITY_FAILED` | `APP_ATTEST_INVALID_INPUT`, `APP_ATTEST_FEATURE_UNSUPPORTED`, `APP_ATTEST_UNKNOWN_SYSTEM_FAILURE` | Not retryable as is |

`details.playErrorCode` is always null on iOS.

## Reinstalls

iOS keeps Keychain items across an uninstall, Android does not. This package
deletes its own leftovers on the first launch of a fresh install, so a
reinstalled app reports `hasAttestationKey() === false` and attests again,
with a new key and a new App Attest key - exactly what an Android reinstall
does. Treat the new key as a new install.
