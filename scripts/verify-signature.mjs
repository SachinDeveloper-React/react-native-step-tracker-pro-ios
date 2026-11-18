#!/usr/bin/env node
// Verifies a signed snapshot the way a server does, with node:crypto only.
//
//   node scripts/verify-signature.mjs signed.json
//
// signed.json: { "publicKey": "<base64 SPKI from attestDevice()>",
//                "signature": <the block getSignedSnapshot() returns> }
//
// The same check works for Android and iOS snapshots: base64 DER ECDSA
// P-256 over the UTF-8 bytes of signedPayload (SHA256withECDSA), and keyId
// = hex SHA-256 of the SubjectPublicKeyInfo.
import { createHash, createPublicKey, verify as verifySignature } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/** @returns {{ ok: boolean, checks: Record<string, boolean>, snapshot: object | null }} */
export function verify({ publicKey, signature }) {
  const spki = Buffer.from(publicKey, 'base64');
  const payload = Buffer.from(signature.signedPayload, 'utf8');
  const key = createPublicKey({ key: spki, format: 'der', type: 'spki' });
  const checks = {
    curveIsP256: key.asymmetricKeyDetails?.namedCurve === 'prime256v1',
    algorithm: signature.algorithm === 'SHA256withECDSA',
    keyIdIsSha256OfSpki: createHash('sha256').update(spki).digest('hex') === signature.keyId,
    payloadSha256: createHash('sha256').update(payload).digest('hex') === signature.payloadSha256,
    signature: verifySignature('sha256', payload, { key, dsaEncoding: 'der' }, Buffer.from(signature.value, 'base64')),
  };
  let snapshot = null;
  try {
    snapshot = JSON.parse(signature.signedPayload);
    checks.schemaVersion2 = snapshot.schemaVersion === 2;
    // Trust what was signed, never the unsigned fields around it.
    if (Array.isArray(snapshot.minutes) && snapshot.minutesStatus === 'enabled') {
      const sum = snapshot.minutes.reduce((s, m) => s + m.steps + m.untimedSteps, 0);
      checks.minutesExplainCount = sum === snapshot.deviceSteps - (snapshot.gatedSteps ?? 0);
    }
  } catch {
    checks.payloadIsJson = false;
  }
  return { ok: Object.values(checks).every(Boolean), checks, snapshot };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const file = process.argv[2];
  if (!file) {
    console.error('usage: node scripts/verify-signature.mjs signed.json');
    process.exit(2);
  }
  const result = verify(JSON.parse(readFileSync(file, 'utf8')));
  console.log(JSON.stringify({ ok: result.ok, checks: result.checks,
    platform: result.snapshot?.platform ?? 'android', date: result.snapshot?.date,
    deviceSteps: result.snapshot?.deviceSteps }, null, 2));
  process.exit(result.ok ? 0 : 1);
}
