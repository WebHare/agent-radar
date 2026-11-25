// Agent Radar's VS Code extension: tells the Agent Radar menu bar app which webview tabs (such as Claude Code
// conversations) are in front of this window, whether the window has focus, and when each tab was last in front
// while it had focus. It only writes its own file and never looks inside tabs.
//
// One file per window: ~/.agent-radar/vscode-windows/<extension host pid>.json, rewritten on every change and
// removed when the window closes. Keep this format in sync with Sources/RadarKit/VSCodeCompanion.swift.
const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

const dir = path.join(os.homedir(), '.agent-radar', 'vscode-windows');
const file = path.join(dir, `${process.pid}.json`);

/** "viewType\nlabel" → when that tab was last in front while the window had focus (ms since 1970). */
const seenAt = new Map();
/** The keys of the tabs that were in front of the focused window at the last update. */
let seenNow = new Set();

const keyOf = tab => `${tab.input.viewType}\n${tab.label}`;

function webviewTabs() {
  return vscode.window.tabGroups.all.flatMap(group => group.tabs)
    .filter(tab => tab.input instanceof vscode.TabInputWebview);
}

function update() {
  const now = Date.now();
  // Tabs that were seen until now.
  for (const key of seenNow) seenAt.set(key, now);

  const focused = vscode.window.state.focused;
  const tabs = webviewTabs();
  seenNow = new Set(focused ? tabs.filter(tab => tab.isActive).map(keyOf) : []);
  for (const key of seenNow) seenAt.set(key, now);
  // Forget tabs that are gone, so the map doesn't grow.
  const present = new Set(tabs.map(keyOf));
  for (const key of seenAt.keys()) if (!present.has(key)) seenAt.delete(key);

  const state = {
    version: 1,
    pid: process.pid,
    app: vscode.env.appName,
    folders: (vscode.workspace.workspaceFolders || []).filter(f => f.uri.scheme === 'file').map(f => f.uri.fsPath),
    focused,
    updatedAt: now,
    tabs: tabs.map(tab => ({
      viewType: tab.input.viewType,
      label: tab.label,
      inFront: tab.isActive,
      ...(seenAt.has(keyOf(tab)) ? { seenAt: seenAt.get(keyOf(tab)) } : {}),
    })),
  };
  try {
    fs.mkdirSync(dir, { recursive: true });
    const temp = `${file}.tmp`;
    fs.writeFileSync(temp, JSON.stringify(state));
    fs.renameSync(temp, file);
  } catch (e) {
    console.error('Agent Radar: could not write', file, e);
  }
}

function activate(context) {
  context.subscriptions.push(
    vscode.window.onDidChangeWindowState(update),
    vscode.window.tabGroups.onDidChangeTabs(update),
    vscode.window.tabGroups.onDidChangeTabGroups(update),
    vscode.workspace.onDidChangeWorkspaceFolders(update),
  );
  update();
}

function deactivate() {
  try {
    fs.unlinkSync(file);
  } catch {
    // Already gone.
  }
}

module.exports = { activate, deactivate };
