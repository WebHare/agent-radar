import AppKit
import SwiftUI
import RadarKit

struct SettingsView: View {
  @StateObject private var model = HooksSettingsModel()

  var body: some View {
    Form {
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
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { model.reload() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.reload() }
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
