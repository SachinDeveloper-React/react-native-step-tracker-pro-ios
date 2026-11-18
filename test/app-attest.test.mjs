// scripts/app-attest.mjs against a synthetic App Attest attestation: a root,
// an intermediate and a credential certificate made with openssl, carrying
// the nonce extension the way Apple's do. A simulator cannot attest, so
// this is how the server path is pinned without a device.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeCbor, verifyAssertion, verifyAttestation } from '../scripts/app-attest.mjs';

const sha256 = (...parts) => createHash('sha256').update(Buffer.concat(parts.map((p) => Buffer.from(p)))).digest();

/** Just enough CBOR to build the objects. */
function cbor(value) {
  const head = (major, n) => {
    if (n < 24) return Buffer.from([(major << 5) | n]);
    if (n < 256) return Buffer.from([(major << 5) | 24, n]);
    const b = Buffer.alloc(3); b[0] = (major << 5) | 25; b.writeUInt16BE(n, 1); return b;
  };
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === 'string') { const s = Buffer.from(value); return Buffer.concat([head(3, s.length), s]); }
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const keys = Object.keys(value);
  return Buffer.concat([head(5, keys.length), ...keys.flatMap((k) => [cbor(k), cbor(value[k])])]);
}

const teamId = 'TEAMID1234';
const bundleId = 'com.example.steps';
const rpIdHash = sha256(Buffer.from(`${teamId}.${bundleId}`));

function openssl(dir, ...args) {
  execFileSync('openssl', args, { cwd: dir, stdio: 'pipe' });
}

function makeAttestation({ challenge = 'server-challenge' } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'appattest-'));
  const credential = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const signing = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const signingSpki = signing.publicKey.export({ format: 'der', type: 'spki' });
  const signingKeyId = createHash('sha256').update(signingSpki).digest('hex');
  const credSpki = credential.publicKey.export({ format: 'der', type: 'spki' });
  const keyIdBytes = sha256(credSpki.subarray(credSpki.length - 65));
  const authData = Buffer.concat([
    rpIdHash, Buffer.from([0x40]), Buffer.alloc(4), Buffer.from('appattestdevelop'),
    Buffer.from([0x00, 0x20]), keyIdBytes,
  ]);
  const clientData = `${challenge}|${signingKeyId}`;
  const nonce = sha256(authData, sha256(Buffer.from(clientData)));

  writeFileSync(join(dir, 'cred.key'), credential.privateKey.export({ format: 'pem', type: 'pkcs8' }));
  writeFileSync(join(dir, 'ca.ext'), 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n');
  writeFileSync(join(dir, 'leaf.ext'), `1.2.840.113635.100.8.2=DER:3024A1220420${nonce.toString('hex')}\n`);
  openssl(dir, 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'root.key');
  openssl(dir, 'req', '-x509', '-new', '-key', 'root.key', '-subj', '/CN=Test Root', '-days', '30', '-out', 'root.pem',
    '-addext', 'basicConstraints=critical,CA:true', '-addext', 'keyUsage=critical,keyCertSign,cRLSign');
  openssl(dir, 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'int.key');
  openssl(dir, 'req', '-new', '-key', 'int.key', '-subj', '/CN=Test Intermediate', '-out', 'int.csr');
  openssl(dir, 'x509', '-req', '-in', 'int.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial',
    '-days', '30', '-extfile', 'ca.ext', '-out', 'int.pem');
  openssl(dir, 'req', '-new', '-key', 'cred.key', '-subj', '/CN=credential', '-out', 'cred.csr');
  openssl(dir, 'x509', '-req', '-in', 'cred.csr', '-CA', 'int.pem', '-CAkey', 'int.key', '-CAcreateserial',
    '-days', '30', '-extfile', 'leaf.ext', '-out', 'cred.pem');
  const der = (name) => {
    openssl(dir, 'x509', '-in', name, '-outform', 'DER', '-out', `${name}.der`);
    return readFileSync(join(dir, `${name}.der`));
  };
  const attestationObject = cbor({
    fmt: 'apple-appattest',
    attStmt: { x5c: [der('cred.pem'), der('int.pem')], receipt: Buffer.from('receipt') },
    authData,
  }).toString('base64');
  return {
    attestationObject, clientData, challenge, credential, rootPem: readFileSync(join(dir, 'root.pem'), 'utf8'),
    keyId: keyIdBytes.toString('base64'), signingPublicKey: signingSpki.toString('base64'), signingKeyId,
  };
}

test('CBOR decodes maps, arrays, bytes and strings', () => {
  assert.deepEqual(decodeCbor(cbor({ a: ['x', Buffer.from([1, 2])] })), { a: ['x', Buffer.from([1, 2])] });
});

test('a genuine attestation verifies, and binds the signing key', () => {
  const a = makeAttestation();
  const result = verifyAttestation({ ...a, teamId, bundleId, environment: 'development' });
  assert.equal(result.signingKeyId, a.signingKeyId);
  assert.match(result.credentialPublicKey, /BEGIN PUBLIC KEY/);
});

test('the wrong challenge, app, environment or root is refused', () => {
  const a = makeAttestation();
  const base = { ...a, teamId, bundleId, environment: 'development' };
  assert.throws(() => verifyAttestation({ ...base, challenge: 'another' }), /clientData/);
  assert.throws(() => verifyAttestation({ ...base, bundleId: 'com.example.other' }), /rpIdHash/);
  assert.throws(() => verifyAttestation({ ...base, environment: 'production' }), /aaguid/);
  assert.throws(() => verifyAttestation({ ...base, clientData: `x${a.clientData}` }), /nonce/);
  assert.throws(() => verifyAttestation({ ...base, rootPem: undefined }), /issued/);
});

test('assertions verify, and a replay is refused', () => {
  const a = makeAttestation();
  const { credentialPublicKey } = verifyAttestation({ ...a, teamId, bundleId, environment: 'development' });
  const requestHash = 'ab'.repeat(32);
  const counter = Buffer.alloc(4);
  counter.writeUInt32BE(1);
  const authenticatorData = Buffer.concat([rpIdHash, Buffer.from([0x40]), counter]);
  const nonce = sha256(authenticatorData, sha256(Buffer.from(requestHash)));
  const signature = sign('sha256', nonce, a.credential.privateKey);
  const token = cbor({ signature, authenticatorData }).toString('base64');
  const args = { token, requestHash, credentialPublicKey, teamId, bundleId };
  assert.deepEqual(verifyAssertion({ ...args, previousCounter: 0 }), { counter: 1 });
  assert.throws(() => verifyAssertion({ ...args, previousCounter: 1 }), /replayed/);
  assert.throws(() => verifyAssertion({ ...args, requestHash: 'cd'.repeat(32), previousCounter: 0 }), /signature/);
});
