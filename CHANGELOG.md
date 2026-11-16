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

### Changed

- Clicking a conversation or opening a workspace now also closes the menu, instead of leaving it open on top of
  the window you went to.
- Clicking a workspace in the menu now opens it right away, also when it has conversations. Rest the pointer on
  it to see its conversations.
- Archived conversations are now listed while they wait for input, have an unread reply or are working, so a
  conversation that still needs you doesn't disappear when you archive it.
