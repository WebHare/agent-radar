import AppKit
import ServiceManagement
import SwiftUI
import RadarKit

struct SettingsView: View {
  @ObservedObject var menuSettings: MenuSettingsStore
  @StateObject private var model = HooksSettingsModel()
  @StateObject private var login = LaunchAtLoginModel()

  var body: some View {
    Form {
      Section {
        Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { login.set(enabled: $0) }))
        if login.needsApproval {
          HStack {
            Label("Allow Agent Radar in Login Items to start it at login.", systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Spacer()
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          }
          .font(.caption)
        }
        if let error = login.lastError {
          Label(error, systemImage: "xmark.octagon")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("General")
      }

      Section {
        Picker("Number", selection: $menuSettings.settings.counter) {
          Text("Waiting and unread").tag(MenuBarCounter.needsUser)
          Text("Waiting only").tag(MenuBarCounter.waitingOnly)
          Text("None, only the icon").tag(MenuBarCounter.iconOnly)
        }
      } header: {
        Text("Menu bar")
      }

      Section {
        Toggle("Terminal sessions", isOn: $menuSettings.settings.showTerminal)
        Toggle("Closed workspaces with open conversations", isOn: $menuSettings.settings.showClosed)
        Toggle("Recent workspaces", isOn: $menuSettings.settings.showRecent)
      } header: {
        Text("Show in the menu")
      } footer: {
        Text("Conversations in hidden sections don't count in the menu bar.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle(isOn: Binding(get: { model.status == .installed }, set: { model.set(installed: $0) })) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Show conversations waiting for input")
            Text("Adds hooks to Claude Code's settings.json that tell Agent Radar when a conversation waits for a permission or an answer. Applies to conversations started after changing this.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .disabled(model.statusError != nil)

        if model.status == .partial {
          Label("Only some of the hooks are installed. Turn this on to install all of them.",
                systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let error = model.statusError ?? model.lastError {
          Label(error, systemImage: "xmark.octagon")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Settings file") {
          Button(model.hooks.settingsURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            model.revealSettings()
          }
          .buttonStyle(.link)
          .help("Show in Finder")
        }
        .font(.caption)
      } header: {
        Text("Claude Code")
      }

      Section {
        Toggle(isOn: $menuSettings.settings.writeDebugLog) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Write a troubleshooting log")
            Text("Logs every Claude Code hook event and what Agent Radar did with it, and every change of a conversation's state with the reason. Includes conversation titles.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        LabeledContent("Log file") {
          Button(RadarPaths.standard.debugLogURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            let url = RadarPaths.standard.debugLogURL
            if FileManager.default.fileExists(atPath: url.path) {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
              NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
          }
          .buttonStyle(.link)
          .help("Show in Finder")
        }
        .font(.caption)
      } header: {
        Text("Advanced")
      }

      Section {
        LabeledContent("Version \(BuildInfo.current.version ?? "unknown")") {
          Button("About Agent Radar") { AboutPanel.show() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { model.reload(); login.reload() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      model.reload()
      login.reload()
    }
  }
}

@MainActor
final class HooksSettingsModel: ObservableObject {
  let hooks = ClaudeHooks(paths: .standard)
  @Published private(set) var status: ClaudeHooks.Status = .notInstalled
  /// Why the status can't be determined (eg. settings.json is invalid); the toggle is disabled then.
  @Published private(set) var statusError: String?
  /// Why the last install or uninstall failed.
  @Published private(set) var lastError: String?

  func reload() {
    do {
      status = try hooks.status()
      statusError = nil
    } catch {
      statusError = error.localizedDescription
    }
  }

  func set(installed: Bool) {
    do {
      if installed { try hooks.install() } else { try hooks.uninstall() }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    reload()
  }

  func revealSettings() {
    let url = hooks.settingsURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }
}

/// Launch at login, through macOS's Login Items. macOS keeps the setting; the app doesn't store it.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
  @Published private(set) var status: SMAppService.Status = .notRegistered
  @Published private(set) var lastError: String?

  var isOn: Bool { status == .enabled || status == .requiresApproval }
  /// Registered, but the user turned it off in System Settings → Login Items.
  var needsApproval: Bool { status == .requiresApproval }

  func reload() { status = SMAppService.mainApp.status }

  func set(enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      lastError = nil
    } catch {
      lastError = "Couldn't change Login Items: \(error.localizedDescription)"
    }
    reload()
  }
}

/// macOS's standard About panel, with where the build comes from and when it was built.
@MainActor
enum AboutPanel {
  static func show() {
    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    let details = NSAttributedString(string: BuildInfo.current.aboutDetails(), attributes: [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: centered,
    ])
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: details])
  }
}
