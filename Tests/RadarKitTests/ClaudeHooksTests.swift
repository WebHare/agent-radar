import Foundation
import Testing
@testable import RadarKit

@Suite struct OrderedJSONTests {
  @Test func roundTripsKeepingOrderAndNumbers() throws {
    let text = """
      {
        "zeta": 1.50,
        "alpha": [true, false, null, -2e3],
        "nested": {"b": "x", "a": "\\u00e9\\ud83d\\ude00\\n\\"q\\""},
        "empty": {},
        "none": []
      }
      """
    let json = try OrderedJSON.parse(text)
    #expect(json.objectMembers?.map(\.0) == ["zeta", "alpha", "nested", "empty", "none"])
    #expect(json["nested"]?["a"]?.stringValue == "é😀\n\"q\"")
    let serialized = json.serialized()
    #expect(serialized.contains(#""zeta": 1.50"#))
    #expect(try OrderedJSON.parse(serialized) == json)
    #expect(serialized == """
      {
        "zeta": 1.50,
        "alpha": [
          true,
          false,
          null,
          -2e3
        ],
        "nested": {
          "b": "x",
          "a": "é😀\\n\\"q\\""
        },
        "empty": {},
        "none": []
      }

      """)
  }

  @Test func rejectsInvalidJSON() {
    for bad in ["", "{", #"{"a" 1}"#, "[1,]", #"{"a":1} x"#, "tru"] {
      #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(bad) }
    }
  }

  @Test func subscriptSetsAppendsAndRemoves() {
    var json = OrderedJSON.object([("a", .number("1")), ("b", .number("2"))])
    json["a"] = .string("x")
    json["c"] = .null
    json["b"] = nil
    #expect(json.objectMembers?.map(\.0) == ["a", "c"])
    #expect(json["a"]?.stringValue == "x")
  }
}

@Suite struct ClaudeHooksTests {
  let command = "/Users/me/.agent-radar/claude-hook.sh"

  func settings(_ text: String) throws -> OrderedJSON { try OrderedJSON.parse(text) }

  @Test func installKeepsOtherSettingsAndHooks() throws {
    let before = try settings("""
      {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}, "theme": "auto"}
      """)
    let after = ClaudeHooks.installing(into: before, command: command)

    #expect(after.objectMembers?.map(\.0) == ["model", "hooks", "theme"])
    let stop = try #require(after["hooks"]?["Stop"]?.arrayValue)
    #expect(stop.count == 2)
    #expect(stop[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue == "say done")
    #expect(ClaudeHooks.status(of: after, command: command) == .installed)
    #expect(after["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["async"] == .bool(true))
  }

  @Test func installTwiceAddsOnce() {
    let once = ClaudeHooks.installing(into: .object([]), command: command)
    #expect(ClaudeHooks.installing(into: once, command: command) == once)
  }

  @Test func uninstallRestoresOriginal() throws {
    for text in [#"{"model": "opus"}"#, #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say"}]}]}}"#] {
      let original = try settings(text)
      let roundTrip = ClaudeHooks.removing(from: ClaudeHooks.installing(into: original, command: command), command: command)
      #expect(roundTrip == original)
    }
  }

  @Test func detectsPartialInstall() throws {
    var json = ClaudeHooks.installing(into: .object([]), command: command)
    json["hooks"]?["Stop"] = nil
    #expect(ClaudeHooks.status(of: json, command: command) == .partial)
    #expect(ClaudeHooks.status(of: .object([]), command: command) == .notInstalled)
    #expect(ClaudeHooks.status(of: ClaudeHooks.installing(into: json, command: command), command: command) == .installed)
  }

  @Test func installAndUninstallFiles() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url.appendingPathComponent("claude"),
                             radarHome: root.url.appendingPathComponent("radar"))
    let hooks = ClaudeHooks(paths: paths)
    try FileManager.default.createDirectory(at: paths.claudeHome, withIntermediateDirectories: true)
    let original = "{\n  \"model\": \"opus\"\n}\n"
    try Data(original.utf8).write(to: hooks.settingsURL)

    #expect(try hooks.status() == .notInstalled)
    try hooks.install()
    #expect(try hooks.status() == .installed)
    #expect(FileManager.default.isExecutableFile(atPath: hooks.scriptURL.path))
    #expect(try String(contentsOf: hooks.backupURL, encoding: .utf8) == original)

    try hooks.uninstall()
    #expect(try hooks.status() == .notInstalled)
    #expect(try String(contentsOf: hooks.settingsURL, encoding: .utf8) == original)
  }

  @Test func refusesToTouchInvalidSettings() throws {
    let root = try TempDir()
    let paths = RadarPaths(vscodeUser: root.url, claudeHome: root.url, radarHome: root.url.appendingPathComponent("w"))
    let hooks = ClaudeHooks(paths: paths)
    try Data("{ broken".utf8).write(to: hooks.settingsURL)
    #expect(throws: ClaudeHooks.HookError.self) { try hooks.install() }
    #expect(try String(contentsOf: hooks.settingsURL, encoding: .utf8) == "{ broken")
  }

  @Test func hookScriptWritesEventLine() throws {
    let root = try TempDir()
    let script = root.url.appendingPathComponent("hook.sh")
    try Data(ClaudeHooks.script.utf8).write(to: script)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.environment = ["HOME": root.url.path, "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"echo \"hi\"\n"}}"#.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    let log = try Data(contentsOf: root.url.appendingPathComponent(".agent-radar/claude-code-events.jsonl"))
    let events = ClaudeHookEvents.parse(log)
    #expect(events.count == 1)
    #expect(events.first?.event == "PermissionRequest")
    #expect(events.first?.session == "s1")
    #expect(events.first?.tool == "Bash")
  }
}
