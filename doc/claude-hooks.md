# Claude Code hooks

Agent Radar can show which Claude Code conversations are **waiting for input**: blocked on a permission
prompt, a question or a plan approval.

Claude Code itself writes that state to its session file (`status: "waiting"`) when the prompt is shown in its
own terminal interface, and Agent Radar reads that without any hooks. For conversations in the VS Code extension
the prompt is shown by the extension instead, and it's not confirmed that the session file says "waiting" then.
The [Claude Code hooks](https://code.claude.com/docs/en/hooks) described here cover that case: small commands
Claude Code runs on certain events, whichever interface shows the prompt.

The hooks are optional. Without them Agent Radar still shows terminal sessions waiting, and unread, working and
open conversations everywhere.

## Installing and removing

- In the app: **Settings… → Show conversations waiting for input**.
- From a terminal, with the app's executable:

  ```sh
  "Agent Radar.app/Contents/MacOS/AgentRadar" --install-claude-hooks
  "Agent Radar.app/Contents/MacOS/AgentRadar" --uninstall-claude-hooks
  # or, in a checkout: swift run AgentRadar --install-claude-hooks
  ```

The hooks only apply to Claude Code conversations started after installing them; running conversations keep
the hooks they started with. The same goes for removing them.

## What gets changed

Installing does two things:

1. It writes the hook script to `~/.agent-radar/claude-hook.sh`.
   - When the app starts and the hooks are installed, it rewrites the script if a newer app version has a
     different one, so updates reach the installed hooks.
2. It adds the script to the `hooks` of Claude Code's user settings, `~/.claude/settings.json` (or
   `$CLAUDE_CONFIG_DIR/settings.json`), once for each event below. Each entry looks like:

   ```json
   "PermissionRequest": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "/Users/you/.agent-radar/claude-hook.sh",
           "async": true
         }
       ]
     }
   ]
   ```

Rules the installer follows:

- It only adds and removes entries whose command is Agent Radar's hook script. Your other settings and hooks
  stay as they are, in the same order.
  - The file is rewritten with two-space indentation, the way Claude Code writes it.
- Before changing settings.json it copies it to `settings.json.bak-agent-radar`.
- Installing twice doesn't add the hooks twice. Installing over a partial install (some events missing) adds the
  missing ones.
- When settings.json isn't valid JSON, it changes nothing and reports the problem.
- When settings.json is a symlink, it writes to the file the symlink points to.
- Removing deletes Agent Radar's entries, and the `hooks` member if nothing else is left in it. The hook script
  itself stays in `~/.agent-radar/`.

## The events

The hooks have no matcher, so they run for every event of these types. Agent Radar decides what each one means.

| Event | Meaning for Agent Radar |
|---|---|
| `PermissionRequest` | Waiting: a permission dialog is shown. |
| `Notification` | Waiting when the notification type is `permission_prompt` or `elicitation_dialog`. Other types (such as `idle_prompt`, sent a while after every finished reply) are ignored; finished conversations show as unread instead. |
| `Elicitation` | Waiting: an MCP server asks the user for input. |
| `PreToolUse` | Waiting when the tool is `AskUserQuestion` or `ExitPlanMode`, which wait for the user's answer. Other tools are ignored. |
| `PostToolUse`, `PostToolUseFailure` | No longer waiting: the tool ran (after permission was given or the question answered). |
| `PermissionDenied`, `ElicitationResult` | No longer waiting: the user answered. |
| `UserPromptSubmit` | No longer waiting: the user sent a message. |
| `Stop`, `StopFailure` | No longer waiting: the reply ended. |
| `SessionStart`, `SessionEnd` | No longer waiting. |

The last event of a conversation decides: it is waiting when that event says so. A waiting conversation only
counts while its Claude Code process is still running.

## The hook script and event log

The script reads the hook's JSON input, takes four fields from it with `/usr/bin/plutil` (part of macOS) and
appends one line to `~/.agent-radar/claude-code-events.jsonl`:

```json
{"event":"PermissionRequest","session":"0b92e3c1-...","type":"","tool":"Bash","time":1794825689}
```

| Field | From the hook input |
|---|---|
| `event` | `hook_event_name` |
| `session` | `session_id` |
| `type` | `notification_type` (Notification events only) |
| `tool` | `tool_name` (tool events only) |
| `time` | the time of the event, in seconds since 1970 |

- Nothing else from the input is kept: no prompts, tool input or output, or file contents.
- The hooks run with `"async": true`, so Claude Code doesn't wait for them, and the script always exits with 0,
  so it can never block or change what Claude Code does.
- Agent Radar reads the log every few seconds. When it grows past 256 KB, Agent Radar rewrites it to just the
  conversations that are waiting at that moment.
  - An event a hook appends at the exact moment of rewriting can get lost. The conversation's next event
    corrects that.
- Async hooks may finish in a different order than their events happened. In practice the events that matter
  (a prompt, then the answer) are seconds apart.

## Checking that it works

1. Install the hooks and start a new Claude Code conversation, in VS Code or a terminal.
2. Ask it to do something that needs permission, and leave the permission prompt open.
3. `tail ~/.agent-radar/claude-code-events.jsonl` shows a `PermissionRequest` line for the session, and
   the menu shows the conversation with a blue dot.
4. Answer the prompt: a `PostToolUse` or `PermissionDenied` line follows and the blue dot disappears.
