import Foundation

/// Where a build of the app comes from, as `scripts/build-app.sh --channel` records it in the Info.plist.
public enum BuildChannel: String, Sendable {
  /// Built on a developer's machine (also `swift run`).
  case local
  /// The DMG built and notarized by CI.
  case dmg
  /// Built for the Mac App Store.
  case appStore = "appstore"

  public var displayName: String {
    switch self {
    case .local: "Local build"
    case .dmg: "Downloaded build"
    case .appStore: "App Store build"
    }
  }
}

/// The version, build number and build date of the running app, so a developer can tell whether they are looking
/// at an up-to-date build.
public struct BuildInfo: Equatable, Sendable {
  public enum Key {
    public static let channel = "AgentRadarBuildChannel"
    public static let date = "AgentRadarBuildDate"
  }

  public var channel: BuildChannel
  public var version: String?
  public var buildNumber: String?
  public var buildDate: Date?

  /// - Parameter executableDate: when there is no build date in the Info.plist (`swift run`), the date of the
  ///   executable stands in for it.
  public init(infoDictionary: [String: Any]?, executableDate: Date? = nil) {
    let info = infoDictionary ?? [:]
    channel = (info[Key.channel] as? String).flatMap(BuildChannel.init(rawValue:)) ?? .local
    version = info["CFBundleShortVersionString"] as? String
    buildNumber = info["CFBundleVersion"] as? String
    buildDate = (info[Key.date] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? executableDate
  }

  public static var current: BuildInfo {
    let executable = Bundle.main.executableURL
    let modified = executable.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }
    return BuildInfo(infoDictionary: Bundle.main.infoDictionary, executableDate: modified?.contentModificationDate)
  }

  /// The line at the bottom of the menu: only for local builds, release builds keep the menu clean.
  public func menuFooter(timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
    guard channel == .local else { return nil }
    var parts = [[channel.displayName, buildNumber].compactMap { $0 }.joined(separator: " ")]
    if let buildDate { parts.append(format(buildDate, timeZone: timeZone, locale: locale)) }
    if let version { parts.append(version) }
    return parts.joined(separator: " · ")
  }

  /// The extra line in the About panel, under the version and build number.
  public func aboutDetails(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    guard let buildDate else { return channel.displayName }
    return "\(channel.displayName), built \(format(buildDate, timeZone: timeZone, locale: locale))"
  }

  private func format(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
    style.timeZone = timeZone
    return date.formatted(style)
  }
}
