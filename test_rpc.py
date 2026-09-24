#!/usr/bin/env python3
"""Adversarial cases for rpc.py. Each one failed before the fix it guards.

Run with: python3 test_rpc.py
"""

import contextlib
import io
import json
import os
import stat
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rpc

FAILURES = []


def check(name, passed, detail=""):
    print("%s %s%s" % ("ok  " if passed else "FAIL", name,
                       "" if passed else "  (%s)" % detail))
    if not passed:
        FAILURES.append(name)


class FakeSocket:
    """Enough of a socket for Rpc(...) to be built and closed."""

    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class FakeRpc:
    """Stands in for Rpc so the read loop can be driven without Discord."""

    def __init__(self, frames=()):
        self.frames = list(frames)
        self.commands = []

    def subscribe(self, event, args=None):
        return "0"

    def unsubscribe(self, event, args=None):
        return "0"

    def command(self, cmd, args=None, evt=None):
        self.commands.append((cmd, args))
        return "0"

    def request(self, cmd, args=None, evt=None):
        if cmd == "GET_VOICE_SETTINGS":
            return {"mute": False, "deaf": False, "input": {"volume": 100}}
        if cmd == "GET_RELATIONSHIPS":
            return {"relationships": list(getattr(self, "relationships", []))}
        # answers maps a command name to its reply, or to an exception to raise
        answer = getattr(self, "answers", {}).get(cmd)
        if isinstance(answer, Exception):
            raise answer
        if callable(answer):
            return answer(args or {})
        return answer or {}

    def readable(self, timeout):
        return True

    # run() ends when the script runs out, which proves it kept looping
    def recv(self):
        if not self.frames:
            raise rpc.RpcError("frames exhausted")
        return self.frames.pop(0)

    def take_deferred(self):
        return []

    def send(self, op, payload):
        return None


@contextlib.contextmanager
def captured_warnings():
    lines = []
    original = rpc.warn
    rpc.warn = lines.append
    try:
        yield lines
    finally:
        rpc.warn = original


def drive(bridge):
    """Run the read loop to frame exhaustion, swallowing the stop and its output."""
    while not rpc.COMMANDS.empty():
        rpc.COMMANDS.get_nowait()
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            bridge.run()
        except rpc.RpcError:
            pass


def leftover_temporary_cannot_widen_a_secret():
    """A .tmp left behind by a crash used to donate its 0644 to the token."""
    with tempfile.TemporaryDirectory() as directory:
        target = os.path.join(directory, "token.json")
        with open(target + ".tmp", "w") as handle:
            handle.write("{}")
        os.chmod(target + ".tmp", 0o644)
        rpc.write_private(target, {"access_token": "not-a-real-token"})
        mode = stat.S_IMODE(os.stat(target).st_mode)
        check("leftover temporary cannot widen a secret", mode == 0o600, oct(mode))


def a_symlink_cannot_redirect_the_token():
    """The .tmp path is predictable, so a symlink there used to take the write."""
    with tempfile.TemporaryDirectory() as directory:
        target = os.path.join(directory, "token.json")
        bystander = os.path.join(directory, "bystander")
        with open(bystander, "w") as handle:
            handle.write("UNTOUCHED")
        os.symlink(bystander, target + ".tmp")
        rpc.write_private(target, {"access_token": "not-a-real-token"})
        with open(bystander) as handle:
            kept = handle.read()
        check("a symlink cannot redirect the token", kept == "UNTOUCHED", kept)


def a_bad_command_value_never_raises():
    """float(None) raised TypeError and killed the command channel for good."""
    fake = FakeRpc()
    with captured_warnings() as warnings:
        rpc.Bridge(fake).handle_command('{"cmd":"inputVolume","value":null}')
    joined = " ".join(warnings)
    # the unknown-command warn also names the command, so pin the wording
    check("a bad inputVolume is named as needing a number",
          "inputVolume needs a number" in joined, joined)
    check("and no command reaches Discord", fake.commands == [], fake.commands)


