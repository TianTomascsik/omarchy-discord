---
type: reference
title: Friend presence over Discord's local RPC socket
description: GET_RELATIONSHIPS and RELATIONSHIP_UPDATE carry the friend list and its presence, behind the relationships.read scope, which Discord gates the same way as rpc
tags: [discord, rpc, oauth, presence]
status: draft
verified:
  - by: Discord's OAuth2 documentation and the community RPC reference; the live socket has not yet been exercised with the scope granted
    at: 2026-09-24
---

# The two calls

`GET_RELATIONSHIPS` returns `{"relationships": [...]}`, one entry per
relationship with `type`, an RPC `user` and a `presence` carrying `status` and
an optional `activity`. `RELATIONSHIP_UPDATE`, subscribed with no arguments,
delivers one such entry whenever a relationship changes, and a presence change
counts. Both need the `relationships.read` scope.

Relationship types: `1` is a friend. Blocked users, incoming and outgoing
requests and implicit relationships arrive on the same event with other type
values and are dropped by `friend_entry`.

Status values seen in the reference are `online`, `idle`, `dnd` and `offline`.
A friend who is invisible reads as `offline`, which is what Discord shows every
other client too. The bridge collapses anything else to `offline` as well, so
the watcher's only positive statuses are the three reachable ones.

The user object carries `id`, `username` and `global_name`; the display name
wins when present.

# The scope is gated like rpc

Discord's scopes table lists `relationships.read` as part of its Social SDK,
to be applied for. That is the same footing as `rpc`, `rpc.voice.read` and
`rpc.voice.write`, which the documentation calls partner-only and which this
plugin has been granting to the application's own owner since its first
release. The expectation, still unmeasured, is that the owner and the App
Testers list can grant it to themselves the same way.

If the local socket refuses the four-scope `AUTHORIZE`, the bridge asks again
with the three voice scopes, records `friendsRefused` in the token file so the
consent modal does not reappear on every connect, and reports the reason in
`friendsError`. `--setup` is the retry path and always asks for all four.

# What is still open

Whether `AUTHORIZE` with `relationships.read` is accepted for an unapproved
application's owner, and whether `RELATIONSHIP_UPDATE` fires for every presence
transition or only for some, both need a live session with the scope granted.
When that is measured, this file moves to `status: stable`.
