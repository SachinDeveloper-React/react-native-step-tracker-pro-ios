// A reference implementation of the server side of App Attest for
// react-native-step-tracker-pro-ios, following Apple's "Validating apps that
// connect to your server", with node:crypto only. See
// docs/SERVER_VERIFICATION_IOS.md for where each check fits.
//
//   import { verifyAttestation, verifyAssertion } from './app-attest.mjs';
import { X509Certificate, createHash, createPublicKey, verify as verifySignature } from 'node:crypto';
import { readFileSync } from 'node:fs';

const sha256 = (...parts) => createHash('sha256').update(Buffer.concat(parts.map((p) => Buffer.from(p)))).digest();

export const APPLE_ROOT_PEM = readFileSync(new URL('./Apple_App_Attestation_Root_CA.pem', import.meta.url), 'utf8');

/** OID 1.2.840.113635.100.8.2, DER-encoded: the extension carrying the nonce. */
const NONCE_OID = Buffer.from('06092a864886f763640802', 'hex');

/** A small CBOR decoder: what App Attest objects use (maps, arrays, strings, bytes, ints). */
export function decodeCbor(input) {
  const buf = Buffer.from(input);
  let o = 0;
  const length = (ai) => {
    if (ai < 24) return ai;
    if (ai === 24) return buf[o++];
    if (ai === 25) { const v = buf.readUInt16BE(o); o += 2; return v; }
    if (ai === 26) { const v = buf.readUInt32BE(o); o += 4; return v; }
    if (ai === 27) { const v = Number(buf.readBigUInt64BE(o)); o += 8; return v; }
    throw new Error(`unsupported CBOR length ${ai}`);
  };
  const read = () => {
    const ib = buf[o++];
    const major = ib >> 5;
    const ai = ib & 31;
    if (major === 7) {
      if (ai === 20) return false;
      if (ai === 21) return true;
      if (ai === 22) return null;
      throw new Error(`unsupported CBOR simple value ${ai}`);
    }
    const n = length(ai);
    switch (major) {
      case 0: return n;
      case 1: return -1 - n;
      case 2: { const v = Buffer.from(buf.subarray(o, o + n)); o += n; return v; }
      case 3: { const v = buf.toString('utf8', o, o + n); o += n; return v; }
      case 4: return Array.from({ length: n }, read);
      case 5: {
        const out = {};
        for (let i = 0; i < n; i++) { const k = read(); out[k] = read(); }
        return out;
      }
      default: throw new Error(`unsupported CBOR major type ${major}`);
    }
  };
  return read();
}

/** rpIdHash | flags | counter | aaguid | credentialIdLength | credentialId ... */
export function parseAuthData(authData) {
  const a = Buffer.from(authData);
  const out = { rpIdHash: a.subarray(0, 32), flags: a[32], counter: a.readUInt32BE(33) };
  if (a.length >= 55) {
    out.aaguid = a.subarray(37, 53);
    const idLength = a.readUInt16BE(53);
    out.credentialId = a.subarray(55, 55 + idLength);
  }
  return out;
}

/** The 32-byte nonce in the credential certificate's 1.2.840.113635.100.8.2 extension. */
function certificateNonce(certDer) {
  const at = certDer.indexOf(NONCE_OID);
  if (at < 0) return null;
  // extnValue OCTET STRING { SEQUENCE { [1] { OCTET STRING (32) } } }
  const window = certDer.subarray(at + NONCE_OID.length, at + NONCE_OID.length + 48);
  const inner = window.indexOf(Buffer.from([0x04, 0x20]));
  return inner < 0 ? null : window.subarray(inner + 2, inner + 34);
}

/** The uncompressed P-256 point of an EC public key. */
function rawPoint(keyObject) {
  const spki = keyObject.export({ format: 'der', type: 'spki' });
  return spki.subarray(spki.length - 65);
}

/**
 * Verifies `DeviceAttestation.appAttest` from attestDevice().
 *
 * @param {object} p
 * @param {string} p.attestationObject base64 CBOR
 * @param {string} p.keyId App Attest's key id (base64)
 * @param {string} p.clientData the `challenge|keyId` string the device attested
 * @param {string} p.challenge the challenge this server issued
 * @param {string} p.signingPublicKey `DeviceAttestation.publicKey` (base64 SPKI)
 * @param {string} p.teamId your Apple developer team id
 * @param {string} p.bundleId the app's bundle id
 * @param {'development'|'production'} p.environment
 * @param {string} [p.rootPem] Apple's App Attestation root, by default the one beside this file
 * @param {Date} [p.now]
 * @returns {{ credentialPublicKey: string, signingKeyId: string, receipt: Buffer }} the
 *   credential key (PEM) to store for assertions, and the signing key id to trust.
 */