def a_good_command_value_reaches_discord():
    """Positive control: without it, deleting the branch entirely reads as a pass."""
    fake = FakeRpc()
    rpc.Bridge(fake).handle_command('{"cmd":"inputVolume","value":42}')
    check("a valid inputVolume reaches Discord",
          fake.commands == [("SET_VOICE_SETTINGS", {"input": {"volume": 42.0}})],
          fake.commands)


def as_number_rejects_both_bad_shapes():
    """float(None) raises TypeError but float(\"loud\") raises ValueError."""
    check("as_number rejects None", rpc.as_number(None) is None)
    check("as_number rejects text", rpc.as_number("loud") is None)
    check("as_number accepts a number", rpc.as_number(80) == 80.0)


def an_unknown_command_is_named():
    fake = FakeRpc()
    with captured_warnings() as warnings:
        rpc.Bridge(fake).handle_command('{"cmd":"bogus"}')
    check("an unknown command is named in the warning",
          any("bogus" in line for line in warnings), warnings)


def a_refused_fire_and_forget_command_is_not_silent():
    """Nobody waits on these, so run() used to discard the ERROR frame."""
    frame = (rpc.OP_FRAME, {"cmd": "SET_VOICE_SETTINGS", "evt": "ERROR", "nonce": "7",
                            "data": {"message": "Invalid Channel Id"}})
    bridge = rpc.Bridge(FakeRpc([frame]))
    with captured_warnings() as warnings:
        drive(bridge)
    joined = " ".join(warnings)
    # a generic unexpected-frame warn would quote both, so pin the refusal wording
    check("a refused fire and forget command is reported as a refusal",
          joined.startswith("Discord refused"), joined)
    check("naming the command", "SET_VOICE_SETTINGS" in joined, joined)
    check("and carrying Discord's message", "Invalid Channel Id" in joined, joined)


def the_public_key_is_refused_as_a_secret():
    exact = rpc.PUBLIC_KEY_LENGTH
    check("the right length of hex reads as the Public Key",
          rpc.looks_like_public_key("f" * exact))
    check("the right length of non-hex does not",
          not rpc.looks_like_public_key("g" * exact))
    check("hex one character short does not",
          not rpc.looks_like_public_key("f" * (exact - 1)))
    check("a real secret does not", not rpc.looks_like_public_key("s3cr3t"))


def a_clipped_warning_marks_the_cut():
    """Testing clip() alone leaves a call site free to go back to a bare slice."""
    padding = "9" * (rpc.WARN_INPUT_CHARS + 10)
    with captured_warnings() as warnings:
        rpc.Bridge(FakeRpc()).handle_command("not json " + padding)
    joined = " ".join(warnings)
    check("an over-long command is clipped where it is warned", "..." in joined, joined)
    check("and the whole input is not echoed", padding not in joined, joined)
    check("a short input is left alone",
          rpc.clip(' {"cmd":"mute"} ', rpc.WARN_INPUT_CHARS) == '{"cmd":"mute"}')


def a_refusal_warning_clips_the_command():
    """The other clip call site, on the path a refused command takes."""

    class RefusingRpc(FakeRpc):
        def request(self, cmd, args=None, evt=None):
            raise rpc.RpcRejected("Invalid Channel Id")

    padding = "9" * (rpc.WARN_INPUT_CHARS + 10)
    while not rpc.COMMANDS.empty():
        rpc.COMMANDS.get_nowait()
    rpc.COMMANDS.put('{"cmd":"refresh","pad":"' + padding + '"}')
    with captured_warnings() as warnings:
        rpc.Bridge(RefusingRpc()).drain_commands()
    joined = " ".join(warnings)
    check("a refusal warning clips the command", "..." in joined, joined)
    check("and does not echo the whole input", padding not in joined, joined)


def a_refusal_is_still_an_rpc_error():
    """Every caller that already catches RpcError must keep catching a refusal."""
    check("RpcRejected subclasses RpcError",
          issubclass(rpc.RpcRejected, rpc.RpcError))


def relationship(kind, user_id, status=None, **user):
    """A RELATIONSHIP_UPDATE payload, or one GET_RELATIONSHIPS entry, as Discord shapes it."""
    payload = {"type": kind, "user": dict(user, id=user_id)}
    if status is not None:
        payload["presence"] = {"status": status}
    return payload


