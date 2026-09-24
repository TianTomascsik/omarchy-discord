---
type: reference
title: Friend presence comes from inside the client, through a file
description: With relationships.read refused to ordinary applications, a BetterDiscord plugin reads Discord's own stores and writes a private state file the widget watches
tags: [discord, betterdiscord, presence, quickshell]
status: stable
verified:
  - by: the plugin running inside a live BetterDiscord 1.12.7 on discord app-1.0.158, writing a 59-friend list with online, idle, dnd and offline statuses, and the widget reading it; the offline-to-online notification measured with a hand-written file
    at: 2026-09-24
---

# Why a file

Discord's local RPC socket refuses `relationships.read` to an application it
has not approved, so the only honest source of a friend list on a personal
setup is the client itself. BetterDiscord plugins run inside the renderer with
Node's `require`, and `BdApi.Webpack.getStore("PresenceStore")`,
`getStore("RelationshipStore")` and `getStore("UserStore")` are the stable
names published plugins already rely on: `RelationshipStore.getFriendIDs()`,
`PresenceStore.getStatus(id)`, `UserStore.getUser(id)` with `globalName` and
`username`, and `addChangeListener` on each store.

The plugin writes `$XDG_STATE_HOME/omarchy-discord/friends.json`, mode 0600
in a 0700 directory, through a temporary file and a rename:

```json
{"schema":1,"active":true,"updatedAt":1727180000000,"friends":[{"id":"1","name":"GM","status":"online"}]}
```

Statuses are `online`, `idle`, `dnd` or `offline`; invisible reads as offline
because that is what Discord shows everyone else. A burst of presence changes
is written once, 750 ms after it settles, and only when the list differs from
the last write. A heartbeat rewrites the file every minute so `updatedAt`
moves; `stop()` writes `active: false`.

# The widget side

`Quickshell.Io.FileView` with `watchChanges` reloads the file on every write.
The widget trusts it only while Discord's processes exist, `active` is true
and `updatedAt` is under three minutes old, checked against a clock the poll
timer bumps, so a client that died with the plugin marked active goes stale
without a file event. While the file is trusted it replaces the bridge's
friend list and hides the consent row; the bridge remains the source for an
application Discord has approved.

# What BetterDiscord's require actually offers

Measured on BetterDiscord 1.12.7, and confirmed in its source: a plugin's
`require` resolves `request`, `https`, `original-fs`, `fs`, `path`, `events`,
`electron`, `process`, `vm`, `module`, `buffer` and `crypto`, and nothing
else. `require("os")` throws at load and the plugin never starts, with no
file to show for it. `fs` is a polyfill over the preload's filesystem API,
but `mkdirSync`, `writeFileSync` and `renameSync` pass their arguments
straight to Node, so `{ recursive, mode }` and the temporary-then-rename
write work as they would in Node. Home is derived from `BdApi.Plugins.folder`,
three levels down from it, when `process.env.HOME` is not there to read.

# Measured live

With BetterDiscord injected by `betterdiscordctl install` and the plugin
switched on in `plugins.json`, the first write landed within a minute of
Discord starting: 59 friends, statuses `online`, `idle`, `dnd` and `offline`,
mode 0600. `PresenceStore.getStatus` answers for friends regardless of shared
servers, which is the client's own friend list behaving as it does on screen.
A Discord update removes the injection; `betterdiscordctl install` puts it
back and the plugin resumes on the next start.