export function verifyAttestation(p) {
  const now = p.now ?? new Date();
  const att = decodeCbor(Buffer.from(p.attestationObject, 'base64'));
  if (att.fmt !== 'apple-appattest') throw new Error('not an App Attest attestation');
  const [credDer, ...intermediates] = att.attStmt.x5c;
  const chain = [credDer, ...intermediates].map((der) => new X509Certificate(der));
  const root = new X509Certificate(p.rootPem ?? APPLE_ROOT_PEM);

  // 1. The certificates lead to Apple's App Attestation Root CA.
  const path = [...chain, root];
  for (let i = 0; i < path.length - 1; i++) {
    const cert = path[i];
    const issuer = path[i + 1];
    if (!cert.checkIssued(issuer) || !cert.verify(issuer.publicKey)) throw new Error(`certificate ${i} is not issued by the next`);
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) throw new Error(`certificate ${i} is not valid now`);
  }

  // 2-4. nonce = SHA256(authData || SHA256(clientData)) is in the credential certificate.
  const clientDataHash = sha256(Buffer.from(p.clientData, 'utf8'));
  const nonce = sha256(att.authData, clientDataHash);
  const certNonce = certificateNonce(Buffer.from(credDer));
  if (!certNonce || !certNonce.equals(nonce)) throw new Error('nonce does not match the credential certificate');

  // 5. SHA256 of the credential public key is the key id, and the credential id.
  const credentialKey = chain[0].publicKey;
  const keyIdBytes = sha256(rawPoint(credentialKey));
  if (!keyIdBytes.equals(Buffer.from(p.keyId, 'base64'))) throw new Error('key id is not the credential key');
  const auth = parseAuthData(att.authData);
  if (!auth.credentialId?.equals(keyIdBytes)) throw new Error('credential id is not the key id');

  // 6. The app: rpIdHash = SHA256("<TeamID>.<bundleId>").
  if (!auth.rpIdHash.equals(sha256(Buffer.from(`${p.teamId}.${p.bundleId}`, 'utf8')))) throw new Error('rpIdHash is not this app');

  // 7. A new key: counter 0.
  if (auth.counter !== 0) throw new Error('counter is not 0');

  // 8. The environment's aaguid.
  const aaguid = p.environment === 'production'
    ? Buffer.concat([Buffer.from('appattest', 'ascii'), Buffer.alloc(7)])
    : Buffer.from('appattestdevelop', 'ascii');
  if (!auth.aaguid?.equals(aaguid)) throw new Error(`aaguid is not ${p.environment}`);

  // 9. The client data binds this server's challenge to the signing key.
  const signingKeyId = createHash('sha256').update(Buffer.from(p.signingPublicKey, 'base64')).digest('hex');
  if (p.clientData !== `${p.challenge}|${signingKeyId}`) throw new Error('clientData is not challenge|keyId');

  return {
    credentialPublicKey: credentialKey.export({ format: 'pem', type: 'spki' }),
    signingKeyId,
    receipt: att.attStmt.receipt,
  };
}

/**
 * Verifies `requestIntegrityToken()`'s App Attest assertion over a signed
 * snapshot's `payloadSha256`.
 *
 * @returns {{ counter: number }} store it; the next must be greater.
 */
export function verifyAssertion({ token, requestHash, credentialPublicKey, teamId, bundleId, previousCounter }) {
  const { signature, authenticatorData } = decodeCbor(Buffer.from(token, 'base64'));
  const clientDataHash = sha256(Buffer.from(requestHash, 'utf8'));
  const nonce = sha256(authenticatorData, clientDataHash);
  if (!verifySignature('sha256', nonce, createPublicKey(credentialPublicKey), signature)) throw new Error('assertion signature is not valid');
  const auth = parseAuthData(authenticatorData);
  if (!auth.rpIdHash.equals(sha256(Buffer.from(`${teamId}.${bundleId}`, 'utf8')))) throw new Error('rpIdHash is not this app');
  if (!(auth.counter > previousCounter)) throw new Error('counter did not increase: a replayed assertion');
  return { counter: auth.counter };
}
