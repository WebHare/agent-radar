import Foundation

/// Conversations of Claude Code: in the VS Code extension and in terminals.
///
/// Sources (all undocumented internals of Claude Code; keep the knowledge about them in this file):
/// - VS Code global state, key `Anthropic.claude-code`:
///   - `sessionUnread:<first workspace folder>`: the session IDs with an unread reply (the orange tab dot).
///     The extension misses replies that finish in a visible tab of an unfocused window; `VSCodeSeen` adds those.
///   - `hiddenSessionIds`: archived sessions. They are left out unless they are waiting, unread or working.
/// - Workspace state, key `Anthropic.claude-code`, member `panelTabSessions`: the conversation tabs that were
///   open in that workspace, with their titles.
/// - Agent Radar's VS Code extension (see `VSCodeCompanion`): which conversation tabs are in front of the focused
///   window. A conversation tab is a webview with `panelViewType`, titled like its `panelTabSessions` entry.
/// - `~/.claude/sessions/<pid>.json`: running sessions with their folder, `entrypoint` (`claude-vscode` for the
///   extension, something else for a terminal), `status` (`busy`, `idle`, or `waiting` with the reason in
///   `waitingFor`), `startedAt` and `statusUpdatedAt`.
/// - `~/.claude/projects/*/<session>.jsonl`: transcripts, for the title of a conversation without a tab.
/// - Agent Radar's own event log, written by the optional hooks (see `ClaudeHookEvents`): which sessions
///   are waiting for the user, for Claude Code versions or modes that don't write the `waiting` status.
public final class ClaudeCodeProvider: ConversationProvider {
  public static let providerID = "claude-code"
  static let extensionKey = "Anthropic.claude-code"
  /// The `viewType` of a conversation tab in the editor area. Conversations in the sidebar are webview views,
  /// which other extensions can't see.
  static let panelViewType = "mainThreadWebview-claudeVSCodePanel"

  private let paths: RadarPaths
  private var titleCache: [String: TitleCacheEntry] = [:]
  private var hostCache: [Int: (host: TerminalHost, tty: String?)] = [:]
  private let seen: TerminalSeen
  private let vscodeSeen: VSCodeSeen
  private let hostResolver: (Int) -> (host: TerminalHost, tty: String?)
  /// How far the hook event log has been read, to report the events added since (nil before the first scan).
  private var hookLogOffset: Int?

  /// `hostResolver` finds the app and tty of a terminal session's process; replaceable for tests.
  public convenience init(paths: RadarPaths) {
    self.init(paths: paths, hostResolver: { (Processes.host(of: $0), Processes.tty(of: $0)) })
  }

