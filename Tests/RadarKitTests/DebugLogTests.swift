import Foundation
import Testing
@testable import RadarKit

@Suite struct HookEffectTests {
  func effect(_ name: String, type: String = "", tool: String = "") -> ClaudeHookEvents.Effect {
    ClaudeHookEvents.effect(of: .init(event: name, session: "s1", type: type, tool: tool))
  }

  @Test func explainsWhatEachEventMeans() {
    #expect(effect("PermissionRequest").waits == true)
    #expect(effect("Stop").waits == false)
    #expect(effect("PreToolUse", tool: "Bash").waits == nil)
    #expect(effect("PreToolUse", tool: "Bash").reason.contains("Bash"))
    #expect(effect("Notification", type: "idle_prompt").waits == nil)
    #expect(effect("SomethingNew").waits == nil)
  }

  /// A finished reply only ends waiting; whether it's unread doesn't come from the hooks.
  @Test func stopSaysUnreadIsNotDecidedByHooks() {
    #expect(effect("Stop").reason.contains("unread"))
  }
}

@Suite struct DebugLogTests {
  func lines(_ fixture: VSCodeFixture) -> [String] {
    let text = (try? String(contentsOf: fixture.paths.debugLogURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  func appendHookEvent(_ fixture: VSCodeFixture, _ event: String) throws {
    let url = ClaudeHookEvents.logURL(paths: fixture.paths)
    let line = #"{"event":"\#(event)","session":"ext1","type":"","tool":"","time":\#(Int(fixture.now))}"# + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
      try handle.close()
    } else {
      try Data(line.utf8).write(to: url)
    }
  }

  @Test func writesNothingWhenOff() throws {
    let fixture = try VSCodeFixture(windows: 2)
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    _ = radar.scan()
    try appendHookEvent(fixture, "Stop")
    _ = radar.scan()
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.debugLogURL.path))
  }

  /// Hook events, what they did, the state changes with their reasons and the user's actions, in order.
  @Test func logsHookEventsStateChangesAndActions() throws {
    let fixture = try VSCodeFixture(windows: 2)
    let radar = Radar(paths: fixture.paths, providers: [ClaudeCodeProvider(paths: fixture.paths)])
    try appendHookEvent(fixture, "PreToolUse")  // before the log is on: not logged
    radar.debugLog.isEnabled = true
    _ = radar.scan()
    var log = lines(fixture)
    #expect(!log.contains { $0.contains("PreToolUse") })
    let appeared = try #require(log.first { $0.contains("ext1") })
    #expect(appeared.contains("unread"))
    #expect(appeared.contains("finished"))  // why: the reply finished after Agent Radar was last sure

    try appendHookEvent(fixture, "Stop")
    _ = radar.scan()
    log = lines(fixture)
    let hook = try #require(log.first { $0.contains("Stop") })
    #expect(hook.contains("ext1"))
    #expect(hook.contains("wasn't waiting"))

    radar.markVSCodeFront()  // two windows: not sure which one the user sees
    radar.markRead(["ext1"])
    _ = radar.scan()
    log = lines(fixture)
    #expect(log.contains { $0.contains("VS Code") && $0.contains("2 windows") })
    #expect(log.contains { $0.contains("marked as read") && $0.contains("ext1") })
    let change = try #require(log.last { $0.contains("ext1") })
    #expect(change.contains("unread → open"))
  }

  @Test func startsANewFileWhenTooLarge() throws {
    let root = try TempDir()
    let url = root.url.appendingPathComponent("debug.log")
    let log = DebugLog(url: url, maxSize: 100)
    log.isEnabled = true
    for i in 0..<10 { log.write("test", "line \(i) with some padding to grow") }
    let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    #expect(size < 200)
    #expect(FileManager.default.fileExists(atPath: url.path + ".1"))
  }
}
