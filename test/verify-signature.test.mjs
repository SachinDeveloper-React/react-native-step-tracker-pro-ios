// scripts/verify-signature.mjs is what a server does with a signed snapshot.
// It is checked here against keys and signatures node makes itself, in the
// same shapes the module returns: SPKI DER public key, DER ECDSA signature.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { verify } from '../scripts/verify-signature.mjs';

function signed(payloadObject) {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const spki = publicKey.export({ format: 'der', type: 'spki' });
  const signedPayload = JSON.stringify(payloadObject);
  const bytes = Buffer.from(signedPayload, 'utf8');
  return {
    publicKey: spki.toString('base64'),
    signature: {
      keyId: createHash('sha256').update(spki).digest('hex'),
      algorithm: 'SHA256withECDSA',
      value: sign('sha256', bytes, { key: privateKey, dsaEncoding: 'der' }).toString('base64'),
      attested: false,
      signedPayload,
      payloadSha256: createHash('sha256').update(bytes).digest('hex'),
    },
  };
}

const snapshot = {
  schemaVersion: 2, platform: 'ios', date: '2026-09-14', deviceSteps: 300, gatedSteps: 100,
  minutesStatus: 'enabled', minutes: [{ minuteStart: 1, steps: 150, untimedSteps: 50 }],
};

test('a genuine signature verifies, with every check', () => {
  const result = verify(signed(snapshot));
  assert.equal(result.ok, true, JSON.stringify(result.checks));
  assert.equal(result.checks.minutesExplainCount, true);
});

test('an edited payload, a wrong key id or a short minute sum fails', () => {
  const tampered = signed(snapshot);
  tampered.signature.signedPayload = tampered.signature.signedPayload.replace('300', '30000');
  assert.equal(verify(tampered).checks.signature, false);

  const wrongKey = signed(snapshot);
  wrongKey.signature.keyId = '00'.repeat(32);
  assert.equal(verify(wrongKey).ok, false);

  const unexplained = signed({ ...snapshot, deviceSteps: 999 });
  assert.equal(verify(unexplained).checks.minutesExplainCount, false);
});