  init(paths: RadarPaths, hostResolver: @escaping (Int) -> (host: TerminalHost, tty: String?)) {
    self.paths = paths
    self.seen = TerminalSeen(paths: paths)
    self.vscodeSeen = VSCodeSeen(paths: paths)
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
    let hookLog = ClaudeHookEvents.read(logURL: ClaudeHookEvents.logURL(paths: paths), newFrom: hookLogOffset)
    hookLogOffset = hookLog.end
    let waiting = Set(hookLog.waiting.keys)
    let waitingReasons = hookLog.waiting.mapValues { e in
      "the hooks' last event for it (\(e.event)\(e.time.map { " at \(DebugLog.time($0))" } ?? "")) means it waits: \(ClaudeHookEvents.effect(of: e).reason)"
    }
    let keys = workspaces.map(\.key)
    let transcripts = transcriptIndex()
    titleCache = titleCache.filter { transcripts[$0.key] != nil }
    seen.prune(keeping: Set(live.filter { !$0.isExtension }.map(\.sessionId)))
    let companionWindows = VSCodeCompanion.read(paths: paths)
    let now = Date()

    var result = ProviderResult()
    // Sessions in VS Code (the extension or its integrated terminal) belong to its workspaces; sessions in
    // other terminals are grouped by folder.
    let inVSCode = live.filter { $0.isExtension || $0.host == .vscode }
    for ws in workspaces {
      let tabs = (ws.extensionState[Self.extensionKey]?["panelTabSessions"] as? [JSONObject]) ?? []
      let liveHere = inVSCode.filter { Self.workspaceKey(forFolder: $0.cwd, among: keys) == ws.key }
      vscodeSeen.markInFront(Self.seenTabs(tabs: tabs, windows: companionWindows.filter { $0.key == ws.key }, now: now),
                             now: now)
      // The extension's unread dot, minus what the user marked as read in the menu since, plus replies the
      // extension misses: those the app isn't sure the user saw. TODO: drop the last part when
      // https://github.com/anthropics/claude-code/issues/110457 is fixed (https://github.com/WebHare/agent-radar/issues/3).
      var reasons: [String: String] = [:]
      // Explains a live session's unread state from VS Code's side; the extension's dot is added below.
      for session in liveHere where !session.busy && !session.waiting {
        reasons[session.sessionId] = vscodeSeen.explain(idleSince: session.statusSince, startedAt: session.startedAt,
                                                        sessionId: session.sessionId)
      }
      let extensionUnread = ((global["sessionUnread:\(ws.key)"] as? [String]) ?? []).filter { id in
        guard let read = vscodeSeen.read[id] else {
          reasons[id] = "the Claude Code extension marks it unread (the orange dot in VS Code)"
          return true
        }
        let reply = liveHere.first { $0.sessionId == id }?.statusSince ?? transcripts[id]?.modified ?? .distantFuture
        if reply > read {
          reasons[id] = "the Claude Code extension marks it unread, and its reply at \(DebugLog.time(reply)) came after you marked it as read at \(DebugLog.time(read))"
          return true
        }
        reasons[id] = "the Claude Code extension still marks it unread, but you marked it as read at \(DebugLog.time(read)), after its last reply"
        return false
      }
      let unread = Set(extensionUnread).union(liveHere.filter {
        !$0.waiting && VSCodeSeen.isUnread(idle: !$0.busy, idleSince: $0.statusSince, startedAt: $0.startedAt,
                                           seenSince: vscodeSeen.seenSince($0.sessionId))
      }.map(\.sessionId))
      result.workspaces[ws.key] = Self.merge(tabs: tabs, unread: unread, live: liveHere, waiting: waiting,
                                             archived: archived, reasons: reasons,
                                             waitingReasons: waitingReasons).map { finish($0, transcripts) }
    }
    // Keep the read marks of conversations that aren't listed but may come back: an archived conversation that
    // was marked as read drops out of the list, and would turn unread again if its mark were forgotten.
    let extensionUnreadIds = global.filter { $0.key.hasPrefix("sessionUnread:") }.values
      .flatMap { ($0 as? [String]) ?? [] }
    for (e, effect, was, now) in hookLog.newEvents {
      let what = e.event + (e.tool.isEmpty ? "" : " \(e.tool)") + (e.type.isEmpty ? "" : " (\(e.type))")
      let action = switch (was, now) {
      case (false, true): "now waiting for input"
      case (true, false): "no longer waiting for input"
      case (true, true): "still waiting for input"
      case (false, false): effect.waits == false ? "wasn't waiting, nothing changes" : "not waiting, nothing changes"
      }
      let fired = e.time.map { ", fired at \(DebugLog.time($0, seconds: true))" } ?? ""
      result.log.append((e.session, "\(what)\(fired): \(action). Why: \(effect.reason)."))
    }
    vscodeSeen.prune(keeping: Set(result.workspaces.values.flatMap { $0.map(\.id) })
      .union(archived).union(live.map(\.sessionId)).union(extensionUnreadIds))

    for session in live where !session.isExtension && session.host != .vscode {
      let unread = TerminalSeen.isUnread(idle: !session.busy, idleSince: session.statusSince,
                                         startedAt: session.startedAt, lastSeen: seen.seen[session.sessionId])
      let state: ConversationState = session.waiting || waiting.contains(session.sessionId) ? .waiting
        : unread ? .unread : session.busy ? .working : .open
      var conversation = finish(Conversation(id: session.sessionId, title: "", state: state, provider: Self.providerID,
                                             target: .terminal(host: session.host, tty: session.tty)),
                                transcripts, untitled: "New conversation")
      let lastSeen = seen.seen[session.sessionId].map { "its terminal tab was last in front at \(DebugLog.time($0))" }
        ?? "its terminal tab hasn't been in front since it started"
      let finished = session.statusSince.map { "its reply finished at \(DebugLog.time($0))" } ?? "it's idle"
      let notSeen = seen.seen[session.sessionId].map { "its terminal tab was last in front before that, at \(DebugLog.time($0))" }
        ?? "its terminal tab hasn't been in front since it started"
      conversation.stateReason = switch state {
      case .waiting: session.waiting ? "the session file says it waits for the user"
        : waitingReasons[session.sessionId] ?? "the hooks say it waits"
      case .unread: "\(finished), and \(notSeen)"
      case .working: "its Claude Code process is busy"
      case .open: "\(finished); \(lastSeen)"
      }
      result.terminalFolders[session.cwd, default: TerminalFolder()].conversations.append(conversation)
      if let started = session.startedAt, started > result.terminalFolders[session.cwd]!.lastActive {
        result.terminalFolders[session.cwd]!.lastActive = started
      }
    }
    return result
  }

