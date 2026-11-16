import Foundation

/// Installs and removes the Claude Code hooks that write Agent Radar's event log (see doc/claude-hooks.md).
///
/// The hooks are added to Claude Code's user settings (`~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR`). The
/// installer only adds or removes hook entries whose command is Agent Radar's hook script, keeps everything else
/// in the file, and keeps a backup of the previous file.
public struct ClaudeHooks {
  public enum Status: Equatable {
    case notInstalled
    /// Installed for some events but not all, eg. after an update added an event.
    case partial
    case installed
  }

  public enum HookError: LocalizedError {
    case unreadableSettings(String)
    case settingsNotAnObject

    public var errorDescription: String? {
      switch self {
      case let .unreadableSettings(detail): "Claude Code's settings.json can't be read: \(detail)"
      case .settingsNotAnObject: "Claude Code's settings.json doesn't contain a JSON object."
      }
    }
  }

  /// Hook events Agent Radar listens to. No matchers: Agent Radar filters events itself.
  public static let events = [
    "Notification", "PermissionRequest", "PermissionDenied", "Elicitation", "ElicitationResult", "PreToolUse",
    "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "StopFailure", "SessionStart", "SessionEnd",
  ]

  /// The hook script. It extracts a few fields with plutil (always present on macOS) so that large hook inputs,
  /// such as tool output, never end up in the log.
  public static let script = #"""
    #!/bin/sh
    # Claude Code hook for Agent Radar. Appends one line per event to Agent Radar's event log, so the
    # radar can tell which conversations are waiting for input. Only reads its input; never blocks Claude Code.
    # Installed and removed by Agent Radar's settings. See doc/claude-hooks.md in Agent Radar's repository.

    dir="$HOME/.agent-radar"
    mkdir -p "$dir" || exit 0
    input=$(cat)
    field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

    printf '{"event":"%s","session":"%s","type":"%s","tool":"%s","time":%s}\n' \
      "$(field hook_event_name)" "$(field session_id)" "$(field notification_type)" "$(field tool_name)" "$(date +%s)" \
      >> "$dir/claude-code-events.jsonl"
    exit 0

    """#

  public let settingsURL: URL
  public let scriptURL: URL

  public init(paths: RadarPaths) {
    settingsURL = paths.claudeHome.appendingPathComponent("settings.json")
    scriptURL = paths.radarHome.appendingPathComponent("claude-hook.sh")
  }

  public var backupURL: URL { settingsURL.appendingPathExtension("bak-agent-radar") }

  public func status() throws -> Status {
    Self.status(of: try readSettings(), command: scriptURL.path)
  }

  public func install() throws {
    let settings = try readSettings()
    try writeScript()
    try write(Self.installing(into: settings, command: scriptURL.path), replacing: settings)
  }

  public func uninstall() throws {
    let settings = try readSettings()
    try write(Self.removing(from: settings, command: scriptURL.path), replacing: settings)
  }

  /// Rewrites the hook script when it differs from this version of the app, so updates reach installed hooks.
  public func updateScriptIfInstalled() {
    guard (try? status()) != .notInstalled,
          (try? String(contentsOf: scriptURL, encoding: .utf8)) != Self.script else { return }
    try? writeScript()
  }

  // MARK: Pure settings transformations (tested)

  static func status(of settings: OrderedJSON, command: String) -> Status {
    let present = events.filter { event in
      settings["hooks"]?[event]?.arrayValue?.contains { isOurs($0, command: command) } ?? false
    }
    return present.isEmpty ? .notInstalled : present.count == events.count ? .installed : .partial
  }

  static func installing(into settings: OrderedJSON, command: String) -> OrderedJSON {
    var settings = removing(from: settings, command: command)
    var hooks = settings["hooks"] ?? .object([])
    for event in events {
      let entry: OrderedJSON = .object([
        ("hooks", .array([.object([("type", .string("command")), ("command", .string(command)), ("async", .bool(true))])])),
      ])
      hooks[event] = .array((hooks[event]?.arrayValue ?? []) + [entry])
    }
    settings["hooks"] = hooks
    return settings
  }

  static func removing(from settings: OrderedJSON, command: String) -> OrderedJSON {
    guard var hooks = settings["hooks"], let members = hooks.objectMembers else { return settings }
    for (event, groups) in members {
      guard let list = groups.arrayValue else { continue }
      let kept = list.filter { !isOurs($0, command: command) }
      if kept.count != list.count { hooks[event] = kept.isEmpty ? nil : .array(kept) }
    }
    var settings = settings
    settings["hooks"] = hooks.objectMembers?.isEmpty == true ? nil : hooks
    return settings
  }

  static func isOurs(_ group: OrderedJSON, command: String) -> Bool {
    group["hooks"]?.arrayValue?.contains { $0["command"]?.stringValue == command } ?? false
  }

  // MARK: Files

  private func readSettings() throws -> OrderedJSON {
    guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .object([]) }
    do {
      let text = try String(contentsOf: settingsURL, encoding: .utf8)
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
      let settings = try OrderedJSON.parse(text)
      guard settings.objectMembers != nil else { throw HookError.settingsNotAnObject }
      return settings
    } catch let error as HookError {
      throw error
    } catch {
      throw HookError.unreadableSettings(String(describing: error))
    }
  }

  private func write(_ settings: OrderedJSON, replacing old: OrderedJSON) throws {
    guard settings != old else { return }
    let fm = FileManager.default
    if fm.fileExists(atPath: settingsURL.path) {
      try? fm.removeItem(at: backupURL)
      try fm.copyItem(at: settingsURL, to: backupURL)
    } else {
      try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    // Write through a symlink (eg. settings kept in a dotfiles repository) instead of replacing it.
    try Data(settings.serialized().utf8).write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
  }

  private func writeScript() throws {
    try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  }
}
