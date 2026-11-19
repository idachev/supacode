import Foundation
import Testing

@testable import supacode

struct RemoteClientQueryFilterTests {
  /// Each string is one `push`; its scalars are the bytes (all of them below 0x100).
  private func run(_ chunks: String...) -> [UInt8] {
    var filter = RemoteQueryFilter()
    return chunks.flatMap { filter.push($0.unicodeScalars.map { UInt8($0.value) }) }
  }

  private func bytes(_ text: String) -> [UInt8] {
    text.unicodeScalars.map { UInt8($0.value) }
  }

  @Test func plainTextAndColoursPass() {
    #expect(run("a\u{1b}[31mb\u{1b}[0m") == bytes("a\u{1b}[31mb\u{1b}[0m"))
  }

  @Test func da1Da2Da3AreDropped() {
    #expect(run("x\u{1b}[c\u{1b}[0c\u{1b}[>c\u{1b}[=cy") == bytes("xy"))
  }

  @Test func dsrAndDecdsrAreDropped() {
    #expect(run("\u{1b}[5n\u{1b}[6n\u{1b}[?6n").isEmpty)
  }

  @Test func decrqmAndPrivateDecrqmAreDropped() {
    #expect(run("\u{1b}[4$p\u{1b}[?2004$p").isEmpty)
  }

  @Test func xtversionIsDropped() {
    #expect(run("\u{1b}[>0q").isEmpty)
  }

  @Test func everyCsiTIsDropped() {
    #expect(run("\u{1b}[14t\u{1b}[8;40;120t").isEmpty)
  }

  @Test func theKittyQueryIsDroppedPushAndPopPass() {
    #expect(run("\u{1b}[?u\u{1b}[>1u\u{1b}[<u") == bytes("\u{1b}[>1u\u{1b}[<u"))
  }

  @Test func decrqssAndXtgettcapAreDropped() {
    #expect(run("\u{1b}P$qm\u{1b}\\\u{1b}P+q544e\u{1b}\\").isEmpty)
  }

  @Test func osc4_10_11_12WithAQuestionMarkAreDroppedTheTitlePasses() {
    let title = Array("\u{1b}]2;заглавие\u{07}".utf8)
    var filter = RemoteQueryFilter()
    let queries = Array("\u{1b}]11;?\u{07}\u{1b}]10;?\u{1b}\\\u{1b}]4;1;?\u{07}\u{1b}]12;?\u{07}".utf8)
    #expect(filter.push(queries) + filter.push(title) == title)
  }

  @Test func osc11WithAValuePasses() {
    #expect(run("\u{1b}]11;rgb:00/00/00\u{07}") == bytes("\u{1b}]11;rgb:00/00/00\u{07}"))
  }

  @Test func mouseModesAndAlternateScreenPass() {
    #expect(run("\u{1b}[?1049h\u{1b}[?1006h") == bytes("\u{1b}[?1049h\u{1b}[?1006h"))
  }

  @Test func aDcsThatIsNotAQueryPasses() {
    #expect(run("\u{1b}Pq#0;2;0;0;0\u{1b}\\") == bytes("\u{1b}Pq#0;2;0;0;0\u{1b}\\"))
  }

  @Test func anEscSequenceWithoutACsiPasses() {
    #expect(run("\u{1b}7a\u{1b}8\u{1b}(B") == bytes("\u{1b}7a\u{1b}8\u{1b}(B"))
  }

  @Test func aQuerySplitAcrossTwoChunksIsDropped() {
    #expect(run("a\u{1b}[", "6nb") == bytes("ab"))
  }

  @Test func anEscAtTheEndOfAChunkWaitsForTheNext() {
    #expect(run("a\u{1b}", "[cb") == bytes("ab"))
  }

  @Test func anOscQuerySplitAcrossTwoChunksIsDropped() {
    #expect(run("\u{1b}]11", ";?\u{07}z") == bytes("z"))
  }

  @Test func cyrillicSplitAcrossTwoChunksComesOutWhole() {
    var filter = RemoteQueryFilter()
    let utf8 = Array("ж".utf8)
    let out = filter.push([utf8[0]]) + filter.push([utf8[1]])
    #expect(String(bytes: out, encoding: .utf8) == "ж")
  }

  @Test func anUnclosedOscIsLetThroughAfterMaxPendingBytes() {
    var filter = RemoteQueryFilter()
    let big = Array("\u{1b}]2;".utf8) + [UInt8](repeating: 0x61, count: RemoteQueryFilter.maxPending)
    #expect(filter.push(big) == big)
    #expect(filter.push(bytes("b\u{1b}[6n")) == bytes("b"))
  }

