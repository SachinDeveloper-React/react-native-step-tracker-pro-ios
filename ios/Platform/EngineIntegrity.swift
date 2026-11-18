import CryptoKit
import DeviceCheck
import Foundation

extension Engine {
    // ---- the verification snapshot ---------------------------------------------------------------

    func verificationSnapshot(_ date: String, _ options: JSON, _ done: @escaping Done) throws {
        let sign = options["sign"]?.boolValue ?? false
        let nonce = options["nonce"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let include = options["include"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let typeNames = options["healthConnectRecordTypes"]?.arrayValue?.compactMap(\.stringValue)
        let kinds = (typeNames ?? ["steps"]).compactMap(HealthSample.Kind.init(rawValue:))
        guard include.allSatisfy(Snapshot.parts.contains), !kinds.isEmpty, kinds.count == (typeNames ?? ["steps"]).count else {
            throw BridgeError.invalid("include takes minutes, motionWindows and healthConnectRecords; healthConnectRecordTypes takes steps and distance")
        }
        let signedOnly = sign && (options["signedOnly"]?.boolValue ?? false)
        let c = clock
        let today = date == c.today()
        // Fresh: the evidence a server scores is never a minute-old count.
        let record = deviceDay(date)
        let (sources, sourcesStatus) = sources(date, mode: .evidence)
        let resolved = today ? resolveToday(record, mode: .display) : resolve(record, mode: .display)
        let now = nowMs
        let orderedKinds = HealthSample.Kind.allOrdered.filter { kinds.contains($0) }
        var input = SnapshotInput(
            date: date, deviceSteps: record.deviceSteps, gatedSteps: record.gatedSteps,
            coverageStartAt: today ? coverageStart(date) : 0,
            countFrom: state.countFromAt > 0 ? state.countFromAt : nil,
            sources: sources, sourcesStatus: sourcesStatus, resolved: resolved.json(),
            otherDevicesSteps: state.otherDevices[date] ?? 0,
            capabilities: Snapshot.capabilities(hasStepCounter: motion.pedometerAvailable, model: DeviceInfo.model, osVersion: DeviceInfo.osVersion),
            clock: Snapshot.clock(nowMs: now, bootMs: DeviceInfo.bootTimeMs, zone: c.timeZone),
            suspectSteps: suspect(record), integrity: integrityReport(date, record: record),
            include: include, nonce: nonce)
        if include.contains("minutes") {
            input.minutesStatus = config.fraudDetectionEnabled ? "enabled" : "disabled"
            input.minutes = config.fraudDetectionEnabled ? record.minutes : []
        }
        if include.contains("healthConnectRecords") {
            input.healthRecords = snapshotRecords(date, orderedKinds)
        }
        let snapshot = Snapshot.build(input)
        guard sign else { return done(.success(snapshot)) }
        let (body, bytes) = Snapshot.signedBody(snapshot, signedAt: now)
        let signature = try signPayload(bytes)
        done(.success(signedOnly ? signature : body.setting("signature", signature)))
    }

    /// The day's raw samples, and whether they could be read. Never throws:
    /// a snapshot is worth signing without them, and `status` says why.
    func snapshotRecords(_ date: String, _ kinds: [HealthSample.Kind]) -> JSON {
        func result(_ status: String, _ records: JSON = .array([]), _ truncated: Bool = false) -> JSON {
            .object([("status", .string(status)), ("recordTypes", .strings(kinds.map(\.rawValue))),
                     ("records", records), ("truncated", .bool(truncated))])
        }
        guard config.healthConnectEnabled else { return result("disabled") }
        guard health.available, HealthSource.missingDeclaration == nil else { return result("unavailable") }
        let g = grants()
        guard kinds.allSatisfy({ $0 == .steps ? g.steps : g.distance }) else { return result("not_granted") }
        let c = clock
        let start = c.startOfDayMs(date)
        let end = min(c.endOfDayExclusiveMs(date), nowMs)
        guard end > start else { return result("read") }
        var samples: [HealthSample] = []
        for kind in kinds {
            switch health.samples(kind, from: start, to: end, limit: HealthSources.maxRecordsPerType + 1) {
            case let .success(list): samples += list
            case let .failure(error):
                if case .timedOut = error { return result("timeout") }
                return result("failed")
            }
        }
        let (records, truncated) = HealthSources.recordList(samples, types: kinds)
        return result("read", records, truncated)
    }

    /// Signs with the install's key, making an unattested one on first use -
    /// which, as on Android 2.3+, does not count as attested.
    func signPayload(_ bytes: Data) throws -> JSON {
        var key = Attestation.currentKey()
        if key == nil {
            let (made, level) = try Attestation.createKey()
            key = made
            state.keyCreatedAt = nowMs
            state.keyCreatedBy = "sign"
            state.keyAttested = false
            state.keySecurityLevel = level
            state.appAttestKeyId = nil
            state.appAttestObject = nil
            state.appAttestClientData = nil
            saveState()
        }
        guard let key else { throw BridgeError(code: "E_UNKNOWN", message: "No signing key") }
        let value = try Attestation.sign(bytes, with: key)
        return Snapshot.signatureBlock(keyId: key.keyId, value: value, attested: state.keyAttested, payload: bytes)
    }

    // ---- attestation ----------------------------------------------------------------------------------

    func describeKey() -> JSON? {
        guard let key = Attestation.currentKey() else { return nil }
        var appAttest: JSON = .null
        if let id = state.appAttestKeyId, let object = state.appAttestObject, let clientData = state.appAttestClientData {
            appAttest = .object([("keyId", .string(id)), ("attestationObject", .string(object)), ("clientData", .string(clientData)),
                                 ("environment", .string(state.appAttestEnvironment ?? DeviceInfo.appAttestEnvironment))])
        }
        return .object([
            ("keyId", .string(key.keyId)),
            ("algorithm", .string("SHA256withECDSA")),
            ("publicKey", .string(key.spki.base64EncodedString())),
            ("certificateChain", .array([])),
            ("attested", .bool(state.keyAttested)),
            ("securityLevel", .string(state.keySecurityLevel ?? "unknown")),
            ("createdAt", .int(state.keyCreatedAt)),
            ("createdBy", .string(state.keyCreatedBy ?? "sign")),
            ("appAttest", appAttest),
        ])
    }

    /// A new key bound to the server's challenge: a Secure Enclave key whose
    /// id App Attest vouches for, through `clientData = challenge|keyId`.
    func attestDevice(_ challenge: String, _ done: @escaping Done) throws {
        let bytes = Data(challenge.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { throw BridgeError.invalid("challenge must be 1-128 bytes of UTF-8") }
        let (key, level) = try Attestation.createKey()
        func finish(attested: Bool, appAttest: (String, Data, String)?) {
            state.keyCreatedAt = nowMs
            state.keyCreatedBy = "attestDevice"
            state.keyAttested = attested
            state.keySecurityLevel = attested ? "secure_enclave" : level
            state.appAttestKeyId = appAttest?.0
            state.appAttestObject = appAttest?.1.base64EncodedString()
            state.appAttestClientData = appAttest?.2
            state.appAttestEnvironment = appAttest == nil ? nil : DeviceInfo.appAttestEnvironment
            saveState()
            log(IntegrityEvent.deviceAttested, .object([("keyId", .string(key.keyId)), ("attested", .bool(attested))]))
            done(.success(describeKey() ?? .null))
        }
        guard level == "secure_enclave", Attestation.appAttestSupported else {
            // A simulator, or a device App Attest does not support: Android's
            // unattested fallback - a key, `attested: false`, no App Attest.
            return finish(attested: false, appAttest: nil)
        }
        let clientData = challenge + "|" + key.keyId
        Attestation.generateAppAttestKey { [weak self] generated in
            self?.queue.async {
                guard let self else { return }
                switch generated {
                case let .failure(error):
                    self.attestFailed(error, while: "making a key", fallback: { finish(attested: false, appAttest: nil) }, done)
                case let .success(appKey):
                    Attestation.attest(appKey, clientData: Data(clientData.utf8)) { attested in
                        self.queue.async {
                            switch attested {
                            case let .success(object): finish(attested: true, appAttest: (appKey, object, clientData))
                            case let .failure(error):
                                self.attestFailed(error, while: "attesting the key", fallback: { finish(attested: false, appAttest: nil) }, done)
                            }
                        }
                    }
                }
            }
        }
    }

    /// An unsupported feature falls back to an unattested key; anything else
    /// rejects - a server outage especially, which must not downgrade an
    /// install that could be attested a moment later.
    private func attestFailed(_ error: Error, while doing: String, fallback: () -> Void, _ done: Done) {
        if Attestation.describe(error).code == .featureUnsupported { return fallback() }
        Attestation.deleteKeys()
        state.keyCreatedBy = nil
        state.appAttestKeyId = nil
        saveState()
        done(.failure(Attestation.failure(error, while: doing)))
    }

    /// An App Attest assertion over SHA-256 of [requestHash] - iOS's answer
    /// where Android returns a Play Integrity token.
    func requestIntegrityToken(_ options: JSON, _ done: @escaping Done) throws {
        let hash = options["requestHash"]?.stringValue ?? ""
        guard !hash.isEmpty, hash.count <= 500 else { throw BridgeError.invalid("requestHash must be a string of 1-500 characters") }
        guard let keyId = state.appAttestKeyId, Attestation.appAttestSupported else {
            throw BridgeError(code: "E_INTEGRITY_UNAVAILABLE",
                              message: "No App Attest key on this install: call attestDevice() on a device that supports App Attest first")
        }
        Attestation.assertion(keyId, clientData: Data(hash.utf8)) { [weak self] result in
            self?.queue.async {
                switch result {
                case let .success(assertion):
                    done(.success(.object([("token", .string(assertion.base64EncodedString())), ("requestHash", .string(hash)),
                                           ("provider", .string("app_attest"))])))
                case let .failure(error):
                    done(.failure(Attestation.failure(error, while: "asserting")))
                }
            }
        }
    }
}
