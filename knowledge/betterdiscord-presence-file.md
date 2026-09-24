---
type: reference
title: Friend presence comes from inside the client, through a file
description: With relationships.read refused to ordinary applications, a BetterDiscord plugin reads Discord's own stores and writes a private state file the widget watches
tags: [discord, betterdiscord, presence, quickshell]
status: draft
verified:
  - by: the plugin exercised in Node against stubbed stores, the widget side against a hand-written file; not yet against a live BetterDiscord, which was not injected on the measuring machine
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

# Not yet measured

The plugin has run only against stubbed stores. BetterDiscord was not injected
into the measuring machine's Discord (app-1.0.158 had no trace of it after an
update), so the first live run will settle whether `getStatus` reports friends
outside shared servers the way the client's own friend list does.
