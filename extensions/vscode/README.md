# Agent Radar for VS Code

Companion extension for [Agent Radar](https://github.com/WebHare/agent-radar), a macOS menu bar app that shows
which AI coding agent conversations need you.

Without this extension, Agent Radar can't tell which VS Code window you're looking at. With several windows open,
it then marks nearly every finished Claude Code reply as unread, even the one you watched finish. This extension
tells Agent Radar which conversation tabs are in front of the window you're using, so those replies count as seen.

## What it does

- In each VS Code window, it writes one small file to `~/.agent-radar/vscode-windows/`, and removes it when the
  window closes.
- That file holds the window's folders, whether the window has focus, and the titles of its webview tabs (such as
  Claude Code conversations), with whether each is in front and when it last was while the window had focus.
- It doesn't read your files, your conversations or anything inside a tab, and it doesn't use the network.

## Limits

- Conversations opened in the sidebar can't be seen by other extensions, so they still count as unread until
  you open them from Agent Radar or mark them as read.
- When two conversations in a workspace have the same title, Agent Radar can't tell which one you looked at, so
  neither counts as seen.
