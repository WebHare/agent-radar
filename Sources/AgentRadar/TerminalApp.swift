import AppKit
import Foundation

/// Talks to macOS Terminal.app through AppleScript. The first use asks the user for permission to control
/// Terminal (System Settings → Privacy & Security → Automation).
@MainActor
enum TerminalApp {
  static let bundleID = "com.apple.Terminal"

  /// The tty of the tab in front, when Terminal is the frontmost app.
  static func frontTTY() -> String? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return nil }
    return run(#"tell application "Terminal" to get tty of selected tab of front window"#)
  }

  /// Brings the tab with this tty to the front.
  static func focus(tty: String) {
    let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    _ = run("""
      tell application "Terminal"
        activate
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is "\(escaped)" then
              set selected of t to true
              set index of w to 1
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      """)
  }

  private static func run(_ source: String) -> String? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil ? result?.stringValue : nil
  }
}
