import Darwin
import Foundation

/// The app a terminal session runs in, found by walking up its process's parents.
public enum TerminalHost: Equatable, Sendable {
  /// macOS Terminal.app; its tabs can be found and focused by their tty.
  case terminalApp
  /// VS Code's integrated terminal.
  case vscode
  /// Anything else (iTerm2, Ghostty, tmux, ...): shown, but can't be focused yet.
  case other

  static func classify(executablePath path: String) -> TerminalHost? {
    if path.contains("/Terminal.app/") { return .terminalApp }
    if path.contains("/Visual Studio Code.app/") || path.contains("/Code Helper") { return .vscode }
    return nil
  }
}

/// Process information from the kernel (libproc), for sessions that run in a terminal.
enum Processes {
  static func bsdInfo(_ pid: Int) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info
  }

  static func parent(of pid: Int) -> Int? {
    guard let info = bsdInfo(pid) else { return nil }
    return Int(info.pbi_ppid)
  }

  /// The controlling terminal, eg. `/dev/ttys003`, as Terminal.app reports it for its tabs.
  static func tty(of pid: Int) -> String? {
    guard let info = bsdInfo(pid), info.e_tdev != UInt32.max, info.e_tdev != 0,
          let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
  }

  static func executablePath(of pid: Int) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  /// Walks up the parents of `pid` to the first app that classifies as a terminal host.
  static func host(of pid: Int) -> TerminalHost {
    var current = pid
    for _ in 0..<40 {
      guard let parent = parent(of: current), parent > 1 else { break }
      if let path = executablePath(of: parent), let host = TerminalHost.classify(executablePath: path) { return host }
      current = parent
    }
    return .other
  }
}
