import Foundation
import Testing
@testable import RadarKit

@Suite struct ArchivedTests {
  @Test func archivedConversationsAreListedOnlyWithAnInterestingState() {
    let tabs: [JSONObject] = [["sessionId": "kept", "title": "Kept"], ["sessionId": "archived", "title": "Old"],
                              ["sessionId": "archivedWorking", "title": "Running"],
                              ["sessionId": "archivedIdle", "title": "Idle"]]
    var waiting = ClaudeCodeProvider.LiveSession(sessionId: "archivedWaiting", cwd: "/w", busy: false)
    waiting.waiting = true
    let live = [ClaudeCodeProvider.LiveSession(sessionId: "archivedWorking", cwd: "/w", busy: true),
                ClaudeCodeProvider.LiveSession(sessionId: "archivedIdle", cwd: "/w", busy: false), waiting]
    let result = ClaudeCodeProvider.merge(tabs: tabs, unread: ["archivedUnread"], live: live, waiting: [],
                                          archived: ["archived", "archivedWorking", "archivedIdle",
                                                     "archivedUnread", "archivedWaiting"])
    #expect(result.map(\.id) == ["kept", "archivedWorking", "archivedUnread", "archivedWaiting"])
    #expect(result.map(\.state) == [.open, .working, .unread, .waiting])
  }
}

@Suite struct TerminalUnreadTests {
  let start = Date(timeIntervalSince1970: 1_000_000)

  @Test func replyAfterLastSeenIsUnread() {
    #expect(TerminalSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, lastSeen: start + 50))
    #expect(!TerminalSeen.isUnread(idle: true, idleSince: start + 100, startedAt: start, lastSeen: start + 150))
  }

  @Test func busySessionIsNotUnread() {
    #expect(!TerminalSeen.isUnread(idle: false, idleSince: start + 100, startedAt: start, lastSeen: nil))
  }

  @Test func idleRightAfterStartupIsNotUnread() {
    #expect(!TerminalSeen.isUnread(idle: true, idleSince: start + 4, startedAt: start, lastSeen: nil))
    #expect(TerminalSeen.isUnread(idle: true, idleSince: start + 60, startedAt: start, lastSeen: nil))
  }

  @Test func seenIsPersistedAndPruned() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url.appendingPathComponent("radar"))
    let seen = TerminalSeen(paths: paths)
    seen.markSeen(["a", "b"], at: start)
    #expect(TerminalSeen(paths: paths).seen["a"] == start)
    seen.prune(keeping: ["b"])
    #expect(TerminalSeen(paths: paths).seen.keys.sorted() == ["b"])
  }
}

@Suite struct TerminalHostTests {
  @Test func classifiesHostApps() {
    #expect(TerminalHost.classify(executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == .terminalApp)
    #expect(TerminalHost.classify(executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron") == .vscode)
    #expect(TerminalHost.classify(executablePath: "/bin/zsh") == nil)
  }

  @Test func readsOwnProcess() {
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    #expect(Processes.parent(of: pid) == Int(getppid()))
    #expect(Processes.executablePath(of: pid) != nil)
  }
}

@Suite struct TerminalIntegrationTests {
  /// A Claude Code session started from a terminal shows up as a terminal folder, unread until its tab is seen.
  @Test func terminalSessionIsGroupedByFolderAndMarkedSeen() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                           claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    let folder = root.url.appendingPathComponent("proj").standardizedFileURL.path
    try FileManager.default.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"),
                                            withIntermediateDirectories: true)
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let now = Date().timeIntervalSince1970 * 1000
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": "term1", "cwd": folder, "status": "idle", "entrypoint": "cli",
      "kind": "interactive", "startedAt": now - 600_000, "statusUpdatedAt": now - 10_000,
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))

    let provider = ClaudeCodeProvider(paths: paths, hostResolver: { _ in (.terminalApp, "/dev/ttys099") })
    let radar = Radar(paths: paths, providers: [provider])
    var sections = radar.scan()
    let workspace = try #require(sections.terminal.first)
    #expect(workspace.name == "proj")
    #expect(workspace.conversations.first?.state == .unread)
    #expect(sections.attentionCount == 1)

    #expect(workspace.conversations.first?.target == .terminal(host: .terminalApp, tty: "/dev/ttys099"))

    radar.markTerminalSeen(tty: "/dev/ttys098")
    #expect(radar.scan().terminal.first?.conversations.first?.state == .unread)
    radar.markTerminalSeen(tty: "/dev/ttys099")
    sections = radar.scan()
    #expect(sections.terminal.first?.conversations.first?.state == .open)
    #expect(sections.attentionCount == 0)
  }

  @Test func integratedTerminalSessionBelongsToVSCodeWorkspace() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                           claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    let folder = root.url.appendingPathComponent("proj").standardizedFileURL.path
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.claudeHome.appendingPathComponent("ide"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    try JSONSerialization.data(withJSONObject: ["pid": pid, "workspaceFolders": [folder]])
      .write(to: paths.claudeHome.appendingPathComponent("ide/1.lock"))
    try JSONSerialization.data(withJSONObject: [
      "pid": pid, "sessionId": "int1", "cwd": folder, "status": "busy", "entrypoint": "cli", "kind": "interactive",
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))

    let provider = ClaudeCodeProvider(paths: paths, hostResolver: { _ in (.vscode, "/dev/ttys050") })
    let sections = Radar(paths: paths, providers: [provider]).scan()
    #expect(sections.terminal.isEmpty)
    #expect(sections.active.first?.workingCount == 1)
  }
}

