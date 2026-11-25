import Foundation
import Testing
@testable import RadarKit

@Suite struct VSCodeCompanionTests {
  let now = Date(timeIntervalSince1970: 2_000_000)
  var alivePid: Int { Int(ProcessInfo.processInfo.processIdentifier) }

  func write(_ json: [String: Any], as name: String, in paths: RadarPaths) throws {
    let dir = VSCodeCompanion.windowsDir(paths: paths)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent(name))
  }

  @Test func readsTheWindowsOfRunningVSCodes() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url)
    try write(["version": 1, "pid": alivePid, "folders": ["/tmp/a/../proj", "/tmp/other"], "focused": true,
               "tabs": [["viewType": "v", "label": "Fix the bug", "inFront": true, "seenAt": 1_999_000_000],
                        ["viewType": "v", "label": "Other", "inFront": false]]],
              as: "1.json", in: paths)
    // A window whose VS Code is gone (no such process), and a broken file.
    try write(["version": 1, "pid": 999_999, "folders": ["/tmp/gone"], "focused": true, "tabs": []],
              as: "2.json", in: paths)
    try Data("{".utf8).write(to: VSCodeCompanion.windowsDir(paths: paths).appendingPathComponent("3.json"))

    let windows = VSCodeCompanion.read(paths: paths)
    #expect(windows.count == 1)
    let window = try #require(windows.first)
    #expect(window.key == "/tmp/proj")
    #expect(window.focused)
    #expect(window.tabs.map(\.label) == ["Fix the bug", "Other"])
    #expect(window.tabs[0].inFront && !window.tabs[1].inFront)
    #expect(window.tabs[0].seenAt == Date(timeIntervalSince1970: 1_999_000))
    #expect(window.tabs[1].seenAt == nil)
  }

  @Test func aTabInFrontOfAFocusedWindowIsSeenNow() {
    let tab = VSCodeCompanion.Tab(viewType: "v", label: "x", inFront: true, seenAt: now - 100)
    #expect(VSCodeCompanion.Window(pid: 1, folders: ["/p"], focused: true, tabs: [tab]).seen(tab, now: now) == now)
    // Unfocused, or not in front: when it was last seen, according to the extension.
    #expect(VSCodeCompanion.Window(pid: 1, folders: ["/p"], focused: false, tabs: [tab]).seen(tab, now: now) == now - 100)
    var behind = tab
    behind.inFront = false
    #expect(VSCodeCompanion.Window(pid: 1, folders: ["/p"], focused: true, tabs: [behind]).seen(behind, now: now) == now - 100)
  }

  @Test func matchesTabsToConversationsByUniqueTitle() {
    let view = ClaudeCodeProvider.panelViewType
    let window = VSCodeCompanion.Window(pid: 1, folders: ["/p"], focused: true, tabs: [
      .init(viewType: view, label: "Fix the bug", inFront: true, seenAt: nil),
      .init(viewType: view, label: "say hi", inFront: true, seenAt: nil),
      .init(viewType: view, label: "Never seen", inFront: false, seenAt: nil),
      .init(viewType: "somethingElse", label: "Elsewhere", inFront: true, seenAt: nil),
    ])
    let tabs: [JSONObject] = [
      ["sessionId": "a", "title": "Fix the bug"],
      ["sessionId": "b", "title": "say hi"],
      ["sessionId": "c", "title": "say hi"],
      ["sessionId": "d", "title": "Never seen"],
      ["sessionId": "e", "title": "Elsewhere"],
    ]
    // "say hi" could be either conversation, so neither counts as seen; another extension's tab doesn't count.
    #expect(ClaudeCodeProvider.seenTabs(tabs: tabs, windows: [window], now: now) == ["a": now])
  }
}

@Suite struct VSCodeCompanionIntegrationTests {
  func state(_ radar: Radar) -> ConversationState? {
    radar.scan().active.flatMap(\.conversations).first { $0.id == "ext1" }?.state
  }

