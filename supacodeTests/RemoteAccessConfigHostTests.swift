import Foundation
import Testing

@testable import supacode

/// The host identity and name parts of `RemoteAccessConfig`
/// (docs/plans/2026-11-10-remote-multi-host-design.md, ИД1, ИД2, ИД4, СУ1).
struct RemoteAccessConfigHostTests {
  private static let base = #"{"enabled":true,"relayURL":"wss://relay.example.com/host","hostKey":"k""#

  private static func decode(_ json: String) throws -> RemoteAccessConfig {
    try JSONDecoder().decode(RemoteAccessConfig.self, from: Data(json.utf8))
  }

  // MARK: - hostName decoding

  @Test func hostNameDecodesWhenAString() throws {
    let config = try Self.decode(Self.base + #","hostName":"Office Mac","lan":false}"#)
    #expect(config.hostName == "Office Mac")
    #expect(config.lan == false)
    #expect(config.relayURL == URL(string: "wss://relay.example.com/host"))
  }

  @Test func hostNameIsNilWhenMissing() throws {
    let config = try Self.decode(Self.base + "}")
    #expect(config.hostName == nil)
    #expect(config.lan)
  }

  @Test func aHostNameOfTheWrongTypeIsIgnored() throws {
    #expect(try Self.decode(Self.base + #","hostName":42}"#).hostName == nil)
    #expect(try Self.decode(Self.base + #","hostName":null}"#).hostName == nil)
    #expect(try Self.decode(Self.base + #","hostName":["a"]}"#).hostName == nil)
  }

  @Test func loadReadsHostNameFromTheFile() throws {
    let url = URL.temporaryDirectory.appending(path: "remote-access-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data((Self.base + #","hostName":"Studio"}"#).utf8).write(to: url)
    #expect(RemoteAccessConfig.load(from: url)?.hostName == "Studio")
  }

  // MARK: - hostID

  @Test func hostIDIsAFixedHashOfTheHardwareUUID() {
    // printf '%s' 'supacode-remote-host-v1:00000000-1111-2222-3333-444444444444' | shasum -a 256
    let id = RemoteAccessConfig.hostID(hardwareUUID: "00000000-1111-2222-3333-444444444444")
    #expect(id == "5ff84c3b79a7faaa")
  }

  @Test func hostIDIsSixteenLowercaseHexAndNeverTheRawUUID() throws {
    let uuid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
    let id = try #require(RemoteAccessConfig.hostID(hardwareUUID: uuid))
    #expect(id.count == 16)
    #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(!uuid.lowercased().contains(id))
    #expect(RemoteAccessConfig.hostID(hardwareUUID: uuid) == id)
    #expect(RemoteAccessConfig.hostID(hardwareUUID: "other") != id)
  }

  @Test func noHardwareUUIDMeansNoHostID() {
    #expect(RemoteAccessConfig.hostID(hardwareUUID: nil) == nil)
    #expect(RemoteAccessConfig.hostID(hardwareUUID: "") == nil)
  }

  // MARK: - displayName

  @Test func displayNamePrefersTheTrimmedConfiguredName() {
    #expect(RemoteAccessConfig.displayName(configured: "  Office Mac \n", computerName: "iMac") == "Office Mac")
  }

  @Test func displayNameFallsBackToTheComputerName() {
    #expect(RemoteAccessConfig.displayName(configured: nil, computerName: "iMac") == "iMac")
    #expect(RemoteAccessConfig.displayName(configured: "", computerName: "iMac") == "iMac")
    #expect(RemoteAccessConfig.displayName(configured: " \t\n", computerName: "iMac") == "iMac")
    #expect(RemoteAccessConfig.displayName(configured: "\u{0007}", computerName: " iMac ") == "iMac")
    #expect(RemoteAccessConfig.displayName(configured: nil, computerName: "  ").isEmpty)
  }

  @Test func displayNameTurnsControlCharactersIntoSpacesAndCutsTo64() {
    #expect(RemoteAccessConfig.displayName(configured: "a\tb\u{0000}c", computerName: "x") == "a b c")
    let long = String(repeating: "я", count: 70)
    #expect(RemoteAccessConfig.displayName(configured: long, computerName: "x") == String(repeating: "я", count: 64))
    // An emoji joiner is a format character, not a control one: it survives.
    #expect(RemoteAccessConfig.displayName(configured: "👨‍💻 Mac", computerName: "x") == "👨‍💻 Mac")
  }

  // MARK: - hostURL

  @Test func hostURLAddsIdAndPercentEncodedName() throws {
    let base = try #require(URL(string: "wss://relay.example.com/host"))
    let url = RemoteAccessConfig.hostURL(base: base, hostID: "5ff84c3b79a7faaa", name: "Ivan's Mac+1 & Офис")
    #expect(
      url.absoluteString
        == "wss://relay.example.com/host?id=5ff84c3b79a7faaa&name=Ivan%27s%20Mac%2B1%20%26%20%D0%9E%D1%84%D0%B8%D1%81")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.first { $0.name == "name" }?.value == "Ivan's Mac+1 & Офис")
  }

  @Test func hostURLKeepsOtherQueryItemsAndReplacesIdAndName() throws {
    let base = try #require(URL(string: "wss://relay.example.com/host?x=1&id=old&name=Old&y=a%20b"))
    let url = RemoteAccessConfig.hostURL(base: base, hostID: "abc", name: "New")
    #expect(url.absoluteString == "wss://relay.example.com/host?x=1&y=a%20b&id=abc&name=New")
  }

  @Test func hostURLReplacesPercentEncodedIdAndNameItems() throws {
    let base = try #require(URL(string: "wss://relay.example.com/host?%69d=old&%6Eame=Old&x=1"))
    let url = RemoteAccessConfig.hostURL(base: base, hostID: "abc", name: "New")
    #expect(url.absoluteString == "wss://relay.example.com/host?x=1&id=abc&name=New")
  }

  @Test func hostURLOmitsANilIdAndAnEmptyName() throws {
    let base = try #require(URL(string: "wss://relay.example.com/host"))
    #expect(RemoteAccessConfig.hostURL(base: base, hostID: nil, name: "Mac").absoluteString
      == "wss://relay.example.com/host?name=Mac")
    #expect(RemoteAccessConfig.hostURL(base: base, hostID: "abc", name: "  ").absoluteString
      == "wss://relay.example.com/host?id=abc")
    #expect(RemoteAccessConfig.hostURL(base: base, hostID: nil, name: "").absoluteString
      == "wss://relay.example.com/host")
  }

  @Test func hostURLNormalizesTheName() throws {
    let base = try #require(URL(string: "wss://relay.example.com/host"))
    let url = RemoteAccessConfig.hostURL(base: base, hostID: nil, name: " a\nb ")
    #expect(url.absoluteString == "wss://relay.example.com/host?name=a%20b")
  }
}
