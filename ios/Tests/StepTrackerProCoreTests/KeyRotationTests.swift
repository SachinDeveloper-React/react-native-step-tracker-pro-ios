import XCTest
@testable import StepTrackerProCore

/// `attestDevice()`'s new key against the install's working one: Apple's
/// service down, a call overtaken by a later one, an app killed while waiting.
final class KeyRotationTests: XCTestCase {
    /// The Keychain's two slots, and what was done to them, in order.
    final class Slots: KeySlots {
        var keys: [KeySlot: String] = [:]
        var log: [String] = []

        func keyId(in slot: KeySlot) -> String? { keys[slot] }

        func delete(_ slot: KeySlot) {
            keys[slot] = nil
            log.append("delete \(slot.rawValue)")
        }

        /// What `Attestation.createKey(in:)` does: whatever was in the slot is replaced.
        func make(_ id: String, in slot: KeySlot) -> KeyRotation {
            keys[slot] = id
            return KeyRotation(slot: slot, keyId: id)
        }
    }

    func testAppleDownLeavesTheInstallsKeyAsItWas() {
        let slots = Slots()
        slots.keys[.a] = "attested"
        let rotation = slots.make("new", in: KeySlot.a.other)
        // App Attest answered serverUnavailable.
        rotation.discard(slots)
        XCTAssertEqual(slots.keys, [.a: "attested"])
        XCTAssertEqual(slots.log, ["delete b"])
    }

    func testAnAttestedKeyIsRecordedBeforeTheOldOneGoes() {
        let slots = Slots()
        slots.keys[.a] = "old"
        let rotation = slots.make("new", in: .b)
        XCTAssertTrue(rotation.promote(slots) { slots.log.append("record") })
        XCTAssertEqual(slots.log, ["record", "delete a"])
        XCTAssertEqual(slots.keys, [.b: "new"])
        XCTAssertEqual(KeySlot.b.other, .a, "the next attestation goes back to a")
    }

    func testAnEarlierCallNeitherReplacesNorDeletesALaterCallsKey() {
        let slots = Slots()
        slots.keys[.a] = "old"
        let first = slots.make("first", in: .b)
        // A second attestDevice() before App Attest answered the first.
        let second = slots.make("second", in: .b)
        XCTAssertFalse(first.promote(slots) { XCTFail("the first call's key must not be recorded") })
        first.discard(slots)
        XCTAssertEqual(slots.keys, [.a: "old", .b: "second"])
        XCTAssertTrue(second.promote(slots) {})
        XCTAssertEqual(slots.keys, [.b: "second"])
    }

    func testAKeyLeftByAnAppKilledWhileWaitingIsReplacedByTheNextCall() {
        let slots = Slots()
        slots.keys[.a] = "old"
        // Killed before App Attest answered: the record still names a.
        _ = slots.make("orphan", in: .b)
        let next = slots.make("next", in: .b)
        XCTAssertTrue(next.promote(slots) {})
        XCTAssertEqual(slots.keys, [.b: "next"])
    }

    func testAStoredSlotReadsBackAndAnUnknownOneDoesNot() throws {
        XCTAssertEqual(try JSONDecoder().decode([KeySlot].self, from: Data(#"["a","b"]"#.utf8)), [.a, .b])
        XCTAssertThrowsError(try JSONDecoder().decode([KeySlot].self, from: Data(#"["c"]"#.utf8)))
    }
}
