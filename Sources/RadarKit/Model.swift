import Foundation

/// State of a single AI conversation, as far as Agent Radar can tell. Ordered by urgency.
public enum ConversationState: Int, Comparable, Sendable {
  /// Blocked on the user: a permission prompt or a question.
  case waiting = 0
  /// Finished a reply that the user hasn't looked at yet.
  case unread = 1
  /// Currently working.
  case working = 2
  /// Open in a tab, nothing pending.
  case open = 3

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public var needsAttention: Bool { self == .waiting || self == .unread }
}

public struct Conversation: Identifiable, Hashable, Sendable {
  /// Provider-specific session ID.
  public var id: String
  public var title: String
  public var state: ConversationState
  /// Which provider reported it, eg. "claude-code".
  public var provider: String
  /// How to bring this conversation to the front, if the provider knows.
  public var target: ConversationTarget?
  /// When the conversation last changed (a message, a tool call, ...), if known.
  public var lastActivity: Date?

  public init(id: String, title: String, state: ConversationState, provider: String, target: ConversationTarget? = nil,
              lastActivity: Date? = nil) {
    self.id = id
    self.title = title
    self.state = state
    self.provider = provider
    self.target = target
    self.lastActivity = lastActivity
  }
}

/// Where a conversation lives, for bringing it to the front.
public enum ConversationTarget: Hashable, Sendable {
  /// A VS Code URL that opens the conversation (after opening its workspace).
  case vscode(URL)
  /// A session in a terminal, identified by its tty (eg. `/dev/ttys003`).
  case terminal(host: TerminalHost, tty: String?)
}

public enum WorkspaceKind: Sendable {
  /// A VS Code folder or .code-workspace file.
  case vscode
  /// A folder with Claude Code sessions running in a terminal.
  case terminalFolder
}

/// An entry in the menu: a VS Code workspace (a folder or a .code-workspace file), or a folder with terminal
/// sessions.
public struct Workspace: Identifiable, Sendable {
  /// The first folder of the workspace (AI extensions key their per-workspace state on this), or for a terminal
  /// folder "terminal:" plus the folder.
  public var id: String
  public var kind: WorkspaceKind
  public var name: String
  /// The folder or .code-workspace file (what to pass to VS Code to reopen it).
  public var openTarget: URL
  public var isOpen: Bool
  public var lastUsed: Date
  public var conversations: [Conversation]

  public init(id: String, kind: WorkspaceKind = .vscode, name: String, openTarget: URL, isOpen: Bool, lastUsed: Date,
              conversations: [Conversation]) {
    self.id = id
    self.kind = kind
    self.name = name
    self.openTarget = openTarget
    self.isOpen = isOpen
    self.lastUsed = lastUsed
    self.conversations = conversations
  }

  public var attentionCount: Int { conversations.filter { $0.state.needsAttention }.count }
  public var workingCount: Int { conversations.filter { $0.state == .working }.count }
  public var attentionConversations: [Conversation] {
    Self.sorted(conversations.filter { $0.state.needsAttention })
  }

  /// All conversations, for the workspace's foldout: those that need the user first, then the most recently
  /// changed.
  public var foldoutConversations: [Conversation] {
    conversations.sorted { a, b in
      if a.state.needsAttention != b.state.needsAttention { return a.state.needsAttention }
      if a.lastActivity != b.lastActivity { return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast) }
      return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
  }

  /// When the most recently changed conversation last changed.
  public var lastActivity: Date? { conversations.compactMap(\.lastActivity).max() }