  // An interrupted sequence is closed with CAN, otherwise the dropped query after it would leave
  // the local terminal inside it, swallowing the text that follows.
  @Test func anOscInterruptedByAQueryIsClosedWithCan() {
    #expect(run("\u{1b}]2;old\u{1b}[6nhello\u{07}") == bytes("\u{1b}]2;old\u{18}hello\u{07}"))
  }

  @Test func aCsiInterruptedByAQueryIsClosedWithCan() {
    #expect(run("\u{1b}[1\u{1b}[6nX") == bytes("\u{1b}[1\u{18}X"))
  }

  // CAN and SUB interrupt a sequence in the terminal too.
  @Test func canInterruptsAnOscAndTheTextAfterItPasses() {
    #expect(run("\u{1b}]11;?\u{18}hello\u{07}") == bytes("\u{1b}]11;?\u{18}hello\u{07}"))
  }

  @Test func subInterruptsADcs() {
    #expect(run("\u{1b}P$q\u{1a}hi") == bytes("\u{1b}P$q\u{1a}hi"))
  }

  @Test func canInterruptsACsi() {
    #expect(run("\u{1b}[6\u{18}n") == bytes("\u{1b}[6\u{18}n"))
  }

  @Test func supacodesPresenceSignalIsDroppedInBothEndings() {
    var filter = RemoteQueryFilter()
    #expect(filter.push(Array("a\u{1b}]3008;x=1\u{07}b".utf8)) == Array("ab".utf8))
    #expect(filter.push(Array("\u{1b}]3008;y\u{1b}\\c".utf8)) == Array("c".utf8))
  }

  @Test func aQuerySplitAcrossTwoPushesIsDroppedWhole() {
    var filter = RemoteQueryFilter()
    #expect(filter.push([0x1b, 0x5b]).isEmpty)
    #expect(filter.push(Array("c!".utf8)) == Array("!".utf8))
  }

  @Test func aBrokenSequenceIsLetThroughAfterTheCap() {
    var filter = RemoteQueryFilter()
    let broken = [0x1b, 0x5d] + [UInt8](repeating: 0x41, count: RemoteQueryFilter.maxPending)
    #expect(filter.push(broken) == broken)
  }

  @Test func aTitleAndAColourSetPass() {
    var filter = RemoteQueryFilter()
    let text = Array("\u{1b}]2;title\u{07}\u{1b}]10;#ffffff\u{07}\u{1b}[31m".utf8)
    #expect(filter.push(text) == text)
  }

  // M-c: the clipboard read (OSC 52 with `?` as its data), DECID (`ESC Z`) and a query behind a
  // doubled ESC are queries too.
  @Test func anOsc52ClipboardReadIsDroppedInBothEndings() {
    #expect(run("a\u{1b}]52;c;?\u{07}b\u{1b}]52;;?\u{1b}\\c") == bytes("abc"))
  }

  @Test func anOsc52ClipboardReadSplitAcrossTwoPushesIsDropped() {
    #expect(run("a\u{1b}]52;c", ";?\u{07}b") == bytes("ab"))
  }

  @Test func anOsc52ClipboardWritePasses() {
    let write = "\u{1b}]52;c;aGVsbG8=\u{07}\u{1b}]52;c;!\u{1b}\\"
    #expect(run(write) == bytes(write))
  }

  @Test func decidIsDroppedWholeOrSplit() {
    #expect(run("a\u{1b}Zb") == bytes("ab"))
    #expect(run("a\u{1b}", "Zb") == bytes("ab"))
  }

  @Test func backTabAndOtherEscFinalsPass() {
    #expect(run("\u{1b}[Z\u{1b}c\u{1b}=") == bytes("\u{1b}[Z\u{1b}c\u{1b}="))
  }

  /// In a terminal the second ESC starts the sequence again, so `ESC ESC [ c` asks for DA1.
  @Test func aQueryBehindADoubledEscIsDropped() {
    #expect(run("a\u{1b}\u{1b}[cb") == bytes("ab"))
    #expect(run("a\u{1b}", "\u{1b}[", "cb") == bytes("ab"))
    #expect(run("a\u{1b}\u{1b}\u{1b}Zb") == bytes("ab"))
  }

  @Test func aSequenceBehindADoubledEscStillPasses() {
    #expect(run("\u{1b}\u{1b}[31mx") == bytes("\u{1b}[31mx"))
  }

  @Test func otherOscNumbersThatStartLike3008Pass() {
    let text = Array("\u{1b}]30080;x\u{07}\u{1b}]300;x\u{07}".utf8)
    var filter = RemoteQueryFilter()
    #expect(filter.push(text) == text)
  }
}
