import Foundation

/// Remembers which replies in VS Code the user has surely seen, so the others count as unread even when the
/// Claude Code extension shows a gray dot. Without knowing which VS Code window is in front, the app is only sure
/// when VS Code is the frontmost app with a single window, when the user marks a conversation as read, or, with
/// Agent Radar's VS Code extension installed, when its tab is in front of the focused window (see `VSCodeCompanion`).
///
/// TODO: workaround for the Claude Code extension ignoring window focus when it decides a reply was seen
/// (https://github.com/anthropics/claude-code/issues/110457). Remove it when that's fixed, and read the unread
/// state from the session file if https://github.com/anthropics/claude-code/issues/110458 lands.
/// Tracked in https://github.com/WebHare/agent-radar/issues/3; the options are compared in
/// https://github.com/WebHare/agent-radar/issues/7.
///
/// Stored in `~/.agent-radar/vscode-front.json`. Not thread-safe: use from one queue.
final class VSCodeSeen {
  /// How often `lastSure` is written to disk while it keeps advancing. A restart may lose this much, which at
  /// worst marks a reply unread that the user saw.
  static let saveInterval: TimeInterval = 30

  private let url: URL
  /// When all VS Code conversations were last surely seen.
  private(set) var lastSure: Date
  /// Session ID → when the user marked it as read (or opened it from the menu).
  private(set) var read: [String: Date] = [:]
  /// Session ID → when its tab was last in front of the focused VS Code window, according to the extension.
  private(set) var inFront: [String: Date] = [:]
  private var savedSure: Date
  /// When `inFront` was last written to disk; it changes on nearly every scan while a tab is in front.
  private var savedInFront = Date.distantPast

  /// The first time, everything before `now` counts as seen, so old replies don't all turn unread.
  init(paths: RadarPaths, now: Date = Date()) {
    url = paths.radarHome.appendingPathComponent("vscode-front.json")
    let raw = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    // `lastFront` is what the first version of this file called it.
    if let seconds = (raw?["lastSure"] ?? raw?["lastFront"]) as? Double {
      lastSure = Date(timeIntervalSince1970: seconds)
      read = ((raw?["read"] as? [String: Double]) ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
      inFront = ((raw?["inFront"] as? [String: Double]) ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
      savedSure = lastSure
    } else {
      lastSure = now
      savedSure = now
      save()
    }
  }

  /// When the user last surely saw this conversation.
  func seenSince(_ sessionId: String) -> Date {
    max(lastSure, read[sessionId] ?? .distantPast, inFront[sessionId] ?? .distantPast)
  }

  /// The user surely sees every VS Code conversation's latest reply now.
  func markAllSeen(at date: Date = Date()) {
    lastSure = date
    if date.timeIntervalSince(savedSure) >= Self.saveInterval { save() }
  }

  func markRead(_ sessionIds: [String], at date: Date = Date()) {
    guard !sessionIds.isEmpty else { return }
    for id in sessionIds { read[id] = date }
    save()
  }

  /// Session ID → when its tab was last seen in front of the focused window. Only moves forward. Saved right away
  /// for a conversation seen for the first time, otherwise at most every `saveInterval`.
  func markInFront(_ seen: [String: Date], now: Date = Date()) {
    var isNew = false
    for (id, date) in seen where date > (inFront[id] ?? .distantPast) {
      isNew = isNew || inFront[id] == nil
      inFront[id] = date
    }
    if isNew || (now.timeIntervalSince(savedInFront) >= Self.saveInterval && !seen.isEmpty) { save() }
  }

  /// Forgets marks of conversations that are gone.
  func prune(keeping ids: Set<String>) {
    let before = read.count + inFront.count
    read = read.filter { ids.contains($0.key) }
    inFront = inFront.filter { ids.contains($0.key) }
    if read.count + inFront.count != before { save() }
  }

  /// Whether an idle session has a reply that finished after the user last surely saw it.
  static func isUnread(idle: Bool, idleSince: Date?, startedAt: Date?, seenSince: Date) -> Bool {
    guard idle, let idleSince else { return false }
    let startup = startedAt.map { $0.addingTimeInterval(TerminalSeen.startupGrace) } ?? .distantPast
    return idleSince > max(seenSince, startup)
  }

  /// Why an idle session counts as unread or not, for the troubleshooting log.
  func explain(idleSince: Date?, startedAt: Date?, sessionId: String) -> String {
    guard let idleSince else { return "idle, but the session file doesn't say since when" }
    let finished = "its reply finished at \(DebugLog.time(idleSince))"
    let read = read[sessionId] ?? .distantPast, front = inFront[sessionId] ?? .distantPast
    let seen = if front >= lastSure && front >= read {
      "its tab was last in front in the focused VS Code window at \(DebugLog.time(front))"
    } else if read >= lastSure {
      "you marked it as read (or opened it from the menu) at \(DebugLog.time(read))"
    } else {
      "Agent Radar was last sure you saw VS Code's replies at \(DebugLog.time(lastSure)) (VS Code in front with one window)"
    }
    if let startedAt, idleSince <= startedAt.addingTimeInterval(TerminalSeen.startupGrace) {
      return "it went idle right after starting, which isn't a reply"
    }
    return Self.isUnread(idle: true, idleSince: idleSince, startedAt: startedAt, seenSince: seenSince(sessionId))
      ? "\(finished), after \(seen)"
      : "\(finished), before \(seen)"
  }

  private func save() {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let raw: [String: Any] = ["lastSure": lastSure.timeIntervalSince1970,
                              "read": read.mapValues { $0.timeIntervalSince1970 },
                              "inFront": inFront.mapValues { $0.timeIntervalSince1970 }]
    if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
      try? data.write(to: url, options: .atomic)
      savedSure = lastSure
      savedInFront = Date()
    }
  }
}
