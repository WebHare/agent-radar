import Foundation

/// Where Agent Radar finds VS Code's and Claude Code's files. Overridable for tests.
public struct RadarPaths: Sendable {
  /// VS Code's user data folder (`~/Library/Application Support/Code/User`).
  public var vscodeUser: URL
  /// Claude Code's config folder (`~/.claude`).
  public var claudeHome: URL
  /// Agent Radar's own folder, where the Claude Code hooks write their events (`~/.agent-radar`).
  public var radarHome: URL

  public init(vscodeUser: URL, claudeHome: URL, radarHome: URL) {
    self.vscodeUser = vscodeUser
    self.claudeHome = claudeHome
    self.radarHome = radarHome
  }

  /// The troubleshooting log (see `DebugLog`).
  public var debugLogURL: URL { radarHome.appendingPathComponent("debug.log") }

  public static var standard: RadarPaths {
    // $HOME first, as the hook script uses it too (and so tests can redirect everything).
    let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".claude")
    return RadarPaths(
      vscodeUser: home.appendingPathComponent("Library/Application Support/Code/User"),
      claudeHome: claudeHome,
      radarHome: home.appendingPathComponent(".agent-radar"))
  }
}

/// Reads VS Code's list of known workspaces from `workspaceStorage/*`, caching each one until its state
/// database changes. Not thread-safe: use from one queue.
final class WorkspaceStorageScanner {
  private struct CacheEntry {
    var modified: Date
    var info: WorkspaceInfo?
  }

  private let paths: RadarPaths
  private let stateKeys: [String]
  private var cache: [String: CacheEntry] = [:]

  init(paths: RadarPaths, stateKeys: [String]) {
    self.paths = paths
    self.stateKeys = stateKeys
  }

  /// All known local workspaces, one per workspace key.
  /// - Parameter openFolders: the folders of each open window. A folder and a .code-workspace file whose first
  ///   folder it is share a key; the one open in a window wins, otherwise the most recently used one.
  func scan(openFolders: [[String]] = []) -> [WorkspaceInfo] {
    let storage = paths.vscodeUser.appendingPathComponent("workspaceStorage")
    let fm = FileManager.default
    let dirs = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
    let open = Set(openFolders)
    var seen = Set<String>()
    var byKey: [String: WorkspaceInfo] = [:]

    for dir in dirs {
      let name = dir.lastPathComponent
      seen.insert(name)
      let db = dir.appendingPathComponent("state.vscdb")
      let modified = (try? fm.attributesOfItem(atPath: db.path)[.modificationDate] as? Date)
        ?? (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date)
        ?? .distantPast
      if cache[name]?.modified != modified {
        cache[name] = CacheEntry(modified: modified, info: Self.readWorkspace(dir: dir, modified: modified, stateKeys: stateKeys))
      }
      guard let info = cache[name]?.info else { continue }
      if let current = byKey[info.key] {
        let (infoOpen, currentOpen) = (open.contains(info.folders), open.contains(current.folders))
        if infoOpen != currentOpen ? !infoOpen : info.lastUsed <= current.lastUsed { continue }
      }
      byKey[info.key] = info
    }
    cache = cache.filter { seen.contains($0.key) }
    return Array(byKey.values)
  }

  static func readWorkspace(dir: URL, modified: Date, stateKeys: [String]) -> WorkspaceInfo? {
    guard let meta = JSON.object(contentsOf: dir.appendingPathComponent("workspace.json")) else { return nil }
    let state = SQLiteReader.readJSONObjects(db: dir.appendingPathComponent("state.vscdb"), keys: stateKeys)

    if let folder = (meta["folder"] as? String).flatMap(localFileURL) {
      guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
      return WorkspaceInfo(key: folder.path, name: folder.lastPathComponent, openTarget: folder,
                           isOpen: false, lastUsed: modified, extensionState: state)
    }
    if let file = (meta["workspace"] as? String).flatMap(localFileURL) {
      guard FileManager.default.fileExists(atPath: file.path),
            let folders = self.folders(ofWorkspaceFile: file), let first = folders.first else { return nil }
      return WorkspaceInfo(key: first.path, name: workspaceName(file: file, firstFolder: first), openTarget: file,
                           folders: folders.map(\.path), isOpen: false, lastUsed: modified, extensionState: state)
    }
    return nil
  }

  /// Local `file://` URLs only; remote workspaces are skipped.
  static func localFileURL(_ string: String) -> URL? {
    guard let url = URL(string: string), url.isFileURL else { return nil }
    return url.standardizedFileURL
  }

  /// The local folders of a .code-workspace file, or nil when it has none or its first folder isn't local.
  static func folders(ofWorkspaceFile file: URL) -> [URL]? {
    guard let json = JSON.object(contentsOf: file), let folders = json["folders"] as? [JSONObject] else { return nil }
    func url(_ folder: JSONObject) -> URL? {
      if let path = folder["path"] as? String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
          : file.deletingLastPathComponent().appendingPathComponent(path)
        return url.standardizedFileURL
      }
      return (folder["uri"] as? String).flatMap(localFileURL)
    }
    guard let first = folders.first, url(first) != nil else { return nil }
    return folders.compactMap(url)
  }

  /// VS Code shows a saved workspace by its file name, and an unsaved one as "Untitled (Workspace)".
  static func workspaceName(file: URL, firstFolder: URL) -> String {
    if file.path.contains("/Code/Workspaces/") { return "\(firstFolder.lastPathComponent) (untitled workspace)" }
    return file.deletingPathExtension().lastPathComponent
  }
}

/// Finds the workspaces open in VS Code windows. Uses the lock files that the Claude Code extension writes per
/// window (`~/.claude/ide/*.lock`), as VS Code itself doesn't keep a live list on disk.
enum OpenWindows {
  struct Window {
    var folders: [String]
    var key: String { folders.first ?? "" }
  }

  static func read(paths: RadarPaths) -> [Window] {
    let dir = paths.claudeHome.appendingPathComponent("ide")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "lock" }.compactMap { file in
      guard let json = JSON.object(contentsOf: file),
            let pid = json["pid"] as? Int, ProcessCheck.isAlive(pid),
            let folders = json["workspaceFolders"] as? [String], !folders.isEmpty else { return nil }
      return Window(folders: folders.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }
  }
}

enum ProcessCheck {
  static func isAlive(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid_t(pid), 0) == 0 || errno == EPERM
  }
}
