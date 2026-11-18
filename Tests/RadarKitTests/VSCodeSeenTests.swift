import Foundation
import Testing
@testable import RadarKit

@Suite struct VSCodeUnreadTests {
  let start = Date(timeIntervalSince1970: 1_000_000)

  @Test func replyFinishedAfterLastSeenIsUnread() {
    #expect(VSCodeSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, seenSince: start + 50))
    #expect(!VSCodeSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, seenSince: start + 150))
  }

  @Test func busySessionIsNotUnread() {
    #expect(!VSCodeSeen.isUnread(idle: false, idleSince: start + 100, startedAt: start, seenSince: start))
  }

  @Test func idleRightAfterStartupIsNotUnread() {
    #expect(!VSCodeSeen.isUnread(idle: true, idleSince: start + 4, startedAt: start, seenSince: start - 100))
    #expect(VSCodeSeen.isUnread(idle: true, idleSince: start + 60, startedAt: start, seenSince: start - 100))
  }

  @Test func startsAsSeenAndIsPersisted() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url.appendingPathComponent("radar"))
    // The first time, everything before now counts as seen, so installing the app doesn't mark old replies unread.
    let seen = VSCodeSeen(paths: paths, now: start)
    #expect(seen.seenSince("a") == start)
    seen.markAllSeen(at: start + 100)
    seen.markRead(["a"], at: start + 200)
    let reloaded = VSCodeSeen(paths: paths, now: start + 300)
    #expect(reloaded.seenSince("a") == start + 200)
    #expect(reloaded.seenSince("b") == start + 100)
    reloaded.prune(keeping: ["b"])
    #expect(VSCodeSeen(paths: paths, now: start + 300).seenSince("a") == start + 100)
  }

  @Test func readsTheFileOfTheFrontmostAppVersion() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url)
    try JSONSerialization.data(withJSONObject: ["lastFront": start.timeIntervalSince1970])
      .write(to: root.url.appendingPathComponent("vscode-front.json"))
    #expect(VSCodeSeen(paths: paths, now: start + 500).seenSince("a") == start)
  }
}

/// A VS Code workspace with one Claude Code session in the extension, and VS Code windows open on it.
struct VSCodeFixture {
  let root: TempDir
  let paths: RadarPaths
  let folder: String
  let now = Date().timeIntervalSince1970
  var pid: Int { Int(ProcessInfo.processInfo.processIdentifier) }

  init(windows: Int = 1, lastSeenAgo: TimeInterval = 60, extensionUnread: [String] = []) throws {
    root = try TempDir()
    paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                       claudeHome: root.url.appendingPathComponent("claude"),
                       radarHome: root.url.appendingPathComponent("radar"))
    folder = root.url.appendingPathComponent("proj").standardizedFileURL.path
    let fm = FileManager.default
    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for dir in ["ide", "sessions"] {
      try fm.createDirectory(at: paths.claudeHome.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try fm.createDirectory(at: paths.radarHome, withIntermediateDirectories: true)
    for i in 0..<windows { try openWindow(i) }
    try finishReply(ago: 10)
    try JSONSerialization.data(withJSONObject: ["lastSure": now - lastSeenAgo])
      .write(to: paths.radarHome.appendingPathComponent("vscode-front.json"))
    if !extensionUnread.isEmpty {
      try fm.createDirectory(at: paths.vscodeUser.appendingPathComponent("globalStorage"), withIntermediateDirectories: true)
      let state = try JSONSerialization.data(withJSONObject: ["sessionUnread:\(folder)": extensionUnread])
      try makeStateDB(paths.vscodeUser.appendingPathComponent("globalStorage/state.vscdb"), ["Anthropic.claude-code": state])
    }
  }

  /// Window 0 shows the workspace with the session; others show other folders.
  func openWindow(_ i: Int) throws {
    let shown = i == 0 ? folder : root.url.appendingPathComponent("other\(i)").path
    try JSONSerialization.data(withJSONObject: ["pid": pid, "workspaceFolders": [shown]])
      .write(to: paths.claudeHome.appendingPathComponent("ide/\(i).lock"))
  }

  func closeWindow(_ i: Int) throws {
    try FileManager.default.removeItem(at: paths.claudeHome.appendingPathComponent("ide/\(i).lock"))
  }

  func finishReply(ago: TimeInterval) throws {
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": "ext1", "cwd": folder, "status": "idle", "entrypoint": "claude-vscode",
      "kind": "interactive", "startedAt": (now - 600) * 1000, "statusUpdatedAt": (now - ago) * 1000,
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))
  }
}

@Suite struct VSCodeUnreadIntegrationTests {
  func state(_ radar: Radar) -> ConversationState? {
    radar.scan().active.first?.conversations.first { $0.id == "ext1" }?.state
  }

  /// A reply the extension didn't mark is unread, until VS Code is in front with just one window.
  @Test func replyIsUnreadUntilVSCodeIsInFrontWithOneWindow() throws {
    let fixture = try VSCodeFixture(windows: 2)
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    #expect(state(radar) == .unread)
    // With two windows open, VS Code in front doesn't tell whether the user saw this one.
    radar.markVSCodeFront()
    #expect(state(radar) == .unread)
    try fixture.closeWindow(1)
    radar.markVSCodeFront()
    #expect(state(radar) == .open)
  }

  @Test func markingAsReadClearsUntilTheNextReply() throws {
    let fixture = try VSCodeFixture(windows: 2)
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    #expect(state(radar) == .unread)
    radar.markRead(["ext1"])
    #expect(state(radar) == .open)
    try fixture.finishReply(ago: -5)  // a later reply
    #expect(state(radar) == .unread)
  }

  /// "Mark as read" also hides the extension's own unread dot for the replies it has seen.
  @Test func markingAsReadHidesTheExtensionsUnreadReply() throws {
    let fixture = try VSCodeFixture(windows: 1, lastSeenAgo: 0, extensionUnread: ["ext1"])
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    radar.markVSCodeFront()
    #expect(state(radar) == .unread)  // the extension's dot isn't cleared by VS Code being in front
    radar.markRead(["ext1"])
    #expect(state(radar) == .open)
  }
}
