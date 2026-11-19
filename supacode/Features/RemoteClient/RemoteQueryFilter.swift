/// Drops terminal queries (and Supacode's OSC 3008) from a remote terminal's output.
///
/// The remote Mac's Ghostty has already answered every query in the remote PTY. If the query also
/// reached the local Ghostty it would answer too, the answer would travel back as input and the
/// program there would read it as typed text. Supacode's OSC 3008 is the agent-presence signal of
/// the remote Mac; the local app must not read it as its own.
///
/// A sequence can be split between two `push` calls, so the filter keeps its state. The 8-bit C1
/// controls (0x9b and the like) are not recognised: in UTF-8 those bytes are part of letters.
/// Port of `supacode-remote/web/src/query-filter.mjs`.
nonisolated struct RemoteQueryFilter: Sendable {
  /// An unfinished sequence longer than this is let through, or a broken OSC would swallow everything.
  static let maxPending = 4096

  private enum State {
    case ground
    case esc
    case csi
    case osc
    case dcs
    /// An ESC inside an OSC or a DCS: `ESC \` ends it, anything else interrupts it.
    case oscEsc
    case dcsEsc
  }

  private static let esc: UInt8 = 0x1b
  private static let bel: UInt8 = 0x07
  /// CAN and SUB end every sequence in the terminal too.
  private static let can: UInt8 = 0x18
  private static let sub: UInt8 = 0x1a
  private static let semicolon = UInt8(ascii: ";")
  private static let questionMark = UInt8(ascii: "?")
  private static let csiPrefixes = Set("?>=<".utf8)
  private static let oscQueryNumbers: Set<[UInt8]> = [
    Array("4".utf8), Array("10".utf8), Array("11".utf8), Array("12".utf8),
  ]
  private static let presenceOscNumber = Array("3008".utf8)
  private static let clipboardOscNumber = Array("52".utf8)

  private var state = State.ground
  /// The bytes of the current sequence, from its ESC on.
  private var pending: [UInt8] = []

  /// The bytes for the local terminal; an unfinished sequence waits for the next call.
  mutating func push(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for byte in bytes { step(byte, into: &out) }
    return out
  }

  // MARK: - State machine

  private mutating func step(_ byte: UInt8, into out: inout [UInt8]) {
    switch state {
    case .ground:
      if byte == Self.esc {
        begin(byte)
      } else {
        out.append(byte)
      }
    case .esc:
      afterEsc(byte, into: &out)
    case .csi:
      if byte == Self.esc {
        restart(byte, into: &out)
        return
      }
      pending.append(byte)
      if byte == Self.can || byte == Self.sub {
        flush(into: &out)
        return
      }
      if (0x40...0x7e).contains(byte) {
        finish(into: &out, drop: Self.isCsiQuery(pending.dropFirst(2)))
      }
      capIfNeeded(into: &out)
    case .osc, .dcs:
      pending.append(byte)
      if byte == Self.bel && state == .osc {
        finish(into: &out, drop: Self.isDroppedOsc(pending.dropFirst(2).dropLast(1)))
        return
      }
      if byte == Self.can || byte == Self.sub {
        flush(into: &out)
        return
      }
      if byte == Self.esc { state = state == .osc ? .oscEsc : .dcsEsc }
      capIfNeeded(into: &out)
    case .oscEsc, .dcsEsc:
      afterStringEsc(byte, into: &out)
    }
  }

  private mutating func afterEsc(_ byte: UInt8, into out: inout [UInt8]) {
    // A second ESC starts the sequence again in the terminal, so the first one does nothing: it is
    // left out and the new one is read as usual (`ESC ESC [ c` is DA1).
    if byte == Self.esc {
      begin(byte)
      return
    }
    pending.append(byte)
    switch byte {
    case UInt8(ascii: "["): state = .csi
    case UInt8(ascii: "]"): state = .osc
    case UInt8(ascii: "P"): state = .dcs
    case UInt8(ascii: "Z"): finish(into: &out, drop: true)  // DECID: asks for the terminal's id
    default: flush(into: &out)  // ESC 7, ESC ( B and the like are not queries
    }
  }

  /// An ESC inside an OSC or a DCS: `ESC \` ends it, anything else interrupts it like in a terminal.
  private mutating func afterStringEsc(_ byte: UInt8, into out: inout [UInt8]) {
    let isOsc = state == .oscEsc
    if byte == UInt8(ascii: "\\") {
      pending.append(byte)
      let body = pending.dropFirst(2).dropLast(2)
      finish(into: &out, drop: isOsc ? Self.isDroppedOsc(body) : Self.isDcsQuery(body))
      return
    }
    // The interrupted sequence passes; its ESC starts a new one.
    pending.removeLast()
    restart(Self.esc, into: &out)
    afterEsc(byte, into: &out)
  }

  private mutating func begin(_ byte: UInt8) {
    state = .esc
    pending = [byte]
  }

  /// An ESC interrupts the current sequence. The terminal would stop it at that same ESC, but if
  /// the new sequence is a query the ESC never reaches it, so CAN closes the old one explicitly.
  private mutating func restart(_ byte: UInt8, into out: inout [UInt8]) {
    flush(into: &out)
    out.append(Self.can)
    begin(byte)
  }

  private mutating func finish(into out: inout [UInt8], drop: Bool) {
    if !drop { out.append(contentsOf: pending) }
    state = .ground
    pending.removeAll(keepingCapacity: true)
  }

  private mutating func flush(into out: inout [UInt8]) {
    finish(into: &out, drop: false)
  }

  private mutating func capIfNeeded(into out: inout [UInt8]) {
    if pending.count > Self.maxPending { flush(into: &out) }
  }

  // MARK: - What is a query

  /// A CSI query by prefix, intermediate bytes and final. `body` is everything after `ESC [`,
  /// the final included.
  private static func isCsiQuery(_ body: ArraySlice<UInt8>) -> Bool {
    guard let final = body.last else { return false }
    let prefix: UInt8? = body.first.flatMap { csiPrefixes.contains($0) ? $0 : nil }
    switch final {
    case UInt8(ascii: "c"):
      return prefix == nil || prefix == UInt8(ascii: ">") || prefix == UInt8(ascii: "=")
    case UInt8(ascii: "n"):
      return prefix == nil || prefix == UInt8(ascii: "?")
    case UInt8(ascii: "p"):
      let middle = body.dropFirst(prefix == nil ? 0 : 1).dropLast(1)
      return middle.contains(UInt8(ascii: "$"))
    case UInt8(ascii: "q"):
      return prefix == UInt8(ascii: ">")
    case UInt8(ascii: "t"):
      return true
    case UInt8(ascii: "u"):
      return prefix == UInt8(ascii: "?")
    default:
      return false
    }
  }

  /// OSC 4/10/11/12 with a `?` after the first `;` ask for a colour; with a value they set it and
  /// pass. OSC 52 whose data (after its second `;`) is `?` reads the clipboard; with base64 data it
  /// sets it and passes. OSC 3008 is Supacode's own presence signal and is always dropped.
  private static func isDroppedOsc(_ body: ArraySlice<UInt8>) -> Bool {
    guard let semicolonIndex = body.firstIndex(of: semicolon) else {
      return Array(body) == presenceOscNumber
    }
    let number = Array(body[body.startIndex..<semicolonIndex])
    if number == presenceOscNumber { return true }
    if number == clipboardOscNumber {
      let rest = body[body.index(after: semicolonIndex)...]
      guard let dataSemicolon = rest.firstIndex(of: semicolon) else { return false }
      return Array(rest[rest.index(after: dataSemicolon)...]) == [questionMark]
    }
    return semicolonIndex > body.startIndex
      && oscQueryNumbers.contains(number)
      && body[semicolonIndex...].contains(questionMark)
  }

  /// DECRQSS (`DCS $ q`) and XTGETTCAP (`DCS + q`).
  private static func isDcsQuery(_ body: ArraySlice<UInt8>) -> Bool {
    body.starts(with: Array("$q".utf8)) || body.starts(with: Array("+q".utf8))
  }
}
