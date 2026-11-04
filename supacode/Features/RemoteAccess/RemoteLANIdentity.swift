import CryptoKit
import Foundation
import Security
import SupacodeSettingsShared

nonisolated private let identityLogger = SupaLogger("RemoteAccess")

/// The LAN shortcut's TLS identity: a self-signed certificate Supacode creates on
/// first use with the system `openssl` and keeps as one PKCS#12 file (mode 0600)
/// in its config directory. It loads into memory only, never into a keychain.
/// The phone pins the certificate's SHA-256 (`fingerprint`), which it receives
/// through the relay together with an HMAC made with the client key.
nonisolated enum RemoteLANIdentity {
  struct Loaded: @unchecked Sendable {
    let identity: SecIdentity
    /// Lowercase hex SHA-256 of the certificate's DER bytes.
    let fingerprint: String
  }

  /// Protects the file format only; the file itself is 0600 in the user's config.
  static let passphrase = "supacode-lan"
  static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")

  static var defaultURL: URL {
    SupacodePaths.configBaseDirectory.appending(path: "remote-lan/identity.p12")
  }

  /// The identity at `url`, created first when the file does not exist. Blocking:
  /// call it off the main actor.
  static func loadOrCreate(at url: URL = defaultURL) -> Loaded? {
    // A host restart can start a second load while the first still creates the
    // file; one at a time, so the second loads what the first created.
    creationLock.lock()
    defer { creationLock.unlock() }
    if !FileManager.default.fileExists(atPath: url.path), !create(at: url) { return nil }
    return load(at: url)
  }

  private static let creationLock = NSLock()

  static func load(at url: URL) -> Loaded? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let options: [String: Any] = [
      kSecImportExportPassphrase as String: passphrase,
      kSecImportToMemoryOnly as String: true,
    ]
    var items: CFArray?
    let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
    guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
      let value = first[kSecImportItemIdentity as String]
    else {
      identityLogger.warning("LAN identity import failed: \(status)")
      return nil
    }
    // The dictionary value is a SecIdentity by contract.
    let identity = value as! SecIdentity  // swiftlint:disable:this force_cast
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
    let der = SecCertificateCopyData(certificate) as Data
    return Loaded(identity: identity, fingerprint: fingerprint(der: der))
  }

  static func fingerprint(der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
  }

  /// HMAC-SHA256 with the client key over `supacode-lan-fp-v1:<fp>`, so the phone
  /// can tell that the fingerprint really comes from its Mac and not from the relay.
  static func fingerprintMAC(fingerprint: String, clientKey: String) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("supacode-lan-fp-v1:\(fingerprint)".utf8),
      using: SymmetricKey(data: Data(clientKey.utf8))
    )
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  /// Writes a new identity file: key and certificate go to a private temporary
  /// directory, are packed into PKCS#12 at `url`, and the temporaries are deleted.
  static func create(at url: URL) -> Bool {
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appending(path: "supacode-lan-\(UUID().uuidString)")
    do {
      try fileManager.createDirectory(
        at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      identityLogger.warning("LAN identity: cannot create directories: \(error)")
      return false
    }
    defer { try? fileManager.removeItem(at: scratch) }
    let keyPath = scratch.appending(path: "k").path
    let certificatePath = scratch.appending(path: "c").path
    // Export next to the key and move it into place only when complete, so an
    // interrupted export never leaves a partial identity file at `url`.
    let exported = scratch.appending(path: "identity.p12")
    let made =
      run([
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
        "-subj", "/CN=Supacode LAN", "-keyout", keyPath, "-out", certificatePath,
      ])
      && run([
        "pkcs12", "-export", "-inkey", keyPath, "-in", certificatePath,
        "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        "-passout", "pass:\(passphrase)", "-out", exported.path,
      ])
    guard made else { return false }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exported.path)
    do {
      try fileManager.moveItem(at: exported, to: url)
    } catch {
      identityLogger.warning("LAN identity: cannot move the new identity into place: \(error)")
      return false
    }
    identityLogger.info("LAN identity created")
    return true
  }

  private static func run(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = openssl
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      identityLogger.warning("LAN identity: openssl failed to start: \(error)")
      return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }
}