def a_friend_entry_reads_name_and_presence():
    user_id, entry = rpc.friend_entry(
        relationship(rpc.RELATIONSHIP_FRIEND, "1", "idle", username="gm", global_name="GM"))
    check("a friend keeps its id", user_id == "1", user_id)
    check("the display name wins over the username", entry["name"] == "GM", entry)
    check("idle is a reachable status", entry["status"] == "idle", entry)
    _, plain = rpc.friend_entry(relationship(rpc.RELATIONSHIP_FRIEND, "2", "online", username="gm"))
    check("without a display name the username is used", plain["name"] == "gm", plain)


def unreachable_presences_read_as_offline():
    """The watcher only fires on reachable, so invisible and unknown must collapse to offline."""
    for status in ("invisible", "unknown", None):
        _, entry = rpc.friend_entry(relationship(rpc.RELATIONSHIP_FRIEND, "1", status, username="gm"))
        check("%r reads as offline" % (status,), entry["status"] == "offline", entry)


def a_non_friend_relationship_is_not_a_friend():
    """Requests and blocks arrive on the same event and must never show up in the list."""
    for kind in (0, 2, 3, 4, 5):
        user_id, entry = rpc.friend_entry(relationship(kind, "9", "online", username="stranger"))
        check("type %d is not a friend" % kind, user_id == "9" and entry is None, entry)
    user_id, entry = rpc.friend_entry({"type": 1, "presence": {"status": "online"}})
    check("a payload without a user is ignored", user_id == "" and entry is None, entry)


def the_bridge_tracks_relationship_updates():
    bridge = rpc.Bridge(FakeRpc())
    added = bridge.apply_relationship(relationship(1, "1", "offline", username="gm"))
    same = bridge.apply_relationship(relationship(1, "1", "offline", username="gm"))
    changed = bridge.apply_relationship(relationship(1, "1", "online", username="gm"))
    removed = bridge.apply_relationship(relationship(0, "1", username="gm"))
    check("a new friend is a change", added)
    check("an identical update is not", not same)
    check("a presence change is", changed)
    check("an unfriend removes the entry", removed and bridge.friends == {}, bridge.friends)


def load_friends_lists_and_subscribes():
    fake = FakeRpc()
    fake.relationships = [relationship(1, "2", "online", username="zed"),
                          relationship(1, "1", "offline", username="amy"),
                          relationship(3, "3", "online", username="pending")]
    subscribed = []
    fake.subscribe = lambda event, args=None: subscribed.append(event) or "0"
    bridge = rpc.Bridge(fake)
    bridge.load_friends()
    with contextlib.redirect_stdout(io.StringIO()) as out:
        bridge.emit()
    state = json.loads(out.getvalue())
    check("friends are listed sorted by name",
          [f["name"] for f in state["friends"]] == ["amy", "zed"], state["friends"])
    check("a pending request is left out", all(f["id"] != "3" for f in state["friends"]))
    check("the bridge subscribes to relationship updates",
          subscribed == ["RELATIONSHIP_UPDATE"], subscribed)
    check("friendsOk is reported", state["friendsOk"] is True and state["friendsError"] == "", state)


def a_refused_friend_list_leaves_voice_alone():
    """The whole point of the fallback: no relationships.read must never cost the call controls."""

    class RefusingRpc(FakeRpc):
        def request(self, cmd, args=None, evt=None):
            if cmd == "GET_RELATIONSHIPS":
                raise rpc.RpcRejected("Unauthorized")
            return FakeRpc.request(self, cmd, args, evt)

    bridge = rpc.Bridge(RefusingRpc())
    bridge.load_friends()
    check("a refusal is reported by name", "Unauthorized" in bridge.state["friendsError"], bridge.state)
    check("and friendsOk is false", bridge.state["friendsOk"] is False)
    check("and the session itself is still ok", bridge.state["ok"] is True)

    missing = rpc.Bridge(FakeRpc(), friends_enabled=False, friends_scope="missing")
    missing.load_friends()
    check("a scope never asked for is not an error", missing.state["friendsError"] == "", missing.state)
    check("and is reported as missing", missing.state["friendsScope"] == "missing", missing.state)
    refused = rpc.Bridge(FakeRpc(), friends_enabled=False, friends_scope="refused", friends_reason="Unauthorized")
    refused.load_friends()
    check("a refused scope carries Discord's reason", "Unauthorized" in refused.state["friendsError"], refused.state)


