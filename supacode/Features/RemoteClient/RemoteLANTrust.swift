import Foundation

/// The client's side of the LAN trust check. The relay hands over the Mac's certificate
/// fingerprint `fp`; the client believes it only if `fpMac` (an HMAC made with the client key,
/// which the relay never learns) matches, and then pins the TLS leaf certificate to `fp`.
nonisolated enum RemoteLANTrust {
  /// `fpMac` is the HMAC the host makes; compared in constant time, hex case of `fpMac` ignored.
  /// `fp` is used exactly as sent: the host signs the string, so another case is another message.
  static func fpMacValid(clientKey: String, fp fingerprint: String, fpMac: String) -> Bool {
    let expected = RemoteLANIdentity.fingerprintMAC(fingerprint: fingerprint, clientKey: clientKey)
    return constantTimeEqual(Array(expected.utf8), Array(fpMac.lowercased().utf8))
  }

  /// The leaf certificate's SHA-256 equals the pinned `fp` (constant time, case ignored).
  static func pinMatches(der: Data, fp pinned: String) -> Bool {
    constantTimeEqual(Array(RemoteLANIdentity.fingerprint(der: der).utf8), Array(pinned.lowercased().utf8))
  }

  /// Compares every byte instead of stopping at the first difference. Only the lengths may
  /// leak; both inputs are hex strings of a fixed length for a valid value.
  static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
      difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
  }
}