@Suite struct ActivityTests {
  let now = Date(timeIntervalSince1970: 10_000_000)

  @Test func formatsShortAges() {
    #expect(AgeFormatter.short(since: now - 20, now: now) == "now")
    #expect(AgeFormatter.short(since: now - 15 * 60, now: now) == "15m")
    #expect(AgeFormatter.short(since: now - 3 * 3600 - 59, now: now) == "3h")
    #expect(AgeFormatter.short(since: now - 2 * 86400, now: now) == "2d")
    #expect(AgeFormatter.short(since: now - 20 * 86400, now: now) == "2w")
    #expect(AgeFormatter.short(since: now - 400 * 86400, now: now) == "1y")
    #expect(AgeFormatter.short(since: now + 60, now: now) == "now")
  }

  @Test func foldoutListsAttentionFirstThenMostRecent() {
    func c(_ id: String, _ state: ConversationState, _ age: TimeInterval?) -> Conversation {
      Conversation(id: id, title: id, state: state, provider: "t", lastActivity: age.map { now - $0 })
    }
    let ws = Workspace(id: "w", name: "w", openTarget: URL(fileURLWithPath: "/w"), isOpen: true, lastUsed: now,
                       conversations: [c("old", .open, 900), c("unknown", .open, nil), c("recent", .working, 10),
                                       c("unread", .unread, 5000)])
    #expect(ws.foldoutConversations.map(\.id) == ["unread", "recent", "old", "unknown"])
    #expect(ws.lastActivity == now - 10)
  }

  @Test func transcriptGivesActivityAndTitleAndIsReadIncrementally() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                           claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    let folder = root.url.appendingPathComponent("proj").standardizedFileURL.path
    let fm = FileManager.default
    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let projectDir = paths.claudeHome.appendingPathComponent("projects/-proj")
    try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let transcript = projectDir.appendingPathComponent("s1.jsonl")
    try Data((#"{"type":"ai-title","aiTitle":"First title"}"# + "\n").utf8).write(to: transcript)
    let written = Date(timeIntervalSinceNow: -3600)
    try fm.setAttributes([.modificationDate: written], ofItemAtPath: transcript.path)
    try JSONSerialization.data(withJSONObject: [
      "pid": Int(ProcessInfo.processInfo.processIdentifier), "sessionId": "s1", "cwd": folder, "status": "busy",
      "entrypoint": "cli",
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))

    let radar = Radar(paths: paths, providers: [ClaudeCodeProvider(paths: paths, hostResolver: { _ in (.terminalApp, nil) })])
    var conversation = try #require(radar.scan().terminal.first?.conversations.first)
    #expect(conversation.title == "First title")
    #expect(abs((conversation.lastActivity ?? .distantPast).timeIntervalSince(written)) < 1)

    // A custom title appended later is picked up; a half-written line is not read yet.
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"custom-title","customTitle":"Renamed"}"# + "\n").utf8))
    try handle.write(contentsOf: Data(#"{"type":"custom-title","customTi"#.utf8))
    try handle.close()
    conversation = try #require(radar.scan().terminal.first?.conversations.first)
    #expect(conversation.title == "Renamed")
  }
}

@Suite struct WaitingStatusTests {
  @Test func sessionStatusWaitingNeedsNoHooks() {
    var session = ClaudeCodeProvider.LiveSession(sessionId: "x", cwd: "/w", busy: false)
    session.waiting = true
    #expect(ClaudeCodeProvider.merge(tabs: [], unread: [], live: [session], waiting: []).first?.state == .waiting)
  }

  @Test func readsWaitingStatusFromSessionFile() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    try FileManager.default.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"),
                                            withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "pid": Int(ProcessInfo.processInfo.processIdentifier), "sessionId": "w1", "cwd": "/tmp/proj",
      "status": "waiting", "waitingFor": "permission", "entrypoint": "cli",
    ]).write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))
    let radar = Radar(paths: paths, providers: [ClaudeCodeProvider(paths: paths, hostResolver: { _ in (.terminalApp, nil) })])
    let sections = radar.scan()
    #expect(sections.terminal.first?.conversations.first?.state == .waiting)
    #expect(sections.attentionCount == 1)
  }
}