  public func markVSCodeSeen() {
    vscodeSeen.markAllSeen()
  }

  public func markRead(_ conversationIds: [String]) {
    vscodeSeen.markRead(conversationIds)
    seen.markSeen(conversationIds)
  }

  public func markTerminalSeen(tty: String) {
    seen.markSeen(readLiveSessions().filter { !$0.isExtension && $0.tty == tty }.map(\.sessionId))
  }

  /// When the user last saw each conversation's tab in front of a focused window, by session ID. A tab is matched
  /// to its conversation by title; a title that several of the workspace's conversations share matches none, as
  /// the app can't tell which one the user saw.
  static func seenTabs(tabs: [JSONObject], windows: [VSCodeCompanion.Window], now: Date) -> [String: Date] {
    let byTitle = Dictionary(grouping: tabs.compactMap { tab -> (title: String, id: String)? in
      guard let id = tab["sessionId"] as? String, let title = tab["title"] as? String else { return nil }
      return (title, id)
    }, by: \.title)
    var result: [String: Date] = [:]
    for window in windows {
      for tab in window.tabs where tab.viewType == panelViewType {
        guard let matches = byTitle[tab.label], matches.count == 1, let seen = window.seen(tab, now: now) else { continue }
        result[matches[0].id] = max(result[matches[0].id] ?? .distantPast, seen)
      }
    }
    return result
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
  /// `reasons` explains the unread or open state of a conversation, `waitingReasons` why the hooks say it waits.
  static func merge(tabs: [JSONObject], unread: Set<String>, live: [LiveSession], waiting: Set<String>,
                    archived: Set<String> = [], reasons: [String: String] = [:],
                    waitingReasons: [String: String] = [:]) -> [Conversation] {
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
      let reason: String
      if let session = liveById[id], session.waiting || waiting.contains(id) {
        state = .waiting
        reason = session.waiting ? "the session file says it waits for the user"
          : waitingReasons[id] ?? "the hooks say it waits for the user"
      } else if unread.contains(id) {
        state = .unread
        reason = reasons[id] ?? "it has an unread reply"
      } else if liveById[id]?.busy == true {
        state = .working
        reason = "its Claude Code process is busy"
      } else {
        state = .open
        reason = reasons[id] ?? (liveById[id] == nil ? "not running, nothing pending" : "running, nothing pending")
      }
      if state == .open && archived.contains(id) { return nil }
      let target: ConversationTarget? = if let session = liveById[id], !session.isExtension {
        .terminal(host: .vscode, tty: session.tty)
      } else {
        openURL(sessionId: id).map { .vscode($0) }
      }
      var conversation = Conversation(id: id, title: titles[id] ?? "", state: state, provider: providerID, target: target)
      conversation.stateReason = reason
      return conversation
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
/// with `event`, `session`, `time` and depending on the event `type` (notification type) and `tool`.
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
    /// When the hook ran.
    var time: Date?
  }

  /// What an event means for whether its conversation waits for the user, and why.
  struct Effect {
    /// true: it waits now; false: it no longer waits; nil: the event doesn't change it.
    var waits: Bool?
    var reason: String
  }

  /// Tools that wait for the user's answer while they run.
  static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
  /// Notification types that mean the session is blocked on the user. `idle_prompt` (sent a while after every
  /// finished reply) is deliberately not one of them; that case is covered by "unread".
  static let waitingNotifications: Set<String> = ["permission_prompt", "elicitation_dialog"]

  static func effect(of e: Event) -> Effect {
    switch e.event {
    case "Notification":
      return waitingNotifications.contains(e.type)
        ? Effect(waits: true, reason: "a \(e.type) notification: Claude Code asks the user something")
        : Effect(waits: nil, reason: "notification type '\(e.type)' isn't about waiting for input (a finished reply shows as unread instead)")
    case "PermissionRequest":
      return Effect(waits: true, reason: "a permission dialog is shown\(e.tool.isEmpty ? "" : " for \(e.tool)")")
    case "Elicitation":
      return Effect(waits: true, reason: "an MCP server asks the user for input")
    case "PreToolUse":
      return questionTools.contains(e.tool)
        ? Effect(waits: true, reason: "\(e.tool) waits for the user's answer")
        : Effect(waits: nil, reason: "\(e.tool.isEmpty ? "the tool" : e.tool) doesn't wait for the user")
    case "PostToolUse", "PostToolUseFailure":
      return Effect(waits: false, reason: "\(e.tool.isEmpty ? "a tool" : e.tool) ran, so any question or permission was answered")
    case "PermissionDenied", "ElicitationResult":
      return Effect(waits: false, reason: "the user answered")
    case "UserPromptSubmit":
      return Effect(waits: false, reason: "the user sent a message")
    case "Stop", "StopFailure":
      return Effect(waits: false, reason: "the reply ended. Hooks don't decide unread: that comes from the session file's idle status and when Agent Radar was last sure you saw it")
    case "SessionStart", "SessionEnd":
      return Effect(waits: false, reason: "the session \(e.event == "SessionStart" ? "started" : "ended")")
    default:
      return Effect(waits: nil, reason: "Agent Radar doesn't use \(e.event.isEmpty ? "this event" : e.event) events")
    }
  }

  /// Session IDs whose last relevant event says they're waiting for the user. Compacts the log when it grows.
  static func waitingSessions(logURL: URL) -> Set<String> {
    Set(read(logURL: logURL, newFrom: nil).waiting.keys)
  }

  /// What the log says, and the events added since byte `newFrom` with what each did.
  struct LogState {
    /// Waiting sessions, with the event that made them wait.
    var waiting: [String: Event] = [:]
    var newEvents: [(event: Event, effect: Effect, wasWaiting: Bool, isWaiting: Bool)] = []
    /// Where the next read starts. The hook script writes each line at once, so lines aren't cut off.
    var end = 0
  }

  static func read(logURL: URL, newFrom offset: Int?) -> LogState {
    guard let data = try? Data(contentsOf: logURL) else { return LogState() }
    var state = LogState()
    state.end = data.count
    // A log that shrank was compacted: what's in it now isn't new.
    let newFrom = offset.map { $0 <= state.end ? $0 : state.end } ?? state.end
    let old = parse(data.prefix(newFrom))
    let all = old + parse(data[newFrom..<state.end])
    for (i, e) in all.enumerated() {
      let effect = effect(of: e)
      let was = state.waiting[e.session] != nil
      if effect.waits == true { state.waiting[e.session] = e }
      if effect.waits == false { state.waiting[e.session] = nil }
      if i >= old.count {
        state.newEvents.append((e, effect, was, state.waiting[e.session] != nil))
      }
    }
    if data.count > maxLogSize { state.end = compact(logURL: logURL, waiting: Set(state.waiting.keys)) }
    return state
  }

  static func parse(_ data: Data) -> [Event] {
    data.split(separator: UInt8(ascii: "\n")).compactMap { line in
      guard let json = JSON.object(Data(line)),
            let event = json["event"] as? String,
            let session = json["session"] as? String, !session.isEmpty else { return nil }
      return Event(event: event, session: session, type: json["type"] as? String ?? "", tool: json["tool"] as? String ?? "",
                   time: (json["time"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
  }

  static func waitingSessions(events: [Event]) -> Set<String> {
    var waiting = Set<String>()
    for e in events {
      switch effect(of: e).waits {
      case true?: waiting.insert(e.session)
      case false?: waiting.remove(e.session)
      case nil: break
      }
    }
    return waiting
  }

  /// Rewrites the log to just the sessions that are waiting now, and returns its new size.
  /// An event appended by a hook while compacting can get lost; the next event of that session corrects it.
  static func compact(logURL: URL, waiting: Set<String>) -> Int {
    let lines = waiting.sorted().map { #"{"event":"Notification","session":"\#($0)","type":"permission_prompt"}"# }
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try? Data(text.utf8).write(to: logURL, options: .atomic)
    return text.utf8.count
  }
}
