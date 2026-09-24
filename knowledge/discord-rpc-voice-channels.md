---
type: reference
title: Listing voice channels and joining one over the local RPC socket
description: GET_GUILDS, GET_CHANNELS and GET_CHANNEL answer under the plain rpc scope; SELECT_VOICE_CHANNEL joins, with force for a user already in a call and a timeout for a client still starting
tags: [discord, rpc, voice]
status: stable
verified:
  - by: listing, joining, holding and leaving measured live against discord app-1.0.158 with the plugin's own voice token, warm and from a cold start
    at: 2026-09-25
---

# Listing, measured

With the token the voice tier already holds (`rpc`, `rpc.voice.read`,
`rpc.voice.write`), the socket answered:

- `GET_GUILDS` with `{"guilds": [{"id", "name", "icon_url"}]}`, 47 of them.
- `GET_CHANNELS {"guild_id"}` with `{"channels": [{"id", "name", "type"}]}`;
  guild voice channels are `type` 2, text 0, categories 4. No `voice_states`.
- `GET_CHANNEL {"channel_id"}` with the full object, including `voice_states`,
  which is how a favourite row learns how many people are in the channel.
- `GET_SELECTED_VOICE_CHANNEL` with the channel object or nothing.

Every one of these is under the plain `rpc` scope; no `rpc.guilds` scope
exists. The bridge asks for the listing only when the picker opens, since it
is one request per guild, and keeps it for the bridge session.

# Joining, measured

`SELECT_VOICE_CHANNEL {"channel_id", "timeout": 30, "force": true}` on an
empty channel answered at once, in under a tenth of a second, with the channel
object, and `GET_SELECTED_VOICE_CHANNEL` named the channel from then on. The
bridge's fire-and-forget form landed the same way: `VOICE_CHANNEL_SELECT`
followed and the call held for as long as it was watched. From a cold start,
`omarchy-shell discord join` launched Discord, the socket appeared after six
seconds and the client was in the channel by fourteen, on the first attempt;
no 4005 or 5001 was seen, so the retry stayed unexercised. Channel names may
themselves start with `#` ("#Tamecap" is a real one), so the hash is only
added where it is missing.

One trap while measuring: sampling the selected channel by opening a fresh
RPC connection every two seconds ended the call by the third sample, in line
with Discord's two-connections-a-minute limit; the same sampling on one held
connection did not. A probe of a live call must keep its connection.

# Joining, from the documentation

`SELECT_VOICE_CHANNEL {"channel_id", "timeout", "force", "navigate"}` joins,
and `channel_id: null` leaves, which the bridge has used for hang-up since
its first release. Discord answers error 5003 when the user is already in a
call unless `force` is true; the documentation asks that `force` only follow
the user's approval to be moved, and a press on a favourite's row is that
approval, so the bridge always sends it. Other codes: 4005 invalid channel,
4006 no permission, 5001 the asynchronous join timed out.

`READY` is only the handshake: nothing says when a freshly started client can
take a join. The bridge sends every join with `timeout` 30 (Discord caps it
at 60), retries once on 4005 or 5001, and the widget gives up after a minute.
Discord also rate-limits RPC connections to two per minute; the bridge's
reconnect loop only reaches the socket once it exists, so a cold start does
not trip it.

The reply to a join is matched by nonce in the bridge's read loop, since the
command is sent fire and forget so a slow join never blocks the call state;
a refusal lands in the snapshot as `joinError` with the code, and
`VOICE_CHANNEL_SELECT` is the success.

# Who is in a channel, live

`SUBSCRIBE VOICE_STATE_CREATE {"channel_id"}` and its `_DELETE` twin work per
favourite under `rpc.voice.read`, and a join in a watched channel arrived as
an event within a second of it happening. The event carries the voice state
but not the channel id, so the bridge answers any of them by re-reading every
favourite with `GET_CHANNEL`, whose `voice_states` give the members: `nick`
first, then `global_name`, then `username`. A dropped favourite is
unsubscribed on the next refresh. The channel the user sits in already has
SPEAKING subscriptions; a second pair for it is harmless.

# Still to measure

The codes a live socket returns for a stale id and for a channel without
Connect permission; the retry keys on the documented 4005 and 5001 until then.
