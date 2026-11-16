import Foundation

/// Conversations of Claude Code: in the VS Code extension and in terminals.
///
/// Sources (all undocumented internals of Claude Code; keep the knowledge about them in this file):
/// - VS Code global state, key `Anthropic.claude-code`:
///   - `sessionUnread:<first workspace folder>`: the session IDs with an unread reply (the orange tab dot).
///   - `hiddenSessionIds`: archived sessions. They are left out unless they are waiting, unread or working.
/// - Workspace state, key `Anthropic.claude-code`, member `panelTabSessions`: the conversation tabs that were
///   open in that workspace, with their titles.
/// - `~/.claude/sessions/<pid>.json`: running sessions with their folder, `entrypoint` (`claude-vscode` for the
///   extension, something else for a terminal), `status` (`busy`, `idle`, or `waiting` with the reason in
///   `waitingFor`), `startedAt` and `statusUpdatedAt`.
/// - `~/.claude/projects/*/<session>.jsonl`: transcripts, for the title of a conversation without a tab.
/// - Agent Radar's own event log, written by the optional hooks (see `ClaudeHookEvents`): which sessions
///   are waiting for the user, for Claude Code versions or modes that don't write the `waiting` status.
public final class ClaudeCodeProvider: ConversationProvider {
  public static let providerID = "claude-code"
  static let extensionKey = "Anthropic.claude-code"

  private let paths: RadarPaths
  private var titleCache: [String: TitleCacheEntry] = [:]
  private var hostCache: [Int: (host: TerminalHost, tty: String?)] = [:]
  private let seen: TerminalSeen
  private let hostResolver: (Int) -> (host: TerminalHost, tty: String?)

  /// `hostResolver` finds the app and tty of a terminal session's process; replaceable for tests.
  public convenience init(paths: RadarPaths) {
    self.init(paths: paths, hostResolver: { (Processes.host(of: $0), Processes.tty(of: $0)) })
  }

  init(paths: RadarPaths, hostResolver: @escaping (Int) -> (host: TerminalHost, tty: String?)) {
    self.paths = paths
    self.seen = TerminalSeen(paths: paths)
    self.hostResolver = hostResolver
  }

  public var workspaceStateKeys: [String] { [Self.extensionKey] }
  public var globalStateKeys: [String] { [Self.extensionKey] }

  struct LiveSession {
    var sessionId: String
    var cwd: String
    var busy: Bool
    /// Claude Code says it waits for the user (a permission prompt, a question, ...).
    var waiting: Bool = false
    /// Started from the VS Code extension (as opposed to a terminal).
    var isExtension: Bool = true
    var host: TerminalHost = .vscode
    var tty: String?
    var startedAt: Date?
    var statusSince: Date?
  }

  public func scan(workspaces: [WorkspaceInfo], globalState: [String: JSONObject]) -> ProviderResult {
    let global = globalState[Self.extensionKey] ?? [:]
    let archived = Set((global["hiddenSessionIds"] as? [String]) ?? [])
    let live = readLiveSessions()
    let waiting = ClaudeHookEvents.waitingSessions(logURL: ClaudeHookEvents.logURL(paths: paths))
    let keys = workspaces.map(\.key)
    let transcripts = transcriptIndex()
    titleCache = titleCache.filter { transcripts[$0.key] != nil }
    seen.prune(keeping: Set(live.filter { !$0.isExtension }.map(\.sessionId)))

    var result = ProviderResult()
    // Sessions in VS Code (the extension or its integrated terminal) belong to its workspaces; sessions in
    // other terminals are grouped by folder.
    let inVSCode = live.filter { $0.isExtension || $0.host == .vscode }
    for ws in workspaces {
      let tabs = (ws.extensionState[Self.extensionKey]?["panelTabSessions"] as? [JSONObject]) ?? []
      let unread = Set((global["sessionUnread:\(ws.key)"] as? [String]) ?? [])
      let liveHere = inVSCode.filter { Self.workspaceKey(forFolder: $0.cwd, among: keys) == ws.key }
      result.workspaces[ws.key] = Self.merge(tabs: tabs, unread: unread, live: liveHere, waiting: waiting,
                                             archived: archived).map { finish($0, transcripts) }
    }

    for session in live where !session.isExtension && session.host != .vscode {
      let unread = TerminalSeen.isUnread(idle: !session.busy, idleSince: session.statusSince,
                                         startedAt: session.startedAt, lastSeen: seen.seen[session.sessionId])
      let state: ConversationState = session.waiting || waiting.contains(session.sessionId) ? .waiting
        : unread ? .unread : session.busy ? .working : .open
      let conversation = finish(Conversation(id: session.sessionId, title: "", state: state, provider: Self.providerID,
                                             target: .terminal(host: session.host, tty: session.tty)),
                                transcripts, untitled: "New conversation")
      result.terminalFolders[session.cwd, default: TerminalFolder()].conversations.append(conversation)
      if let started = session.startedAt, started > result.terminalFolders[session.cwd]!.lastActive {
        result.terminalFolders[session.cwd]!.lastActive = started
      }
    }
    return result
  }

