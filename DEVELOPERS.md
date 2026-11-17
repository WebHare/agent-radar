# Developing Agent Radar

How Agent Radar works inside, and how to build, test and release it. See [README.md](README.md) for what it
does, [doc/requirements.md](doc/requirements.md) for every expected behaviour and decision, and
[CHANGELOG.md](CHANGELOG.md) for what changed per version.

## Where the data comes from

The app reads the state that VS Code, Claude Code and the terminal already keep, every 3 seconds. It never
writes to it, apart from the hooks you can switch on in Settings.

| What | Where |
|---|---|
| Running Claude Code sessions: folder, busy, idle or waiting, started from VS Code or a terminal | `~/.claude/sessions/<pid>.json` |
| Which app a terminal session runs in, and its tab (tty) | the session's parent processes |
| Waiting for input (VS Code extension) | `~/.agent-radar/claude-code-events.jsonl`, written by the optional hooks |
| Last change of a conversation | the modification time of its transcript |
| Full conversation titles | `~/.claude/projects/*/<session>.jsonl` (`custom-title` / `ai-title` lines) |
| Known VS Code workspaces, last used | `~/Library/Application Support/Code/User/workspaceStorage/*/workspace.json` and the date of `state.vscdb` |
| Open conversation tabs per VS Code workspace | `workspaceStorage/*/state.vscdb`, row `Anthropic.claude-code`, `panelTabSessions` |
| Unread and archived VS Code conversations | `globalStorage/state.vscdb`, row `Anthropic.claude-code`, `sessionUnread:<first folder>` and `hiddenSessionIds` |
| Open VS Code windows | `~/.claude/ide/*.lock` (written per window by the Claude Code extension) |
| Unread terminal sessions | `~/.agent-radar/terminal-seen.json`: when you last had each session's tab in front |
| Replies the extension doesn't mark unread | `~/.agent-radar/vscode-front.json`: when the user last surely saw all VS Code conversations (VS Code in front with a single window), and which ones they marked as read (workaround for anthropics/claude-code#110457, see issues #3 and #7) |

A VS Code workspace is identified by its first folder, because that's how the extension keys its state. All of
these formats are internal to VS Code and Claude Code and may change with an update.

## Layout

- `Sources/RadarKit`: all logic, tested.
  - `Model.swift`: workspaces, conversations, states, the menu sections and the `ConversationProvider` protocol.
  - `MenuSettings.swift`: the user's menu choices (which sections, what the menu bar counts) and how they're stored.
  - `Radar.swift`: combines VS Code's workspaces and all providers into the menu sections.
  - `ClaudeCodeProvider.swift`: everything specific to Claude Code's state, including the hook event log.
  - `ClaudeHooks.swift`: installing and removing the Claude Code hooks, and the hook script.
  - `VSCodeState.swift`: VS Code's workspace list and open windows.
  - `Processes.swift`: finding the terminal app and tab of a session's process.
  - `TerminalSeen.swift`: unread state for terminal sessions.
  - `VSCodeSeen.swift`: which VS Code replies the user surely saw, for replies the extension doesn't mark unread.
  - `OrderedJSON.swift`: JSON editing that keeps the order of the user's settings.json.
- `Sources/AgentRadar`: the SwiftUI menu bar app (views, and talking to Terminal.app).
- `Tests/RadarKitTests`: unit tests, and integration tests against a fake VS Code and Claude Code setup on disk.
- `scripts/build-app.sh`: building the app bundle and DMG; `scripts/AgentRadar.entitlements`: its entitlements.
- `doc/`: [requirements](doc/requirements.md) and [the Claude Code hooks](doc/claude-hooks.md).
- `CHANGELOG.md`: what changed per version.

## Developing

```sh
swift test                                    # run the tests
swift run AgentRadar --dump                   # print what the menu would show, from the real data on this machine
swift run AgentRadar                          # run the menu bar app from the terminal
swift run AgentRadar --install-claude-hooks   # or --uninstall-claude-hooks
scripts/build-app.sh                          # build build/Agent Radar.app
```

`scripts/build-app.sh` also takes `--universal` (Apple silicon and Intel), `--dmg` (also builds
`build/Agent-Radar-<version>.dmg`) and `--install`. It signs with `SIGN_IDENTITY` when set, for example
`SIGN_IDENTITY="Developer ID Application: WebHare bv (MF6WPNPK5H)"`; otherwise with the first Developer ID
Application or Apple Development certificate in your keychain; otherwise ad-hoc (`SIGN_IDENTITY=-` forces
ad-hoc). Sign with a certificate when you can: macOS ties privacy permissions (such as access to workspace
files on the Desktop) to the signature, and an ad-hoc signature changes with every build, so macOS asks again
after each one. The app is then signed with
the hardened runtime and [the Apple Events entitlement](scripts/AgentRadar.entitlements), which is needed to
talk to Terminal. A locally signed DMG is not notarized; only CI does that.

## Continuous integration

[.github/workflows/build.yml](.github/workflows/build.yml) runs the tests and builds a universal app and DMG
on every push to `main` and every pull request. The DMG is attached to the run as
`Agent-Radar-<version>-<run>.dmg`.

Without signing secrets, the app is **ad-hoc signed**. macOS then refuses to open it after downloading: open it
once via System Settings → Privacy & Security → **Open Anyway**, or run
`xattr -dr com.apple.quarantine "/Applications/Agent Radar.app"`.

With these repository secrets and variables, the app and DMG are signed with WebHare's **Developer ID** (team
MF6WPNPK5H) and notarized, so they open without warnings:

| Name                                | Kind     | Contents                                                                   |
| ----------------------------------- | -------- | -------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_P12`             | secret   | base64 of the exported "Developer ID Application" certificate + key (.p12) |
| `MACOS_CERTIFICATE_PASSWORD`        | secret   | password of that .p12                                                      |
| `NOTARY_API_KEY`                    | secret   | base64 of an App Store Connect API key (.p8) with the Developer role       |
| `NOTARY_API_KEY_ID`                 | variable | that key's Key ID                                                          |
| `NOTARY_API_ISSUER_ID`              | variable | the Issuer ID shown above the App Store Connect API keys list              |

Don't set these by hand: WebHare's portal (the `webhare_portal` module) maintains them from its
`data/github-projects.yaml`, which holds the IDs and reads the secrets from its registry.
