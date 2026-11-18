import AppKit
import SwiftUI
import RadarKit

struct MenuContent: View {
  @ObservedObject var store: RadarStore
  let settings: MenuSettings
  /// The workspace whose foldout is open.
  @State private var foldout: String?
  /// The window the menu bar item shows the menu in, so going somewhere can close it.
  @State private var menuWindow: NSWindow?
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          let sections = settings.visibleSections(of: store.sections)
          section("Active workspaces", sections.active, empty: "No VS Code windows with Claude Code open")
          section("Terminal sessions", sections.terminal, empty: nil)
          section("Closed workspaces with open conversations", sections.closedWithConversations, empty: nil)
          section("Recent workspaces", sections.recent, empty: nil)
        }
        .padding(10)
      }
      .frame(maxHeight: 560)
      .fixedSize(horizontal: false, vertical: true)

      Divider()
      HStack {
        Button("Refresh") { store.refresh() }
        Spacer()
        Button("Settings…") { showSettings() }
          .keyboardShortcut(",")
        Button("Quit") { NSApp.terminate(nil) }
          .keyboardShortcut("q")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      if let footer = BuildInfo.current.menuFooter() {
        Text(footer)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
      }
    }
    .frame(width: 360)
    .background(WindowReader(window: $menuWindow))
    .environment(\.dismissMenu, DismissMenuAction {
      foldout = nil
      menuWindow?.close()
    })
  }

  /// Opens the settings window, or brings it back to the front when it's already open behind other apps.
  /// `SettingsLink` alone leaves an already open window where it is, and an accessory app isn't activated
  /// by clicking its menu, so the window is raised explicitly.
  private func showSettings() {
    menuWindow?.close()
    NSApp.activate(ignoringOtherApps: true)
    openSettings()
    // The window may only exist after openSettings has been handled.
    DispatchQueue.main.async {
      for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
      }
    }
  }

  @ViewBuilder
  private func section(_ title: String, _ workspaces: [Workspace], empty: String?) -> some View {
    if !workspaces.isEmpty || empty != nil {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.bottom, 2)
        if workspaces.isEmpty, let empty {
          Text(empty)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
        }
        ForEach(workspaces) { workspace in
          WorkspaceRow(workspace: workspace, foldout: $foldout, store: store)
        }
      }
    }
  }
}

struct WorkspaceRow: View {
  let workspace: Workspace
  @Binding var foldout: String?
  let store: RadarStore
  @Environment(\.dismissMenu) private var dismissMenu
  @State private var hoverTask: Task<Void, Never>?

  /// How long the pointer has to rest on a row before its foldout opens.
  static let hoverDelay: Duration = .milliseconds(350)