  static func sorted(_ list: [Conversation]) -> [Conversation] {
    list.sorted {
      $0.state != $1.state ? $0.state < $1.state : $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
}

/// Information about a workspace gathered from VS Code, handed to each provider.
public struct WorkspaceInfo: @unchecked Sendable {
  public var key: String
  public var name: String
  public var openTarget: URL
  public var isOpen: Bool
  public var lastUsed: Date
  /// Raw extension state from the workspace's own state.vscdb, keyed by storage key (usually the extension ID).
  public var extensionState: [String: JSONObject]

  public init(key: String, name: String, openTarget: URL, isOpen: Bool, lastUsed: Date, extensionState: [String: JSONObject]) {
    self.key = key
    self.name = name
    self.openTarget = openTarget
    self.isOpen = isOpen
    self.lastUsed = lastUsed
    self.extensionState = extensionState
  }
}

/// What a provider found.
public struct ProviderResult {
  /// Conversations per VS Code workspace key. Keys of unknown workspaces are ignored.
  public var workspaces: [String: [Conversation]] = [:]
  /// Terminal sessions per folder.
  public var terminalFolders: [String: TerminalFolder] = [:]

  public init() {}
}

public struct TerminalFolder {
  public var conversations: [Conversation] = []
  /// When the most recent session in it started.
  public var lastActive: Date = .distantPast

  public init() {}
}

/// A source of AI conversations (Claude Code, and in the future other assistants).
public protocol ConversationProvider {
  /// Storage keys (usually extension IDs) this provider wants from each workspace's state.vscdb.
  var workspaceStateKeys: [String] { get }
  /// Storage keys (usually extension IDs) this provider wants from VS Code's global state.vscdb.
  var globalStateKeys: [String] { get }
  func scan(workspaces: [WorkspaceInfo], globalState: [String: JSONObject]) -> ProviderResult
  /// The user is looking at the terminal tab with this tty: its sessions count as seen.
  func markTerminalSeen(tty: String)
  /// The user surely sees every VS Code conversation's latest reply now.
  func markVSCodeSeen()
  /// The user marked these conversations as read, or opened them from the menu.
  func markRead(_ conversationIds: [String])
}

/// The three sections of the menu.
public struct WorkspaceSections: Sendable {
  public var active: [Workspace] = []
  public var terminal: [Workspace] = []
  public var closedWithConversations: [Workspace] = []
  public var recent: [Workspace] = []

  public init(active: [Workspace] = [], terminal: [Workspace] = [], closedWithConversations: [Workspace] = [],
              recent: [Workspace] = []) {
    self.active = active
    self.terminal = terminal
    self.closedWithConversations = closedWithConversations
    self.recent = recent
  }

  public var attentionCount: Int { (active + terminal + closedWithConversations).reduce(0) { $0 + $1.attentionCount } }

  public static let recentLimit = 10

  /// Splits workspaces into the menu sections. Within a section, workspaces that need the user come first,
  /// then the most recently used.
  public static func make(from workspaces: [Workspace]) -> WorkspaceSections {
    let order: (Workspace, Workspace) -> Bool = { a, b in
      if (a.attentionCount > 0) != (b.attentionCount > 0) { return a.attentionCount > 0 }
      return a.lastUsed > b.lastUsed
    }
    var result = WorkspaceSections()
    result.terminal = workspaces.filter { $0.kind == .terminalFolder }.sorted(by: order)
    let workspaces = workspaces.filter { $0.kind == .vscode }
    result.active = workspaces.filter(\.isOpen).sorted(by: order)
    result.closedWithConversations = workspaces.filter { !$0.isOpen && !$0.conversations.isEmpty }.sorted(by: order)
    result.recent = Array(workspaces.filter { !$0.isOpen && $0.conversations.isEmpty }.sorted(by: order).prefix(recentLimit))
    return result
  }
}

/// Short "how long ago" labels for the menu: "now", "15m", "3h", "2d", "5w", "1y".
public enum AgeFormatter {
  public static func short(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
    if minutes < 1 { return "now" }
    if hours < 1 { return "\(minutes)m" }
    if days < 1 { return "\(hours)h" }
    if days < 7 { return "\(days)d" }
    if days < 365 { return "\(days / 7)w" }
    return "\(days / 365)y"
  }
}
