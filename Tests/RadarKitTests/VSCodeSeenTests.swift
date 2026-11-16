import Foundation
import Testing
@testable import RadarKit

@Suite struct VSCodeUnreadTests {
  let start = Date(timeIntervalSince1970: 1_000_000)

  @Test func replyFinishedAfterVSCodeWasLastInFrontIsUnread() {
    #expect(VSCodeSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, lastFront: start + 50))
    #expect(!VSCodeSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, lastFront: start + 150))
  }

  @Test func busySessionIsNotUnread() {
    #expect(!VSCodeSeen.isUnread(idle: false, idleSince: start + 100, startedAt: start, lastFront: start))
  }

  @Test func idleRightAfterStartupIsNotUnread() {
    #expect(!VSCodeSeen.isUnread(idle: true, idleSince: start + 4, startedAt: start, lastFront: start - 100))
    #expect(VSCodeSeen.isUnread(idle: true, idleSince: start + 60, startedAt: start, lastFront: start - 100))
  }

  @Test func startsAsSeenAndIsPersisted() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url.appendingPathComponent("radar"))
    // The first time, everything before now counts as seen, so installing the app doesn't mark old replies unread.
    let seen = VSCodeSeen(paths: paths, now: start)
    #expect(seen.lastFront == start)
    seen.markFront(at: start + 100)
    #expect(VSCodeSeen(paths: paths, now: start + 200).lastFront == start + 100)
  }
}

@Suite struct VSCodeUnreadIntegrationTests {
  /// A reply that finished while VS Code wasn't in front is unread, even though the extension didn't mark it,
  /// until VS Code comes to the front.
  @Test func replyFinishedWhileVSCodeWasInTheBackgroundIsUnread() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                           claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    let folder = root.url.appendingPathComponent("proj").standardizedFileURL.path
    let fm = FileManager.default
    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("ide"), withIntermediateDirectories: true)
    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try fm.createDirectory(at: paths.radarHome, withIntermediateDirectories: true)
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let now = Date().timeIntervalSince1970
    try JSONSerialization.data(withJSONObject: ["pid": pid, "workspaceFolders": [folder]])
      .write(to: paths.claudeHome.appendingPathComponent("ide/1.lock"))
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": "ext1", "cwd": folder, "status": "idle", "entrypoint": "claude-vscode",
      "kind": "interactive", "startedAt": (now - 600) * 1000, "statusUpdatedAt": (now - 10) * 1000,
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))
    try JSONSerialization.data(withJSONObject: ["lastFront": now - 60])
      .write(to: paths.radarHome.appendingPathComponent("vscode-front.json"))

    let radar = Radar(paths: paths, providers: [ClaudeCodeProvider(paths: paths)])
    #expect(radar.scan().active.first?.conversations.first?.state == .unread)
    radar.markVSCodeFront()
    #expect(radar.scan().active.first?.conversations.first?.state == .open)
  }
}
