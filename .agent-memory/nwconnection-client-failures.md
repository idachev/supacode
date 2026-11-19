---
name: nwconnection-client-failures
description: Read before writing a Network.framework WebSocket/TLS client; its handshake failures land in .waiting, and it never shows an HTTP status.
paths:
  - supacode/Features/RemoteClient/RemoteClientSocket.swift
  - supacodeTests/RemoteClientSocketTests.swift
---

# Network.framework client failures land in `.waiting`, and the HTTP status is invisible

As a client, `NWConnection` with `NWProtocolWebSocket` over TLS does not reach `.failed` when the
handshake is refused. A pin rejected in the verify block (`-9808`), an aborted upgrade
(`ECONNABORTED`) and an HTTP 401 before the upgrade all put it in `.waiting`, where it retries by
itself forever. A socket whose owner does its own reconnects must treat `.waiting` as closed.

`NWConnection` never shows the HTTP status of a refused upgrade; a 401 looks like a plain abort.
`URLSessionWebSocketTask` does show it (`task.response as? HTTPURLResponse` in
`didCompleteWithError`). That is why the remote client's relay socket uses URLSession (a 401 or
403 must stop the retries), while the LAN socket uses `NWConnection` for the leaf-certificate pin.

A `URLSession` holds its delegate strongly until it is invalidated, so a socket that is its own
delegate never deinits while open; the relay socket uses a delegate object that holds it weakly.

**Why:** found in the remote-client socket spike (Task 5, 2026-11-19); the first try waited on
`.failed` and never saw a refused pin.
