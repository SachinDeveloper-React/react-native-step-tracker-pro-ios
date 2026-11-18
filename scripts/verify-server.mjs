#!/usr/bin/env node
// A development verifier for the example app: POST /verify with
// { publicKey, signature } and it answers with the checks a server makes;
// POST /report prints whatever the app sends. Development only - a real
// server also verifies the App Attest attestation (docs/SERVER_VERIFICATION_IOS.md).
//
//   node scripts/verify-server.mjs [port]      (default 8787)
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
import { verify } from './verify-signature.mjs';

const port = Number(process.argv[2] ?? 8787);
const out = process.env.VERIFY_SERVER_DUMP;

createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => (body += chunk));
  req.on('end', () => {
    try {
      const data = JSON.parse(body || '{}');
      let answer;
      if (req.url === '/verify') {
        const result = verify(data);
        answer = { ok: result.ok, checks: result.checks };
        console.log(`[verify] ${JSON.stringify(answer)}`);
      } else {
        answer = { ok: true };
        for (const line of data.lines ?? []) console.log(line);
      }
      if (out) writeFileSync(`${out}-${req.url.slice(1)}.json`, JSON.stringify(data, null, 2));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(answer));
    } catch (error) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: String(error) }));
    }
  });
}).listen(port, () => console.log(`verify server on http://localhost:${port}`));