  private var hasFoldout: Bool { !workspace.conversations.isEmpty }
  private var isFoldedOut: Binding<Bool> {
    Binding(get: { foldout == workspace.id }, set: { if !$0, foldout == workspace.id { foldout = nil } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HoverButton(highlighted: foldout == workspace.id, action: click, onHover: hover) {
        HStack(spacing: 8) {
          Image(systemName: icon)
            .foregroundStyle(.secondary)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 1) {
            Text(workspace.name)
              .lineLimit(1)
            if let subtitle {
              Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 4)
          if workspace.workingCount > 0 {
            ProgressView()
              .controlSize(.small)
              .help(workspace.workingCount == 1 ? "Claude is working" : "\(workspace.workingCount) conversations are working")
          }
          if workspace.attentionCount > 0 {
            CountBadge(count: workspace.attentionCount)
          }
          if let last = workspace.lastActivity {
            AgeLabel(date: last)
          }
          if hasFoldout {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
      }
      .help(workspace.openTarget.path)
      .contextMenu { MarkAllAsReadButton(workspace: workspace, store: store) }
      .popover(isPresented: isFoldedOut, arrowEdge: .trailing) {
        ConversationFoldout(workspace: workspace, store: store, dismissMenu: dismissMenu)
      }

      ForEach(workspace.attentionConversations) { conversation in
        ConversationButton(conversation: conversation, workspace: workspace, store: store) {
          ConversationLine(conversation: conversation)
            .padding(.leading, 24)
        }
      }
    }
  }

  /// Clicking a row always goes to its workspace; only resting on it opens the foldout.
  private func click() {
    hoverTask?.cancel()
    dismissMenu()
    Opener.open(workspace)
  }

  /// Resting on a row opens its foldout, closing any other; resting on a row without conversations closes it.
  private func hover(_ inside: Bool) {
    hoverTask?.cancel()
    guard inside else { return }
    hoverTask = Task { @MainActor in
      try? await Task.sleep(for: Self.hoverDelay)
      guard !Task.isCancelled else { return }
      if hasFoldout {
        foldout = workspace.id
      } else if foldout != nil {
        foldout = nil
      }
    }
  }

  private var icon: String {
    if workspace.kind == .terminalFolder { return "terminal" }
    return workspace.openTarget.pathExtension == "code-workspace" ? "square.stack" : "folder"
  }

  private var subtitle: String? {
    var parts: [String] = []
    let waiting = workspace.conversations.filter { $0.state == .waiting }.count
    let unread = workspace.conversations.filter { $0.state == .unread }.count
    if waiting > 0 { parts.append("\(waiting) waiting") }
    if unread > 0 { parts.append("\(unread) unread") }
    if workspace.workingCount > 0 { parts.append("\(workspace.workingCount) working") }
    let total = workspace.conversations.count
    if total > 0 { parts.append(total == 1 ? "1 conversation" : "\(total) conversations") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// The workspace's conversations, with their state and when they last changed. Clicking one goes straight to it,
/// closing the menu.
struct ConversationFoldout: View {
  let workspace: Workspace
  let store: RadarStore
  let dismissMenu: DismissMenuAction

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(workspace.name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(workspace.foldoutConversations) { conversation in
            ConversationButton(conversation: conversation, workspace: workspace, store: store,
                               dismissMenu: dismissMenu) {
              ConversationLine(conversation: conversation, showAge: true)
            }
          }
        }
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)
      let unread = workspace.conversations.filter { $0.state == .unread }
      if workspace.kind == .vscode || !unread.isEmpty {
        Divider().padding(.vertical, 2)
      }
      if !unread.isEmpty {
        HoverButton(action: { store.markRead(unread) }) {
          Label("Mark all as read", systemImage: "checkmark.circle")
            .font(.callout)
        }
      }
      if workspace.kind == .vscode {
        HoverButton(action: { dismissMenu(); Opener.open(workspace) }) {
          Label(workspace.isOpen ? "Show workspace in VS Code" : "Open workspace in VS Code", systemImage: "arrow.up.forward.app")
            .font(.callout)
        }
      }
    }
    .padding(8)
    .frame(width: 340)
  }
}

/// A conversation in the menu or a foldout. Clicking it goes straight to it, which also counts as reading it;
/// right-clicking an unread one offers to mark it as read without going there.
struct ConversationButton<Label: View>: View {
  let conversation: Conversation
  let workspace: Workspace
  let store: RadarStore
  var dismissMenu: DismissMenuAction?
  @ViewBuilder let label: () -> Label
  @Environment(\.dismissMenu) private var environmentDismissMenu

  var body: some View {
    HoverButton(action: open, label: label)
      .help(conversation.state.helpText)
      .contextMenu {
        if conversation.state == .unread {
          Button("Mark as Read") { store.markRead([conversation]) }
        }
      }
  }

  private func open() {
    (dismissMenu ?? environmentDismissMenu)()
    if conversation.state == .unread { store.markRead([conversation]) }
    Opener.open(conversation, in: workspace)
  }
}

/// Marks all unread conversations of a workspace as read.
struct MarkAllAsReadButton: View {
  let workspace: Workspace
  let store: RadarStore

  var body: some View {
    let unread = workspace.conversations.filter { $0.state == .unread }
    if !unread.isEmpty {
      Button("Mark All as Read") { store.markRead(unread) }
    }
  }
}

/// Closes the menu and its foldout, for when a click takes the user somewhere else.
struct DismissMenuAction {
  let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
  @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
  @Entry var dismissMenu = DismissMenuAction {}
}

/// Hands over the window a view is shown in.
struct WindowReader: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView { WindowView(found: $window) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class WindowView: NSView {
    @Binding var found: NSWindow?
    init(found: Binding<NSWindow?>) {
      _found = found
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { DispatchQueue.main.async { self.found = window } }
    }
  }
}

struct ConversationLine: View {
  let conversation: Conversation
  var showAge = false

  var body: some View {
    HStack(spacing: 6) {
      StateDot(state: conversation.state)
      Text(conversation.title)
        .font(.callout)
        .lineLimit(1)
      Spacer(minLength: 4)
      if showAge, let last = conversation.lastActivity {
        AgeLabel(date: last)
      }
    }
  }
}

/// "15m", "2d": how long ago something changed, with the exact time on hover.
struct AgeLabel: View {
  let date: Date

  var body: some View {
    Text(AgeFormatter.short(since: date))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .help("Last change: \(date.formatted(date: .abbreviated, time: .shortened))")
  }
}

struct HoverButton<Label: View>: View {
  var highlighted = false
  let action: () -> Void
  var onHover: ((Bool) -> Void)?
  @ViewBuilder let label: () -> Label
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      label()
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering || highlighted ? Color.primary.opacity(0.08) : .clear))
    }
    .buttonStyle(.plain)
    .onHover { inside in
      hovering = inside
      onHover?(inside)
    }
  }
}

struct CountBadge: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.caption.weight(.semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.orange))
  }
}

/// Same colors as the tab dots in the Claude Code extension: blue for waiting, orange for unread. Working
/// conversations get a spinner and idle ones a gray outline.
struct StateDot: View {
  let state: ConversationState

  var body: some View {
    switch state {
    case .waiting: Circle().fill(Color.blue).frame(width: 7, height: 7)
    case .unread: Circle().fill(Color.orange).frame(width: 7, height: 7)
    case .working: ProgressView().controlSize(.mini).frame(width: 7, height: 7)
    case .open: Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
    }
  }
}

extension ConversationState {
  var helpText: String {
    switch self {
    case .waiting: "Waiting for input"
    case .unread: "Unread reply"
    case .working: "Working"
    case .open: "Nothing pending"
    }
  }
}

/// Brings workspaces and conversations to the front, in VS Code or Terminal.
@MainActor
enum Opener {
  static let vscodeBundleID = "com.microsoft.VSCode"

  static func open(_ workspace: Workspace) {
    if workspace.kind == .terminalFolder {
      if let conversation = workspace.foldoutConversations.first { open(conversation, in: workspace) }
      return
    }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleID) else { return }
    NSWorkspace.shared.open([workspace.openTarget], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
  }

  static func open(_ conversation: Conversation, in workspace: Workspace) {
    switch conversation.target {
    case let .vscode(url)?:
      // Open the workspace first, so the conversation opens in the right window.
      open(workspace)
      DispatchQueue.main.asyncAfter(deadline: .now() + (workspace.isOpen ? 0.5 : 3)) {
        NSWorkspace.shared.open(url)
      }
    case let .terminal(.terminalApp, tty?)?:
      TerminalApp.focus(tty: tty)
    default:
      if workspace.kind == .vscode { open(workspace) }
    }
  }
}
