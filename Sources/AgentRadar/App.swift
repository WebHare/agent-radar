import AppKit
import SwiftUI
import RadarKit

@main
struct AgentRadarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = RadarStore()
  @StateObject private var menuSettings = MenuSettingsStore()

  init() {
    CommandLineMode.runIfRequested()
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(store: store, settings: menuSettings.settings)
    } label: {
      MenuBarLabel(count: menuSettings.settings.menuBarCount(for: store.sections),
                   showsNumber: menuSettings.settings.menuBarShowsNumber)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(menuSettings: menuSettings)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    ClaudeHooks(paths: .standard).updateScriptIfInstalled()
  }
}

/// `--dump`, `--install-claude-hooks` and `--uninstall-claude-hooks` run without the UI, for scripts and checks.
enum CommandLineMode {
  static func runIfRequested() {
    let args = CommandLine.arguments
    if args.contains("--dump") {
      print(DumpFormatter.format(Radar().scan()))
      exit(0)
    }
    let install = args.contains("--install-claude-hooks")
    if install || args.contains("--uninstall-claude-hooks") {
      let hooks = ClaudeHooks(paths: .standard)
      do {
        if install { try hooks.install() } else { try hooks.uninstall() }
        print("\(install ? "Installed" : "Removed") the Agent Radar hooks in \(hooks.settingsURL.path)")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
  }
}

/// Rescans every few seconds on a background queue and publishes the result.
@MainActor
final class RadarStore: ObservableObject {
  @Published private(set) var sections = WorkspaceSections()
  @Published private(set) var lastScan: Date?

  private let queue = DispatchQueue(label: "agent-radar.scan", qos: .utility)
  private let radar = Radar()
  private var timer: Timer?
  private var scanning = false

  static let interval: TimeInterval = 3

  init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    guard !scanning else { return }
    scanning = true
    let radar = self.radar
    // Terminal sessions have no unread state of their own: a session counts as seen while its Terminal tab is
    // in front. Only asked when there are terminal sessions, so nobody else gets Terminal's permission prompt.
    let frontTTY = sections.terminal.isEmpty ? nil : TerminalApp.frontTTY()
    // The Claude Code extension misses replies that finish in an unfocused window, so the app also counts a
    // reply as unread until VS Code was in front. TODO: remove when
    // https://github.com/anthropics/claude-code/issues/110457 is fixed (https://github.com/WebHare/agent-radar/issues/3).
    let vscodeFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Opener.vscodeBundleID
    queue.async {
      if vscodeFront { radar.markVSCodeFront() }
      if let frontTTY { radar.markTerminalSeen(tty: frontTTY) }
      let result = radar.scan()
      Task { @MainActor in
        self.sections = result
        self.lastScan = Date()
        self.scanning = false
      }
    }
  }
}

/// The menu and menu bar choices from Settings, saved in the user defaults.
@MainActor
final class MenuSettingsStore: ObservableObject {
  @Published var settings: MenuSettings {
    didSet { if settings != oldValue { settings.save(to: .standard) } }
  }

  init() { settings = MenuSettings(defaults: .standard) }
}

struct MenuBarLabel: View {
  let count: Int
  let showsNumber: Bool

  var body: some View {
    if count > 0 && showsNumber {
      Label("\(count)", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
        .labelStyle(.titleAndIcon)
    } else if count > 0 {
      Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
    } else {
      Image(systemName: "bubble.left.and.bubble.right")
    }
  }
}

enum DumpFormatter {
  static func format(_ sections: WorkspaceSections) -> String {
    var lines = ["Needs attention: \(sections.attentionCount)"]
    for (title, list) in [("Active", sections.active), ("Terminal", sections.terminal),
                          ("Closed with conversations", sections.closedWithConversations), ("Recent", sections.recent)] {
      lines.append("\n== \(title)")
      for ws in list {
        let age = ws.lastActivity.map { AgeFormatter.short(since: $0) } ?? "-"
        lines.append("\(ws.name)  [\(ws.id)]  attention=\(ws.attentionCount) working=\(ws.workingCount) total=\(ws.conversations.count) last=\(age)")
        for c in ws.foldoutConversations {
          let age = c.lastActivity.map { AgeFormatter.short(since: $0) } ?? "-"
          lines.append("    \(c.state)  \(age)  \(c.title)  (\(c.id))")
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}
