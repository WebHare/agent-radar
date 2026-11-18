import Foundation
import SQLite3
import Testing
@testable import RadarKit

@Suite struct HookEventTests {
  func event(_ name: String, _ session: String = "s1", type: String = "", tool: String = "") -> ClaudeHookEvents.Event {
    .init(event: name, session: session, type: type, tool: tool)
  }

  @Test func permissionPromptWaitsUntilToolRuns() {
    #expect(ClaudeHookEvents.waitingSessions(events: [event("PermissionRequest")]) == ["s1"])
    #expect(ClaudeHookEvents.waitingSessions(events: [event("PermissionRequest"), event("PostToolUse")]) == [])
    #expect(ClaudeHookEvents.waitingSessions(events: [event("PermissionRequest"), event("PermissionDenied")]) == [])
  }

  @Test func idleNotificationIsNotWaiting() {
    #expect(ClaudeHookEvents.waitingSessions(events: [event("Notification", type: "idle_prompt")]) == [])
    #expect(ClaudeHookEvents.waitingSessions(events: [event("Notification", type: "permission_prompt")]) == ["s1"])
  }

  @Test func questionToolsWait() {
    #expect(ClaudeHookEvents.waitingSessions(events: [event("PreToolUse", tool: "AskUserQuestion")]) == ["s1"])
    #expect(ClaudeHookEvents.waitingSessions(events: [event("PreToolUse", tool: "Bash")]) == [])
  }

  @Test func sessionsAreIndependent() {
    let events = [event("PermissionRequest", "a"), event("PermissionRequest", "b"), event("Stop", "a")]
    #expect(ClaudeHookEvents.waitingSessions(events: events) == ["b"])
  }

  @Test func parsesHookScriptOutputAndSkipsGarbage() {
    let log = """
      {"event":"PermissionRequest","session":"abc","type":"","tool":"Bash","time":1}
      not json
      {"event":"Stop","session":"","type":"","tool":"","time":2}

      """
    let events = ClaudeHookEvents.parse(Data(log.utf8))
    #expect(events.count == 1)
    #expect(events.first?.tool == "Bash")
  }

  @Test func compactingKeepsWaitingSessions() throws {
    let dir = try TempDir()
    let log = dir.url.appendingPathComponent("events.jsonl")
    var lines = (0..<4000).map { #"{"event":"PostToolUse","session":"busy\#($0)","type":"","tool":"Read","time":1}"# }
    lines.append(#"{"event":"PermissionRequest","session":"waiter","type":"","tool":"Bash","time":2}"#)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)

    #expect(ClaudeHookEvents.waitingSessions(logURL: log) == ["waiter"])
    #expect(try Data(contentsOf: log).count < 200)
    #expect(ClaudeHookEvents.waitingSessions(logURL: log) == ["waiter"])
  }
}

@Suite struct ClaudeCodeProviderTests {
  @Test func mergeCombinesTabsUnreadAndLiveSessions() {
    let tabs: [JSONObject] = [["sessionId": "tab1", "title": "First"], ["sessionId": "tab2", "title": "Second"]]
    let live = [ClaudeCodeProvider.LiveSession(sessionId: "tab2", cwd: "/w", busy: true),
                ClaudeCodeProvider.LiveSession(sessionId: "sidebar", cwd: "/w", busy: false),
                ClaudeCodeProvider.LiveSession(sessionId: "asking", cwd: "/w", busy: false)]
    let result = ClaudeCodeProvider.merge(tabs: tabs, unread: ["tab1", "closedTab"], live: live,
                                          waiting: ["asking", "notLive"])
    let states = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.state) })
    #expect(states == ["tab1": .unread, "tab2": .working, "closedTab": .unread, "sidebar": .open, "asking": .waiting])
    #expect(result.first?.title == "First")
    #expect(result.first?.target == .vscode(URL(string: "vscode://anthropic.claude-code/open?session=tab1")!))
  }

  @Test func waitingWinsOverUnread() {
    let live = [ClaudeCodeProvider.LiveSession(sessionId: "x", cwd: "/w", busy: false)]
    #expect(ClaudeCodeProvider.merge(tabs: [], unread: ["x"], live: live, waiting: ["x"]).first?.state == .waiting)
  }

  @Test func sessionFolderMapsToWorkspace() {
    let keys = ["/p/a", "/p/a/sub", "/p/b"]
    #expect(ClaudeCodeProvider.workspaceKey(forFolder: "/p/a", among: keys) == "/p/a")
    #expect(ClaudeCodeProvider.workspaceKey(forFolder: "/p/a/sub/deeper", among: keys) == "/p/a/sub")
    #expect(ClaudeCodeProvider.workspaceKey(forFolder: "/p/ab", among: keys) == nil)
  }

  @Test func transcriptTitlePrefersCustomTitle() {
    let transcript = """
      {"type":"user","message":"mentions \\"ai-title\\" in text"}
      {"type":"ai-title","aiTitle":"Generated","sessionId":"s"}
      {"type":"custom-title","customTitle":"Mine","sessionId":"s"}
      {"type":"ai-title","aiTitle":"Generated later","sessionId":"s"}
      """
    #expect(ClaudeCodeProvider.title(fromTranscript: Data(transcript.utf8)) == "Mine")
    #expect(ClaudeCodeProvider.title(fromTranscript: Data(#"{"type":"ai-title","aiTitle":"Only"}"#.utf8)) == "Only")
    #expect(ClaudeCodeProvider.title(fromTranscript: Data()) == nil)
  }
}