@contextlib.contextmanager
def stubbed(**replacements):
    """Swap module functions for the duration of one case."""
    originals = {name: getattr(rpc, name) for name in replacements}
    for name, value in replacements.items():
        setattr(rpc, name, value)
    try:
        yield
    finally:
        for name, value in originals.items():
            setattr(rpc, name, value)


def a_cached_token_is_never_reprompted():
    """The loop the first release had: every reconnect asked Discord again."""
    asked = []
    with stubbed(valid_token=lambda *a: {"access_token": "t", "scope": "rpc"},
                 authorize=lambda *a: asked.append(a) or {}):
        token = rpc.obtain_token(None, "id", "secret")
    check("a cached token is used as is", token["access_token"] == "t", token)
    check("and Discord is not asked", asked == [], asked)


def a_first_authorization_asks_for_voice_only_once():
    asked = []
    with stubbed(valid_token=lambda *a: None,
                 authorize=lambda rpc_, cid, sec, scopes: asked.append(list(scopes)) or {"access_token": "t", "scope": " ".join(scopes)}):
        token = rpc.obtain_token(None, "id", "secret")
    check("exactly one consent", len(asked) == 1, asked)
    check("for the voice scopes only", asked[0] == rpc.BASE_SCOPES, asked)
    check("and the token comes back", token["access_token"] == "t", token)


def a_refused_authorization_is_fatal_not_a_loop():
    def refuse(*a):
        raise rpc.RpcRejected("declined")
    with stubbed(valid_token=lambda *a: None, authorize=refuse):
        try:
            rpc.obtain_token(None, "id", "secret")
            check("a refusal raises AuthorizationFailed", False, "no exception")
        except rpc.AuthorizationFailed as error:
            check("a refusal raises AuthorizationFailed, naming the cause", "declined" in str(error), error)
    check("AuthorizationFailed is still an RpcError", issubclass(rpc.AuthorizationFailed, rpc.RpcError))


def a_missing_redirect_is_explained_in_the_refusal():
    """The one refusal a first-time user hits, measured live: the portal had no redirect saved."""
    def refuse(*a):
        raise rpc.RpcRejected('OAuth2 Error: invalid_request: Missing "redirect_uri" in request.')
    with stubbed(valid_token=lambda *a: None, authorize=refuse):
        try:
            rpc.obtain_token(None, "id", "secret")
            check("a missing redirect raises", False, "no exception")
        except rpc.AuthorizationFailed as error:
            check("a missing redirect names the URI to register", rpc.REDIRECT_URI in str(error), error)
    check("other refusals get no hint", rpc.authorization_hint("declined") == "")


def granting_friends_uses_its_own_connection():
    """Measured live: AUTHORIZE on the bridge's authenticated socket answers "Already authenticated"."""
    sockets = []
    def fresh_socket():
        sockets.append(FakeSocket())
        return sockets[-1]
    with stubbed(connect_socket=fresh_socket, handshake=lambda r, c: {},
                 authorize=lambda r, cid, sec, scopes: {"access_token": "t2", "scope": " ".join(scopes)},
                 save_token=lambda t: None):
        token = rpc.grant_friends_scope("id", "secret")
    check("the grant opens a connection of its own", len(sockets) == 1, sockets)
    check("and closes it afterwards", sockets[0].closed)
    check("and the token carries the scope", rpc.friends_scope_state(token)[0] == "granted", token)


