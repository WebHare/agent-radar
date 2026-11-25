import Foundation

/// What Agent Radar's own VS Code extension (`extensions/vscode`) reports about each VS Code window: its folders,
/// whether it has focus, and its webview tabs with whether each is in front of its editor group and when it was
/// last in front while the window had focus. Agent-neutral: providers pick their own tabs by `viewType`.
///
/// One file per window, `~/.agent-radar/vscode-windows/<extension host pid>.json`, rewritten on every change and
/// removed when the window closes. A file whose process is gone (VS Code crashed) is ignored.
/// Keep this format in sync with `extensions/vscode/extension.js`.
public enum VSCodeCompanion {
  public struct Tab: Equatable, Sendable {
    public var viewType: String
    /// The tab's title as VS Code shows it.
    public var label: String
    /// The tab is the one shown in its editor group.
    public var inFront: Bool
    /// When it was last in front while the window had focus, up to the last change; nil if never.
    public var seenAt: Date?
  }

  public struct Window: Equatable, Sendable {
    public var pid: Int
    public var folders: [String]
    public var focused: Bool
    public var tabs: [Tab]
    /// The workspace key: the first folder, as for `OpenWindows`.
    public var key: String { folders.first ?? "" }

    /// When the user last saw `tab`: now while it's in front of this focused window, otherwise what the extension
    /// recorded (the file isn't rewritten while nothing changes, so a tab still in front is still being seen).
    public func seen(_ tab: Tab, now: Date) -> Date? {
      focused && tab.inFront ? now : tab.seenAt
    }
  }

  static func windowsDir(paths: RadarPaths) -> URL {
    paths.radarHome.appendingPathComponent("vscode-windows")
  }

  static func read(paths: RadarPaths) -> [Window] {
    let dir = windowsDir(paths: paths)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { file in
      guard let json = JSON.object(contentsOf: file),
            let pid = json["pid"] as? Int, ProcessCheck.isAlive(pid),
            let folders = json["folders"] as? [String], !folders.isEmpty else { return nil }
      let tabs = ((json["tabs"] as? [JSONObject]) ?? []).compactMap { tab -> Tab? in
        guard let viewType = tab["viewType"] as? String, let label = tab["label"] as? String else { return nil }
        return Tab(viewType: viewType, label: label, inFront: tab["inFront"] as? Bool ?? false,
                   seenAt: (tab["seenAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
      }
      return Window(pid: pid, folders: folders.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                    focused: json["focused"] as? Bool ?? false, tabs: tabs)
    }
  }
}
