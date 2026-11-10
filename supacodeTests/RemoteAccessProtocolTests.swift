import Foundation
import Testing

@testable import supacode

struct RemoteAccessProtocolTests {
  @Test func hostFrameSplitsOnTheFirstNewlineOnly() throws {
    let parsed = try #require(RemoteHostFrame.parse("abc\n{\"t\":\"input\",\"b64\":\"a\\nb\"}"))
    #expect(parsed.connID == "abc")
    #expect(String(bytes: parsed.json, encoding: .utf8) == "{\"t\":\"input\",\"b64\":\"a\\nb\"}")
  }

  @Test func hostFrameWithoutPrefixIsRejected() {
    #expect(RemoteHostFrame.parse("{\"t\":\"list\"}") == nil)
    #expect(RemoteHostFrame.parse("\n{\"t\":\"list\"}") == nil)
  }

  @Test func hostFrameEncodeRoundTrips() throws {
    let text = RemoteHostFrame.encode(connID: "0a1b", payload: Data("{\"t\":\"hello\"}".utf8))
    #expect(text == "0a1b\n{\"t\":\"hello\"}")
    let parsed = try #require(RemoteHostFrame.parse(text))
    #expect(parsed.connID == "0a1b")
  }

  @Test func inboundDecodesEveryRequestShape() throws {
    let attach = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"attach","id":2,"contentId":"C","scrollback":500}"#.utf8)))
    #expect(attach == RemoteInboundMessage(t: "attach", id: 2, contentId: "C", scrollback: 500))
    let input = try #require(RemoteJSON.decodeInbound(Data(#"{"t":"input","contentId":"C","b64":"DQ=="}"#.utf8)))
    #expect(input.b64 == "DQ==")
    #expect(RemoteJSON.decodeInbound(Data("not json".utf8)) == nil)
    #expect(RemoteJSON.decodeInbound(Data(#"{"id":1}"#.utf8)) == nil)
  }

  @Test func tabNewRequestDecodesTheWorktreeID() throws {
    let request = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":4,"worktreeId":"/Users/x/repo/wt"}"#.utf8)))
    #expect(request == RemoteInboundMessage(t: "tab.new", id: 4, worktreeId: "/Users/x/repo/wt"))
  }

  @Test func tabNewReplyEncodesTheContractFields() throws {
    let reply = RemoteTabNewMessage(id: 4, worktreeId: "/Users/x/repo/wt", tabId: "T", contentId: "C")
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(reply)) as? [String: Any])
    #expect(json.count == 5)
    #expect(json["t"] as? String == "tab.new")
    #expect(json["id"] as? Int == 4)
    #expect(json["worktreeId"] as? String == "/Users/x/repo/wt")
    #expect(json["tabId"] as? String == "T")
    #expect(json["contentId"] as? String == "C")
  }

  @Test func errorEncodesANullIDExplicitly() throws {
    let json = try #require(
      try JSONSerialization.jsonObject(with: RemoteJSON.encode(RemoteErrorMessage(id: nil, message: "x")))
        as? [String: Any])
    #expect(json["t"] as? String == "error")
    #expect(json.keys.contains("id"))
    #expect(json["id"] is NSNull)
  }

  @Test func outputIsChunkedAndKeepsBytesIntact() throws {
    let text = "Здравей 👋 \u{1B}[31mred\u{1B}[0m"
    let bytes = Array(text.utf8)
    let messages = RemoteJSON.outputMessages(contentID: "C", bytes: bytes, chunkSize: 5)
    #expect(messages.count == (bytes.count + 4) / 5)
    var joined: [UInt8] = []
    for message in messages {
      let json = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String])
      #expect(json["t"] == "out")
      #expect(json["contentId"] == "C")
      let b64 = try #require(json["b64"])
      let decoded = try #require(Data(base64Encoded: b64))
      joined += Array(decoded)
    }
    #expect(joined == bytes)
    #expect(RemoteJSON.outputMessages(contentID: "C", bytes: []).isEmpty)
  }

  @Test func captureRequestMatchesTheZmxPackedLayout() {
    // Header: tag 22, len 8 LE, 3 pad; payload: format, rows u32 LE, 3 pad.
    #expect(
      ZmxIPCFrameEncoder.capture(format: ZmxIPCFrameEncoder.formatVT, scrollbackRows: 0x0102)
        == [22, 8, 0, 0, 0, 0, 0, 0, 1, 0x02, 0x01, 0, 0, 0, 0, 0])
  }

  @Test func sendFrameCarriesRawBytes() {
    #expect(ZmxIPCFrameEncoder.frame(tag: ZmxIPCFrameEncoder.sendTag, payload: [0x03]) == [18, 1, 0, 0, 0, 0, 0, 0, 3])
  }

  @Test func suggestionReplyParsing() {
    #expect(RemoteSuggestionRunner.parse(#"["git status", "/btw ok"]"#) == ["git status", "/btw ok"])
    let fenced = "Sure:\n```json\n[\"a\", \" a \", \"\", \"b\", \"c\", \"d\"]\n```"
    #expect(RemoteSuggestionRunner.parse(fenced) == ["a", "b", "c"])
    #expect(RemoteSuggestionRunner.parse("no array here") == nil)
    #expect(RemoteSuggestionRunner.parse("[1, 2]") == nil)
  }

  @Test func suggestionPromptCarriesTheTerminalText() {
    let prompt = RemoteSuggestionRunner.prompt(terminalText: "$ make test\nFAILED")
    #expect(prompt.contains("<terminal>\n$ make test\nFAILED\n</terminal>"))
    #expect(prompt.contains("JSON array"))
  }

  @Test func lastLinesDropsTrailingBlankRowsAndKeepsIndentation() {
    let text = "one\n  two  \nthree\n\n   \n"
    #expect(RemoteHostRouter.lastLines(text, count: 2) == "  two\nthree")
    #expect(RemoteHostRouter.lastLines(text, count: 10) == "one\n  two\nthree")
  }

  @Test func helloCarriesTheHostIDWhenThereIsOne() throws {
    let hello = RemoteHelloMessage(host: "Office Mac", hostId: "5ff84c3b79a7faaa")
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(hello)) as? [String: Any])
    #expect(json.count == 4)
    #expect(json["t"] as? String == "hello")
    #expect(json["v"] as? Int == 1)
    #expect(json["host"] as? String == "Office Mac")
    #expect(json["hostId"] as? String == "5ff84c3b79a7faaa")
  }

  @Test func helloWithoutAHostIDOmitsTheField() throws {
    let hello = RemoteHelloMessage(host: "Office Mac")
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(hello)) as? [String: Any])
    #expect(json.count == 3)
    #expect(!json.keys.contains("hostId"))
    #expect(!json.keys.contains("lan"))
  }

  @Test func helloCarriesTheAppBuildWhenThereIsOne() throws {
    let app = RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154")
    #expect(app == "Supacode 0.11.5 (154)")
    let hello = RemoteHelloMessage(host: "Office Mac", hostId: "5ff84c3b79a7faaa", app: app)
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(hello)) as? [String: Any])
    #expect(json.count == 5)
    #expect(json["app"] as? String == "Supacode 0.11.5 (154)")
  }

  @Test func appLabelUsesWhatExistsAndNeverIsEmpty() {
    #expect(RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: nil) == "Supacode 0.11.5")
    #expect(RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "  ") == "Supacode 0.11.5")
    #expect(RemoteHelloMessage.appLabel(shortVersion: nil, build: "154") == "Supacode (154)")
    #expect(RemoteHelloMessage.appLabel(shortVersion: nil, build: nil) == nil)
    #expect(RemoteHelloMessage.appLabel(shortVersion: "", build: "") == nil)
  }

  @Test func appLabelCarriesTheBuildDateAndShaWhenKnown() {
    let all = RemoteHelloMessage.appLabel(
      shortVersion: "0.11.5", build: "154", buildDate: "2026-11-10 14:25:09", commit: "2e264f48")
    #expect(all == "Supacode 0.11.5 (154) · 2026-11-10 · 2e264f48")
  }

  @Test func appLabelLeavesOutAMissingDateOrSha() {
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: nil, commit: "2e264f48")
        == "Supacode 0.11.5 (154) · 2e264f48")
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: "2026-11-10 14:25:09", commit: nil)
        == "Supacode 0.11.5 (154) · 2026-11-10")
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: "  ", commit: "")
        == "Supacode 0.11.5 (154)")
  }

  @Test func appLabelTreatsTheStampPlaceholderAndAMalformedDateAsUnknown() {
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: "n/a", commit: "unknown")
        == "Supacode 0.11.5 (154)")
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: "20261110", commit: "Unknown")
        == "Supacode 0.11.5 (154)")
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: "0.11.5", build: "154", buildDate: nil, commit: "2e264f48-dirty")
        == "Supacode 0.11.5 (154) · 2e264f48-dirty")
  }

  @Test func appLabelWithOnlyTheStampStillNamesTheApp() {
    #expect(
      RemoteHelloMessage.appLabel(shortVersion: nil, build: nil, buildDate: "2026-11-10 14:25:09", commit: "2e264f48")
        == "Supacode · 2026-11-10 · 2e264f48")
  }

  @Test func appLabelWithNothingKnownIsNil() {
    #expect(RemoteHelloMessage.appLabel(shortVersion: nil, build: nil, buildDate: nil, commit: nil) == nil)
    #expect(RemoteHelloMessage.appLabel(shortVersion: " ", build: "", buildDate: "", commit: " ") == nil)
    #expect(RemoteHelloMessage.appLabel(shortVersion: nil, build: nil, buildDate: "bad", commit: "unknown") == nil)
  }

  @Test func helloCarriesTheFullAppLabel() throws {
    let app = RemoteHelloMessage.appLabel(
      shortVersion: "0.11.5", build: "154", buildDate: "2026-11-10 14:25:09", commit: "2e264f48")
    let hello = RemoteHelloMessage(host: "Office Mac", app: app)
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(hello)) as? [String: Any])
    #expect(json["app"] as? String == "Supacode 0.11.5 (154) · 2026-11-10 · 2e264f48")
  }

  @Test func helloWithoutAnAppBuildOmitsTheField() throws {
    let hello = RemoteHelloMessage(host: "Office Mac", app: nil)
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(hello)) as? [String: Any])
    #expect(!json.keys.contains("app"))
  }

  @Test func renameFrameGoesToTheControlConnID() throws {
    let text = RemoteHostFrame.renameFrame(name: "Office Mac")
    #expect(text.hasPrefix("@\n"))
    let parsed = try #require(RemoteHostFrame.parse(text))
    #expect(parsed.connID == RemoteHostFrame.controlConnID)
    // Field by field: JSONEncoder does not promise a key order.
    let json = try #require(try JSONSerialization.jsonObject(with: parsed.json) as? [String: Any])
    #expect(json.count == 2)
    #expect(json["t"] as? String == "host.name")
    #expect(json["name"] as? String == "Office Mac")
  }

  @Test func renameFrameNormalizesTheNameAndOmitsAnEmptyOne() throws {
    let normalized = try #require(RemoteHostFrame.parse(RemoteHostFrame.renameFrame(name: " a\tb ")))
    let json = try #require(try JSONSerialization.jsonObject(with: normalized.json) as? [String: Any])
    #expect(json["name"] as? String == "a b")
    let empty = try #require(RemoteHostFrame.parse(RemoteHostFrame.renameFrame(name: "  ")))
    let emptyJSON = try #require(try JSONSerialization.jsonObject(with: empty.json) as? [String: Any])
    #expect(emptyJSON.count == 1)
    #expect(emptyJSON["t"] as? String == "host.name")
  }

  @Test func onlyTheInstalledAppHostsUnlessOverridden() {
    #expect(RemoteAccessConfig.mayHost(bundlePath: "/Applications/supacode.app", override: nil))
    #expect(
      !RemoteAccessConfig.mayHost(
        bundlePath: "/Users/x/supacode/.build/DerivedData/Build/Products/Debug/supacode.app", override: nil))
    #expect(RemoteAccessConfig.mayHost(bundlePath: "/tmp/supacode.app", override: "1"))
    #expect(!RemoteAccessConfig.mayHost(bundlePath: "/Applications/supacode.app", override: "0"))
  }

  // MARK: - resize

  private static let attachedContent = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

  private typealias ResizeOutcome = Result<RemoteResizeRequest, RemoteResizeRequest.Ignored>

  private static func resize(_ json: String, attached: UUID? = attachedContent) throws -> ResizeOutcome {
    let message = try #require(RemoteJSON.decodeInbound(Data(json.utf8)))
    return RemoteResizeRequest.resolve(message, attached: attached)
  }

  @Test func resizeOfTheAttachedContentIsDecoded() throws {
    let json = #"{"t":"resize","contentId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","cols":132,"rows":43}"#
    let message = try #require(RemoteJSON.decodeInbound(Data(json.utf8)))
    #expect(message.t == "resize")
    #expect(
      try Self.resize(json)
        == .success(RemoteResizeRequest(contentID: Self.attachedContent, columns: 132, rows: 43)))
    // The content id is matched as a UUID, not as text.
    let lowercased = #"{"t":"resize","contentId":"6f9619ff-8b86-d011-b42d-00cf4fc964ff","cols":132,"rows":43}"#
    #expect(
      try Self.resize(lowercased)
        == .success(RemoteResizeRequest(contentID: Self.attachedContent, columns: 132, rows: 43)))
  }

  @Test func resizeIsClampedToTheHostLimits() throws {
    func resolved(_ cols: Int, _ rows: Int) throws -> ResizeOutcome {
      try Self.resize(
        #"{"t":"resize","contentId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","cols":\#(cols),"rows":\#(rows)}"#)
    }
    func request(_ cols: Int, _ rows: Int) -> ResizeOutcome {
      .success(RemoteResizeRequest(contentID: Self.attachedContent, columns: cols, rows: rows))
    }
    #expect(try resolved(19, 4) == request(20, 5))
    #expect(try resolved(20, 5) == request(20, 5))
    #expect(try resolved(500, 200) == request(500, 200))
    #expect(try resolved(501, 201) == request(500, 200))
    #expect(try resolved(0, -3) == request(20, 5))
    #expect(try resolved(10_000, 10_000) == request(500, 200))
  }

  @Test func resizeWithAMissingOrNonIntegerSizeIsIgnored() throws {
    let id = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
    for fields in [
      #""cols":80"#, #""rows":24"#, #""cols":"80","rows":24"#, #""cols":80.5,"rows":24"#,
      #""cols":80,"rows":null"#, #""cols":80,"rows":true"#, #""cols":[80],"rows":24"#,
    ] {
      #expect(try Self.resize(#"{"t":"resize","contentId":"\#(id)",\#(fields)}"#) == .failure(.invalidSize))
    }
  }

  @Test func resizeOfAContentThisConnectionIsNotAttachedToIsIgnored() throws {
    let other = #"{"t":"resize","contentId":"\#(UUID().uuidString)","cols":80,"rows":24}"#
    #expect(try Self.resize(other) == .failure(.notAttached))
    let attachedID = #"{"t":"resize","contentId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","cols":80,"rows":24}"#
    #expect(try Self.resize(attachedID, attached: nil) == .failure(.notAttached))
    #expect(try Self.resize(#"{"t":"resize","cols":80,"rows":24}"#) == .failure(.notAttached))
    #expect(try Self.resize(#"{"t":"resize","contentId":"tab-1","cols":80,"rows":24}"#) == .failure(.notAttached))
  }
}