def granting_friends_records_a_refusal_with_its_reason():
    saved = []
    def refuse(*a):
        raise rpc.RpcRejected("Invalid scope")
    with stubbed(connect_socket=lambda: FakeSocket(), handshake=lambda r, c: {}, authorize=refuse,
                 load_token=lambda: {"access_token": "t", "scope": "rpc"},
                 save_token=lambda t: saved.append(t)):
        token = rpc.grant_friends_scope("id", "secret")
    scope, reason = rpc.friends_scope_state(token)
    check("a refused grant is remembered", scope == "refused" and token.get("friendsRefused") is True, token)
    check("with Discord's reason", reason == "Invalid scope", reason)
    check("and written to disk", saved == [token], saved)
    check("without losing the voice token", token["access_token"] == "t", token)


def granting_friends_detects_a_token_that_lacks_the_scope():
    saved = []
    with stubbed(connect_socket=lambda: FakeSocket(), handshake=lambda r, c: {},
                 authorize=lambda *a: {"access_token": "t2", "scope": "rpc rpc.voice.read rpc.voice.write"},
                 load_token=lambda: {"access_token": "t2", "scope": "rpc rpc.voice.read rpc.voice.write"},
                 save_token=lambda t: saved.append(t)):
        token = rpc.grant_friends_scope("id", "secret")
    scope, reason = rpc.friends_scope_state(token)
    check("a token without the scope reads as refused", scope == "refused", token)
    check("and names the scope", rpc.FRIENDS_SCOPE in reason, reason)
    granted = {"scope": "rpc " + rpc.FRIENDS_SCOPE}
    check("a token with the scope reads as granted", rpc.friends_scope_state(granted) == ("granted", ""))
    check("a plain token reads as missing", rpc.friends_scope_state({"scope": "rpc"}) == ("missing", ""))


def the_grant_command_reaches_the_bridge():
    bridge = rpc.Bridge(FakeRpc(), friends_enabled=False, client_id="id", client_secret="secret", friends_scope="missing")
    with stubbed(grant_friends_scope=lambda cid, sec: {"access_token": "t2", "scope": "rpc " + rpc.FRIENDS_SCOPE}):
        try:
            bridge.handle_command('{"cmd":"grantFriends"}')
            check("a granted scope restarts the session", False, "no restart")
        except rpc.SessionRestart:
            check("a granted scope restarts the session", True)
    refused = rpc.Bridge(FakeRpc(), friends_enabled=False, client_id="id", client_secret="secret", friends_scope="missing")
    with stubbed(grant_friends_scope=lambda cid, sec: {"access_token": "t", "scope": "rpc",
                                                       "friendsRefused": True, "friendsRefusedReason": "Invalid scope"}):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            refused.handle_command('{"cmd":"grantFriends"}')
    state = json.loads(out.getvalue().splitlines()[-1])
    check("a refused scope is reported in place",
          state["friendsScope"] == "refused" and "Invalid scope" in state["friendsError"], state)


def a_relationship_event_in_the_loop_emits_the_friend():
    frame = (rpc.OP_FRAME, {"cmd": "DISPATCH", "evt": "RELATIONSHIP_UPDATE",
                            "data": relationship(1, "1", "online", username="gm")})
    bridge = rpc.Bridge(FakeRpc([frame]))
    while not rpc.COMMANDS.empty():
        rpc.COMMANDS.get_nowait()
    with contextlib.redirect_stdout(io.StringIO()) as out:
        try:
            bridge.run()
        except rpc.RpcError:
            pass
    lines = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    check("the event reaches stdout as a friend",
          any(f["id"] == "1" and f["status"] == "online" for line in lines for f in line["friends"]),
          lines)


def snapshot_of(bridge):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        bridge.emit()
    return json.loads(out.getvalue().splitlines()[-1])


def rpc_rejected_carries_discords_code():
    check("a refusal keeps its code", rpc.RpcRejected("nope", 4005).code == 4005)
    check("and defaults to zero", rpc.RpcRejected("nope").code == 0)
    check("and a None code is zero", rpc.RpcRejected("nope", None).code == 0)


