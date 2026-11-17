import Foundation
import Testing
@testable import RadarKit

@Suite struct BuildInfoTests {
  let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
  let english = Locale(identifier: "en_GB")

  @Test func readsChannelNumberAndDateFromTheInfoDictionary() {
    let info = BuildInfo(infoDictionary: [
      "CFBundleShortVersionString": "v0.1-3-gabc1234",
      "CFBundleVersion": "42",
      "AgentRadarBuildChannel": "dmg",
      "AgentRadarBuildDate": "2026-11-16T13:05:00Z",
    ])
    #expect(info.channel == .dmg)
    #expect(info.version == "v0.1-3-gabc1234")
    #expect(info.buildNumber == "42")
    #expect(info.buildDate == ISO8601DateFormatter().date(from: "2026-11-16T13:05:00Z"))
  }

  @Test func withoutABundleItIsALocalBuildDatedByTheExecutable() {
    let built = Date(timeIntervalSince1970: 1_800_000_000)
    let info = BuildInfo(infoDictionary: nil, executableDate: built)
    #expect(info.channel == .local)
    #expect(info.buildNumber == nil)
    #expect(info.buildDate == built)
  }

  @Test func unknownChannelsCountAsLocal() {
    #expect(BuildInfo(infoDictionary: ["AgentRadarBuildChannel": "nightly"]).channel == .local)
    #expect(BuildInfo(infoDictionary: ["AgentRadarBuildChannel": "appstore"]).channel == .appStore)
  }

  @Test func onlyLocalBuildsGetAMenuFooterInLocalTime() {
    var info = BuildInfo(infoDictionary: [
      "CFBundleShortVersionString": "v0.1-3-gabc1234-dirty",
      "CFBundleVersion": "7",
      "AgentRadarBuildChannel": "local",
      "AgentRadarBuildDate": "2026-11-16T13:05:00Z",
    ])
    #expect(info.menuFooter(timeZone: amsterdam, locale: english) == "Local build 7 · 16 Nov 2026 at 14:05 · v0.1-3-gabc1234-dirty")

    info.channel = .dmg
    #expect(info.menuFooter(timeZone: amsterdam, locale: english) == nil)
    info.channel = .appStore
    #expect(info.menuFooter(timeZone: amsterdam, locale: english) == nil)
  }

  @Test func footerLeavesOutWhatIsUnknown() {
    let info = BuildInfo(infoDictionary: nil)
    #expect(info.menuFooter(timeZone: amsterdam, locale: english) == "Local build")
  }

  @Test func aboutCreditsNameTheChannelAndBuildDate() {
    let info = BuildInfo(infoDictionary: [
      "CFBundleVersion": "42",
      "AgentRadarBuildChannel": "dmg",
      "AgentRadarBuildDate": "2026-11-16T13:05:00Z",
    ])
    #expect(info.aboutDetails(timeZone: amsterdam, locale: english) == "Downloaded build, built 16 Nov 2026 at 14:05")
  }
}
