import Foundation
import HealthKit
import UIKit

/// The engine's ties to the system: launch, foreground and background, the
/// clock, the charger, midnight, live pedometer updates and Apple Health's
/// background delivery.
enum Lifecycle {
    /// From the engine's boot, on its queue.
    static func install(_ engine: Engine) {
        let center = NotificationCenter.default
        let q = engine.queue
        func on(_ name: Notification.Name, _ work: @escaping (Engine) -> Void) {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in q.async { work(engine) } }
        }
        on(UIApplication.willEnterForegroundNotification) { $0.onForeground() }
        on(UIApplication.didBecomeActiveNotification) { $0.startLiveIfNeeded() }
        on(UIApplication.didEnterBackgroundNotification) { $0.motion.stopLive() }
        on(UIApplication.significantTimeChangeNotification) { $0.checkDay() }
        on(.NSSystemClockDidChange) { $0.onClockChanged() }
        on(.NSSystemTimeZoneDidChange) { $0.onTimeZoneChanged() }
        on(UIApplication.protectedDataDidBecomeAvailableNotification) { engine in
            // A locked phone's reads failed; now they can run.
            engine.sourceCache.removeAll()
            engine.recompute(reason: "unlocked")
        }
        on(UIDevice.batteryStateDidChangeNotification) { $0.onBatteryChanged(announce: true) }
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
            q.async { engine.onBatteryChanged(announce: false) }
        }
        engine.scheduleMidnight()
        engine.checkClockAtBoot()
        engine.observeHealthIfGranted()
        engine.startLiveIfNeeded()
    }
}

extension Engine {
    // ---- the clock -----------------------------------------------------------------------------

    func checkClockAtBoot() {
        let zone = TimeZone.current.identifier
        if let previous = state.lastTimeZone, previous != zone {
            log(IntegrityEvent.timezoneChanged, .object([("from", .string(previous)), ("to", .string(zone))]))
            state.lastTimeZone = zone
        }
        let offset = DeviceInfo.bootOffsetMs
        // Across a reboot the offset moves by however long the phone was
        // off; only a jump within one boot is a clock edit.
        let boot = DeviceInfo.bootTimeMs
        if abs(offset - boot) < 60_000 { state.lastBootOffsetMs = offset }
        saveState()
        checkDay()
    }

    func onClockChanged() {
        let offset = DeviceInfo.bootOffsetMs
        let jump = offset - state.lastBootOffsetMs
        if abs(jump) > 5_000 { log(IntegrityEvent.clockChanged, .object([("jumpMs", .int(jump))])) }
        state.lastBootOffsetMs = offset
        saveState()
        checkDay()
        scheduleMidnight()
    }

    func onTimeZoneChanged() {
        let zone = TimeZone.current.identifier
        if state.lastTimeZone != zone {
            log(IntegrityEvent.timezoneChanged, .object([("from", .optional(state.lastTimeZone)), ("to", .string(zone))]))
            state.lastTimeZone = zone
            saveState()
        }
        hourCache.removeAll()
        lastFull = nil
        checkDay()
        scheduleMidnight()
    }

