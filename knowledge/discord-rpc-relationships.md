---
type: reference
title: Friend presence over Discord's local RPC socket
description: GET_RELATIONSHIPS and RELATIONSHIP_UPDATE carry the friend list and its presence, behind the relationships.read scope, which Discord gates the same way as rpc
tags: [discord, rpc, oauth, presence]
status: stable
verified:
  - by: a live AUTHORIZE on the local socket from an ordinary, unapproved application with the redirect registered, Omarchy 4.0.2, discord app-1.0.158
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

# Measured on the way there

A first-time application with no redirect saved fails `AUTHORIZE` outright
with `OAuth2 Error: invalid_request: Missing "redirect_uri" in request.`
That refusal arrives on the socket before any token exchange, and a bridge
that reconnects after a failure turns it into a consent modal every few
seconds. Authorization is therefore asked once per bridge process, and a
refusal ends the process with a distinct exit code the widget does not
respawn.

The developer portal's OAuth2 URL generator, checked on 2026-09-24, offers
`rpc`, `rpc.voice.read`, `rpc.voice.write`, `rpc.notifications.read` and
the other rpc scopes, but not `relationships.read`. That is why the friend
scope is requested on its own, after the voice tier is already working.

# Measured: the scope is refused for an ordinary application

With the redirect registered, the voice scopes granted and a fresh socket,
`AUTHORIZE` with `relationships.read` added answers:

```
OAuth2 Error: invalid_scope: The requested scope is invalid, unknown, or malformed.
```

Discord does not show a consent modal for it and the owner of the
application gets no exception. So unlike `rpc`, which an unapproved
application's owner can grant to themselves, the friend scope needs the
application to be approved for it first, and for a personal plugin that route
is closed. The bridge keeps the request, since an approved application would
succeed, but the Friends section has to say plainly that an ordinary one will
not.

Whether `RELATIONSHIP_UPDATE` fires for every presence transition therefore
remains unmeasured, and cannot be measured without an approved application.
