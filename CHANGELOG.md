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
- Mark a conversation as read by right-clicking it in the menu, or all of a workspace's conversations
  with **Mark all as read** in its foldout. Opening a conversation from the menu also marks it as read.

### Fixed

- A multi-folder workspace open in VS Code no longer turns into a single-folder entry in the menu when its first
  folder was also opened on its own; clicking it brings the workspace window forward instead of opening the
  folder in a new window.
- **Settings…** now brings the settings window to the front when it was already open behind another app.
- A VS Code conversation whose reply finished now counts as unread unless Agent Radar is sure you saw it, even
  when the Claude Code extension shows a gray dot for it. With several VS Code windows open, Agent Radar can't
  tell which one you're looking at, so it errs on the side of showing the reply as unread.

### Changed

- Clicking a conversation or opening a workspace now also closes the menu, instead of leaving it open on top of
  the window you went to.
- Clicking a workspace in the menu now opens it right away, also when it has conversations. Rest the pointer on
  it to see its conversations.
- Archived conversations are now listed while they wait for input, have an unread reply or are working, so a
  conversation that still needs you doesn't disappear when you archive it.
