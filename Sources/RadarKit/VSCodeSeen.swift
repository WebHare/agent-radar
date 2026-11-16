import Foundation

/// Remembers when VS Code was last the frontmost app, so a reply that finished after that counts as unread.
///
/// TODO: workaround for the Claude Code extension ignoring window focus when it decides a reply was seen
/// (https://github.com/anthropics/claude-code/issues/110457). Remove it when that's fixed, and read the unread
/// state from the session file if https://github.com/anthropics/claude-code/issues/110458 lands.
/// Tracked in https://github.com/WebHare/agent-radar/issues/3.
///
/// Stored in `~/.agent-radar/vscode-front.json`. Not thread-safe: use from one queue.
final class VSCodeSeen {
  /// How often the time is written to disk while VS Code stays in front. A restart may lose this much, which
  /// at worst marks a reply unread that the user saw.
  static let saveInterval: TimeInterval = 30

  private let url: URL
  private(set) var lastFront: Date
  private var savedFront: Date

  /// The first time, everything before `now` counts as seen, so old replies don't all turn unread.
  init(paths: RadarPaths, now: Date = Date()) {
    url = paths.radarHome.appendingPathComponent("vscode-front.json")
    if let data = try? Data(contentsOf: url),
       let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
       let seconds = raw["lastFront"] {
      lastFront = Date(timeIntervalSince1970: seconds)
      savedFront = lastFront
    } else {
      lastFront = now
      savedFront = now
      save()
    }
  }

  /// VS Code is the frontmost app now.
  func markFront(at date: Date = Date()) {
    lastFront = date
    if date.timeIntervalSince(savedFront) >= Self.saveInterval { save() }
  }

  /// Whether an idle session has a reply that finished after VS Code was last in front.
  static func isUnread(idle: Bool, idleSince: Date?, startedAt: Date?, lastFront: Date) -> Bool {
    guard idle, let idleSince else { return false }
    let startup = startedAt.map { $0.addingTimeInterval(TerminalSeen.startupGrace) } ?? .distantPast
    return idleSince > max(lastFront, startup)
  }

  private func save() {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: ["lastFront": lastFront.timeIntervalSince1970]) {
      try? data.write(to: url, options: .atomic)
      savedFront = lastFront
    }
  }
}