def list_channels_emits_its_own_line_kind():
    fake = FakeRpc()
    fake.answers = {
        "GET_GUILDS": {"guilds": [{"id": "10", "name": "GM's Server"}, {"id": "20", "name": "Text only"}]},
        "GET_CHANNELS": lambda args: {"channels": [
            {"id": "1", "name": "General", "type": 2}, {"id": "2", "name": "chat", "type": 0},
            {"id": "3", "name": "AFK", "type": 2}]} if args["guild_id"] == "10" else {"channels": [{"id": "9", "name": "chat", "type": 0}]},
    }
    bridge = rpc.Bridge(fake)
    with contextlib.redirect_stdout(io.StringIO()) as out:
        bridge.list_channels()
    line = json.loads(out.getvalue().splitlines()[-1])
    check("the listing is its own kind", line.get("kind") == "channels" and "ok" not in line, line)
    check("only voice channels are listed", [c["id"] for c in line["guilds"][0]["channels"]] == ["1", "3"], line)
    check("a guild without voice channels is left out", [g["id"] for g in line["guilds"]] == ["10"], line)
    check("guild names are cached for later lookups", bridge.guilds.get("10") == "GM's Server", bridge.guilds)


def a_refused_guild_listing_skips_that_guild_only():
    fake = FakeRpc()
    fake.answers = {
        "GET_GUILDS": {"guilds": [{"id": "10", "name": "Refusing"}, {"id": "20", "name": "Open"}]},
        "GET_CHANNELS": lambda args: (_ for _ in ()).throw(rpc.RpcRejected("Unauthorized", 4006)) if args["guild_id"] == "10"
        else {"channels": [{"id": "5", "name": "Voice", "type": 2}]},
    }
    with captured_warnings() as warnings:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rpc.Bridge(fake).list_channels()
    line = json.loads(out.getvalue().splitlines()[-1])
    check("the open guild is still listed", [g["id"] for g in line["guilds"]] == ["20"], line)
    check("and the refusal is warned about by guild", any("10" in w for w in warnings), warnings)


def a_join_sends_select_voice_channel_with_force_and_timeout():
    fake = FakeRpc()
    bridge = rpc.Bridge(fake)
    bridge.handle_command('{"cmd":"join","channelId":"123"}')
    check("a join is one SELECT_VOICE_CHANNEL",
          fake.commands == [("SELECT_VOICE_CHANNEL", {"channel_id": "123", "timeout": rpc.JOIN_TIMEOUT_SEC, "force": True})],
          fake.commands)
    check("and its nonce is remembered against the channel", list(bridge.pending_joins.values()) == ["123"], bridge.pending_joins)


def a_join_with_a_bad_id_never_reaches_discord():
    fake = FakeRpc()
    with captured_warnings() as warnings:
        rpc.Bridge(fake).handle_command('{"cmd":"join","channelId":"general"}')
    check("a non-numeric id is refused before Discord sees it", fake.commands == [], fake.commands)
    check("and named in the warning", any("general" in w for w in warnings), warnings)


def a_refused_join_lands_in_the_snapshot_with_its_code():
    error = (rpc.OP_FRAME, {"cmd": "SELECT_VOICE_CHANNEL", "evt": "ERROR", "nonce": "0",
                            "data": {"code": 4005, "message": "Invalid Channel Id"}})
    fake = FakeRpc([error])
    bridge = rpc.Bridge(fake)
    bridge.pending_joins["0"] = "123"
    with captured_warnings():
        with contextlib.redirect_stdout(io.StringIO()) as out:
            try:
                bridge.run()
            except rpc.RpcError:
                pass
    lines = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    check("the refusal is emitted with channel, code and message",
          any(line.get("joinError") == {"channelId": "123", "code": 4005, "message": "Invalid Channel Id"} for line in lines), lines)
    check("and the nonce is forgotten", bridge.pending_joins == {}, bridge.pending_joins)


def a_join_reply_clears_the_pending_nonce():
    reply = (rpc.OP_FRAME, {"cmd": "SELECT_VOICE_CHANNEL", "nonce": "0", "data": {"id": "123"}})
    bridge = rpc.Bridge(FakeRpc([reply]))
    bridge.pending_joins["0"] = "123"
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            bridge.run()
        except rpc.RpcError:
            pass
    check("a successful reply forgets the nonce without an error", bridge.pending_joins == {} and bridge.state["joinError"] == {})


