import Foundation

/// Collects VS Code workspaces, and conversations (in VS Code and terminals) from all providers, into the menu
/// sections.
/// Not thread-safe: call `scan()` from one queue.
public final class Radar: @unchecked Sendable {
  private let paths: RadarPaths
  private let providers: [ConversationProvider]
  private let storage: WorkspaceStorageScanner

  public init(paths: RadarPaths = .standard, providers: [ConversationProvider]? = nil) {
    self.paths = paths
    self.providers = providers ?? [ClaudeCodeProvider(paths: paths)]
    let keys = Array(Set(self.providers.flatMap(\.workspaceStateKeys))).sorted()
    self.storage = WorkspaceStorageScanner(paths: paths, stateKeys: keys)
  }

  public func scan() -> WorkspaceSections {
    var infos = storage.scan()
    let windows = OpenWindows.read(paths: paths)
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
    for provider in providers {
      let result = provider.scan(workspaces: infos, globalState: globalState)
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
    return WorkspaceSections.make(from: workspaces)
  }

  /// The user is looking at the terminal tab with this tty (eg. `/dev/ttys003`).
  public func markTerminalSeen(tty: String) {
    for provider in providers { provider.markTerminalSeen(tty: tty) }
  }

  /// VS Code is the frontmost app now. Only with a single VS Code window open does that mean the user sees its
  /// conversations; with more, the app can't tell which window they're looking at (see
  /// https://github.com/WebHare/agent-radar/issues/7).
  public func markVSCodeFront() {
    guard Set(OpenWindows.read(paths: paths).map(\.key)).count <= 1 else { return }
    for provider in providers { provider.markVSCodeSeen() }
  }

  /// The user marked these conversations as read, or opened them from the menu.
  public func markRead(_ conversationIds: [String]) {
    for provider in providers { provider.markRead(conversationIds) }
  }
}
