import Foundation

/// The troubleshooting log, switched on in Settings: one line per thing that went into a conversation's state
/// (a hook event and what it did, the user marking something as read, VS Code coming to the front) and per
/// state change with its reason. Plain text in `~/.agent-radar/debug.log`, for the user to read or attach to an
/// issue. Holds session IDs and conversation titles; nothing else from the conversations.
/// Not thread-safe: use from the scan queue.
public final class DebugLog {
  public var isEnabled = false
  public let url: URL
  /// Past this size the log moves to `debug.log.1` (replacing the previous one) and a new one starts.
  let maxSize: Int

  public init(url: URL, maxSize: Int = 5 * 1024 * 1024) {
    self.url = url
    self.maxSize = maxSize
  }

  private static let timeFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return format
  }()

  private static let secondsFormat: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return format
  }()

  /// A time for the log; `seconds` for times that are only known to the second (such as hook events).
  static func time(_ date: Date, seconds: Bool = false) -> String {
    (seconds ? secondsFormat : timeFormat).string(from: date)
  }

  /// Appends `<time>  <category>  <message>`. Does nothing when the log is off.
  public func write(_ category: String, _ message: String, at date: Date = Date()) {
    guard isEnabled else { return }
    let line = "\(Self.time(date))  \(category.padding(toLength: 6, withPad: " ", startingAt: 0))  \(message)\n"
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + line.utf8.count > maxSize {
      let old = URL(fileURLWithPath: url.path + ".1")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: url, to: old)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
}
