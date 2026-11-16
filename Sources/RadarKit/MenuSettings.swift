import Foundation

/// What the menu bar number counts.
public enum MenuBarCounter: String, CaseIterable, Sendable {
  /// Conversations waiting for input or with unread messages.
  case needsUser
  /// Only conversations waiting for input.
  case waitingOnly
  /// No number; the icon still changes when something needs the user.
  case iconOnly
}

/// The user's choices for the menu and the menu bar item, stored in the app's user defaults.
public struct MenuSettings: Equatable, Sendable {
  public var counter: MenuBarCounter = .needsUser
  public var showTerminal = true
  public var showClosed = true
  public var showRecent = true

  public enum Key {
    public static let counter = "menuBarCounter"
    public static let showTerminal = "showTerminalSessions"
    public static let showClosed = "showClosedWorkspaces"
    public static let showRecent = "showRecentWorkspaces"
  }

  public init() {}

  public init(defaults: UserDefaults) {
    counter = defaults.string(forKey: Key.counter).flatMap(MenuBarCounter.init(rawValue:)) ?? .needsUser
    showTerminal = defaults.object(forKey: Key.showTerminal) as? Bool ?? true
    showClosed = defaults.object(forKey: Key.showClosed) as? Bool ?? true
    showRecent = defaults.object(forKey: Key.showRecent) as? Bool ?? true
  }

  public func save(to defaults: UserDefaults) {
    defaults.set(counter.rawValue, forKey: Key.counter)
    defaults.set(showTerminal, forKey: Key.showTerminal)
    defaults.set(showClosed, forKey: Key.showClosed)
    defaults.set(showRecent, forKey: Key.showRecent)
  }

  /// The sections the menu shows. Active workspaces are always shown.
  public func visibleSections(of sections: WorkspaceSections) -> WorkspaceSections {
    var result = sections
    if !showTerminal { result.terminal = [] }
    if !showClosed { result.closedWithConversations = [] }
    if !showRecent { result.recent = [] }
    return result
  }

  /// The number for the menu bar item: only what the menu shows counts, so the number always matches it.
  public func menuBarCount(for sections: WorkspaceSections) -> Int {
    let visible = visibleSections(of: sections)
    switch counter {
    case .needsUser, .iconOnly: return visible.attentionCount
    case .waitingOnly: return visible.waitingCount
    }
  }

  public var menuBarShowsNumber: Bool { counter != .iconOnly }
}

extension WorkspaceSections {
  /// Conversations waiting for input, in the sections that count.
  public var waitingCount: Int {
    (active + terminal + closedWithConversations).reduce(0) { total, ws in
      total + ws.conversations.filter { $0.state == .waiting }.count
    }
  }
}