@Suite struct SectionTests {
  func ws(_ id: String, open: Bool, age: TimeInterval, _ states: [ConversationState] = []) -> Workspace {
    Workspace(id: id, name: id, openTarget: URL(fileURLWithPath: "/\(id)"), isOpen: open,
              lastUsed: Date(timeIntervalSince1970: 1_000_000 - age),
              conversations: states.enumerated().map { Conversation(id: "\(id)\($0.offset)", title: "", state: $0.element, provider: "t") })
  }

  @Test func splitsAndOrdersSections() {
    let sections = WorkspaceSections.make(from: [
      ws("openOld", open: true, age: 100),
      ws("openNew", open: true, age: 1),
      ws("openNeedsYou", open: true, age: 50, [.unread]),
      ws("closedTabs", open: false, age: 5, [.open]),
      ws("closedUnread", open: false, age: 60, [.unread, .open]),
      ws("recent", open: false, age: 2),
    ])
    #expect(sections.active.map(\.id) == ["openNeedsYou", "openNew", "openOld"])
    #expect(sections.closedWithConversations.map(\.id) == ["closedUnread", "closedTabs"])
    #expect(sections.recent.map(\.id) == ["recent"])
    #expect(sections.attentionCount == 2)
  }

  @Test func limitsRecent() {
    let sections = WorkspaceSections.make(from: (0..<15).map { ws("r\($0)", open: false, age: Double($0)) })
    #expect(sections.recent.count == WorkspaceSections.recentLimit)
    #expect(sections.recent.first?.id == "r0")
  }

  @Test func workingAndOpenDontNeedAttention() {
    #expect(ws("w", open: true, age: 0, [.working, .open]).attentionCount == 0)
    #expect(ws("w", open: true, age: 0, [.waiting, .unread, .working]).attentionCount == 2)
  }
}

