import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AgentPresenceOSCTests {
  // MARK: - parse.

  @Test func parsesValidSignal() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy")
    #expect(signal?.agent == "claude")
    #expect(signal?.eventRawValue == "busy")
  }

  @Test func parsesAntigravitySignal() {
    let signal = AgentPresenceOSC.parse(id: "antigravity", metadata: "event=busy")
    #expect(signal?.agent == "antigravity")
    #expect(signal?.eventRawValue == "busy")
    #expect(SkillAgent(rawValue: signal?.agent ?? "") == .antigravity)
  }

  @Test func rejectsEmptyId() {
    #expect(AgentPresenceOSC.parse(id: "", metadata: "event=busy") == nil)
  }

  @Test func rejectsMissingEvent() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "pid=5") == nil)
  }

  @Test func rejectsUnknownEvent() {
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=not_a_real_event") == nil)
  }

  @Test func ignoresUnknownFieldsAndOrdering() {
    // A leftover `token=` from an older emitter is just an unknown field now: ignored.
    let signal = AgentPresenceOSC.parse(id: "codex", metadata: "extra=1;token=zzz;event=session_start")
    #expect(signal?.eventRawValue == "session_start")
    #expect(signal?.agent == "codex")
  }

  @Test func skipsBareSegmentWithoutEquals() {
    // A segment with no '=' (a stray sentinel byte) is skipped, not fatal.
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "garbage;event=idle")
    #expect(signal?.eventRawValue == "idle")
  }

  // MARK: - emit / parse round-trip.

  @Test func emitMetadataRoundTripsThroughParse() {
    for event in [HookEvent.sessionStart, .sessionEnd, .busy, .awaitingInput, .idle] {
      let metadata = AgentPresenceOSC.metadata(event: event)
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: metadata)
      #expect(signal?.eventRawValue == event.rawValue)
    }
  }

  // MARK: - pid field (local-host liveness).

  @Test func parsesPositivePidField() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;pid=4321")
    #expect(signal?.pid == 4321)
  }

  @Test func absentPidParsesAsNil() {
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy")
    #expect(signal?.eventRawValue == "busy")
    #expect(signal?.pid == nil)
  }

  @Test func rejectsNonPositiveAndGarbagePid() {
    // 0 / negatives would let `kill(_:0)` match the caller's process group and
    // pin a permanent badge; a non-numeric pid is dropped, not fatal.
    for raw in ["0", "-7", "abc", ""] {
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;pid=\(raw)")
      #expect(signal?.eventRawValue == "busy")
      #expect(signal?.pid == nil)
    }
  }

  @Test func rejectsPidThatOverflowsPidT() {
    // Defense in depth against a future change from `pid_t(raw)` to `Int(raw)`:
    // a value beyond pid_t's range must drop, not wrap.
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;pid=99999999999999")
    #expect(signal?.pid == nil)
  }

  @Test func metadataPidSuffixRoundTripsThroughParse() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, pidSuffix: ";pid=99")
    let signal = AgentPresenceOSC.parse(id: "claude", metadata: metadata)
    #expect(signal?.pid == 99)
  }

  @Test func presenceEventThreadsLocalPid() {
    let metadata = AgentPresenceOSC.metadata(event: .busy, pidSuffix: ";pid=4242")
    let result = AgentSignal.presenceEvent(
      id: "claude", metadata: metadata, surfaceID: UUID(), surfaceExists: true)
    #expect((try? result.get())?.pid == 4242)
  }

  @Test func actionMapsSessionEndToEndElseStart() {
    #expect(AgentPresenceOSC.action(for: .sessionEnd) == "end")
    for event in [HookEvent.sessionStart, .busy, .awaitingInput, .idle] {
      #expect(AgentPresenceOSC.action(for: event) == "start")
    }
  }

  // MARK: - session / reason fields (agent session resume).

  @Test func parsesLowerAndUppercaseSessionIDKeepingCase() {
    for id in ["01a17693-8129-7c41-9dd3-c208ee9604ce", "A064B54A-E529-45C3-91CF-89CF1A424494"] {
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=session_start;pid=7;session=\(id)")
      #expect(signal?.eventRawValue == "session_start")
      #expect(signal?.pid == 7)
      #expect(signal?.sessionID == id)
    }
  }

  @Test func malformedSessionIDDropsOnlyThatField() {
    let valid = "a064b54a-e529-45c3-91cf-89cf1a424494"
    let invalid = [
      "zzzzzzzz-e529-45c3-91cf-89cf1a424494",  // 36 chars, not hex
      String(valid.dropLast()),  // 35
      valid + "0",  // 37
      "{\(valid)}",  // braced form
      "my-grok-session-title",  // a grok title `--resume` would accept
      "",
    ]
    for raw in invalid {
      let signal = AgentPresenceOSC.parse(
        id: "claude", metadata: "event=session_start;pid=9;session=\(raw);reason=other")
      #expect(signal?.eventRawValue == "session_start", "\(raw)")
      #expect(signal?.pid == 9, "\(raw)")
      #expect(signal?.sessionID == nil, "\(raw)")
      #expect(signal?.endReason == "other", "\(raw)")
    }
  }

  @Test func parsesEndReasonToken() {
    for reason in ["prompt_input_exit", "clear", "logout", "other", "shutdown", String(repeating: "a", count: 32)] {
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=session_end;reason=\(reason)")
      #expect(signal?.endReason == reason)
    }
  }

  @Test func malformedEndReasonDropsOnlyThatField() {
    let id = "a064b54a-e529-45c3-91cf-89cf1a424494"
    for raw in ["", "Other", "prompt-input-exit", "x1", "caf\u{e9}", "a\u{1b}b", String(repeating: "a", count: 33)] {
      let signal = AgentPresenceOSC.parse(id: "claude", metadata: "event=session_end;session=\(id);reason=\(raw)")
      #expect(signal?.eventRawValue == "session_end", "\(raw)")
      #expect(signal?.sessionID == id, "\(raw)")
      #expect(signal?.endReason == nil, "\(raw)")
    }
  }

  @Test func duplicateSessionOrReasonRejectsTheSignal() {
    let first = "a064b54a-e529-45c3-91cf-89cf1a424494"
    let second = "5b1ba78a-3208-4d0e-a389-9030d6e8e892"
    let twoSessions = "event=session_start;session=\(first);session=\(second)"
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: twoSessions) == nil)
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: "event=session_end;reason=other;reason=clear") == nil)
  }

  @Test func signalsWithoutSessionFieldsAreUnchanged() {
    #expect(
      AgentPresenceOSC.parse(id: "claude", metadata: "event=busy;pid=5")
        == AgentPresenceOSC.Signal(agent: "claude", eventRawValue: "busy", pid: 5))
    let signal = AgentPresenceOSC.parse(id: "codex", metadata: "event=session_start")
    #expect(signal?.sessionID == nil)
    #expect(signal?.endReason == nil)
  }

  @Test func presenceEventCopiesSessionIDAndEndReason() {
    let id = "01a17693-8129-7c41-9dd3-c208ee9604ce"
    let result = AgentSignal.presenceEvent(
      id: "codex", metadata: "event=session_end;pid=42;session=\(id);reason=other",
      surfaceID: UUID(), surfaceExists: true)
    let event = try? result.get()
    #expect(event?.event == "session_end")
    #expect(event?.pid == 42)
    #expect(event?.sessionID == id)
    #expect(event?.endReason == "other")
  }

  @Test func presenceEventWithoutSessionFieldsLeavesThemNil() {
    let result = AgentSignal.presenceEvent(
      id: "claude", metadata: "event=busy", surfaceID: UUID(), surfaceExists: true)
    let event = try? result.get()
    #expect(event?.sessionID == nil)
    #expect(event?.endReason == nil)
  }

  @Test func socketDecodedHookEventCarriesNoSession() throws {
    let surfaceID = UUID()
    let json = #"{"event":"session_start","v":1,"agent":"claude","surface_id":"\#(surfaceID.uuidString)","pid":5}"#
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.sessionID == nil)
    #expect(event.endReason == nil)
    #expect(event == AgentHookEvent(agent: "claude", event: "session_start", surfaceID: surfaceID, pid: 5))
  }

  // MARK: - presenceEvent (attribution to receiving surface).

  @Test func presenceEventAttributesToReceivingSurface() {
    let surfaceID = UUID()
    let metadata = AgentPresenceOSC.metadata(event: .busy)
    let result = AgentSignal.presenceEvent(
      id: "claude", metadata: metadata, surfaceID: surfaceID, surfaceExists: true)
    let event = try? result.get()
    #expect(event?.surfaceID == surfaceID)
    #expect(event?.agent == "claude")
    #expect(event?.event == "busy")
    #expect(event?.pid == nil)
  }

  @Test func presenceEventDropsUnknownSurface() {
    let metadata = AgentPresenceOSC.metadata(event: .busy)
    let result = AgentSignal.presenceEvent(
      id: "claude", metadata: metadata, surfaceID: UUID(), surfaceExists: false)
    #expect(result == .failure(.unknownSurface))
  }

  @Test func presenceEventDropsMalformedMetadata() {
    let result = AgentSignal.presenceEvent(
      id: "claude", metadata: "event=nope", surfaceID: UUID(), surfaceExists: true)
    #expect(result == .failure(.parseFailed))
  }

  // MARK: - AgentHookEvent synthesis.

  @Test func synthesizedHookEventDefaultsToPidlessAndKeepsSurface() {
    let surfaceID = UUID()
    let event = AgentHookEvent(agent: "claude", event: "busy", surfaceID: surfaceID)
    #expect(event.pid == nil)
    #expect(event.surfaceID == surfaceID)
    #expect(event.agent == "claude")
    #expect(event.event == "busy")
    #expect(event.version == 1)
  }

  // MARK: - parseNotify.

  /// base64 of the JSON-escaped content of `text`, matching the wire the emitter
  /// ships (`awk`-extracted escaped value / Pi's `JSON.stringify(...).slice(1,-1)`).
  private static func field(_ text: String) -> String {
    guard let json = try? JSONEncoder().encode(text) else { return "" }
    // `json` is `"..."`; drop the surrounding quote bytes, keep the escaped content.
    return Data(json.dropFirst().dropLast()).base64EncodedString()
  }

  private static func notifyMeta(title: String? = nil, body: String? = nil) -> String {
    AgentPresenceOSC.notifyMetadata(title: title.map(field) ?? "", body: body.map(field) ?? "")
  }

  @Test func parsesValidNotify() {
    let signal = AgentPresenceOSC.parseNotify(id: "claude", metadata: Self.notifyMeta(body: "hi"))
    #expect(signal?.agent == "claude")
    #expect(signal?.title == nil)
    #expect(signal?.body == "hi")
  }

  @Test func parsesNotifyWithTitleAndBody() {
    let signal = AgentPresenceOSC.parseNotify(
      id: "claude", metadata: Self.notifyMeta(title: "Done", body: "all good"))
    #expect(signal?.title == "Done")
    #expect(signal?.body == "all good")
  }

  @Test func decodesEscapedQuotesNewlinesAndUnicode() {
    let signal = AgentPresenceOSC.parseNotify(
      id: "claude", metadata: Self.notifyMeta(body: "line \"one\"\nDONE ✓"))
    #expect(signal?.body == "line \"one\"\nDONE ✓")
  }

  @Test func rejectsNotifyWithoutKind() {
    #expect(AgentPresenceOSC.parseNotify(id: "claude", metadata: "body=\(Self.field("x"))") == nil)
  }

  @Test func notifyWithoutBodyParsesAsTitleOnly() {
    // Body is optional: a missing body yields a title-only signal (macOS shows a
    // body-less toast), not a dropped notify.
    let signal = AgentPresenceOSC.parseNotify(id: "claude", metadata: Self.notifyMeta(title: "Heads up"))
    #expect(signal?.title == "Heads up")
    #expect(signal?.body == nil)
  }

  @Test func rejectsNotifyWithEmptyId() {
    #expect(AgentPresenceOSC.parseNotify(id: "", metadata: Self.notifyMeta(body: "x")) == nil)
  }

  @Test func invalidBase64FieldDecodesToNil() {
    let signal = AgentPresenceOSC.parseNotify(id: "claude", metadata: "kind=notify;body=!!notb64")
    #expect(signal?.body == nil)
  }

  @Test func decodeToleratesTrailingPartialEscapeFromEmitCut() {
    // A body byte-capped mid-`\"` leaves a dangling backslash; decoding must shed
    // it and preview the rest rather than dropping the notify (the >2048 truncate
    // path relies on this).
    let escaped = #"say \"#  // ends with a lone backslash (a cut `\"`)
    let signal = AgentPresenceOSC.parseNotify(
      id: "claude", metadata: "kind=notify;body=\(Data(escaped.utf8).base64EncodedString())")
    #expect(signal?.body == "say ")
  }

  @Test func decodeShedsCutSurrogatePairEscapeToPreview() {
    // A body cut mid surrogate-pair escape (`\uD83D\uDE0` is 11 dangling bytes)
    // must shed back to the recoverable prefix, not drop the whole body to empty.
    let escaped = #"done \uD83D\uDE0"#
    let signal = AgentPresenceOSC.parseNotify(
      id: "claude", metadata: "kind=notify;body=\(Data(escaped.utf8).base64EncodedString())")
    // The recoverable prefix survives (not dropped to empty); exact trailing
    // depends on Foundation's lone-surrogate handling, so assert the prefix.
    #expect(signal?.body?.hasPrefix("done") == true)
  }

  @Test func base64TruncatedBodyDecodesToNilTitleOnly() {
    // A mid-base64 cut (length not a multiple of 4, the ghostty .allocating path)
    // is not decodable: the body drops and the toast falls back to the title.
    let valid = Data("hello world body".utf8).base64EncodedString()
    let cut = String(valid.dropLast())  // break base64 alignment
    let signal = AgentPresenceOSC.parseNotify(
      id: "claude", metadata: "kind=notify;title=\(Self.field("Done"));body=\(cut)")
    #expect(signal?.title == "Done")
    #expect(signal?.body == nil)
  }

  @Test func notifyMetadataRoundTripsThroughParseNotify() {
    let metadata = Self.notifyMeta(title: "T", body: "round trip")
    let signal = AgentPresenceOSC.parseNotify(id: "codex", metadata: metadata)
    #expect(signal?.title == "T")
    #expect(signal?.body == "round trip")
  }

  @Test func presenceParseRejectsNotifyMetadata() {
    // Presence and notify are disjoint: a notify payload must not parse as presence.
    #expect(AgentPresenceOSC.parse(id: "claude", metadata: Self.notifyMeta(body: "x")) == nil)
  }

  // MARK: - notification (parse + sanitize).

  @Test func notificationExtractsBody() {
    let resolved = AgentSignal.notification(
      id: "claude", metadata: Self.notifyMeta(body: "all done"), surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.body == "all done")
  }

  @Test func notificationDropsUnknownSurface() {
    let result = AgentSignal.notification(
      id: "claude", metadata: Self.notifyMeta(body: "x"), surfaceExists: false)
    if case .failure(.unknownSurface) = result {} else { Issue.record("expected unknownSurface, got \(result)") }
  }

  @Test func notificationDropsClosedSurfaceWithoutWarning() {
    // A signal targeting a closed surface is benign, not malformed: the call site
    // routes `.unknownSurface` to `.debug`, never `.warning`. Asserting the exact
    // failure case locks that mapping in since `parseFailed` is the only
    // warn-level branch.
    let result = AgentSignal.notification(
      id: "claude", metadata: Self.notifyMeta(body: "x"), surfaceExists: false)
    guard case .failure(let drop) = result else {
      Issue.record("expected failure, got \(result)")
      return
    }
    if case .unknownSurface = drop {
    } else {
      Issue.record("expected unknownSurface, got \(drop)")
    }
    if case .parseFailed = drop { Issue.record("unknown surface must not log as a malformed warning") }
  }

  @Test func notificationFallsBackToAgentTitleWhenAbsent() {
    let resolved = AgentSignal.notification(
      id: "codex", metadata: Self.notifyMeta(body: "body only"), surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.title == "codex")
  }

  @Test func notificationShowsTitleOnlyToastWhenBodyAbsent() {
    // A turn-complete notify with no body still fires, showing just the title.
    let resolved = AgentSignal.notification(
      id: "claude", metadata: Self.notifyMeta(), surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.title == "claude")
    #expect(value.body.isEmpty)
  }

  @Test func notificationDropsPayloadThatSanitizesEmpty() {
    // Body of only control / whitespace and no usable title sanitizes to empty,
    // so the toast is suppressed rather than shown blank.
    let result = AgentSignal.notification(
      id: " ", metadata: Self.notifyMeta(body: "\n"), surfaceExists: true)
    if case .failure(.empty) = result {} else { Issue.record("expected empty, got \(result)") }
  }

  @Test func sanitizeStripsControlCharsAndCollapsesNewlines() {
    let dirty = "a\u{1B}[31mred\u{07}\nline"
    #expect(AgentSignal.sanitizeNotificationText(dirty, max: 1000) == "a[31mred line")
  }

  @Test func sanitizeCapsToMaxScalars() {
    let long = String(repeating: "x", count: 500)
    #expect(AgentSignal.sanitizeNotificationText(long, max: 100).count == 100)
  }

  @Test func notificationStripsEmbeddedOSCSequenceFromBody() {
    // A notify body that smuggles a nested OSC 3008 presence sequence must not
    // forward the ESC or the framing bytes to the toast: the C0 strip is the
    // only line of defense between an attacker-controlled message and the
    // terminal's own escape parser. The ESC bytes ride in via JSON's six-char
    // unicode escape (raw 0x1B is illegal in a JSON string); the C0 strip
    // must drop both the opening ESC and the trailing ST ESC before the
    // toast sees them.
    let body = "before\u{1B}]3008;start=evil;event=busy\u{1B}\\after"
    let resolved = AgentSignal.notification(
      id: "claude", metadata: Self.notifyMeta(body: body), surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    // No ESC byte may reach the toast, no matter where it sat in the payload.
    #expect(!value.body.unicodeScalars.contains { $0.value == 0x1B })
    // Printable framing bytes survive (they are not C0); the load-bearing
    // assertion is that the ESC is gone, so a downstream renderer cannot
    // re-trigger an escape parser.
    #expect(value.body == #"before]3008;start=evil;event=busy\after"#)
    // The standalone sanitize entry point pins the same contract directly.
    let dirty = "before\u{1B}]3008;start=evil;event=busy\u{1B}\\after"
    #expect(
      AgentSignal.sanitizeNotificationText(dirty, max: 1000)
        == #"before]3008;start=evil;event=busy\after"#)
  }

  // MARK: - large payload (metadata cap headroom).

  @Test func largeNotifyPayloadNearMetadataCapRoundTripsEndToEnd() {
    // A near-cap body must survive parseNotify + notification(...) end to end and
    // stay under the 2048-byte OSC cap so a real terminal does not truncate.
    let bodyText = String(repeating: "y", count: 1400)
    let metadata = Self.notifyMeta(title: "Big", body: bodyText)
    #expect(metadata.utf8.count < 2048)

    let signal = AgentPresenceOSC.parseNotify(id: "codex", metadata: metadata)
    #expect(signal?.body == bodyText)

    let resolved = AgentSignal.notification(
      id: "codex", metadata: metadata, surfaceExists: true)
    guard case .success(let value) = resolved else {
      Issue.record("expected success, got \(resolved)")
      return
    }
    #expect(value.title == "Big")
    // Body is sanitized + capped at 1000 scalars (see AgentSignal.notification).
    #expect(value.body.count == 1000)
    #expect(value.body.allSatisfy { $0 == "y" })
  }

  // MARK: - emitNotifyShell stdin capture.

  @Test func emitNotifyShellCapturesStdinByDefault() {
    let shell = AgentPresenceOSC.emitNotifyShell(agent: .copilot)
    #expect(shell.hasPrefix("\(AgentPresenceOSC.readStdinSnippet); "))
    #expect(shell.contains("start=copilot"))
  }

  @Test func emitNotifyShellSkipsStdinCaptureWhenCallerOwnsIt() {
    // The notification hook reads `$__in` once itself, so the notify leg must
    // not read stdin again (it is already drained).
    let shell = AgentPresenceOSC.emitNotifyShell(agent: .copilot, readsStdin: false)
    #expect(!shell.contains("$(cat)"))
    #expect(shell.contains("start=copilot"))
  }
}
