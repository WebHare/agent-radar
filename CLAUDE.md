# Agent Radar

A macOS menu bar app in Swift/SwiftUI that shows which AI coding agent conversations need the user, wherever
they run: in any VS Code window or in a terminal. Currently supports Claude Code. This file only holds what an
agent needs on top of the other documentation:

- `doc/requirements.md`: every expected feature, business rule, caveat and product decision (see
  [Requirements](#requirements)).
- `doc/claude-hooks.md`: the optional Claude Code hooks: what they change, log and mean.
- `README.md`: for users: what it does and how to install it. No developer documentation here.
- `CONTRIBUTING.md`: the contribution policy (issues welcome; code only with a CLA, agreed beforehand). Not
  developer documentation.
- `DEVELOPERS.md`: for developers: where the data comes from, the code layout, building, testing, signing
  and CI.
- `CHANGELOG.md`: what changed for users, per version (see [Changelog](#changelog)).

Read the relevant section before changing behaviour, and update it in the same change when a decision changes.

## Requirements

- All expected features, business rules, caveats and product decisions are recorded in
  [doc/requirements.md](doc/requirements.md).
  - Read it before changing behaviour, so a change doesn't silently break an earlier decision.
  - Update it in the same change whenever a feature, rule, caveat or decision is added, changed or dropped.
    This includes every request from the user that changes behaviour, however small (a UI tweak, a bug report
    that reveals an unstated expectation): record it in requirements.md without being asked, and mention it
    in your report.
  - Move items out of "Not built yet" when they are built.
  - When the code and requirements.md disagree, treat it as a bug in one of the two and ask which is right
    instead of guessing.
- Write requirements.md mostly as indented bulleted lists of requirements / user stories:
  - One requirement per bullet, describing what the user can do or what the app must (not) do.
  - Nest bullets for details, rules, edge cases and caveats of their parent.
  - Add a short *why* to a bullet when the reason isn't obvious, so the decision can be revisited
    deliberately rather than by accident.
  - Describe behaviour, not implementation: no type names, file names or code unless the user can see them.

## Changelog

- Mention every new feature and every non-trivial change in [CHANGELOG.md](CHANGELOG.md), in the same change.
  - Add it under `## Unreleased`, in the `Added`, `Changed`, `Fixed` or `Removed` group.
  - Write for users: what they can now do or will notice, in a sentence or two. No code, file names or commit
    hashes.
  - Leave out refactors, tests, docs and build changes that users don't notice.
  - When tagging a release, rename `Unreleased` to the version and date (`## 0.2 - 2026-11-20`) and start a
    new empty `Unreleased` section.

## Rules

- **Logic lives in `Sources/RadarKit`, views in `Sources/AgentRadar`.** Anything with a branch, a sort or
  a parse goes in RadarKit with a test; the app target stays views and wiring only.
- **Test first.** Write the failing test, watch it fail, then fix. `swift test`.
- **Don't assume VS Code.** Conversations can live in VS Code, in VS Code's integrated terminal or in a
  terminal app, and more editors and agents will follow. Keep editor- and agent-specific knowledge in its own
  file, and name things for what they are (`Workspace` with a `kind`, `ConversationTarget`), not after VS Code.
- **Read only.** The app never writes to the files of editors, terminals or agents, except for adding and removing its
  own hook entries in Claude Code's settings.json when the user switches the hooks in Settings (only through
  `ClaudeHooks`). Its other files live in `~/.agent-radar/`, which is also the only place the companion VS Code
  extension (`extensions/vscode`) writes to. Open SQLite databases read-only (`mode=ro`).
- **Undocumented formats stay in one place per provider.** Everything known about the Claude Code extension's
  internal state (storage keys, session files, transcripts, hook events) lives in `ClaudeCodeProvider.swift`;
  VS Code's own storage in `VSCodeState.swift`; process and terminal lookups in `Processes.swift`, and
  AppleScript for Terminal.app in the app's `TerminalApp.swift`. A new agent gets its own `ConversationProvider`.
- **Never touch the user's real Claude Code settings** without asking. Test installing the hooks
  (`--install-claude-hooks`) with `HOME` and `CLAUDE_CONFIG_DIR` pointing to a scratch folder; the app honours
  both.
- **Keep [doc/claude-hooks.md](doc/claude-hooks.md) in sync** with `ClaudeHooks.swift` and the event handling in
  `ClaudeCodeProvider.swift`: users read it to decide whether to let the app change their settings.
- **Commits:** `feat:` / `fix:` / `chore:` plus a sentence.
- **English on GitHub.** Write all issues, pull requests, comments, reviews and other GitHub communication in
  English, also when the user talks to you in another language.
- **Every change goes through a PR.** `main` only accepts pull requests that pass CI and are up to date with
  `main`; never commit to or push `main` directly.
- **Offer to commit.** When a change is finished and looks ready to commit (tests pass, docs updated), ask the
  user which they want: nothing yet, commit on a feature branch, commit and open a PR, or commit, open a PR and
  automerge it.
  - Commit only your own changes; leave changes from other sessions in the working tree alone.
  - Put the commit on a `feature/` branch off an up-to-date `main`, and open the PR with `gh pr create`.
  - Automerge means `gh pr merge --auto`, so GitHub merges it once CI passes. When `main` moves on before
    that, the PR waits until it's brought up to date (`gh pr update-branch`).

## Checking against real data

- `swift run AgentRadar --dump` prints the sections and conversations as the menu would show them, from the
  real VS Code and Claude Code state on this machine. Use it to check a change before looking at the UI.
- To see what the extension stores, read (never write) the `Anthropic.claude-code` row of `ItemTable` in
  `~/Library/Application Support/Code/User/globalStorage/state.vscdb` and in
  `.../workspaceStorage/<id>/state.vscdb`. VS Code saves these with a delay of a few seconds.
- After a Claude Code extension update, run `--dump` and compare with the tab dots in VS Code; the formats are
  not documented and may change.
- Terminal sessions: run `claude` in a Terminal.app tab and check the Terminal section of `--dump`. A session
  run from a shell inside VS Code (including this agent's own tools) counts as VS Code's integrated terminal.

## Verifying UI

A successful build does not prove the menu works. Run the app (`scripts/build-app.sh` and open the bundle in
`build/`), open the menu, and check it in light and dark. Say in your report what you did not look at.