  public func markTerminalSeen(tty: String) {
    seen.markSeen(readLiveSessions().filter { !$0.isExtension && $0.tty == tty }.map(\.sessionId))
  }

  /// Adds what the transcript knows: when the conversation last changed, and its full title (tab titles are
  /// cut off with "…").
  private func finish(_ item: Conversation, _ transcripts: [String: TranscriptFile],
                      untitled: String = "Untitled conversation") -> Conversation {
    var conversation = item
    if let file = transcripts[conversation.id] {
      conversation.lastActivity = file.modified
      if conversation.title.isEmpty || conversation.title.hasSuffix("…"),
         let full = transcriptTitle(file, sessionId: conversation.id) {
        conversation.title = full
      }
    }
    if conversation.title.isEmpty { conversation.title = untitled }
    return conversation
  }

  /// Combines the sources into one conversation per session. Titles come from the tabs and may be empty.
  /// Archived conversations are left out, unless they're waiting, unread or working.
  static func merge(tabs: [JSONObject], unread: Set<String>, live: [LiveSession], waiting: Set<String>,
                    archived: Set<String> = []) -> [Conversation] {
    let liveById = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
    var titles: [String: String] = [:]
    var order: [String] = []
    func add(_ id: String) {
      guard titles[id] == nil else { return }
      titles[id] = ""
      order.append(id)
    }

    for tab in tabs {
      guard let id = tab["sessionId"] as? String, !id.isEmpty else { continue }
      add(id)
      if titles[id] != nil, let title = tab["title"] as? String, !title.isEmpty { titles[id] = title }
    }
    unread.sorted().forEach(add)
    live.map(\.sessionId).forEach(add)

    return order.compactMap { id in
      let state: ConversationState
      if let session = liveById[id], session.waiting || waiting.contains(id) {
        state = .waiting
      } else if unread.contains(id) {
        state = .unread
      } else if liveById[id]?.busy == true {
        state = .working
      } else {
        state = .open
      }
      if state == .open && archived.contains(id) { return nil }
      let target: ConversationTarget? = if let session = liveById[id], !session.isExtension {
        .terminal(host: .vscode, tty: session.tty)
      } else {
        openURL(sessionId: id).map { .vscode($0) }
      }
      return Conversation(id: id, title: titles[id] ?? "", state: state, provider: providerID, target: target)
    }
  }

  /// The workspace a session belongs to: the one whose first folder is the session's folder, else the one
  /// whose first folder contains it.
  static func workspaceKey(forFolder folder: String, among keys: [String]) -> String? {
    if keys.contains(folder) { return folder }
    return keys.filter { folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
  }

  static func openURL(sessionId: String) -> URL? {
    var components = URLComponents()
    components.scheme = "vscode"
    components.host = "anthropic.claude-code"
    components.path = "/open"
    components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
    return components.url
  }

  /// Running interactive sessions, from VS Code and terminals.
  func readLiveSessions() -> [LiveSession] {
    let dir = paths.claudeHome.appendingPathComponent("sessions")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var alivePids = Set<Int>()
    let sessions: [LiveSession] = files.filter { $0.pathExtension == "json" }.compactMap { file in
      guard let json = JSON.object(contentsOf: file),
            (json["kind"] as? String ?? "interactive") == "interactive",
            let pid = json["pid"] as? Int, ProcessCheck.isAlive(pid),
            let id = json["sessionId"] as? String,
            let cwd = json["cwd"] as? String else { return nil }
      alivePids.insert(pid)
      var session = LiveSession(sessionId: id, cwd: URL(fileURLWithPath: cwd).standardizedFileURL.path,
                                busy: json["status"] as? String == "busy")
      session.waiting = json["status"] as? String == "waiting"
      session.isExtension = json["entrypoint"] as? String == "claude-vscode"
      session.startedAt = Self.date(json["startedAt"])
      session.statusSince = Self.date(json["statusUpdatedAt"])
      if !session.isExtension {
        if hostCache[pid] == nil { hostCache[pid] = hostResolver(pid) }
        session.host = hostCache[pid]!.host
        session.tty = hostCache[pid]!.tty
      }
      return session
    }
    hostCache = hostCache.filter { alivePids.contains($0.key) }
    return sessions
  }

  /// Claude Code writes times as milliseconds since 1970.
  static func date(_ value: Any?) -> Date? {
    (value as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
  }

  /// A transcript file and when it last changed.
  struct TranscriptFile {
    var url: URL
    var modified: Date
    var size: Int
  }

  /// All transcripts by session ID. Listed once per scan.
  func transcriptIndex() -> [String: TranscriptFile] {
    let fm = FileManager.default
    let projects = paths.claudeHome.appendingPathComponent("projects")
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    var index: [String: TranscriptFile] = [:]
    for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
      for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
      where file.pathExtension == "jsonl" {
        let values = try? file.resourceValues(forKeys: Set(keys))
        let entry = TranscriptFile(url: file, modified: values?.contentModificationDate ?? .distantPast,
                                   size: values?.fileSize ?? 0)
        let id = file.deletingPathExtension().lastPathComponent
        if let existing = index[id], existing.modified > entry.modified { continue }
        index[id] = entry
      }
    }
    return index
  }

  /// What has been read of a transcript so far, so a growing transcript is only read from where it was left.
  struct TitleCacheEntry {
    var offset: Int = 0
    var titles = TranscriptTitles()
  }

  /// The title Claude Code gave the conversation (a custom title wins over the generated one).
  func transcriptTitle(_ file: TranscriptFile, sessionId: String) -> String? {
    var entry = titleCache[sessionId] ?? TitleCacheEntry()
    if file.size < entry.offset { entry = TitleCacheEntry() }  // rewritten: start over
    if file.size > entry.offset, let handle = try? FileHandle(forReadingFrom: file.url) {
      defer { try? handle.close() }
      try? handle.seek(toOffset: UInt64(entry.offset))
      let data = (try? handle.readToEnd()) ?? Data()
      // Only complete lines; a line still being written is read next time.
      if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
        entry.titles.read(data[data.startIndex...lastNewline])
        entry.offset += lastNewline - data.startIndex + 1
      }
    }
    titleCache[sessionId] = entry
    return entry.titles.title
  }

