# Changelog

Notable changes to Agent Radar, newest first. Versions are the git tags the app is built from.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- First version: a menu bar item that counts the Claude Code conversations waiting for input or with unread
  replies, in VS Code windows, VS Code's integrated terminal and Terminal.app.
- The menu lists active, terminal, closed and recent workspaces, with a foldout of each workspace's
  conversations. Clicking a conversation goes straight to it.
- Optional Claude Code hooks, switched on in Settings, to see when the VS Code extension waits for input.
- An About panel, opened from Settings, with the version, build number and build date.
- Settings to launch Agent Radar at login, to choose what the number in the menu bar counts (waiting and unread,
  waiting only, or no number), and to hide the Terminal, Closed and Recent sections of the menu.

### Fixed

- **Settings…** now brings the settings window to the front when it was already open behind another app.
- A VS Code conversation whose reply finished while VS Code wasn't the frontmost app now counts as unread until
  you switch back to VS Code, even when the Claude Code extension shows a gray dot for it.

### Changed

- Clicking a conversation or opening a workspace now also closes the menu, instead of leaving it open on top of
  the window you went to.
- Clicking a workspace in the menu now opens it right away, also when it has conversations. Rest the pointer on
  it to see its conversations.
- Archived conversations are now listed while they wait for input, have an unread reply or are working, so a
  conversation that still needs you doesn't disappear when you archive it.
