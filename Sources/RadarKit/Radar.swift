import Foundation

/// Collects VS Code workspaces, and conversations (in VS Code and terminals) from all providers, into the menu
/// sections.
/// Not thread-safe: call `scan()` from one queue.
public final class Radar: @unchecked Sendable {
  private let paths: RadarPaths
  private let providers: [ConversationProvider]
  private let storage: WorkspaceStorageScanner
  /// The troubleshooting log; off until Settings switches it on.
  public let debugLog: DebugLog
  /// Each conversation's state at the previous scan, to log what changed.
  private var previous: [String: Logged] = [:]
  private var loggedBefore = false
  /// What was last logged about VS Code being in front and the terminal tab in front, to log only changes.
  private var frontNote: String?
  private var terminalNote: String?

  private struct Logged {
    var state: ConversationState
    var label: String
  }

  public init(paths: RadarPaths = .standard, providers: [ConversationProvider]? = nil) {
    self.paths = paths
    self.providers = providers ?? [ClaudeCodeProvider(paths: paths)]
    let keys = Array(Set(self.providers.flatMap(\.workspaceStateKeys))).sorted()
    self.storage = WorkspaceStorageScanner(paths: paths, stateKeys: keys)
    self.debugLog = DebugLog(url: paths.debugLogURL)
  }

  /// `trigger` says what started the scan, for the troubleshooting log: "poll" for the regular rescan.
  public func scan(trigger: String = "poll") -> WorkspaceSections {
    let windows = OpenWindows.read(paths: paths)
    var infos = storage.scan(openFolders: windows.map(\.folders))
    let openKeys = Set(windows.map(\.key))
    for i in infos.indices where openKeys.contains(infos[i].key) {
      infos[i].isOpen = true
    }
    // A window whose workspace VS Code hasn't saved state for yet.
    let known = Set(infos.map(\.key))
    for window in windows where !known.contains(window.key) {
      let folder = URL(fileURLWithPath: window.key)
      infos.append(WorkspaceInfo(key: window.key, name: folder.lastPathComponent, openTarget: folder,
                                 isOpen: true, lastUsed: Date(), extensionState: [:]))
    }

    let globalKeys = Array(Set(providers.flatMap(\.globalStateKeys))).sorted()
    let globalState = SQLiteReader.readJSONObjects(
      db: paths.vscodeUser.appendingPathComponent("globalStorage/state.vscdb"), keys: globalKeys)

    var conversations: [String: [Conversation]] = [:]
    var terminalFolders: [String: TerminalFolder] = [:]
    var providerLog: [(conversationId: String, message: String)] = []
    for provider in providers {
      let result = provider.scan(workspaces: infos, globalState: globalState)
      providerLog += result.log
      for (key, list) in result.workspaces {
        conversations[key, default: []].append(contentsOf: list)
      }
      for (folder, found) in result.terminalFolders {
        terminalFolders[folder, default: TerminalFolder()].conversations.append(contentsOf: found.conversations)
        terminalFolders[folder]!.lastActive = max(terminalFolders[folder]!.lastActive, found.lastActive)
      }
    }

    var workspaces = infos.map { info in
      Workspace(id: info.key, name: info.name, openTarget: info.openTarget, isOpen: info.isOpen,
                lastUsed: info.lastUsed, conversations: conversations[info.key] ?? [])
    }
    for (folder, found) in terminalFolders {
      let url = URL(fileURLWithPath: folder)
      workspaces.append(Workspace(id: "terminal:" + folder, kind: .terminalFolder, name: url.lastPathComponent,
                                  openTarget: url, isOpen: true, lastUsed: found.lastActive,
                                  conversations: found.conversations))
    }
    log(workspaces: workspaces, providerLog: providerLog, trigger: trigger)
    var sections = WorkspaceSections.make(from: workspaces)
    sections.sharedFolders = Self.sharedFolders(windows: windows, known: storage.all)
    return sections
  }

  /// Open windows with the same first folder but different folders (a folder and a workspace file starting with it,
  /// or two such workspace files), described by the workspace VS Code knows them as.
  static func sharedFolders(windows: [OpenWindows.Window], known: [WorkspaceInfo]) -> [SharedFolder] {
    func describe(_ folders: [String]) -> String {
      let matches = known.filter { $0.folders == folders }
      let home = { (path: String) in (path as NSString).abbreviatingWithTildeInPath }
      // A single folder can be both a folder workspace and a workspace file with just that folder; the folder wins.
      if let info = matches.first(where: { $0.openTarget.path == folders.first && folders.count == 1 }) ?? matches.first {
        return info.openTarget.pathExtension == "code-workspace"
          ? "\(info.name) (\(home(info.openTarget.path)))"
          : "\(info.name) (the folder \(home(info.openTarget.path)))"
      }
      return "a window with \(folders.map(home).joined(separator: ", "))"
    }
    let byKey = Dictionary(grouping: Set(windows.map(\.folders)), by: { $0.first ?? "" })
    return byKey.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.map { key, lists in
      SharedFolder(folder: key, windows: lists.map(describe).sorted())
    }
  }

