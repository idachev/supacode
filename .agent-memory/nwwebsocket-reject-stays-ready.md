---
name: nwwebsocket-reject-stays-ready
description: Read before changing the LAN shortcut's WebSocket upgrade or auth; NWProtocolWebSocket `.reject` does not close the connection.
paths:
  - supacode/Features/RemoteAccess/RemoteLANServer.swift
  - supacodeTests/RemoteAccessLANServerTests.swift
---

# `.reject` from a WebSocket client request handler does not close the connection

With `NWProtocolWebSocket.Options.setClientRequestHandler` returning `Response(status: .reject, ...)`,
the server-side `NWConnection` still reaches `.ready`, and the client gets no HTTP response
(a `URLSessionWebSocketTask` then hangs on send/receive forever). Treating `.ready` as
"authenticated" lets a wrong key in: commit a268700c did exactly that, and only the wrong-key
test's timeout showed it.

The handler cannot tell which connection it serves, so `RemoteLANServer` puts a marker header
(`X-Supacode-LAN: 1`) only on the accepted response, and `LANPeer` reads
`(connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.additionalServerHeaders`
on `.ready` and closes the connection when the marker is missing. Keep that check when you touch
the upgrade path.

A test that a refused upgrade fails waits on the task's `URLSessionWebSocketDelegate`
(`didCompleteWithError` / `didClose`) with a bounded wait, never on send/receive.
