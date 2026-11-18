import Foundation

/// What the ObjC++ TurboModule calls. Every call hops onto the engine's
/// queue; nothing here blocks the caller's thread.
@objc(StepTrackerProBridge)
public final class StepTrackerProBridge: NSObject {
    @objc public static let shared = StepTrackerProBridge()

    private var engine: Engine { Engine.shared }

    /// From the module's `+load`, at the end of launch - also a background
    /// launch for Apple Health's delivery, when no JavaScript may run.
    @objc public static func applicationDidFinishLaunching() {
        Engine.shared.queue.async { Engine.shared.bootIfNeeded() }
    }

    @objc public func attachEmitter(_ emitter: @escaping (String, [String: Any]) -> Void) {
        engine.queue.async {
            self.engine.bootIfNeeded()
            self.engine.emitter = { name, payload in
                if let dict = payload.foundation as? [String: Any] { emitter(name, dict) }
            }
        }
    }

    @objc public func detachEmitter() {
        engine.queue.async { self.engine.emitter = nil }
    }

    @objc public func call(_ method: String, args: [Any], resolve: @escaping (Any?) -> Void,
                           reject: @escaping (String, String, [String: Any]?) -> Void) {
        let arguments = args.map { JSON(foundation: $0) }
        engine.queue.async {
            self.engine.bootIfNeeded()
            self.engine.handle(method, arguments) { result in
                switch result {
                case let .success(value):
                    resolve(value.isNull ? nil : value.foundation)
                case let .failure(error):
                    reject(error.code, error.message, error.details)
                }
            }
        }
    }
}
