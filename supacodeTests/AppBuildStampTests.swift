import Testing

@testable import supacode

struct AppBuildStampTests {
  @Test func lineJoinsTheBuildClockAndShortCommit() {
    #expect(AppBuildStamp.line(date: "2026-10-02 14:25", commit: "0be38e07") == "2026-10-02 14:25 · 0be38e07")
  }

  @Test func lineKeepsADirtyCommitMarker() {
    #expect(
      AppBuildStamp.line(date: "2026-10-02 14:25", commit: "0be38e07-dirty") == "2026-10-02 14:25 · 0be38e07-dirty")
  }
}
