import Darwin
import Foundation
import MachO
import UIKit

/// Facts about the phone and the app: model, OS, boot time, the app's own
/// entitlements and usage strings, and the cheap integrity hints.
enum DeviceInfo {
    /// `hw.machine`, e.g. `iPhone15,2`; the simulated model on a simulator.
    static let model: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Epoch ms of the boot, from `kern.boottime`: constant for one boot,
    /// unless the wall clock is edited - which is the point. Sleep does not
    /// move it; wall clock minus `systemUptime` would, since the uptime
    /// stops while the phone sleeps.
    static var bootTimeMs: Int64 {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Int64(boot.tv_sec) * 1000 + Int64(boot.tv_usec) / 1000
    }

    static func nowMs() -> Int64 { DayClock.ms(Date()) }

    // ---- the app's declarations -----------------------------------------------------

    static func hasInfoKey(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The app's own entitlements, read from its code signature; nil when
    /// they cannot be read, which is not the same as none.
    static let entitlements: [String: Any]? = Entitlements.read()

    /// True or false when known; nil when the signature could not be read.
    static func hasEntitlement(_ key: String) -> Bool? {
        guard let entitlements else { return nil }
        if let flag = entitlements[key] as? Bool { return flag }
        return entitlements[key] != nil
    }

    static var appAttestEnvironment: String {
        if let value = entitlements?["com.apple.developer.devicecheck.appattest-environment"] as? String {
            return value == "production" ? "production" : "development"
        }
        // Without the entitlement App Attest uses development for builds
        // installed from Xcode, production for the App Store and TestFlight
        // - which carry no embedded provisioning profile.
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil && !isSimulator
            ? "production" : "development"
    }

    // ---- integrity hints ---------------------------------------------------------------

    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// A debugger is attached, or the build may be debugged (`get-task-allow`).
    static var appDebuggable: Bool {
        if debuggerAttached { return true }
        if let allow = entitlements?["get-task-allow"] as? Bool { return allow }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Cheap jailbreak indicators: well-known files, and tweak-injection
    /// libraries loaded into this process. No private API; any of it can be
    /// hidden on a jailbroken phone - App Attest is the check to trust.
    static var jailbreakIndicators: Bool {
        if isSimulator { return false }
        let paths = [
            "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd", "/etc/apt",
            "/private/var/lib/apt", "/var/jb", "/var/binpack", "/usr/bin/ssh", "/bin/bash",
        ]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        let markers = ["mobilesubstrate", "substitute", "libhooker", "frida", "cycript", "ellekit"]
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let lower = String(cString: name).lowercased()
            if markers.contains(where: { lower.contains($0) }) { return true }
        }
        let probe = "/private/step-tracker-pro-\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: false, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        return false
    }

    static func signals(pedometerAvailable: Bool) -> JSON {
        .object([
            ("emulator", .bool(isSimulator)),
            ("testKeysBuild", .bool(false)),
            ("suBinary", .bool(jailbreakIndicators)),
            ("adbEnabled", .bool(false)),
            ("developerOptions", .bool(false)),
            ("appDebuggable", .bool(appDebuggable)),
            ("stepCounter", pedometerAvailable
                ? .object([("name", .string("CMPedometer")), ("vendor", .string("Apple")), ("version", .int(0)), ("wakeUp", .bool(true))])
                : .null),
        ])
    }

    // ---- UIKit, on the main thread -------------------------------------------------------

    static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    static func open(_ url: URL?, done: @escaping (Bool) -> Void) {
        guard let url else { return done(false) }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { done($0) }
        }
    }

    static var backgroundRefresh: String {
        onMain {
            switch UIApplication.shared.backgroundRefreshStatus {
            case .available: return "available"
            case .denied: return "denied"
            case .restricted: return "restricted"
            @unknown default: return "restricted"
            }
        }
    }

    static var isForeground: Bool { onMain { UIApplication.shared.applicationState != .background } }

    static var protectedDataAvailable: Bool { onMain { UIApplication.shared.isProtectedDataAvailable } }
}

/// Reads the entitlements a binary was signed with: the code signature's
/// entitlements blob on a device, the `__TEXT,__entitlements` section a
/// simulator build carries. Public file APIs only.
enum Entitlements {
    static func read() -> [String: Any]? {
        guard let path = Bundle.main.executablePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    private static func u32(_ d: Data, _ o: Int, big: Bool) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        let v = d.subdata(in: d.startIndex + o..<d.startIndex + o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= d.count else { return nil }
        return UInt64(littleEndian: d.subdata(in: d.startIndex + o..<d.startIndex + o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
    }

    static func parse(_ file: Data) -> [String: Any]? {
        guard let magic = u32(file, 0, big: false) else { return nil }
        // A fat binary: take the arm64 (or first) slice.
        if magic == 0xBEBAFECA {
            guard let count = u32(file, 4, big: true) else { return nil }
            for i in 0..<Int(min(count, 8)) {
                let entry = 8 + i * 20
                guard let offset = u32(file, entry + 8, big: true), let size = u32(file, entry + 12, big: true),
                      Int(offset) + Int(size) <= file.count else { continue }
                let slice = file.subdata(in: Int(offset)..<Int(offset) + Int(size))
                if let found = parse(slice) { return found }
            }
            return nil
        }
        guard magic == 0xFEEDFACF, let ncmds = u32(file, 16, big: false) else { return nil }
        var cursor = 32
        for _ in 0..<min(Int(ncmds), 512) {
            guard let cmd = u32(file, cursor, big: false), let size = u32(file, cursor + 4, big: false), size > 0 else { return nil }
            if cmd == 0x1D, let off = u32(file, cursor + 8, big: false), let len = u32(file, cursor + 12, big: false) {
                if let found = fromSignature(file, Int(off), Int(len)) { return found }
            }
            if cmd == 0x19, let found = fromSegment(file, cursor) { return found }
            cursor += Int(size)
        }
        return nil
    }

    private static func fromSignature(_ file: Data, _ off: Int, _ len: Int) -> [String: Any]? {
        guard u32(file, off, big: true) == 0xFADE0CC0, let count = u32(file, off + 8, big: true) else { return nil }
        for i in 0..<Int(min(count, 64)) {
            guard let blobOffset = u32(file, off + 12 + i * 8 + 4, big: true) else { continue }
            let blob = off + Int(blobOffset)
            if u32(file, blob, big: true) == 0xFADE7171, let length = u32(file, blob + 4, big: true), length > 8,
               blob + Int(length) <= file.count {
                return plist(file.subdata(in: blob + 8..<blob + Int(length)))
            }
        }
        return nil
    }

    /// `__TEXT,__entitlements`, where a simulator build keeps them.
    private static func fromSegment(_ file: Data, _ cursor: Int) -> [String: Any]? {
        guard let nsects = u32(file, cursor + 64, big: false) else { return nil }
        for s in 0..<Int(min(nsects, 64)) {
            let section = cursor + 72 + s * 80
            guard section + 80 <= file.count else { return nil }
            let name = String(decoding: file.subdata(in: section..<section + 16).prefix { $0 != 0 }, as: UTF8.self)
            guard name == "__entitlements", let size = u64(file, section + 40), let offset = u32(file, section + 48, big: false),
                  Int(offset) + Int(size) <= file.count else { continue }
            return plist(file.subdata(in: Int(offset)..<Int(offset) + Int(size)))
        }
        return nil
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