  /// With several windows open, a reply is seen when its tab is in front of the focused window.
  @Test func aReplyInTheTabInFrontOfTheFocusedWindowIsSeen() throws {
    let fixture = try VSCodeFixture(windows: 2)
    try fixture.storeTabs([("ext1", "Fix the bug"), ("other", "Something else")])
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    #expect(state(radar) == .unread)
    try fixture.companion(focused: true, tabs: [("Something else", true, nil)])
    #expect(state(radar) == .unread)
    try fixture.companion(focused: false, tabs: [("Fix the bug", true, nil)])
    #expect(state(radar) == .unread)
    try fixture.companion(focused: true, tabs: [("Fix the bug", true, nil)])
    #expect(state(radar) == .open)
    // Stays seen after the user moved on, until the next reply.
    try fixture.companion(focused: false, tabs: [("Fix the bug", true, fixture.now - 1)])
    #expect(state(radar) == .open)
    try fixture.finishReply(ago: -5)
    #expect(state(radar) == .unread)
  }

  /// VS Code can report a folder by another path than the Claude Code extension, such as /private/var/... for
  /// /var/...: both are the same folder.
  @Test func matchesTheWindowWhateverPathVSCodeReports() throws {
    let fixture = try VSCodeFixture(windows: 2)
    try fixture.storeTabs([("ext1", "Fix the bug")])
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    let realPath = try #require(realpath(fixture.folder, nil).map { String(cString: $0) })
    #expect(realPath != fixture.folder)
    try fixture.companion(focused: true, folder: realPath, tabs: [("Fix the bug", true, nil)])
    #expect(state(radar) == .open)
  }

  /// The user saw the reply finish and switched away before Agent Radar looked: the extension's own record counts.
  @Test func aReplySeenBetweenScansCounts() throws {
    let fixture = try VSCodeFixture(windows: 2)
    try fixture.storeTabs([("ext1", "Fix the bug")])
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    try fixture.companion(focused: false, tabs: [("Fix the bug", false, fixture.now - 20)])
    #expect(state(radar) == .unread)  // seen before the reply finished (10 seconds ago)
    try fixture.companion(focused: false, tabs: [("Fix the bug", false, fixture.now - 2)])
    #expect(state(radar) == .open)
  }

  @Test func seenTabsAreRememberedAcrossRestarts() throws {
    let fixture = try VSCodeFixture(windows: 2)
    try fixture.storeTabs([("ext1", "Fix the bug")])
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    try fixture.companion(focused: true, tabs: [("Fix the bug", true, nil)])
    #expect(state(radar) == .open)
    try fixture.removeCompanion()
    let restarted = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    #expect(state(restarted) == .open)
  }
}

extension VSCodeFixture {
  /// The conversation tabs the Claude Code extension stored for the workspace.
  func storeTabs(_ tabs: [(id: String, title: String)]) throws {
    let dir = paths.vscodeUser.appendingPathComponent("workspaceStorage/proj")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"folder":"\#(URL(fileURLWithPath: folder).absoluteString)"}"#.utf8)
      .write(to: dir.appendingPathComponent("workspace.json"))
    let state = try JSONSerialization.data(withJSONObject: [
      "panelTabSessions": tabs.map { ["sessionId": $0.id, "title": $0.title] }])
    try makeStateDB(dir.appendingPathComponent("state.vscdb"), ["Anthropic.claude-code": state])
  }

  /// What the companion extension in window 0 reports: its Claude tabs, whether each is in front, and when it was
  /// last seen.
  func companion(focused: Bool, folder: String? = nil, tabs: [(label: String, inFront: Bool, seenAt: TimeInterval?)]) throws {
    let dir = VSCodeCompanion.windowsDir(paths: paths)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json: [String: Any] = [
      "version": 1, "pid": pid, "folders": [folder ?? self.folder], "focused": focused,
      "tabs": tabs.map { tab -> [String: Any] in
        var json: [String: Any] = ["viewType": ClaudeCodeProvider.panelViewType, "label": tab.label,
                                   "inFront": tab.inFront]
        if let seenAt = tab.seenAt { json["seenAt"] = seenAt * 1000 }
        return json
      },
    ]
    try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("\(pid).json"))
  }

  func removeCompanion() throws {
    try FileManager.default.removeItem(at: VSCodeCompanion.windowsDir(paths: paths).appendingPathComponent("\(pid).json"))
  }
}
