// The TurboModule this package registers is driven by
// react-native-step-tracker-pro's JavaScript, so its codegen spec must be
// that package's spec, byte for byte: a method added or retyped there and
// not here would be missing from the native module, or called with the
// wrong types. This fails until the copy is refreshed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

test('src/NativeStepTrackerPro.ts is the peer package spec, byte for byte', () => {
  const peerRoot = dirname(require.resolve('react-native-step-tracker-pro/package.json'));
  const peer = readFileSync(join(peerRoot, 'src', 'NativeStepTrackerPro.ts'));
  const ours = readFileSync(join(here, '..', 'src', 'NativeStepTrackerPro.ts'));
  assert.ok(
    peer.equals(ours),
    'src/NativeStepTrackerPro.ts differs from react-native-step-tracker-pro/src/NativeStepTrackerPro.ts; ' +
      'copy it over and implement whatever changed in ios/StepTrackerProModule.mm'
  );
});

test('the peer package is at least the version this one needs', () => {
  const peer = require('react-native-step-tracker-pro/package.json');
  const [major, minor] = peer.version.split('.').map(Number);
  assert.ok(major > 2 || (major === 2 && minor >= 11), `peer is ${peer.version}; need >= 2.11.0`);
});

test('the Swift library version matches package.json', () => {
  const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'));
  const swift = readFileSync(join(here, '..', 'ios', 'Core', 'LibraryVersion.swift'), 'utf8');
  const match = swift.match(/current\s*=\s*"([^"]+)"/);
  assert.ok(match, 'LibraryVersion.current not found');
  assert.equal(match[1], pkg.version);
});

test('every spec method is implemented in the ObjC++ module', () => {
  const spec = readFileSync(join(here, '..', 'src', 'NativeStepTrackerPro.ts'), 'utf8');
  const mm = readFileSync(join(here, '..', 'ios', 'StepTrackerProModule.mm'), 'utf8');
  const body = spec.slice(spec.indexOf('export interface Spec'), spec.indexOf('export default'));
  const methods = [...body.matchAll(/^\s+([a-zA-Z]+)\(/gm)].map((m) => m[1]);
  assert.ok(methods.length > 60, `parsed ${methods.length} methods`);
  const missing = methods.filter((name) => !new RegExp(`-\\s*\\([^)]*\\)\\s*${name}\\b`).test(mm));
  assert.deepEqual(missing, []);
});