def a_channel_select_clears_the_join_error_and_names_the_id():
    fake = FakeRpc()
    fake.answers = {"GET_CHANNEL": {"name": "General", "guild_id": "10", "voice_states": []}, "GET_GUILD": {"name": "GM's Server"}}
    bridge = rpc.Bridge(fake)
    bridge.state["joinError"] = {"channelId": "123", "code": 4005, "message": "x"}
    bridge.select_channel("123")
    check("landing in a channel clears the error", bridge.state["joinError"] == {})
    check("and the snapshot names the selected id", bridge.state["channelId"] == "123")
    bridge.select_channel(None)
    check("leaving empties the id", bridge.state["channelId"] == "")


def refresh_counts_only_the_channels_it_is_asked_about():
    fake = FakeRpc()
    fake.answers = {
        "GET_SELECTED_VOICE_CHANNEL": {},
        "GET_CHANNEL": lambda args: {"1": {"voice_states": [{}, {}]}, "2": {"voice_states": []}}.get(args["channel_id"])
        or (_ for _ in ()).throw(rpc.RpcRejected("Unknown Channel", 4005)),
    }
    bridge = rpc.Bridge(fake)
    with contextlib.redirect_stdout(io.StringIO()):
        bridge.handle_command('{"cmd":"refresh","channels":["1","2","3","general"]}')
    check("counts come back per channel", bridge.state["channelCounts"] == {"1": 2, "2": 0}, bridge.state["channelCounts"])


def has_scope_reads_discords_space_separated_list():
    token = {"scope": "rpc rpc.voice.read relationships.read"}
    check("a granted scope is found", rpc.has_scope(token, "relationships.read"))
    check("a prefix is not a scope", not rpc.has_scope(token, "rpc.voice"))
    check("a missing token has no scopes", not rpc.has_scope({}, "rpc"))
    check("None is tolerated", not rpc.has_scope(None, "rpc"))


def main():
    for case in (leftover_temporary_cannot_widen_a_secret,
                 a_symlink_cannot_redirect_the_token,
                 a_bad_command_value_never_raises,
                 a_good_command_value_reaches_discord,
                 as_number_rejects_both_bad_shapes,
                 an_unknown_command_is_named,
                 a_refused_fire_and_forget_command_is_not_silent,
                 the_public_key_is_refused_as_a_secret,
                 a_clipped_warning_marks_the_cut,
                 a_refusal_warning_clips_the_command,
                 a_refusal_is_still_an_rpc_error,
                 a_friend_entry_reads_name_and_presence,
                 unreachable_presences_read_as_offline,
                 a_non_friend_relationship_is_not_a_friend,
                 the_bridge_tracks_relationship_updates,
                 load_friends_lists_and_subscribes,
                 a_refused_friend_list_leaves_voice_alone,
                 a_relationship_event_in_the_loop_emits_the_friend,
                 has_scope_reads_discords_space_separated_list,
                 rpc_rejected_carries_discords_code,
                 list_channels_emits_its_own_line_kind,
                 a_refused_guild_listing_skips_that_guild_only,
                 a_join_sends_select_voice_channel_with_force_and_timeout,
                 a_join_with_a_bad_id_never_reaches_discord,
                 a_refused_join_lands_in_the_snapshot_with_its_code,
                 a_join_reply_clears_the_pending_nonce,
                 a_channel_select_clears_the_join_error_and_names_the_id,
                 refresh_counts_only_the_channels_it_is_asked_about,
                 a_cached_token_is_never_reprompted,
                 a_first_authorization_asks_for_voice_only_once,
                 a_refused_authorization_is_fatal_not_a_loop,
                 a_missing_redirect_is_explained_in_the_refusal,
                 granting_friends_uses_its_own_connection,
                 granting_friends_records_a_refusal_with_its_reason,
                 granting_friends_detects_a_token_that_lacks_the_scope,
                 the_grant_command_reaches_the_bridge):
        case()
    print("\n%d failed" % len(FAILURES) if FAILURES else "\nall passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