  static func title(fromTranscript data: Data) -> String? {
    var titles = TranscriptTitles()
    titles.read(data)
    return titles.title
  }
}

/// The titles found in (part of) a transcript.
struct TranscriptTitles {
  var aiTitle: String?
  var customTitle: String?
  var title: String? { customTitle ?? aiTitle }

  mutating func read(_ data: Data) {
    for line in data.split(separator: UInt8(ascii: "\n")) {
      let isCustom = line.range(of: Data("\"custom-title\"".utf8)) != nil
      let isAI = !isCustom && line.range(of: Data("\"ai-title\"".utf8)) != nil
      guard isCustom || isAI, let json = JSON.object(Data(line)) else { continue }
      if isCustom, json["type"] as? String == "custom-title", let t = json["customTitle"] as? String { customTitle = t }
      if isAI, json["type"] as? String == "ai-title", let t = json["aiTitle"] as? String { aiTitle = t }
    }
  }
}

/// The event log written by the optional Claude Code hooks (the script in `ClaudeHooks`): one JSON object per line
/// with `event`, `session`, and depending on the event `type` (notification type) and `tool`.
public enum ClaudeHookEvents {
  static let maxLogSize = 256 * 1024

  public static func logURL(paths: RadarPaths) -> URL {
    paths.radarHome.appendingPathComponent("claude-code-events.jsonl")
  }

  struct Event {
    var event: String
    var session: String
    var type: String
    var tool: String
  }

  /// Session IDs whose last relevant event says they're waiting for the user. Compacts the log when it grows.
  static func waitingSessions(logURL: URL) -> Set<String> {
    guard let data = try? Data(contentsOf: logURL) else { return [] }
    let waiting = waitingSessions(events: parse(data))
    if data.count > maxLogSize { compact(logURL: logURL, waiting: waiting) }
    return waiting
  }

  static func parse(_ data: Data) -> [Event] {
    data.split(separator: UInt8(ascii: "\n")).compactMap { line in
      guard let json = JSON.object(Data(line)),
            let event = json["event"] as? String,
            let session = json["session"] as? String, !session.isEmpty else { return nil }
      return Event(event: event, session: session, type: json["type"] as? String ?? "", tool: json["tool"] as? String ?? "")
    }
  }

  /// Tools that wait for the user's answer while they run.
  static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
  /// Notification types that mean the session is blocked on the user. `idle_prompt` (sent a while after every
  /// finished reply) is deliberately not one of them; that case is covered by "unread".
  static let waitingNotifications: Set<String> = ["permission_prompt", "elicitation_dialog"]

  static func waitingSessions(events: [Event]) -> Set<String> {
    var waiting = Set<String>()
    for e in events {
      switch e.event {
      case "Notification":
        if waitingNotifications.contains(e.type) { waiting.insert(e.session) }
      case "PermissionRequest", "Elicitation":
        waiting.insert(e.session)
      case "PreToolUse":
        if questionTools.contains(e.tool) { waiting.insert(e.session) }
      case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult", "UserPromptSubmit", "Stop",
           "StopFailure", "SessionStart", "SessionEnd":
        waiting.remove(e.session)
      default:
        break
      }
    }
    return waiting
  }

  /// Rewrites the log to just the sessions that are waiting now.
  /// An event appended by a hook while compacting can get lost; the next event of that session corrects it.
  static func compact(logURL: URL, waiting: Set<String>) {
    let lines = waiting.sorted().map { #"{"event":"Notification","session":"\#($0)","type":"permission_prompt"}"# }
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try? Data(text.utf8).write(to: logURL, options: .atomic)
  }
}