  /// Writes what the providers received and every conversation whose state changed, with the reason.
  private func log(workspaces: [Workspace], providerLog: [(conversationId: String, message: String)], trigger: String) {
    var current: [String: (Conversation, Logged)] = [:]
    for ws in workspaces {
      for c in ws.conversations {
        current[c.id] = (c, Logged(state: c.state, label: "\(c.id) “\(c.title)” in \(ws.name)"))
      }
    }
    defer { previous = current.mapValues(\.1) }
    guard debugLog.isEnabled else {
      loggedBefore = false
      return
    }
    func label(_ id: String) -> String { current[id]?.1.label ?? previous[id]?.label ?? "\(id) (not listed)" }

    for entry in providerLog {
      debugLog.write("hook", "\(label(entry.conversationId)): \(entry.message)")
    }
    if !loggedBefore {
      // Just switched on: the starting point.
      loggedBefore = true
      let listed = current.values.sorted { $0.1.label < $1.1.label }
      debugLog.write("start", "Log switched on. \(listed.count) conversations listed; those not open:")
      for (c, logged) in listed where c.state != .open {
        debugLog.write("state", "\(logged.label): \(Self.name(c.state)). Why: \(c.stateReason).")
      }
      return
    }
    for (id, (c, logged)) in current.sorted(by: { $0.value.1.label < $1.value.1.label }) {
      let before = previous[id].map { Self.name($0.state) } ?? "new"
      guard previous[id]?.state != c.state else { continue }
      debugLog.write("state", "\(logged.label): \(before) → \(Self.name(c.state)) (\(trigger)). Why: \(c.stateReason).")
    }
    for (id, old) in previous.sorted(by: { $0.value.label < $1.value.label }) where current[id] == nil {
      debugLog.write("state", "\(old.label): \(Self.name(old.state)) → no longer listed (\(trigger)). Why: archived with nothing pending, or its workspace, tab or session is gone.")
    }
  }

  static func name(_ state: ConversationState) -> String {
    switch state {
    case .waiting: "waiting"
    case .unread: "unread"
    case .working: "working"
    case .open: "open"
    }
  }

  /// The user is looking at the terminal tab with this tty (eg. `/dev/ttys003`).
  public func markTerminalSeen(tty: String) {
    note(&terminalNote, "Terminal.app is in front with the tab on \(tty): its sessions count as seen")
    for provider in providers { provider.markTerminalSeen(tty: tty) }
  }

  /// No terminal tab with a Claude Code session is in front (anymore).
  public func noTerminalInFront() {
    note(&terminalNote, nil, otherwise: "No Terminal.app tab with a session is in front anymore")
  }

  /// VS Code is the frontmost app now. Only with a single VS Code window open does that mean the user sees its
  /// conversations; with more, the app can't tell which window they're looking at (see
  /// https://github.com/WebHare/agent-radar/issues/7).
  public func markVSCodeFront() {
    let windows = Set(OpenWindows.read(paths: paths).map(\.key)).count
    guard windows <= 1 else {
      note(&frontNote, "VS Code is in front with \(windows) windows: only conversation tabs that Agent Radar's VS Code extension reports in front of the focused window count as seen")
      return
    }
    note(&frontNote, "VS Code is in front with \(windows) window: all its replies count as seen while it stays in front")
    for provider in providers { provider.markVSCodeSeen() }
  }

  /// Another app than VS Code is in front.
  public func vscodeNotInFront() {
    note(&frontNote, nil, otherwise: "VS Code is no longer in front")
  }

  /// Logs `text` when it differs from what was last logged on the subject. With `text` nil, logs `otherwise` once.
  private func note(_ last: inout String?, _ text: String?, otherwise: String = "") {
    guard text != last else { return }
    if debugLog.isEnabled { debugLog.write("front", text ?? otherwise) }
    last = text
  }

  /// The user marked these conversations as read, or opened them from the menu.
  public func markRead(_ conversationIds: [String]) {
    for id in conversationIds {
      debugLog.write("user", "\(previous[id]?.label ?? id): marked as read (opened from the menu or Mark as read)")
    }
    for provider in providers { provider.markRead(conversationIds) }
  }
}
