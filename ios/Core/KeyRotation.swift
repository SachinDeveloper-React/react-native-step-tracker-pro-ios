import Foundation

/// Where a signing key is kept. The install's key is in one slot; a key
/// `attestDevice()` is still waiting on Apple for is in the other. Every
/// key made before there were two is in `a`.
enum KeySlot: String, Codable {
    case a, b

    var other: KeySlot { self == .a ? .b : .a }
}

/// The Keychain as a key rotation sees it: two slots, a key or none in each.
protocol KeySlots {
    /// The id of the key in [slot]; nil when it is empty.
    func keyId(in slot: KeySlot) -> String?
    func delete(_ slot: KeySlot)
}

/// `attestDevice()`'s new key, from the moment it is made in the slot the
/// install's key is not in until it replaces that key or is thrown away.
///
/// Until App Attest has vouched for the new key, the install's key goes on
/// signing - and its App Attest key answering `requestIntegrityToken()` -
/// so a call that fails, Apple's service being down above all, leaves the
/// install exactly as it was. A later call makes its key in the same slot,
/// replacing this one's: this rotation then neither replaces the
/// install's key nor deletes the later call's.
struct KeyRotation {
    /// Where the new key is.
    let slot: KeySlot
    let keyId: String

    /// The slot still holds this rotation's key.
    func isCurrent(_ slots: some KeySlots) -> Bool { slots.keyId(in: slot) == keyId }

    /// The new key becomes the install's: [record] writes that down, then
    /// the old key goes - in that order, so an app killed in between still
    /// has the key it recorded. False, with nothing done, when a later call
    /// replaced this one's key.
    func promote(_ slots: some KeySlots, record: () -> Void) -> Bool {
        guard isCurrent(slots) else { return false }
        record()
        slots.delete(slot.other)
        return true
    }

    /// The attestation failed: the new key goes, if it is still this
    /// rotation's. The install's key is not touched.
    func discard(_ slots: some KeySlots) {
        if isCurrent(slots) { slots.delete(slot) }
    }
}