    func scheduleMidnight() {
        midnightTimer?.cancel()
        let c = clock
        let next = c.endOfDayExclusiveMs(c.today())
        let delay = max(1_000, next - nowMs + 1_000)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delay)))
        timer.setEventHandler { [weak self] in
            self?.checkDay()
            self?.scheduleMidnight()
        }
        timer.resume()
        midnightTimer = timer
    }

    /// `dayChanged` when the local date moved - midnight, a zone, a clock edit.
    func checkDay() {
        let today = clock.today()
        guard let previous = state.lastDate, previous != today else {
            state.lastDate = today
            return
        }
        state.lastDate = today
        state.continuity = nil
        sourceCache.removeAll()
        lastFull = nil
        if today > previous { hourCache = hourCache.filter { _ in false } }
        // The day that closed: its count as it stands, kept now - the first
        // computation after it closed (or the next one) makes it final.
        let closed = deviceDay(previous)
        saveState()
        emit("dayChanged", .object([
            ("previousDate", .string(previous)), ("currentDate", .string(today)), ("previousDaySteps", .int(closed.deviceSteps)),
        ]))
        startLiveIfNeeded()
    }

    // ---- foreground, charger -----------------------------------------------------------------

    func onForeground() {
        checkDay()
        grantCache = nil
        let status = healthStatus()
        let fingerprint = status.serialized()
        if let previous = state.healthFingerprint, previous != fingerprint {
            emit("healthConnectStatusChanged", status)
        }
        state.healthFingerprint = fingerprint
        saveState()
        observeHealthIfGranted()
        startLiveIfNeeded()
        recompute(reason: "foreground")
    }

    func onBatteryChanged(announce: Bool) {
        let level = DeviceInfo.onMain { UIDevice.current.batteryState }
        let plugged = level == .charging || level == .full
        guard plugged != charging else { return }
        charging = plugged
        let now = nowMs
        if plugged {
            state.chargingSpans.append([now, 0])
        } else if let last = state.chargingSpans.indices.last, state.chargingSpans[last].count == 2, state.chargingSpans[last][1] == 0 {
            state.chargingSpans[last][1] = now
        }
        let cutoff = clock.startOfDayMs(clock.minusDays(clock.today(), Engine.pedometerDays + 1))
        state.chargingSpans.removeAll { $0.count == 2 && $0[1] != 0 && $0[1] < cutoff }
        saveState()
        if announce { log(plugged ? IntegrityEvent.chargingStarted : IntegrityEvent.chargingStopped) }
    }

    // ---- live updates ----------------------------------------------------------------------------

    /// While tracking runs and the app is in front, the pedometer's live
    /// updates move the number on screen. The coprocessor counts anyway.
    func startLiveIfNeeded() {
        guard state.trackingState == .running, motion.pedometerAvailable, motion.authorized, DeviceInfo.isForeground else {
            motion.stopLive()
            return
        }
        let today = clock.today()
        let from = countingWindows(today, until: nowMs).last?.0 ?? nowMs
        if motion.liveFrom == from && liveDate == today { return }
        liveDate = today
        motion.startLive(from: from, onUpdate: { [weak self] _, at in
            self?.queue.async {
                guard let self else { return }
                self.state.lastPedometerAt = max(self.state.lastPedometerAt, at)
                if self.clock.today() != self.liveDate { self.checkDay() }
                self.emitSteps()
                if let last = self.lastFull, self.nowMs - last.at >= 60_000 { _ = self.deviceDay(self.clock.today()) }
            }
        }, onError: { [weak self] error in
            self?.queue.async {
                self?.emit("error", .object([("code", .string("E_SENSOR_UNAVAILABLE")),
                                             ("message", .string("Pedometer updates failed: \(error.localizedDescription)"))]))
            }
        })
    }

    // ---- recomputation and background delivery ---------------------------------------------

    /// Recomputes the open days, keeps them, and tells JS what moved: today's
    /// count, a past day Apple Health filled in late, a new winner.
    func recompute(reason: String) {
        let c = clock
        let today = c.today()
        state.lastPedometerAt = max(state.lastPedometerAt, nowMs)
        // Today first, so the number on screen never waits for history.
        let record = deviceDay(today)
        _ = resolveToday(record, mode: .display)
        emitSteps(force: true)
        // Then the open days: any recent day not yet final.
        for offset in 1..<Engine.pedometerDays {
            let date = c.minusDays(today, offset)
            if isGone(date) { continue }
            if let stored = store.day(date), stored.final { continue }
            if countingWindows(date, until: nowMs).isEmpty && store.day(date) == nil { continue }
            _ = deviceDay(date)
        }
        checkBackfill()
        // Retention, as Android prunes on its schedule.
        _ = pruneHistory(Double(config.historyRetentionDays))
        saveState()
    }

    /// `historyBackfilled` when a past day's resolved number grew - a watch
    /// syncing late into Apple Health.
    func checkBackfill() {
        guard shouldConsultHealth() else { return }
        let c = clock
        let today = c.today()
        for offset in 1..<Engine.pedometerDays {
            let date = c.minusDays(today, offset)
            if isGone(date) { continue }
            sourceCache.removeValue(forKey: date)
            let resolved = resolve(deviceDay(date), mode: .display).totals.steps
            let previous = state.lastResolvedSteps[date]
            state.lastResolvedSteps[date] = resolved
            if let previous, resolved > previous {
                emit("historyBackfilled", .object([
                    ("date", .string(date)), ("addedSteps", .int(resolved - previous)), ("totalSteps", .int(resolved)), ("reason", .string("late")),
                ]))
            }
        }
        let keep = c.minusDays(today, Engine.pedometerDays)
        state.lastResolvedSteps = state.lastResolvedSteps.filter { $0.key >= keep }
    }

    /// Observer queries and hourly background delivery for the types this
    /// app reads - registered at every launch, before it finishes, which is
    /// what Apple Health requires to wake the app.
    func observeHealthIfGranted() {
        guard config.healthConnectEnabled, config.healthConnectReadEnabled, health.available,
              HealthSource.missingDeclaration == nil, !health.observing,
              health.requestStatus(readKinds) == .unnecessary else { return }
        if DeviceInfo.hasEntitlement("com.apple.developer.healthkit.background-delivery") == false {
            emit("error", .object([("code", .string("E_HEALTH_CONNECT_NOT_DECLARED")),
                                   ("message", .string("Background delivery needs the com.apple.developer.healthkit.background-delivery entitlement; Apple Health will only be read while the app runs."))]))
        }
        health.observe(readKinds, onChange: { [weak self] completion in
            guard let self else { return completion() }
            // Called promptly whatever happens: iOS stops waking an app
            // that does not answer.
            let once = Once(completion)
            self.queue.asyncAfter(deadline: .now() + 20) { once.run() }
            self.queue.async {
                self.sourceCache.removeAll()
                self.recompute(reason: "health")
                once.run()
            }
        }, onError: { [weak self] message in
            self?.queue.async { self?.emit("error", .object([("code", .string("E_HEALTH_CONNECT_UNAVAILABLE")), ("message", .string(message))])) }
        })
    }
}

/// Runs a completion handler exactly once.
final class Once {
    private var work: (() -> Void)?
    private let lock = NSLock()

    init(_ work: @escaping () -> Void) { self.work = work }

    func run() {
        lock.lock()
        let w = work
        work = nil
        lock.unlock()
        w?()
    }
}
