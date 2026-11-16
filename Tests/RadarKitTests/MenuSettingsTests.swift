import Foundation
import Testing
@testable import RadarKit

@Suite struct MenuSettingsTests {
  func ws(_ id: String, kind: WorkspaceKind = .vscode, _ states: [ConversationState]) -> Workspace {
    Workspace(id: id, kind: kind, name: id, openTarget: URL(fileURLWithPath: "/\(id)"), isOpen: true, lastUsed: Date(),
              conversations: states.enumerated().map { Conversation(id: "\(id)\($0.offset)", title: "", state: $0.element, provider: "t") })
  }

  var sections: WorkspaceSections {
    WorkspaceSections(active: [ws("a", [.waiting, .unread, .working])],
                      terminal: [ws("t", kind: .terminalFolder, [.unread, .unread])],
                      closedWithConversations: [ws("c", [.waiting, .open])],
                      recent: [ws("r", [])])
  }

  @Test func defaultsShowEverythingAndCountWaitingAndUnread() {
    let settings = MenuSettings()
    let visible = settings.visibleSections(of: sections)
    #expect(visible.terminal.count == 1 && visible.closedWithConversations.count == 1 && visible.recent.count == 1)
    #expect(settings.menuBarCount(for: sections) == 5)
    #expect(settings.menuBarShowsNumber)
  }

  @Test func hiddenSectionsAreLeftOutAndNotCounted() {
    var settings = MenuSettings()
    settings.showTerminal = false
    settings.showClosed = false
    settings.showRecent = false
    let visible = settings.visibleSections(of: sections)
    #expect(visible.active.map(\.id) == ["a"])
    #expect(visible.terminal.isEmpty && visible.closedWithConversations.isEmpty && visible.recent.isEmpty)
    #expect(settings.menuBarCount(for: sections) == 2)
  }

  @Test func waitingOnlyCountsWaiting() {
    var settings = MenuSettings()
    settings.counter = .waitingOnly
    #expect(settings.menuBarCount(for: sections) == 2)
    #expect(settings.menuBarShowsNumber)
  }

  @Test func iconOnlyHidesTheNumberButStillCounts() {
    var settings = MenuSettings()
    settings.counter = .iconOnly
    #expect(settings.menuBarCount(for: sections) == 5)
    #expect(!settings.menuBarShowsNumber)
  }

  @Test func readsAndWritesUserDefaults() throws {
    let defaults = try #require(UserDefaults(suiteName: "agent-radar-tests-\(UUID().uuidString)"))
    #expect(MenuSettings(defaults: defaults) == MenuSettings())

    var settings = MenuSettings()
    settings.counter = .waitingOnly
    settings.showRecent = false
    settings.save(to: defaults)
    #expect(MenuSettings(defaults: defaults) == settings)

    defaults.set("garbage", forKey: MenuSettings.Key.counter)
    #expect(MenuSettings(defaults: defaults).counter == .needsUser)
  }
}
