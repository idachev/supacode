import Foundation
import Testing

@testable import supacode

struct RemoteClientModelsTests {
  @Test func theKeyFileSplitsAtTheLastSlash() {
    #expect(
      RemoteClientKey.parse("relay.example.com/abcde-fghij\n")
        == RemoteClientKey(relayHost: "relay.example.com", key: "abcde-fghij"))
    #expect(
      RemoteClientKey.parse("http://10.0.2.2:8787/test-key")
        == RemoteClientKey(relayHost: "http://10.0.2.2:8787", key: "test-key"))
    for bad in ["", "onlykey", "/key", "relay.example.com/", "   ", "http://onlyhost"] {
      #expect(RemoteClientKey.parse(bad) == nil)
    }
  }

  @Test func theKeyFileLoadsFromDisk() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "remote-client-key-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try "relay.example.com/abcde-fghij\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(RemoteClientKey.load(from: url) == RemoteClientKey(relayHost: "relay.example.com", key: "abcde-fghij"))
    let missing = url.deletingLastPathComponent().appending(path: "missing-\(UUID().uuidString).txt")
    #expect(RemoteClientKey.load(from: missing) == nil)
  }

  @Test func theClientURLCarriesTheHost() {
    let key = RemoteClientKey(relayHost: "relay.example.com", key: "k")
    #expect(
      key.clientURL(hostID: "3f9a0c1d2e4b5a69")?.absoluteString
        == "wss://relay.example.com/client?host=3f9a0c1d2e4b5a69")
    #expect(key.clientURL(hostID: nil)?.absoluteString == "wss://relay.example.com/client")
    #expect(
      RemoteClientKey(relayHost: "http://10.0.2.2:8787", key: "k").clientURL(hostID: nil)?.absoluteString
        == "ws://10.0.2.2:8787/client")
    #expect(
      RemoteClientKey(relayHost: "https://relay.example.com", key: "k").clientURL(hostID: nil)?.absoluteString
        == "wss://relay.example.com/client")
  }

  @Test func theProtocolDocsListExampleDecodes() {
    guard case .list(let list) = RemoteClientFrame.decode(Self.listExample) else {
      Issue.record("not a list")
      return
    }
    #expect(list.id == 1)
    #expect(list.canRefreshWorktrees)
    let worktree = list.repos.first?.worktrees.first
    #expect(list.repos.first?.group == "Work")
    #expect(list.repos.first?.canCreateWorktree == true)
    #expect(list.repos.first?.rowIds == ["/w"])
    #expect(worktree?.status == "pinned")
    #expect(worktree?.title == nil)
    #expect(worktree?.canDeleteWorktree == false)
    #expect(worktree?.tabs.first?.contentId == "C1")
    #expect(worktree?.tabs.first?.agents.first?.activity == "busy")
    #expect(worktree?.layout?.mode == "tabsPerSplit")
    #expect(worktree?.layout?.groups.first?.id == "main")
    #expect(worktree?.layout?.groups.first?.zoomedPaneId == nil)
    #expect(worktree?.layout?.panes.first?.selectedTabId == "T1")
    #expect(list.sections.map(\.kind) == ["active", "pinned", "group", "repository"])
    #expect(list.sections[2].collapsed == true)
    #expect(list.sections[2].repositoryIds == ["/r"])
    #expect(list.sections[3].repositoryId == "/r")
    #expect(list.loadFailures == [RemoteClientLoadFailure(repositoryId: "/bad", message: "not a git repository")])
  }

  @Test func unknownStringsAndMissingFieldsStillDecode() {
    let text =
      #"{"t":"list","id":null,"repos":[{"id":"r","worktrees":[{"id":"w","status":"future","#
      + #""tabs":[{"id":"t","agents":[{"agent":"x","activity":"dreaming"}]}]}]}],"#
      + #""sections":[{"kind":"shelf"}]}"#
    guard case .list(let list) = RemoteClientFrame.decode(text) else {
      Issue.record("not a list")
      return
    }
    #expect(list.id == nil)
    #expect(list.repos[0].worktrees[0].status == "future")
    #expect(list.repos[0].worktrees[0].layout == nil)
    #expect(list.repos[0].worktrees[0].tabs[0].agents[0].activity == "dreaming")
    #expect(list.sections[0].kind == "shelf")
    #expect(list.canRefreshWorktrees == false)
  }

  @Test func nullFieldsTakeTheirDefaults() {
    let text = #"{"t":"list","id":2,"repos":[{"id":"r","name":null,"group":null,"worktrees":null,"rowIds":null}]}"#
    guard case .list(let list) = RemoteClientFrame.decode(text) else {
      Issue.record("not a list")
      return
    }
    #expect(list.repos[0].name == "")
    #expect(list.repos[0].worktrees.isEmpty)
    #expect(list.repos[0].rowIds.isEmpty)
  }

  @Test func anIdentifiedTypeWithoutAnIDIsNoFrame() {
    #expect(RemoteClientFrame.decode(#"{"t":"list","repos":[{"name":"no id"}]}"#) == nil)
  }

  @Test func theLayoutNodeDecodesBothShapes() throws {
    let json =
      #"{"split":{"direction":"horizontal","ratio":0.25,"left":{"pane":"A"},"right":"#
      + #"{"split":{"direction":"vertical","ratio":0.5,"left":{"pane":"B"},"right":{"pane":"C"}}}}}"#
    let data = Data(json.utf8)
    let node = try JSONDecoder().decode(RemoteClientLayoutNode.self, from: data)
    #expect(
      node
        == .split(
          direction: "horizontal", ratio: 0.25, left: .pane("A"),
          right: .split(direction: "vertical", ratio: 0.5, left: .pane("B"), right: .pane("C"))))
    #expect(try JSONDecoder().decode(RemoteClientLayoutNode.self, from: Data(#"{"pane":"A"}"#.utf8)) == .pane("A"))
  }

  @Test func aBrokenLayoutDropsOnlyTheLayout() {
    let text =
      #"{"t":"list","id":3,"repos":[{"id":"r","worktrees":[{"id":"w","name":"n","#
      + #""layout":{"groups":[{"id":"main","tree":{"future":1}}]}}]}]}"#
    guard case .list(let list) = RemoteClientFrame.decode(text) else {
      Issue.record("not a list")
      return
    }
    #expect(list.repos[0].worktrees[0].name == "n")
    #expect(list.repos[0].worktrees[0].layout == nil)
  }

  @Test func helloKeepsItsLANAndCaps() {
    let text =
      #"{"t":"hello","v":1,"host":"Mac","hostId":"3f9a","#
      + #""lan":{"addrs":["192.168.1.10"],"port":49731,"fp":"aa","fpMac":"bb"},"#
      + #""app":"Supacode 1","caps":["watch","layout"]}"#
    guard case .hello(let hello) = RemoteClientFrame.decode(text) else {
      Issue.record("not a hello")
      return
    }
    #expect(hello.v == 1)
    #expect(hello.hostId == "3f9a")
    #expect(hello.lan == RemoteClientLAN(addrs: ["192.168.1.10"], port: 49731, fp: "aa", fpMac: "bb"))
    #expect(hello.caps == ["watch", "layout"])
  }

  @Test func relayWithoutHostsIsAnOldRelay() {
    guard case .relay(let status) = RemoteClientFrame.decode(#"{"t":"relay","hostOnline":true}"#) else {
      Issue.record("not a relay")
      return
    }
    #expect(status.hostOnline)
    #expect(status.hosts == nil)
  }

  @Test func relayWithAnEmptyHostsListIsANewRelay() {
    guard case .relay(let status) = RemoteClientFrame.decode(#"{"t":"relay","hostOnline":false,"hosts":[]}"#) else {
      Issue.record("not a relay")
      return
    }
    #expect(status.hosts == [])
  }

  @Test func relayHostsKeepTheirNames() {
    let text =
      #"{"t":"relay","hostOnline":true,"host":"3f9a","hosts":["#
      + #"{"id":"3f9a","name":"Office Mac","online":true},{"id":"a41b","online":false}]}"#
    guard case .relay(let status) = RemoteClientFrame.decode(text) else {
      Issue.record("not a relay")
      return
    }
    #expect(status.host == "3f9a")
    #expect(
      status.hosts == [
        RemoteClientHostInfo(id: "3f9a", name: "Office Mac", online: true),
        RemoteClientHostInfo(id: "a41b", name: nil, online: false),
      ])
  }

  @Test func attachedAndSizeAndDetachedDecode() {
    #expect(
      RemoteClientFrame.decode(#"{"t":"attached","id":2,"contentId":"C","cols":180,"rows":50}"#)
        == .attached(id: 2, contentId: "C", cols: 180, rows: 50))
    #expect(
      RemoteClientFrame.decode(#"{"t":"size","contentId":"C","cols":90,"rows":30}"#)
        == .size(contentId: "C", cols: 90, rows: 30))
    #expect(
      RemoteClientFrame.decode(#"{"t":"detached","contentId":"C","reason":"closed"}"#)
        == .detached(contentId: "C", reason: "closed"))
  }

  @Test func outDecodesItsBytes() {
    #expect(
      RemoteClientFrame.decode(#"{"t":"out","contentId":"C","b64":"DQ=="}"#) == .out(contentId: "C", bytes: [0x0D]))
    #expect(RemoteClientFrame.decode(#"{"t":"out","contentId":"C","b64":"!!!"}"#) == nil)
  }

  @Test func anErrorKeepsItsCode() {
    #expect(
      RemoteClientFrame.decode(#"{"t":"error","id":8,"message":"m","code":"worktree_dirty"}"#)
        == .error(id: 8, message: "m", code: "worktree_dirty", contentId: nil))
    #expect(
      RemoteClientFrame.decode(#"{"t":"error","id":null,"message":"m","code":"resize_failed","contentId":"C"}"#)
        == .error(id: nil, message: "m", code: "resize_failed", contentId: "C"))
  }

  @Test func anotherReplyKeepsItsStringFields() {
    #expect(
      RemoteClientFrame.decode(
        #"{"t":"pane.split","id":7,"worktreeId":"/w","paneId":"P","tabId":"T","contentId":"T"}"#)
        == .reply(
          t: "pane.split", id: 7,
          fields: ["worktreeId": "/w", "paneId": "P", "tabId": "T", "contentId": "T"]))
  }

  @Test func aReplyTextsNumbersAndBooleansAndSkipsTheRest() {
    #expect(
      RemoteClientFrame.decode(#"{"t":"watch","id":5,"on":true,"n":7,"x":null,"o":{"a":1},"l":[1],"s":"v"}"#)
        == .reply(t: "watch", id: 5, fields: ["on": "true", "n": "7", "s": "v"]))
  }

  @Test func pongAndGarbageAreNoFrame() {
    #expect(RemoteClientFrame.decode("pong") == nil)
    #expect(RemoteClientFrame.decode("{}") == nil)
    #expect(RemoteClientFrame.decode("not json") == nil)
    #expect(RemoteClientFrame.decode("[1,2]") == nil)
    #expect(RemoteClientFrame.decode(#"{"t":5}"#) == nil)
  }

  /// The `list` JSON of docs/remote-access-protocol.md, with its `sections` and a `layout`.
  private static let listExample = #"""
    {"t":"list","id":1,"canRefreshWorktrees":true,"repos":[
      {"id":"/r","name":"supacode","group":"Work","canCreateWorktree":true,"rowIds":["/w"],"worktrees":[
        {"id":"/w","name":"remote-access","branch":"remote-access",
         "status":"pinned","focused":true,"title":null,
         "working":true,"canDeleteWorktree":false,"tabs":[
           {"id":"T1","contentId":"C1","title":"claude","focused":true,
            "working":false,"readOnly":false,
            "agents":[{"agent":"claude","activity":"busy"}]}
         ],
         "layout":{
           "mode":"tabsPerSplit",
           "activeGroupId":"main",
           "groups":[
             {"id":"main","focusedPaneId":"P1",
              "tree":{"split":{"direction":"horizontal","ratio":0.5,
                               "left":{"pane":"P1"},"right":{"pane":"P2"}}}}
           ],
           "panes":[{"id":"P1","tabIds":["T1"],"selectedTabId":"T1"},{"id":"P2","tabIds":[]}]
         }}
      ]}
    ],
    "sections":[
      {"kind":"active","title":"Active","worktreeIds":["/w"]},
      {"kind":"pinned","title":"Pinned","worktreeIds":["/w"]},
      {"kind":"group","title":"Work","collapsed":true,"repositoryIds":["/r"]},
      {"kind":"repository","repositoryId":"/r"}
    ],
    "loadFailures":[{"repositoryId":"/bad","message":"not a git repository"}]}
    """#
}
