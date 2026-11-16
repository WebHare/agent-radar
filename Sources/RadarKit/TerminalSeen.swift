import Foundation

/// Remembers when the user last looked at each terminal session (its Terminal.app tab was in front), so a
/// reply that finished after that counts as unread. Terminals have no unread state of their own.
/// Stored in `~/.agent-radar/terminal-seen.json`. Not thread-safe: use from one queue.
final class TerminalSeen {
  /// A session that became idle within this time after it started has only finished starting up, not replied.
  static let startupGrace: TimeInterval = 15

  private let url: URL
  /// Session ID → time last seen.
  private(set) var seen: [String: Date] = [:]

  init(paths: RadarPaths) {
    url = paths.radarHome.appendingPathComponent("terminal-seen.json")
    if let data = try? Data(contentsOf: url),
       let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
      seen = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }
  }

  func markSeen(_ sessionIds: [String], at date: Date = Date()) {
    guard !sessionIds.isEmpty else { return }
    for id in sessionIds { seen[id] = date }
    save()
  }

  /// Forgets sessions that no longer run.
  func prune(keeping live: Set<String>) {
    let before = seen.count
    seen = seen.filter { live.contains($0.key) }
    if seen.count != before { save() }
  }

  /// Whether an idle session has a reply the user hasn't seen: it became idle after it was last seen.
  static func isUnread(idle: Bool, idleSince: Date?, startedAt: Date?, lastSeen: Date?) -> Bool {
    guard idle, let idleSince else { return false }
    let baseline = lastSeen ?? startedAt.map { $0.addingTimeInterval(startupGrace) } ?? .distantFuture
    return idleSince > baseline
  }

  private func save() {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let raw = seen.mapValues { $0.timeIntervalSince1970 }
    if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
      try? data.write(to: url, options: .atomic)
    }
  }
}
