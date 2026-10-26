---
name: reducer-cancel-id-isolation
description: Read before adding a cancel id to a TCA reducer, or when the build fails with "main actor-isolated conformance ... Sendable".
paths:
  - supacode/Features/**/Reducer/*.swift
---

# A cancel-id enum whose cases are the id must be `nonisolated`

The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. An enum whose cases are used
directly as the id, e.g. `enum AgentResumeCancelID: Hashable { case wake }` with
`.cancellable(id: AgentResumeCancelID.wake)`, gets a MainActor-isolated `Hashable` conformance and
fails to build: "main actor-isolated conformance of '...' to 'Hashable' cannot satisfy conformance
requirement for a 'Sendable' type parameter [#IsolatedConformances]".

Declare it `nonisolated enum ...CancelID: Hashable, Sendable`, as `TerminalsFeature`, `LicenseFeature`
and `AgentPresenceFeature` do. The other pattern in the repo, `private enum CancelID` with
`static let` String ids (`AppFeature`, `RepositoriesFeature`), builds fine as is.

**Why:** on 2026-10-26 this stopped `make build-app` after review, because writers do not compile.
