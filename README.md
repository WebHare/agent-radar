# Agent Radar

A macOS menu bar app that shows which AI coding agent conversations need you, wherever they run: in any VS Code
window or in a terminal.

Each place only tells you about its own conversations. The Claude Code extension marks a tab with a blue dot when
it waits for you and an orange dot when it has an unread reply, but only within its own window; a terminal tab
tells you nothing until you look at it. Agent Radar puts the total in the menu bar and lists:

1. **Active workspaces**: VS Code workspaces open in a window, with the conversations that need you.
2. **Terminal sessions**: Claude Code running in a terminal, by folder.
3. **Closed workspaces with open conversations**: VS Code workspaces closed while conversation tabs were still
   open or unread.
4. **Recent workspaces**: other recently opened VS Code workspaces.

Each workspace shows how long ago its most recent conversation changed ("15m", "2d"). Hover over it, or click
it, to see all its conversations with their state and last change; click a conversation to go straight to it:
in VS Code, or its tab in Terminal.app. See [doc/requirements.md](doc/requirements.md) for the complete behaviour.

| | VS Code extension | VS Code integrated terminal | Terminal.app | Other terminals |
|---|---|---|---|---|
| Working | ✓ | ✓ | ✓ | ✓ |
| Waiting for input | with the hooks | ✓ | ✓ | ✓ |
| Unread | ✓ | – | ✓ | – |
| Click to bring forward | ✓ | workspace only | ✓ | – |

Supports Claude Code now. Other agents (Codex, Copilot, ...) and editors (Cursor, VS Code Insiders) can be added
later.

## Installing

Requires macOS 14 and a Swift 6 toolchain (Xcode or the Command Line Tools).

```sh
scripts/build-app.sh --install      # builds and starts ~/Applications/Agent Radar.app
```

With terminal sessions running, macOS asks once whether Agent Radar may control Terminal. That's used to see
which tab is in front (to mark a session as read) and to bring a session's tab forward.

### Why there's a "Show conversations waiting for input" setting

Claude Code writes `"status": "waiting"` to its session file in `~/.claude/sessions/` whenever its terminal
interface shows a prompt, such as a permission question. Agent Radar reads that, so sessions in a terminal
(including VS Code's integrated terminal) show as **waiting for input** without any setup.

In the VS Code extension, the extension shows the prompt itself, and we haven't confirmed that Claude Code
writes "waiting" to the session file then. To be sure those conversations show as waiting too, turn on
**Settings… → Show conversations waiting for input**. This adds Claude Code hooks to
`~/.claude/settings.json` that log when a conversation starts and stops waiting. They only apply to sessions
started after turning the setting on. See [doc/claude-hooks.md](doc/claude-hooks.md) for what exactly gets
changed and logged.

If the session file turns out to say "waiting" for VS Code extension sessions as well, this setting will be
removed. To check: while a VS Code conversation shows a permission prompt, look for `"status": "waiting"` in
its file in `~/.claude/sessions/`.

## How it works

The app reads the state that VS Code, Claude Code and the terminal already keep, every 3 seconds. It never
writes to it, apart from the hooks you can switch on in Settings. These formats are internal to VS Code and
Claude Code and may change with an update.

## Contributing

Found a bug or have an idea? Anyone is welcome to [file an issue](../../issues). If you'd like to contribute
code, please read [CONTRIBUTING.md](CONTRIBUTING.md) first. See [CHANGELOG.md](CHANGELOG.md) for what changed
per version.

## Developing

See [DEVELOPERS.md](DEVELOPERS.md) for where the data comes from, the code layout, building, testing and CI.

## License

Copyright © 2026 WebHare b.v. Licensed under the GNU General Public License version 2. See [LICENSE](LICENSE).
