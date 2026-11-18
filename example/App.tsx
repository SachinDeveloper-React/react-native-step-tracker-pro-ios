/**
 * One screen: permissions, today's count, its minutes, Apple Health
 * sources, and a signed snapshot ready to verify with
 * `node scripts/verify-signature.mjs` (Share sends the JSON it needs).
 *
 * The JavaScript is react-native-step-tracker-pro's, unchanged from
 * Android: react-native-step-tracker-pro-ios only registers the native module.
 */
import React, { useCallback, useEffect, useState } from 'react';
import { Button, ScrollView, Share, StyleSheet, Text, View } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import StepTracker, { isSupported } from 'react-native-step-tracker-pro';
import type {
  DeviceAttestation,
  HealthConnectStatus,
  PermissionStatus,
  SnapshotSignature,
  StepMinute,
  StepSnapshot,
  StepSource,
} from 'react-native-step-tracker-pro';

const today = () => {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
};

/**
 * The development verifier (`node scripts/verify-server.mjs`): localhost on
 * the simulator; on a device, your Mac's address on the same network.
 */
const VERIFY_URL = 'http://localhost:8787';

async function post(path: string, body: unknown): Promise<{ ok: boolean } | null> {
  try {
    const res = await fetch(`${VERIFY_URL}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return (await res.json()) as { ok: boolean };
  } catch {
    return null;
  }
}

/**
 * The reference consumer's calls, once, for the device checklist - reads
 * only. Nothing here starts, stops, pauses or resets tracking, sets
 * countFrom or other devices' steps: run on a phone being tested, those
 * would change the very count being measured. Use the buttons for them.
 */
async function smokeTest(): Promise<string[]> {
  const lines: string[] = [];
  const log = (line: string) => lines.push(line);
  const date = today();
  const seen: Record<string, number> = {};
  const subs = (['stepsChanged', 'trackingStateChanged', 'goalProgressChanged', 'dayChanged'] as const).map((event) =>
    StepTracker.addListener(event, () => {
      seen[event] = (seen[event] ?? 0) + 1;
    })
  );
  const calls: Array<[string, () => Promise<unknown>]> = [
    ['getConfig', () => StepTracker.getConfig()],
    ['getTrackingState', () => StepTracker.getTrackingState()],
    ['getTrackingHealth', () => StepTracker.getTrackingHealth()],
    ['getTodaySteps', () => StepTracker.getTodaySteps()],
    ['getStepsForDate', () => StepTracker.getStepsForDate(date)],
    ['checkPermissions', () => StepTracker.checkPermissions()],
    ['getHealthConnectStatus', () => StepTracker.getHealthConnectStatus()],
    ['getBackgroundRestrictionStatus', () => StepTracker.getBackgroundRestrictionStatus()],
    ['requestBackgroundPermissions', () => StepTracker.requestBackgroundPermissions()],
    ['getIntegrityReport', () => StepTracker.getIntegrityReport(date)],
    ['getVerificationSnapshot', () => StepTracker.getVerificationSnapshot(date, { include: ['minutes', 'motionWindows', 'healthConnectRecords'] })],
    ['hasAttestationKey', () => StepTracker.hasAttestationKey()],
    ['getDeviceCapabilities', () => StepTracker.getDeviceCapabilities()],
    ['getWeeklyStats', () => StepTracker.getWeeklyStats()],
    ['getHistory', () => StepTracker.getHistory(date, date)],
    ['getStepSources', () => StepTracker.getStepSources(date, date)],
    ['getCurrentStepSource', () => StepTracker.getCurrentStepSource()],
    ['prepareIntegrity', () => StepTracker.prepareIntegrity()],
    ['attestDevice', () => StepTracker.attestDevice(`challenge-${Date.now()}`)],
    ['getAttestationKeyInfo', () => StepTracker.getAttestationKeyInfo()],
    ['getSignedSnapshot', () => StepTracker.getSignedSnapshot(date, { nonce: 'n', include: ['minutes', 'motionWindows', 'healthConnectRecords'], healthConnectRecordTypes: ['steps', 'distance'] })],
    ['requestIntegrityToken', () => StepTracker.requestIntegrityToken({ requestHash: 'abc' })],
    ['getHealthConnectRecords', () => StepTracker.getHealthConnectRecords(`${date}T00:00:00Z`, new Date().toISOString())],
    ['getMotionWindows', () => StepTracker.getMotionWindows(date, date)],
    ['readHealthConnectVitals', () => StepTracker.readHealthConnectVitals(`${date}T00:00:00Z`, new Date().toISOString(), { types: ['heartRate'] })],
    ['writeHealthConnectSteps', () => StepTracker.writeHealthConnectSteps(date)],
    ['revokeHealthConnectPermissions', () => StepTracker.revokeHealthConnectPermissions()],
    ['getSyncStatus', () => StepTracker.getSyncStatus()],
  ];
  for (const [name, run] of calls) {
    try {
      const value = await run();
      log(`[smoke] ok ${name} ${JSON.stringify(value)?.slice(0, 300)}`);
    } catch (e) {
      const err = e as { code?: string; message?: string };
      log(`[smoke] reject ${name} ${err.code} ${err.message}`);
    }
  }
  try {
    const key = await StepTracker.getAttestationKeyInfo();
    const signature = await StepTracker.getSignedSnapshot(date, { nonce: 'smoke', include: ['minutes'] });
    if (key) {
      const verdict = await post('/verify', { publicKey: key.publicKey, signature });
      log(`[smoke] verify ${JSON.stringify(verdict)}`);
    }
  } catch (e) {
    log(`[smoke] verify-failed ${(e as Error).message}`);
  }
  await new Promise<void>((resolve) => setTimeout(resolve, 1000));
  subs.forEach((sub) => sub.remove());
  log(`[smoke] events ${JSON.stringify(seen)}`);
  await post('/report', { lines });
  return lines;
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.row}>
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.value}>{value}</Text>
    </View>
  );
}

function Screen() {
  const [permissions, setPermissions] = useState<PermissionStatus | null>(null);
  const [health, setHealth] = useState<HealthConnectStatus | null>(null);
  const [snapshot, setSnapshot] = useState<StepSnapshot | null>(null);
  const [minutes, setMinutes] = useState<StepMinute[]>([]);
  const [sources, setSources] = useState<StepSource[]>([]);
  const [key, setKey] = useState<DeviceAttestation | null>(null);
  const [signed, setSigned] = useState<SnapshotSignature | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [checks, setChecks] = useState<string[]>([]);
  const [verified, setVerified] = useState<string>('-');

  const refresh = useCallback(async () => {
    try {
      setPermissions(await StepTracker.checkPermissions());
      setHealth(await StepTracker.getHealthConnectStatus());
      setSnapshot(await StepTracker.getTodaySteps());
      setMinutes(await StepTracker.getStepMinutes(today(), today()));
      setSources((await StepTracker.getStepSources(today(), today())).sources);
      setKey(await StepTracker.getAttestationKeyInfo());
      setError(null);
    } catch (e) {
      setError(String((e as Error).message ?? e));
    }
  }, []);

  useEffect(() => {
    if (!isSupported()) {
      setError('No native module: install react-native-step-tracker-pro-ios and run pod install.');
      return;
    }
    const sub = StepTracker.addListener('stepsChanged', setSnapshot);
    StepTracker.initialize({
      dailyGoal: 8000,
      healthConnectReadTypes: ['steps', 'distance'],
      fraudDetection: { enabled: true, activityRecognition: true },
      motionGate: { enabled: true },
    })
      .then(refresh)
      .then(smokeTest)
      .then((lines) => {
        setChecks(lines);
        return refresh();
      })
      .catch((e) => setError(String(e.message ?? e)));
    return () => sub.remove();
  }, [refresh]);

  const act = (work: () => Promise<unknown>) => async () => {
    try {
      await work();
      await refresh();
    } catch (e) {
      setError(`${(e as { code?: string }).code ?? ''} ${(e as Error).message}`);
    }
  };

  const sign = act(async () => {
    const nonce = Math.random().toString(36).slice(2);
    const block = await StepTracker.getSignedSnapshot(today(), {
      nonce,
      include: ['minutes', 'motionWindows', 'healthConnectRecords'],
      healthConnectRecordTypes: ['steps', 'distance'],
    });
    setSigned(block);
    const info = await StepTracker.getAttestationKeyInfo();
    const verdict = info ? await post('/verify', { publicKey: info.publicKey, signature: block }) : null;
    setVerified(verdict ? (verdict.ok ? 'verified' : 'FAILED') : 'no verifier running');
  });

  const share = async () => {
    if (!signed || !key) return;
    // What scripts/verify-signature.mjs takes: the public key and the block.
    await Share.share({ message: JSON.stringify({ publicKey: key.publicKey, signature: signed }) });
  };

  const minuteSum = minutes.reduce((sum, m) => sum + m.steps + m.untimedSteps, 0);

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.title}>Step Tracker Pro - iOS</Text>
      {error ? <Text style={styles.error}>{error}</Text> : null}

      <Text style={styles.section}>Permissions</Text>
      <Row label="Motion & Fitness" value={String(permissions?.activityRecognition ?? '-')} />
      <Row label="Apple Health steps" value={String(health?.stepsGranted ?? '-')} />
      <Row label="Readable types" value={(health?.grantedReadTypes ?? []).join(', ') || '-'} />
      <View style={styles.buttons}>
        <Button title="Motion" onPress={act(() => StepTracker.requestPermissions())} />
        <Button title="Apple Health" onPress={act(() => StepTracker.enableHealthConnect())} />
        <Button title="Start" onPress={act(() => StepTracker.startTracking())} />
        <Button title="Pause" onPress={act(() => StepTracker.pauseTracking())} />
        <Button title="Stop" onPress={act(() => StepTracker.stopTracking())} />
      </View>

      <Text style={styles.section}>Today</Text>
      <Row label="Steps" value={String(snapshot?.steps ?? '-')} />
      <Row label="State" value={snapshot?.state ?? '-'} />
      <Row label="This phone" value={String(snapshot?.stepSource.deviceSteps ?? '-')} />
      <Row label="Held as a vehicle's" value={String(snapshot?.gatedSteps ?? '-')} />
      <Row label="Answered by" value={snapshot?.stepSource.appName ?? '-'} />
      <Row label="Distance (m)" value={String(snapshot?.distance ?? '-')} />
      <Row label="Calories (kcal)" value={String(snapshot?.calories ?? '-')} />

      <Text style={styles.section}>Minutes</Text>
      <Row label="Minutes with steps" value={String(minutes.length)} />
      <Row label="Their sum" value={String(minuteSum)} />
      {minutes.slice(-5).map((m) => (
        <Row key={m.minuteStart} label={new Date(m.minuteStart).toLocaleTimeString()} value={`${m.steps} (${m.vehicleSteps} vehicle, ${m.stillSteps} still)`} />
      ))}

      <Text style={styles.section}>Apple Health sources</Text>
      {sources.length === 0 ? <Text>None read</Text> : null}
      {sources.map((s) => (
        <Row key={s.packageName} label={`${s.appName} (${s.kind})`} value={`${s.steps}, manual ${s.manualSteps}`} />
      ))}

      <Text style={styles.section}>Signed snapshot</Text>
      <Row label="Key" value={key ? `${key.keyId.slice(0, 12)}… ${key.securityLevel}${key.attested ? ', attested' : ''}` : 'none'} />
      <View style={styles.buttons}>
        <Button title="Attest" onPress={act(() => StepTracker.attestDevice(Math.random().toString(36).slice(2)))} />
        <Button title="Sign today" onPress={sign} />
        <Button title="Share" onPress={share} disabled={!signed} />
      </View>
      {signed ? (
        <>
          <Row label="payloadSha256" value={signed.payloadSha256.slice(0, 24) + '…'} />
          <Row label="Payload bytes" value={String(signed.signedPayload.length)} />
          <Row label="Server check" value={verified} />
          <Text style={styles.mono}>{signed.signedPayload.slice(0, 600)}</Text>
        </>
      ) : null}
      <Text style={styles.section}>Checks</Text>
      <Row
        label="Calls that resolved"
        value={checks.length ? `${checks.filter((l) => l.startsWith('[smoke] ok')).length} of ${checks.filter((l) => /\[smoke\] (ok|reject)/.test(l)).length}` : 'running…'}
      />
      {checks.filter((l) => !l.startsWith('[smoke] ok')).map((l) => (
        <Text key={l} style={styles.mono}>{l.slice(8, 160)}</Text>
      ))}
      <Button title="Refresh" onPress={refresh} />
    </ScrollView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.fill}>
        <Screen />
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  container: { padding: 16, gap: 6 },
  title: { fontSize: 22, fontWeight: '600', marginBottom: 8 },
  section: { fontSize: 17, fontWeight: '600', marginTop: 16 },
  row: { flexDirection: 'row', justifyContent: 'space-between', gap: 12 },
  label: { color: '#555', flexShrink: 1 },
  value: { fontVariant: ['tabular-nums'], flexShrink: 1, textAlign: 'right' },
  buttons: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  error: { color: '#b00020' },
  mono: { fontFamily: 'Menlo', fontSize: 11 },
});