@Suite struct RadarIntegrationTests {
  /// Builds a fake VS Code + Claude Code setup on disk and checks the whole scan.
  @Test func scansFakeSetup() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                             claudeHome: root.url.appendingPathComponent("claude"),
                             radarHome: root.url.appendingPathComponent("radar"))
    let fm = FileManager.default
    let projects = root.url.appendingPathComponent("projects")
    for name in ["open", "closed", "recent", "multi1", "multi2"] {
      try fm.createDirectory(at: projects.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let workspaceFile = projects.appendingPathComponent("Multi.code-workspace")
    try Data("{ \"folders\": [ { \"path\": \"multi1\" }, { \"path\": \"multi2\" } ], // comment\n }".utf8)
      .write(to: workspaceFile)

    func storage(_ id: String, _ meta: String, tabs: [[String: String]] = []) throws {
      let dir = paths.vscodeUser.appendingPathComponent("workspaceStorage/\(id)")
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(meta.utf8).write(to: dir.appendingPathComponent("workspace.json"))
      let state = try JSONSerialization.data(withJSONObject: ["panelTabSessions": tabs])
      try makeStateDB(dir.appendingPathComponent("state.vscdb"), ["Anthropic.claude-code": state])
    }
    try storage("1", #"{"folder":"\#(projects.appendingPathComponent("open").absoluteString)"}"#,
                tabs: [["sessionId": "o1", "title": "Open one"], ["sessionId": "o2", "title": "Open two"]])
    try storage("2", #"{"folder":"\#(projects.appendingPathComponent("closed").absoluteString)"}"#,
                tabs: [["sessionId": "c1", "title": "Closed one"]])
    try storage("3", #"{"folder":"\#(projects.appendingPathComponent("recent").absoluteString)"}"#)
    try storage("4", #"{"workspace":"\#(workspaceFile.absoluteString)"}"#)
    try storage("5", #"{"folder":"\#(projects.appendingPathComponent("deleted").absoluteString)"}"#)
    try storage("6", #"{"folder":"vscode-remote://ssh-remote+host/srv"}"#)

    let openPath = projects.appendingPathComponent("open").standardizedFileURL.path
    let multiPath = projects.appendingPathComponent("multi1").standardizedFileURL.path
    let unread = try JSONSerialization.data(withJSONObject: ["sessionUnread:\(openPath)": ["o1"]])
    try fm.createDirectory(at: paths.vscodeUser.appendingPathComponent("globalStorage"), withIntermediateDirectories: true)
    try makeStateDB(paths.vscodeUser.appendingPathComponent("globalStorage/state.vscdb"), ["Anthropic.claude-code": unread])

    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("ide"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["pid": pid, "workspaceFolders": [openPath]])
      .write(to: paths.claudeHome.appendingPathComponent("ide/1.lock"))
    try JSONSerialization.data(withJSONObject: ["pid": 999_999_999, "workspaceFolders": [multiPath]])
      .write(to: paths.claudeHome.appendingPathComponent("ide/2.lock"))
    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["pid": pid, "sessionId": "o2", "cwd": openPath, "status": "idle",
                                                "entrypoint": "claude-vscode"])
      .write(to: paths.claudeHome.appendingPathComponent("sessions/1.json"))
    try fm.createDirectory(at: paths.radarHome, withIntermediateDirectories: true)
    try Data(#"{"event":"PermissionRequest","session":"o2","type":"","tool":"Bash","time":1}"#.utf8)
      .write(to: ClaudeHookEvents.logURL(paths: paths))

    let sections = Radar(paths: paths).scan()

    #expect(sections.active.map(\.name) == ["open"])
    let open = try #require(sections.active.first)
    #expect(open.attentionConversations.map(\.title) == ["Open two", "Open one"])
    #expect(open.attentionConversations.map(\.state) == [.waiting, .unread])
    #expect(sections.closedWithConversations.map(\.name) == ["closed"])
    #expect(Set(sections.recent.map(\.name)) == ["recent", "Multi"])
    #expect(sections.recent.first { $0.name == "Multi" }?.openTarget.lastPathComponent == "Multi.code-workspace")
    #expect(sections.attentionCount == 2)
  }
}

@Suite struct SharedFirstFolderTests {
  /// A folder and a .code-workspace file whose first folder it is share a workspace key. The one open in a window
  /// must win, also when VS Code wrote the other one's state more recently.
  func scan(windowFolders: [String]) throws -> Workspace? {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url.appendingPathComponent("Code/User"),
                           claudeHome: root.url.appendingPathComponent("claude"),
                           radarHome: root.url.appendingPathComponent("radar"))
    let fm = FileManager.default
    let projects = root.url.appendingPathComponent("projects")
    for name in ["main", "extra"] {
      try fm.createDirectory(at: projects.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let workspaceFile = projects.appendingPathComponent("Main.code-workspace")
    try Data(#"{ "folders": [ { "path": "main" }, { "path": "extra" } ] }"#.utf8).write(to: workspaceFile)

    func storage(_ id: String, _ meta: String, age: TimeInterval) throws {
      let dir = paths.vscodeUser.appendingPathComponent("workspaceStorage/\(id)")
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(meta.utf8).write(to: dir.appendingPathComponent("workspace.json"))
      let db = dir.appendingPathComponent("state.vscdb")
      try makeStateDB(db, [:])
      try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: db.path)
    }
    try storage("folder", #"{"folder":"\#(projects.appendingPathComponent("main").absoluteString)"}"#, age: 10)
    try storage("file", #"{"workspace":"\#(workspaceFile.absoluteString)"}"#, age: 100)

    try fm.createDirectory(at: paths.claudeHome.appendingPathComponent("ide"), withIntermediateDirectories: true)
    let folders = windowFolders.map { projects.appendingPathComponent($0).standardizedFileURL.path }
    try JSONSerialization.data(withJSONObject: ["pid": Int(ProcessInfo.processInfo.processIdentifier),
                                                "workspaceFolders": folders])
      .write(to: paths.claudeHome.appendingPathComponent("ide/1.lock"))
    let sections = Radar(paths: paths).scan()
    #expect(sections.active.count == 1)
    return sections.active.first
  }

  @Test func openWorkspaceFileWinsOverMoreRecentFolder() throws {
    let active = try scan(windowFolders: ["main", "extra"])
    #expect(active?.name == "Main")
    #expect(active?.openTarget.lastPathComponent == "Main.code-workspace")
  }

  @Test func openFolderWinsOverWorkspaceFile() throws {
    let active = try scan(windowFolders: ["main"])
    #expect(active?.name == "main")
    #expect(active?.openTarget.lastPathComponent == "main")
  }
}

struct TempDir {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-radar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}

func makeStateDB(_ url: URL, _ items: [String: Data]) throws {
  var db: OpaquePointer?
  guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
  defer { sqlite3_close(db) }
  sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil)
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  for (key, value) in items {
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES (?, ?)", -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, key, -1, transient)
    _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(value.count), transient) }
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
  }
}
