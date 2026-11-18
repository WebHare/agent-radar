# Agent Radar requirements

What Agent Radar does and the rules it follows. See [CLAUDE.md](../CLAUDE.md) for how to maintain this file.

## General

- Agent Radar is a macOS menu bar app that shows which AI coding agent conversations need the user, wherever
  they run: in VS Code windows or in terminals.
  - *Why:* each place only shows its own conversations (the Claude Code extension only those of the workspace in
    its own window, a terminal only its own tab), so a conversation waiting elsewhere goes unnoticed.
  - Requires macOS 14 or later.
- Supported now: Claude Code, in the VS Code extension, in VS Code's integrated terminal and in other terminals.
  - The app is built so other agents (Codex, Copilot, ...) and editors can be added as separate sources.
  - *Why:* hence the name "Agent Radar", which names neither an editor nor an agent.
- The app only reads. It never changes the files or settings of editors, terminals or agents.
  - Exception: when the user turns on the optional Claude Code hooks in Settings (see
    [Waiting for input](#waiting-for-input)), the app adds them to Claude Code's settings, and removes them
    again when the user turns them off. Nothing else is ever changed.
- The app has no Dock icon, only a menu bar item.

## Menu bar item

- The menu bar item shows how many conversations need the user.
  - A conversation needs the user when it is **waiting for input** or has **unread messages**.
  - When nothing needs the user, the item shows just the icon, without a number.
  - In Settings the user chooses what the number counts:
    - **Waiting and unread** (the default).
    - **Waiting only**, for users who find a number for every finished reply too noisy.
    - **None, only the icon**: no number, but the icon still changes when something needs the user.
  - Only conversations in sections the menu shows count, so the number always matches the menu.
    - *Why:* a number the user can't find in the menu is useless.
- The count updates by itself within a few seconds of a change.
  - VS Code saves its state with some delay, so an unread change there can take a few seconds to show.

## Conversation states

- **Waiting for input**: the conversation is blocked on the user, such as a permission prompt or a question.
  - Matches the "pending" (blue) dot on the conversation's tab in VS Code.
- **Unread**: the conversation finished a reply the user hasn't looked at yet.
  - In VS Code: matches the orange dot on the conversation's tab, and comes from the same data, so opening the
    conversation in VS Code clears it here too.
  - In VS Code, a conversation is also unread when its reply finished and the app isn't sure the user saw it.
    Such a conversation can be unread here while its tab dot is gray.
    - *Why:* the extension only marks a reply unread when its tab is hidden, and ignores window focus. A reply
      that finishes in a tab in front of a background window, or while VS Code is behind another app, keeps a gray
      dot and went unnoticed. Better a reply marked unread that the user saw than one they missed.
    - The app is only sure while VS Code is the frontmost app with a single window open. It can't tell which of
      several windows the user is looking at without asking for extra permissions, so it doesn't try.
      - *Why:* checking only whether VS Code was in front missed replies in one window while the user worked in
        another. The options and their trade-offs are in issue #7.
    - Consequence: with several VS Code windows open, nearly every finished reply counts as unread, including
      the one the user is watching, until it's cleared.
    - It's cleared when the user sends a new message in the conversation, opens it from the menu, marks it as
      read in the menu, or when VS Code is in front with a single window.
    - Temporary: drop this once the extension takes window focus into account (reported to Claude Code as
      anthropics/claude-code#110457, tracked here in issue #3).
    - Also applies to sessions in VS Code's integrated terminal, which have no unread dot of their own.
    - Replies that finished before the app first ran don't count.
  - In a terminal: see [Terminal sessions](#terminal-sessions).
- **Working**: the conversation is busy (thinking or running tools). Not counted in the menu bar.
  - A workspace or folder with working conversations shows a spinner in the menu, with the number in its
    subtitle.
  - Comes from Claude Code's own session state, so it works without the optional hooks.
- **Open**: the conversation is open (in a VS Code tab, or running in a terminal) with nothing pending.
- Archived conversations (archived in the Claude Code extension) are left out, unless they are waiting for
  input, unread or working.
  - *Why:* archiving is how the user says they're done with a conversation; counting them made the numbers
    meaningless. But an archived conversation that still needs the user (or is still busy) must not disappear.
  - An archived conversation that is merely open (running with nothing pending) is left out.

## Waiting for input

- Claude Code writes "waiting" to its own session state when its terminal interface shows a prompt, and the app
  reads that without any setup.
- For the VS Code extension, where the extension shows the prompt, that isn't confirmed, so the app can also get
  "waiting" from optional Claude Code hooks that the user installs in their Claude Code settings.
  - The same hooks cover the VS Code extension and terminals.
  - The hooks append one line per event to the app's event log; they never block or change Claude Code.
  - The user turns them on and off in **Settings…** with **Show conversations waiting for input**.
    - Turning it on adds the hooks to Claude Code's user settings; turning it off removes them again.
    - The user's other settings and hooks stay as they are, in the same order, and a backup of the previous
      settings file is kept.
    - When the settings file can't be read, the app changes nothing and shows why, with the switch disabled.
    - When only some of the hooks are installed, the switch is off and a warning says so; turning it on
      installs the rest.
    - The settings screen shows where the settings file is, and clicking it shows the file in Finder.
  - They can also be installed and removed from the command line, for scripted setups.
  - The hooks only log the event type, conversation, notification type and tool name, never prompts or output.
    - *Why:* the log is a plain file; it shouldn't become a copy of the user's conversations.
  - See [claude-hooks.md](claude-hooks.md) for the details.
  - They only apply to sessions started after installing them.
  - Without the hooks, the app still shows unread, working and open conversations, and terminal sessions that
    are waiting.
  - Only conversations that are still running can be waiting.
  - A permission prompt or question counts as waiting; Claude Code's "idle for a while" reminder does not.
    - *Why:* that reminder fires for every finished conversation, which is already covered by "unread".
- The event log is kept small automatically.

## Terminal sessions

- Claude Code sessions running in a terminal (outside VS Code) are listed by the folder they run in.
  - Only while they run; a terminal has nothing like VS Code's restorable tabs.
- Sessions in VS Code's integrated terminal belong to the VS Code workspace whose folder they run in, not to a
  terminal folder.
  - Clicking them opens the workspace; the app can't select a specific integrated terminal.
- Terminals have no unread state of their own, so the app keeps it:
  - A session is unread when it finished a reply after the user last looked at its tab.
  - The user has looked at a tab when it was the tab in front while the terminal app was in front.
    - Only works for Terminal.app for now; in other terminals the app can't see which tab is in front.
  - A session that just started and hasn't replied yet is not unread.
  - What the user has seen is remembered across restarts of the app, for as long as the session runs.
- Clicking a session in the menu or the folder's foldout brings its tab to the front.
  - Terminal.app only. The first time, macOS asks whether Agent Radar may control Terminal.
  - Sessions in other terminals are shown, but clicking them does nothing yet.
- The app only talks to Terminal.app while there are terminal sessions, so users without them never get the
  permission question.

## The menu

- Opening the menu bar item shows four sections:
  1. **Active workspaces**: VS Code workspaces open in a window, with how many conversations need the user.
  2. **Terminal sessions**: folders with Claude Code sessions running in a terminal.
  3. **Closed workspaces with open conversations**: VS Code workspaces not open in a window that still had
     conversation tabs open or unread conversations when they were closed.
  4. **Recent workspaces**: other recently opened VS Code workspaces.
     - Limited to the 10 most recent.
  - Empty sections are left out, except Active workspaces, which then says so.
  - In Settings the user can hide Terminal sessions, Closed workspaces and Recent workspaces.
    - Active workspaces can't be hidden: it's the core of the menu.
    - Hidden sections are still tracked (eg. what the user has seen in Terminal), they're just not shown or
      counted.
- Within a section, entries that need the user come first, then the most recently used.
- Every entry shows how long ago its most recently changed conversation changed, as a short age ("now", "15m",
  "3h", "2d", "5w", "1y"), with the exact time on hover.
  - A conversation changes when Claude Code writes to its transcript: a message, a tool call, a title.
- An entry that needs the user lists those conversations by title under it, marked waiting or unread.
- Resting the pointer on an entry with conversations opens a foldout beside the menu:
  - It lists all the entry's conversations with their state and age: those that need the user first, then the
    most recently changed.
  - Clicking a conversation goes straight to it.
    - That also counts as reading it, so it's no longer unread.
  - Right-clicking an unread conversation offers **Mark as Read**, without going to it.
  - When the entry has unread conversations, the foldout has **Mark all as read**; right-clicking the entry
    offers the same.
    - Marking as read also hides the extension's own unread dot here (not in VS Code), until the next reply.
      *Why:* the app can't change the extension's state, but the user has said they've seen it.
  - For a VS Code workspace, the foldout also has an item to open the workspace itself.
  - Resting on another entry switches the foldout to that entry; resting on an entry without conversations
    closes it.
- Clicking an entry opens its workspace right away, whether or not it has conversations.
  - *Why:* going to the workspace is the common case; the foldout is one hover away.
  - For a VS Code workspace this opens it in VS Code (or brings its window to the front); for a terminal folder
    it brings its most relevant session to the front.
- Whenever a click takes the user to a conversation or workspace (in the menu or in a foldout), the menu and
  its foldout close.
  - *Why:* the menu otherwise stays open on top of the window the user just went to.
- Clicking a VS Code conversation opens its workspace (brings its window to the front if already open) and then
  the conversation.
- A VS Code workspace is a folder or a `.code-workspace` file; it is shown by the folder or file name, without
  extension.
  - Workspaces whose folder or file no longer exists are left out.
  - Remote workspaces (SSH, containers) are left out.
- A VS Code window only counts as open when the Claude Code extension is active in it.
  - *Why:* VS Code keeps no live list of its windows on disk; the extension does.
- The menu has **Refresh**, **Settings…** and **Quit**.
  - **Settings…** always brings the settings window to the front, also when it's already open behind
    another app's windows.
- A local build (built on a developer's machine) shows its build number, build date and time (in the local
  time zone) and version in a small line at the bottom of the menu.
  - *Why:* so a developer can see at a glance whether they are looking at an up-to-date build.
  - Release builds (the downloadable DMG, and a future App Store build) don't show this line; they show the
    same details in About.

## Settings

- **Launch at login** starts Agent Radar when the user logs in.
  - Uses macOS's Login Items, so the user can also turn it off in System Settings.
  - When it's turned off there, or macOS wants the user to allow it first, Settings says so and has a button
    to open Login Items.
  - Only works for the app bundle, not when run with `swift run`; Settings shows the error then.
- What the menu bar number counts and which sections the menu shows: see [Menu bar item](#menu-bar-item) and
  [The menu](#the-menu).
- **Show conversations waiting for input**: see [Waiting for input](#waiting-for-input).
- Settings shows the app's version, with an **About Agent Radar** button.
  - About shows the version, the build number, whether it is a local, downloaded (DMG) or App Store build, and
    when it was built.
- Settings other than the hooks and Launch at login are stored in the app's own preferences.

## Not built yet

- An App Store build. The app already knows it as a kind of build, but nothing builds or submits it yet.

- Notifications when a conversation starts waiting.
- Seeing which tab is in front, and bringing a tab forward, in terminals other than Terminal.app (iTerm2,
  Ghostty, ...), and for sessions inside tmux or screen.
- Claude Code background sessions (`claude agents`) and Claude Code in the Desktop app.
- Other agents (Codex, Copilot, ...).
- VS Code Insiders, Cursor and other VS Code variants.
