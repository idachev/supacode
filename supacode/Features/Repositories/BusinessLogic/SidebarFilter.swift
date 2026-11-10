import Foundation
import IdentifiedCollections

/// The sidebar filter's text matcher. Ported from Supacode Remote (Android
/// `FuzzyMatch.kt` / `SessionGroups.filter`, web `fuzzy-match.js`) so the Mac
/// sidebar finds the same rows the phone and the browser find for the same text.
///
/// One trimmed, lowercased needle (no tokens, no diacritic folding). A text
/// matches when it contains the needle, or when some substring of it is within
/// `allowedErrors` edits of the needle: a missing, extra or changed character,
/// or two swapped neighbours, one edit each. The budget grows with the needle so
/// a short word does not match almost everything.
nonisolated struct SidebarFilter: Equatable, Sendable {
  /// Trimmed, lowercased query; never empty.
  let needle: String
  private let needleCharacters: [Character]

  /// Nil for an empty or whitespace-only query: the sidebar is then unfiltered.
  init?(query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    needle = trimmed.lowercased()
    needleCharacters = Array(needle)
  }

  /// Up to 3 characters: exact substring only; 4-5: one edit; 6 and more: two.
  static func allowedErrors(forLength length: Int) -> Int {
    switch length {
    case ...3: 0
    case 4...5: 1
    default: 2
    }
  }

  func matches(_ text: String?) -> Bool {
    guard let text, !text.isEmpty else { return false }
    let haystack = text.lowercased()
    if haystack.contains(needle) { return true }
    let maxErrors = Self.allowedErrors(forLength: needleCharacters.count)
    return maxErrors > 0 && Self.bestDistance(Array(haystack), needleCharacters) <= maxErrors
  }

  /// The smallest edit distance between `query` and any substring of `text`
  /// (Sellers, with adjacent transposition as in Damerau). Starting anywhere in
  /// `text` is free, so the first row is zeros; the end is the smallest value in
  /// the last column. Three rows are kept because a transposition looks two back.
  static func bestDistance(_ text: [Character], _ query: [Character]) -> Int {
    let queryCount = query.count
    var previous2 = [Int](repeating: 0, count: queryCount + 1)
    var previous = Array(0...queryCount)
    var best = previous[queryCount]
    guard queryCount > 0 else { return best }
    for textIndex in text.indices {
      var current = [Int](repeating: 0, count: queryCount + 1)
      for queryIndex in 1...queryCount {
        let cost = query[queryIndex - 1] == text[textIndex] ? 0 : 1
        var distance = min(previous[queryIndex] + 1, current[queryIndex - 1] + 1, previous[queryIndex - 1] + cost)
        if queryIndex > 1, textIndex > 0,
          query[queryIndex - 1] == text[textIndex - 1], query[queryIndex - 2] == text[textIndex]
        {
          distance = min(distance, previous2[queryIndex - 2] + 1)
        }
        current[queryIndex] = distance
      }
      best = min(best, current[queryCount])
      previous2 = previous
      previous = current
    }
    return best
  }
}

extension RepositoriesFeature.State {
  /// Repositories whose displayed sidebar name matches: their sections keep
  /// every row while filtering. The name is the one the section header shows
  /// (custom title, else the repository or folder name), the same value the
  /// remote host sends the phone as `repo.name`.
  func sidebarFilterMatchedRepositoryIDs(_ filter: SidebarFilter) -> Set<Repository.ID> {
    let localRootsByID: [Repository.ID: URL] = Dictionary(
      repositoryRoots.map {
        (RepositoryID($0.standardizedFileURL.path(percentEncoded: false)), $0.standardizedFileURL)
      },
      uniquingKeysWith: { first, _ in first }
    )
    var ids = Set(repositories.ids).union(localRootsByID.keys)
    ids = ids.filter { filter.matches(repositorySidebarSortName(for: $0, localRootsByID: localRootsByID)) }
    return ids
  }

  /// Whether a row stays while filtering: its repository's name matched, or
  /// the row's own title (custom, else displayed name), name or branch does.
  func sidebarFilterKeepsRow(
    _ id: SidebarItemID,
    filter: SidebarFilter,
    matchedRepositoryIDs: Set<Repository.ID>
  ) -> Bool {
    if let item = sidebarItems[id: id] {
      if matchedRepositoryIDs.contains(item.repositoryID) { return true }
      return filter.matches(item.resolvedSidebarTitle) || filter.matches(item.name)
        || filter.matches(item.branchName)
    }
    // A pending row with no item yet: only its repository or typed title can match.
    guard let pending = pendingWorktrees.first(where: { $0.id == id }) else { return false }
    return matchedRepositoryIDs.contains(pending.repositoryID) || filter.matches(pending.customization?.title)
  }

  /// One repository-level section while filtering, or nil when nothing in it
  /// is left to show. A repository whose name matched keeps all its rows; any
  /// other keeps only its matching rows and drops out when none is left (a
  /// match that lives only in Active / Pinned does not keep an empty header).
  func sidebarFilteredSection(
    _ section: SidebarStructure.Section,
    filter: SidebarFilter,
    matchedRepositoryIDs: Set<Repository.ID>
  ) -> SidebarStructure.Section? {
    switch section {
    case .repository(let repositoryID, let groups):
      if matchedRepositoryIDs.contains(repositoryID) { return section }
      let kept = groups.map { group in
        SidebarItemGroup(
          slot: group.slot,
          repositoryID: group.repositoryID,
          rowIDs: group.rowIDs.filter {
            sidebarFilterKeepsRow($0, filter: filter, matchedRepositoryIDs: matchedRepositoryIDs)
          }
        )
      }
      guard kept.contains(where: { !$0.rowIDs.isEmpty }) else { return nil }
      return .repository(repositoryID: repositoryID, groups: kept)
    case .folder(let repositoryID, let rowID):
      if matchedRepositoryIDs.contains(repositoryID) { return section }
      return sidebarFilterKeepsRow(rowID, filter: filter, matchedRepositoryIDs: matchedRepositoryIDs)
        ? section : nil
    case .failedRepository(let repositoryID, _, _, _, _), .environmentBlockedRepository(let repositoryID, _, _, _):
      return matchedRepositoryIDs.contains(repositoryID) ? section : nil
    case .highlight, .repositoryGroup, .placeholder:
      return section
    }
  }
}
